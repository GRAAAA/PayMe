import UIKit

enum ReceiptConfidenceLevel: Sendable, Equatable {
    case accepted
    case needsReview
    case poor

    init(confidence: Double) {
        if confidence >= ReceiptScanPolicy.autoAcceptConfidence {
            self = .accepted
        } else if confidence >= ReceiptScanPolicy.needsReviewConfidence {
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

enum ReceiptScanPolicy {
    static let autoAcceptConfidence = 0.82
    static let needsReviewConfidence = 0.65
    static let maximumQuantity = 99
    static let subtotalToleranceInCents = 2
    static let totalToleranceInCents = 2
}

struct ReceiptExtractionPipeline {
    private let smartAI: GeminiReceiptExtractor
    private let localOCR: ReceiptOCRService
    private let validator: ReceiptScanValidator

    init(
        smartAI: GeminiReceiptExtractor = GeminiReceiptExtractor(),
        localOCR: ReceiptOCRService = ReceiptOCRService(),
        validator: ReceiptScanValidator = ReceiptScanValidator()
    ) {
        self.smartAI = smartAI
        self.localOCR = localOCR
        self.validator = validator
    }

    func parse(images: [UIImage]) async throws -> ParsedReceipt {
        if smartAI.isConfigured {
            do {
                return validator.validate(try await smartAI.parse(images: images))
            } catch {
                // Quiet fallback only when the proxy cannot produce a result.
                // Avoids exposing infrastructure issues to the user.
            }
        }

        return validator.validate(try await localOCR.parse(images: images))
    }
}

struct ReceiptScanValidator {
    func validate(_ receipt: ParsedReceipt) -> ParsedReceipt {
        var validated = receipt
        var warnings = Set(receipt.warnings)
        var excluded = receipt.excludedLines

        let storeName = receipt.storeName.trimmingCharacters(in: .whitespacesAndNewlines)
        validated.storeName = storeName.isEmpty ? "New receipt" : storeName
        if storeName.isEmpty {
            warnings.insert("Please check the restaurant or store name.")
        }

        if let date = receipt.date, date > Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now {
            validated.date = nil
            warnings.insert("The detected date looked wrong, so it was not used.")
        }

        validated.items = receipt.items.compactMap { item in
            let name = cleanName(item.name)
            let quantity = min(max(item.quantity, 1), ReceiptScanPolicy.maximumQuantity)
            var confidence = min(max(item.confidence, 0), 1)

            guard !name.isEmpty, item.price > 0 else {
                excluded.append(
                    ExcludedReceiptLine(
                        text: "\(item.name) \(item.price)",
                        suggestedName: name,
                        amount: item.price > 0 ? item.price : nil,
                        reason: "Not added because the item name or price looked invalid"
                    )
                )
                warnings.insert("Some weak item rows need review.")
                return nil
            }

            if name.count <= 2 || quantity != item.quantity {
                confidence = min(confidence, 0.72)
                warnings.insert("Some weak item rows need review.")
            }

            return ParsedItem(
                name: name,
                price: item.price,
                quantity: quantity,
                confidence: confidence
            )
        }

        validated.tax = max(0, receipt.tax)
        validated.discounts = receipt.discounts.compactMap { discount in
            guard discount.amount > 0 else { return nil }
            let name = cleanName(discount.name)
            return ParsedDiscount(name: name.isEmpty ? "Discount" : name, amount: discount.amount)
        }
        validated.currencyCode = receipt.currencyCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        applySubtotalValidation(to: &validated, warnings: &warnings)
        applyTotalValidation(to: &validated, warnings: &warnings)

        validated.confidence = min(max(validated.confidence, 0), 1)
        validated.warnings = warnings.sorted()
        validated.excludedLines = excluded
        return validated
    }

    private func applySubtotalValidation(to receipt: inout ParsedReceipt, warnings: inout Set<String>) {
        guard let subtotal = receipt.subtotal else { return }
        let discountTotal = receipt.discounts.reduce(Decimal.zero) { $0 + $1.amount }
        let itemsTotal = receipt.items.reduce(Decimal.zero) { $0 + $1.price * Decimal($1.quantity) }
        let matchesSubtotal = cents(itemsTotal, subtotal) <= ReceiptScanPolicy.subtotalToleranceInCents
        let matchesBeforeDiscount = cents(itemsTotal, subtotal + discountTotal) <= ReceiptScanPolicy.subtotalToleranceInCents

        guard !matchesSubtotal && !matchesBeforeDiscount else { return }
        warnings.insert("Item prices do not match the printed subtotal.")
        capConfidence(of: &receipt, at: 0.78)
    }

    private func applyTotalValidation(to receipt: inout ParsedReceipt, warnings: inout Set<String>) {
        guard let total = receipt.total else {
            warnings.insert("The printed total was not confidently detected.")
            capConfidence(of: &receipt, at: 0.78)
            return
        }

        let itemTotal = receipt.items.reduce(Decimal.zero) { $0 + $1.price * Decimal($1.quantity) }
        let discountTotal = receipt.discounts.reduce(Decimal.zero) { $0 + $1.amount }
        let calculated = max(0, itemTotal - discountTotal + receipt.tax + receipt.rounding)
        guard cents(calculated, total) > ReceiptScanPolicy.totalToleranceInCents else { return }

        warnings.insert("The detected total does not match the item, discount, and tax amounts.")
        capConfidence(of: &receipt, at: 0.74)
    }

    private func capConfidence(of receipt: inout ParsedReceipt, at maximum: Double) {
        receipt.confidence = min(receipt.confidence, maximum)
        receipt.items = receipt.items.map {
            ParsedItem(
                name: $0.name,
                price: $0.price,
                quantity: $0.quantity,
                confidence: min($0.confidence, maximum)
            )
        }
    }

    private func cleanName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func cents(_ left: Decimal, _ right: Decimal) -> Int {
        abs(NSDecimalNumber(decimal: (left - right) * 100).intValue)
    }
}
