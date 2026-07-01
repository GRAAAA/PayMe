import Foundation
import UIKit

/// Production-safe extractor: the iPhone app calls our Cloudflare Worker,
/// and the Worker calls Gemini with a server-side secret.
///
/// The Gemini API key must never be shipped in the app bundle.
struct GeminiReceiptExtractor {
    private let defaultProxyURL = "https://payme.antonyhyeon.workers.dev/scan-receipt"

    var isConfigured: Bool {
        proxyURL != nil
    }

    func parse(images: [UIImage]) async throws -> ParsedReceipt {
        guard let proxyURL else { throw ProxyExtractionError.missingProxyURL }

        let payload = ProxyReceiptRequest(
            images: images.prefix(1).compactMap { image in
                image.normalizedForProxy().jpegData(compressionQuality: 0.62)?.base64EncodedString()
            }
        )
        guard !payload.images.isEmpty else { throw ProxyExtractionError.invalidImage }

        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PayMe-iOS", forHTTPHeaderField: "X-PayMe-Client")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProxyExtractionError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProxyExtractionError.serverRejected(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ProxyReceiptResponse.self, from: data)
        return decoded.parsedReceipt
    }

    private var proxyURL: URL? {
        let configured = UserDefaults.standard.string(forKey: "payme.proxyURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return URL(string: configured.isEmpty ? defaultProxyURL : configured)
    }
}

private enum ProxyExtractionError: Error {
    case missingProxyURL
    case invalidImage
    case badResponse
    case serverRejected(Int)
}

private struct ProxyReceiptRequest: Encodable {
    var images: [String]
}

private struct ProxyReceiptResponse: Decodable {
    var storeName: String
    var date: String?
    var currencyCode: String?
    var items: [ProxyParsedItem]
    var discounts: [ProxyParsedDiscount]
    var tax: Double
    var rounding: Double
    var subtotal: Double?
    var total: Double?
    var confidence: Double
    var warnings: [String]
    var excludedLines: [ProxyExcludedLine]

    var parsedReceipt: ParsedReceipt {
        let cleanStoreName = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedItems = items
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.price > 0 }
            .map {
                ParsedItem(
                    name: $0.name,
                    price: NSDecimalNumber(value: $0.price).decimalValue,
                    quantity: max(1, $0.quantity),
                    confidence: min(max($0.confidence, 0), 1)
                )
            }
        let parsedDiscounts = discounts
            .filter { $0.amount > 0 }
            .map {
                ParsedDiscount(
                    name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Discount" : $0.name,
                    amount: NSDecimalNumber(value: $0.amount).decimalValue
                )
            }

        return ParsedReceipt(
            storeName: cleanStoreName.isEmpty ? "New receipt" : cleanStoreName,
            date: date.flatMap(Self.parseDate),
            items: parsedItems,
            discounts: parsedDiscounts,
            tax: NSDecimalNumber(value: max(0, tax)).decimalValue,
            rounding: NSDecimalNumber(value: rounding).decimalValue,
            subtotal: subtotal.map { NSDecimalNumber(value: $0).decimalValue },
            total: total.map { NSDecimalNumber(value: $0).decimalValue },
            currencyCode: currencyCode?.uppercased() ?? "",
            confidence: min(max(confidence, 0), 1),
            warnings: warnings,
            excludedLines: excludedLines.map {
                ExcludedReceiptLine(
                    text: $0.text,
                    suggestedName: "",
                    amount: nil,
                    reason: $0.reason
                )
            }
        )
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formats = ["yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "dd-MMM-yy", "dd-MMM-yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

private struct ProxyParsedItem: Decodable {
    var name: String
    var price: Double
    var quantity: Int
    var confidence: Double
}

private struct ProxyParsedDiscount: Decodable {
    var name: String
    var amount: Double
}

private struct ProxyExcludedLine: Decodable {
    var text: String
    var reason: String
}

private extension UIImage {
    func normalizedForProxy(maxDimension: CGFloat = 1400) -> UIImage {
        let longest = max(size.width, size.height)
        let scale = min(1, maxDimension / max(longest, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
