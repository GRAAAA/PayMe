import UIKit
import Vision
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins

struct ReceiptOCRService {
    func parse(images: [UIImage]) async throws -> ParsedReceipt {
        let pages = try await withThrowingTaskGroup(of: (Int, [RecognizedLine]).self) { group in
            for (page, image) in images.enumerated() {
                group.addTask {
                    let variants = ReceiptImageProcessor.variants(for: image)
                    var passes: [[RecognizedLine]] = []

                    for (index, variant) in variants.enumerated() {
                        let lines = try await recognize(
                            variant,
                            page: page,
                            usesLanguageCorrection: index == 0
                        )
                        passes.append(lines)
                    }

                    return (page, OCRCandidateMerger.merge(passes))
                }
            }
            var result: [(Int, [RecognizedLine])] = []
            for try await page in group { result.append(page) }
            return result.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        let lines = pages.flatMap { $0 }
        return ReceiptParser.parse(
            lines: lines,
            corrections: ReceiptCorrectionStore.hints()
        )
    }

    private func recognize(
        _ image: UIImage,
        page: Int,
        usesLanguageCorrection: Bool
    ) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { observation -> RecognizedLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedLine(
                        text: candidate.string,
                        bounds: observation.boundingBox,
                        confidence: candidate.confidence,
                        page: page
                    )
                } ?? []
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = usesLanguageCorrection
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.005
            request.customWords = [
                "subtotal", "total", "tax", "SST", "GST", "service",
                "rounding", "quantity", "qty", "cashier", "invoice"
            ]
            do {
                try VNImageRequestHandler(
                    cgImage: cgImage,
                    orientation: .up
                ).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private enum ReceiptImageProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let maximumDimension: CGFloat = 3_200

    static func variants(for image: UIImage) -> [UIImage] {
        let normalized = normalizeAndResize(image)
        guard let input = CIImage(image: normalized) else { return [normalized] }

        let controls = CIFilter.colorControls()
        controls.inputImage = input
        controls.saturation = 0
        controls.contrast = 1.35
        controls.brightness = 0.04

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = controls.outputImage
        sharpen.sharpness = 0.65

        guard
            let output = sharpen.outputImage,
            let cgImage = context.createCGImage(output, from: output.extent)
        else {
            return [normalized]
        }

        return [normalized, UIImage(cgImage: cgImage)]
    }

    private static func normalizeAndResize(_ image: UIImage) -> UIImage {
        let sourceSize = image.size
        let longestSide = max(sourceSize.width, sourceSize.height)
        let scale = min(1, maximumDimension / max(longestSide, 1))
        let targetSize = CGSize(
            width: max(1, sourceSize.width * scale),
            height: max(1, sourceSize.height * scale)
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

enum OCRCandidateMerger {
    static func merge(_ passes: [[RecognizedLine]]) -> [RecognizedLine] {
        var merged: [RecognizedLine] = []

        for candidate in passes.flatMap({ $0 }) where !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let index = merged.firstIndex(where: { sameObservation($0, candidate) }) {
                if quality(candidate) > quality(merged[index]) {
                    merged[index] = candidate
                }
            } else {
                merged.append(candidate)
            }
        }

        return merged.sorted {
            if $0.page != $1.page { return $0.page < $1.page }
            if abs($0.midY - $1.midY) > 0.004 { return $0.midY > $1.midY }
            return $0.minX < $1.minX
        }
    }

    private static func sameObservation(_ lhs: RecognizedLine, _ rhs: RecognizedLine) -> Bool {
        guard lhs.page == rhs.page else { return false }

        let verticalOverlap = overlap(
            lhs.bounds.minY...lhs.bounds.maxY,
            rhs.bounds.minY...rhs.bounds.maxY
        ) / max(min(lhs.bounds.height, rhs.bounds.height), 0.0001)
        let horizontalOverlap = overlap(
            lhs.bounds.minX...lhs.bounds.maxX,
            rhs.bounds.minX...rhs.bounds.maxX
        ) / max(min(lhs.bounds.width, rhs.bounds.width), 0.0001)

        if verticalOverlap >= 0.55 && horizontalOverlap >= 0.65 {
            return true
        }

        let normalizedLeft = normalize(lhs.text)
        let normalizedRight = normalize(rhs.text)
        let centersAreClose = abs(lhs.bounds.midX - rhs.bounds.midX) < 0.025
            && abs(lhs.bounds.midY - rhs.bounds.midY) < 0.012
        return centersAreClose
            && (normalizedLeft == normalizedRight
                || normalizedLeft.contains(normalizedRight)
                || normalizedRight.contains(normalizedLeft))
    }

    private static func overlap(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound))
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func quality(_ line: RecognizedLine) -> Double {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var score = Double(line.confidence)
        score += Double(min(text.count, 60)) * 0.002

        if text.range(of: #"\d+[.,]\d{2}\b"#, options: .regularExpression) != nil {
            score += 0.05
        }
        if text.rangeOfCharacter(from: .letters) != nil {
            score += 0.02
        }
        if text.count <= 2 {
            score -= 0.08
        }
        return score
    }
}

private enum OCRError: Error {
    case invalidImage
}
