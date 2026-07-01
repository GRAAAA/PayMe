import UIKit

enum ReceiptConfidenceLevel: Sendable, Equatable {
    case accepted
    case needsReview
    case poor

    init(confidence: Double) {
        if confidence >= 0.82 {
            self = .accepted
        } else if confidence >= 0.65 {
            self = .needsReview
        } else {
            self = .poor
        }
    }

    var message: String? {
        switch self {
        case .accepted:
            nil
        case .needsReview:
            "Please quickly check the scanned items."
        case .poor:
            "This receipt was hard to read. Please check it or retake the photo."
        }
    }
}

struct ReceiptExtractionPipeline {
    private let smartAI: GeminiReceiptExtractor
    private let localOCR: ReceiptOCRService

    init(
        smartAI: GeminiReceiptExtractor = GeminiReceiptExtractor(),
        localOCR: ReceiptOCRService = ReceiptOCRService()
    ) {
        self.smartAI = smartAI
        self.localOCR = localOCR
    }

    func parse(images: [UIImage]) async throws -> ParsedReceipt {
        if smartAI.isConfigured {
            do {
                return try await smartAI.parse(images: images)
            } catch {
                // Quiet fallback only when the proxy cannot produce a result.
                // Avoids exposing infrastructure issues to the user.
            }
        }

        return try await localOCR.parse(images: images)
    }
}
