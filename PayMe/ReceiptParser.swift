import Foundation
import CoreGraphics

// MARK: - OCR input

struct RecognizedLine: Sendable {
    let text: String
    let bounds: CGRect
    let confidence: Float
    let page: Int

    init(
        text: String,
        bounds: CGRect,
        confidence: Float = 1,
        page: Int = 0
    ) {
        self.text = text
        self.bounds = bounds
        self.confidence = confidence
        self.page = page
    }

    init(
        text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 0.2,
        height: CGFloat = 0.018,
        confidence: Float = 1,
        page: Int = 0
    ) {
        self.init(
            text: text,
            bounds: CGRect(x: x, y: y - height / 2, width: width, height: height),
            confidence: confidence,
            page: page
        )
    }

    var minX: CGFloat { bounds.minX }
    var maxX: CGFloat { bounds.maxX }
    var midY: CGFloat { bounds.midY }
    var height: CGFloat { bounds.height }
}

// MARK: - Structured output

struct ParsedReceipt: Sendable {
    var storeName: String
    var date: Date?
    var items: [ParsedItem]
    var discounts: [ParsedDiscount]
    var tax: Decimal
    var rounding: Decimal
    var subtotal: Decimal?
    var total: Decimal?
    var currencyCode: String
    var confidence: Double
    var warnings: [String]
    var excludedLines: [ExcludedReceiptLine]
}

struct ParsedDiscount: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var amount: Decimal
}

struct ParsedItem: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var price: Decimal
    var quantity: Int
    var confidence: Double
}

struct ExcludedReceiptLine: Identifiable, Sendable {
    let id = UUID()
    var text: String
    var suggestedName: String
    var amount: Decimal?
    var reason: String
}

struct ReceiptCorrectionHints: Sendable {
    var acceptedNames: Set<String> = []
    var rejectedNames: Set<String> = []
}

enum ReceiptCorrectionStore {
    private static let acceptedKey = "payme.receipt.accepted-item-names"
    private static let rejectedKey = "payme.receipt.rejected-item-names"
    private static let maximumEntries = 250

    static func hints() -> ReceiptCorrectionHints {
        ReceiptCorrectionHints(
            acceptedNames: Set(UserDefaults.standard.stringArray(forKey: acceptedKey) ?? []),
            rejectedNames: Set(UserDefaults.standard.stringArray(forKey: rejectedKey) ?? [])
        )
    }

    static func rememberAccepted(_ name: String) {
        update(name, addTo: acceptedKey, removeFrom: rejectedKey)
    }

    static func rememberRejected(_ name: String) {
        update(name, addTo: rejectedKey, removeFrom: acceptedKey)
    }

    private static func update(_ name: String, addTo: String, removeFrom: String) {
        let key = correctionKey(name)
        guard key.count >= 3 else { return }

        var destination = UserDefaults.standard.stringArray(forKey: addTo) ?? []
        destination.removeAll(where: { $0 == key })
        destination.append(key)
        if destination.count > maximumEntries {
            destination.removeFirst(destination.count - maximumEntries)
        }
        UserDefaults.standard.set(destination, forKey: addTo)

        var opposite = UserDefaults.standard.stringArray(forKey: removeFrom) ?? []
        opposite.removeAll(where: { $0 == key })
        UserDefaults.standard.set(opposite, forKey: removeFrom)
    }
}

// MARK: - Pipeline

enum ReceiptParser {
    static func parse(
        lines: [RecognizedLine],
        corrections: ReceiptCorrectionHints = ReceiptCorrectionHints()
    ) -> ParsedReceipt {
        let document = ReceiptDocument(lines: lines)
        var totals = TotalsExtractor.extract(from: document)
        if totals.subtotal == nil,
           let total = totals.total,
           let tax = totals.tax {
            let inferred = total - tax - (totals.rounding ?? 0)
            if inferred > 0 { totals.subtotal = inferred }
        }
        let section = ItemSectionDetector.detect(in: document, totals: totals)
        let merchant = MerchantExtractor.extract(from: document, before: section?.topY)
        let extraction = ItemExtractor.extract(
            from: document,
            section: section,
            subtotal: totals.subtotal,
            corrections: corrections
        )
        let candidates = extraction.candidates
        let discounts = DiscountExtractor.extract(from: document)
        let discountTotal = discounts.reduce(Decimal.zero) { $0 + $1.amount }
        if totals.subtotal == nil, let total = totals.total {
            let candidateSum = candidates.reduce(Decimal.zero) { $0 + $1.lineTotal }
            if abs(cents(candidateSum) - cents(total)) <= 1 {
                totals.subtotal = candidateSum
                if totals.tax == nil { totals.tax = 0 }
            }
        }
        let reconciliationSubtotal: Decimal? = {
            guard let subtotal = totals.subtotal, discountTotal > 0 else {
                return totals.subtotal
            }
            let candidateSum = candidates.reduce(Decimal.zero) { $0 + $1.lineTotal }
            if abs(cents(candidateSum) - cents(subtotal + discountTotal)) <= 2 {
                return subtotal + discountTotal
            }
            return subtotal
        }()
        let reconciled = ReceiptReconciler.reconcile(
            candidates: candidates,
            subtotal: reconciliationSubtotal
        )
        let verificationExclusions = reconciled.rejected.map {
            ExcludedReceiptLine(
                text: "\($0.item.name) \(formatMoney($0.lineTotal))",
                suggestedName: $0.item.name,
                amount: $0.lineTotal,
                reason: "Not added because the amount could not be verified against the receipt subtotal"
            )
        }
        let currency = CurrencyExtractor.extract(from: document)
        let date = ReceiptDateExtractor.extract(from: document)

        var tax: Decimal = 0
        var rejectedTax = false
        if let subtotal = totals.subtotal, let total = totals.total {
            let candidateSum = candidates.reduce(Decimal.zero) { $0 + $1.lineTotal }
            let subtotalIsAfterDiscount =
                discountTotal > 0 &&
                abs(cents(candidateSum) - cents(subtotal + discountTotal)) <= 2
            let beforeDiscountTax =
                total - subtotal + discountTotal - (totals.rounding ?? 0)
            let afterDiscountTax =
                total - subtotal - (totals.rounding ?? 0)
            let maximumTax = max(subtotal, reconciliationSubtotal ?? subtotal) *
                Decimal(string: "0.30")!
            let derivedCandidates = subtotalIsAfterDiscount
                ? [afterDiscountTax, beforeDiscountTax]
                : [beforeDiscountTax, afterDiscountTax]
            let plausibleDerived = derivedCandidates.first {
                $0 >= 0 && $0 <= maximumTax
            }
            if let plausibleDerived {
                tax = plausibleDerived
            } else if let printedTax = totals.tax,
                      printedTax >= 0,
                      printedTax <= subtotal * Decimal(string: "0.30")!,
                      abs(cents(subtotal - discountTotal + printedTax + (totals.rounding ?? 0)) - cents(total)) <= 2 {
                tax = printedTax
            } else {
                rejectedTax = totals.tax != nil
            }
        } else if let printedTax = totals.tax,
                  let subtotal = totals.subtotal,
                  printedTax >= 0,
                  printedTax <= subtotal * Decimal(string: "0.30")! {
            tax = printedTax
        }

        var warnings = reconciled.warnings
        if rejectedTax {
            warnings.append("An implausible tax value was ignored. Please check tax manually.")
        }
        if merchant.confidence < 0.55 {
            warnings.append("Please check the restaurant or store name.")
        }
        if reconciled.items.isEmpty {
            warnings.append("No reliable item rows were found. Add or correct items manually.")
        }
        if let subtotal = totals.subtotal {
            let itemSum = reconciled.items.lineTotal
            let matchesBeforeDiscount = abs(cents(itemSum) - cents(subtotal)) <= 1
            let matchesAfterDiscount =
                abs(cents(itemSum) - cents(subtotal + discountTotal)) <= 2
            if !matchesBeforeDiscount && !matchesAfterDiscount {
                warnings.append("Item prices do not match the printed subtotal.")
            }
        }
        if totals.total == nil {
            warnings.append("The printed total was not confidently detected.")
        }

        let confidenceParts = [
            merchant.confidence,
            reconciled.confidence,
            totals.confidence
        ]
        let confidence = confidenceParts.reduce(0, +) / Double(confidenceParts.count)

        return ParsedReceipt(
            storeName: merchant.name,
            date: date,
            items: reconciled.items,
            discounts: discounts,
            tax: tax,
            rounding: totals.rounding ?? 0,
            subtotal: totals.subtotal,
            total: totals.total,
            currencyCode: currency,
            confidence: confidence,
            warnings: Array(Set(warnings)).sorted(),
            excludedLines: deduplicateExcluded(
                extraction.excluded + verificationExclusions
            )
        )
    }
}

// MARK: - Discounts

private enum DiscountExtractor {
    static func extract(from document: ReceiptDocument) -> [ParsedDiscount] {
        let extracted: [ParsedDiscount] = document.rows.compactMap { row -> ParsedDiscount? in
            guard SemanticRules.isDiscount(row.normalized),
                  let rawAmount = MoneyParser.last(in: row.text)
            else { return nil }

            let amount = abs(rawAmount)
            guard amount > 0 else { return nil }

            var name = MoneyParser.removingTrailingValue(from: row.text)
            name = name.replacingOccurrences(
                of: #"^\s*(?:discount|promo(?:tion)?|voucher|coupon)\s*:?\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            name = cleanWhitespace(name)
            if name.isEmpty { name = "Discount" }

            return ParsedDiscount(name: name, amount: amount)
        }
        return extracted.reduce(into: [ParsedDiscount]()) { result, discount in
            let duplicate = result.contains {
                correctionKey($0.name) == correctionKey(discount.name) &&
                    abs(cents($0.amount) - cents(discount.amount)) <= 1
            }
            if !duplicate { result.append(discount) }
        }
    }
}

// MARK: - Document model

private struct ReceiptDocument {
    let lines: [RecognizedLine]
    let rows: [ReceiptRow]
    let medianHeight: CGFloat

    init(lines: [RecognizedLine]) {
        self.lines = lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if $0.page != $1.page { return $0.page < $1.page }
                if abs($0.midY - $1.midY) > 0.002 { return $0.midY > $1.midY }
                return $0.minX < $1.minX
            }
        medianHeight = Self.median(
            self.lines.map(\.height).filter { $0 > 0.002 }
        ) ?? 0.018
        rows = Self.buildRows(lines: self.lines, medianHeight: medianHeight)
    }

    private static func buildRows(
        lines: [RecognizedLine],
        medianHeight: CGFloat
    ) -> [ReceiptRow] {
        var rows: [ReceiptRow] = []
        // Keep physical rows narrow. Perspective skew is handled later by
        // column matching; a broad tolerance merges adjacent receipt lines.
        let tolerance = max(0.0025, medianHeight * 0.30)

        for line in lines {
            if let index = rows.indices.last,
               rows[index].page == line.page,
               abs(rows[index].midY - line.midY) <= tolerance {
                rows[index].fragments.append(line)
                rows[index].recalculate()
            } else {
                rows.append(ReceiptRow(fragments: [line]))
            }
        }
        return rows.map {
            var row = $0
            row.fragments.sort { $0.minX < $1.minX }
            row.recalculate()
            return row
        }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

private struct ReceiptRow {
    var fragments: [RecognizedLine]
    var page = 0
    var midY: CGFloat = 0
    var minX: CGFloat = 0
    var maxX: CGFloat = 0

    init(fragments: [RecognizedLine]) {
        self.fragments = fragments
        recalculate()
    }

    mutating func recalculate() {
        page = fragments.first?.page ?? 0
        midY = fragments.map(\.midY).reduce(0, +) / CGFloat(max(fragments.count, 1))
        minX = fragments.map(\.minX).min() ?? 0
        maxX = fragments.map(\.maxX).max() ?? 0
    }

    var text: String {
        fragments.map(\.text).joined(separator: " ")
    }

    var normalized: String { normalize(text) }
    var confidence: Double {
        guard !fragments.isEmpty else { return 0 }
        return Double(fragments.map(\.confidence).reduce(0, +)) / Double(fragments.count)
    }
}

// MARK: - Merchant

private enum MerchantExtractor {
    struct Result {
        let name: String
        let confidence: Double
    }

    static func extract(from document: ReceiptDocument, before topY: CGFloat?) -> Result {
        let candidates = document.lines.filter { line in
            if let topY, line.midY <= topY { return false }
            let text = cleanWhitespace(line.text)
            let lower = normalize(text)
            return text.filter(\.isLetter).count >= 3 &&
                !SemanticRules.isMetadata(lower) &&
                !SemanticRules.isAddress(lower) &&
                !SemanticRules.isTableHeader(lower) &&
                !SemanticRules.isCategory(lower) &&
                ItemTextParser.explicitQuantity(in: text) == nil &&
                MoneyParser.last(in: text) == nil
        }

        guard let best = candidates.max(by: {
            score($0, anchorY: topY) < score($1, anchorY: topY)
        }) else {
            return Result(name: "Scanned receipt", confidence: 0)
        }
        return Result(
            name: cleanMerchantName(best.text),
            confidence: min(1, max(0.35, score(best, anchorY: topY) / 22))
        )
    }

    private static func score(_ line: RecognizedLine, anchorY: CGFloat?) -> Double {
        let text = cleanWhitespace(line.text)
        let words = text.split(separator: " ").count
        let letters = text.filter(\.isLetter).count
        let centered = 1 - min(abs(Double(line.bounds.midX) - 0.5), 0.5) * 2
        let concise = words <= 5 ? 4.0 : 0
        let upperRatio = Double(text.filter(\.isUppercase).count) / Double(max(letters, 1))
        let brandMark = text.lowercased().hasSuffix("x") ? 4.0 : 0
        let legalSuffixPenalty = normalize(text).contains("sdn bhd") ? 3.0 : 0
        let proximity: Double
        if let anchorY {
            let distance = max(0, Double(line.midY - anchorY))
            proximity = max(0, 1 - distance / 0.35) * 9
        } else {
            proximity = 0
        }
        return min(Double(letters), 24) * 0.12 +
            centered * 5 +
            concise +
            upperRatio * 2 +
            Double(line.confidence) * 3 +
            proximity +
            brandMark -
            legalSuffixPenalty
    }

    private static func cleanMerchantName(_ text: String) -> String {
        cleanWhitespace(text)
            .replacingOccurrences(
                of: #"\s+(?:sdn\.?\s*bhd\.?|llc|ltd\.?|inc\.?)$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

// MARK: - Section detection

private struct ItemSection {
    let page: Int
    let topY: CGFloat
    let bottomY: CGFloat
    let hasHeader: Bool
}

private enum ItemSectionDetector {
    static func detect(in document: ReceiptDocument, totals: ParsedTotals) -> ItemSection? {
        let header = document.rows.first(where: {
            SemanticRules.isTableHeader($0.normalized)
        })
        let subtotalRow = document.rows.first(where: {
            SemanticRules.isSubtotal($0.normalized)
        })

        if let header {
            let bottom = subtotalRow?.midY ??
                totals.firstTotalsY ??
                max(0, header.midY - 0.55)
            return ItemSection(
                page: header.page,
                topY: header.midY,
                bottomY: bottom,
                hasHeader: true
            )
        }

        let pricedRows = document.rows.filter {
            !SemanticRules.isMetadata($0.normalized) &&
                MoneyParser.last(in: $0.text) != nil
        }
        guard let first = pricedRows.first else { return nil }
        let bottom = subtotalRow?.midY ??
            totals.firstTotalsY ??
            pricedRows.last.map {
                max(0, $0.midY - document.medianHeight * 1.5)
            } ??
            max(0, first.midY - 0.55)
        return ItemSection(
            page: first.page,
            topY: min(0.98, first.midY + document.medianHeight * 1.5),
            bottomY: bottom,
            hasHeader: false
        )
    }
}

// MARK: - Items

private struct ItemCandidate {
    let item: ParsedItem
    let lineTotal: Decimal
    let y: CGFloat
}

private enum ItemExtractor {
    struct Result {
        var candidates: [ItemCandidate]
        var excluded: [ExcludedReceiptLine]
    }

    static func extract(
        from document: ReceiptDocument,
        section: ItemSection?,
        subtotal: Decimal?,
        corrections: ReceiptCorrectionHints
    ) -> Result {
        guard let section else { return Result(candidates: [], excluded: []) }
        let lines = document.lines.filter {
            $0.page == section.page &&
                $0.midY < section.topY &&
                $0.midY > section.bottomY
        }
        guard !lines.isEmpty else { return Result(candidates: [], excluded: []) }

        let candidates: [ItemCandidate]
        if section.hasHeader {
            var found: [ItemCandidate] = []
            found += inlineCandidates(lines, corrections: corrections)
            found += columnCandidates(lines, excluding: found, corrections: corrections)
            found += detailRowCandidates(lines, excluding: found, corrections: corrections)
            candidates = deduplicate(found)
        } else {
            candidates = listCandidates(document.rows.filter {
                $0.page == section.page &&
                    $0.midY < section.topY &&
                    $0.midY > section.bottomY
            }, corrections: corrections)
        }

        let rows = document.rows.filter {
            $0.page == section.page &&
                $0.midY < section.topY &&
                $0.midY > section.bottomY
        }
        return Result(
            candidates: candidates,
            excluded: excludedRows(rows, candidates: candidates)
        )
    }

    private static func listCandidates(
        _ rows: [ReceiptRow],
        corrections: ReceiptCorrectionHints
    ) -> [ItemCandidate] {
        var result: [ItemCandidate] = []
        var pendingName: (parsed: ParsedItemText, y: CGFloat, confidence: Double)?

        for row in rows.sorted(by: { $0.midY > $1.midY }) {
            let text = row.text
            let normalized = row.normalized

            if SemanticRules.isMetadata(normalized) ||
                SemanticRules.isCategory(normalized) {
                pendingName = nil
                continue
            }

            let value = MoneyParser.last(in: text)
            if SemanticRules.isProductDetail(normalized), let value {
                if value >= 0, let pendingName {
                    let quantity = ItemTextParser.explicitQuantity(in: text) ??
                        pendingName.parsed.quantity
                    result.append(candidate(
                        name: pendingName.parsed.name,
                        quantity: quantity,
                        lineTotal: value,
                        y: pendingName.y,
                        confidence: min(pendingName.confidence, row.confidence) * 0.88
                    ))
                }
                pendingName = nil
                continue
            }

            if let value, value >= 0 {
                let priceFragment = row.fragments
                    .filter { MoneyParser.last(in: $0.text) != nil && $0.minX >= 0.60 }
                    .max { $0.minX < $1.minX }
                let rawName = priceFragment.map { price in
                    row.fragments.filter { $0.minX < price.minX }.map(\.text).joined(separator: " ")
                } ?? MoneyParser.removingTrailingValue(from: text)
                let parsed = ItemTextParser.parse(rawName, corrections: corrections)
                if parsed.isValid,
                   !SemanticRules.hasUnitPrice(normalized),
                   !SemanticRules.isProductDetail(normalized) {
                    result.append(candidate(
                        name: parsed.name,
                        quantity: parsed.quantity,
                        lineTotal: value,
                        y: row.midY,
                        confidence: row.confidence * 0.9
                    ))
                } else if let pendingName,
                          pendingName.y > row.midY,
                          pendingName.y - row.midY <= 0.035,
                          row.minX >= 0.55 {
                    result.append(candidate(
                        name: pendingName.parsed.name,
                        quantity: pendingName.parsed.quantity,
                        lineTotal: value,
                        y: pendingName.y,
                        confidence: min(pendingName.confidence, row.confidence) * 0.8
                    ))
                }
                pendingName = nil
                continue
            }

            let parsed = ItemTextParser.parse(text, corrections: corrections)
            if parsed.isValid,
               !SemanticRules.hasUnitPrice(normalized),
               !SemanticRules.isProductDetail(normalized) {
                pendingName = (parsed, row.midY, row.confidence)
            } else {
                pendingName = nil
            }
        }
        return deduplicate(result)
    }

    private static func inlineCandidates(
        _ lines: [RecognizedLine],
        corrections: ReceiptCorrectionHints
    ) -> [ItemCandidate] {
        lines.compactMap { line in
            let values = MoneyParser.all(in: line.text)
            guard let lineTotal = values.last else { return nil }
            let lower = normalize(line.text)
            guard !SemanticRules.isMetadata(lower) else { return nil }

            let hasUnitPrice = SemanticRules.hasUnitPrice(lower)
            guard values.count >= 2 || !hasUnitPrice else { return nil }
            let rawName = MoneyParser.removingTrailingValue(from: line.text)
            let parsed = ItemTextParser.parse(rawName, corrections: corrections)
            guard parsed.isValid else { return nil }
            return candidate(
                name: parsed.name,
                quantity: parsed.quantity,
                lineTotal: lineTotal,
                y: line.midY,
                confidence: Double(line.confidence) * (values.count >= 2 ? 0.95 : 0.78)
            )
        }
    }

    private static func columnCandidates(
        _ lines: [RecognizedLine],
        excluding existing: [ItemCandidate],
        corrections: ReceiptCorrectionHints
    ) -> [ItemCandidate] {
        let priceLines = lines.filter {
            $0.minX >= 0.65 &&
                MoneyParser.last(in: $0.text) != nil &&
                !SemanticRules.hasUnitPrice(normalize($0.text))
        }.sorted { $0.midY > $1.midY }

        let nameLines = lines.filter {
            $0.minX < 0.62 &&
                ItemTextParser.parse($0.text, corrections: corrections).isValid &&
                !SemanticRules.isMetadata(normalize($0.text)) &&
                !SemanticRules.isProductDetail(normalize($0.text))
        }.sorted { $0.midY > $1.midY }

        var result: [ItemCandidate] = []
        var usedNameIndices = Set<Int>()

        for priceLine in priceLines {
            guard let lineTotal = MoneyParser.last(in: priceLine.text) else { continue }
            let matches = nameLines.enumerated().filter { index, line in
                !usedNameIndices.contains(index) &&
                    abs(line.midY - priceLine.midY) <= 0.035 &&
                    !existing.contains { abs($0.y - line.midY) < 0.01 }
            }
            guard let best = matches.min(by: {
                abs($0.element.midY - priceLine.midY) <
                    abs($1.element.midY - priceLine.midY)
            }) else { continue }

            let parsed = ItemTextParser.parse(best.element.text, corrections: corrections)
            let distance = Double(abs(best.element.midY - priceLine.midY))
            let geometryConfidence = max(0.45, 1 - distance / 0.04)
            result.append(candidate(
                name: parsed.name,
                quantity: parsed.quantity,
                lineTotal: lineTotal,
                y: best.element.midY,
                confidence: geometryConfidence * Double(best.element.confidence)
            ))
            usedNameIndices.insert(best.offset)
        }
        return result
    }

    private static func detailRowCandidates(
        _ lines: [RecognizedLine],
        excluding existing: [ItemCandidate],
        corrections: ReceiptCorrectionHints
    ) -> [ItemCandidate] {
        let sorted = lines.sorted { $0.midY > $1.midY }
        var result: [ItemCandidate] = []

        for (index, detail) in sorted.enumerated() {
            guard SemanticRules.isProductDetail(normalize(detail.text)),
                  let lineTotal = MoneyParser.last(in: detail.text)
            else { continue }

            let preceding = sorted.prefix(index).reversed().first {
                detail.midY < $0.midY &&
                    $0.midY - detail.midY <= 0.05 &&
                    ItemTextParser.parse($0.text, corrections: corrections).isValid
            }
            guard let preceding,
                  !existing.contains(where: { abs($0.y - preceding.midY) < 0.01 })
            else { continue }

            let parsed = ItemTextParser.parse(preceding.text, corrections: corrections)
            let quantity = ItemTextParser.explicitQuantity(in: detail.text) ?? parsed.quantity
            result.append(candidate(
                name: parsed.name,
                quantity: quantity,
                lineTotal: lineTotal,
                y: preceding.midY,
                confidence: 0.72 * Double(preceding.confidence)
            ))
        }
        return result
    }

    private static func candidate(
        name: String,
        quantity: Int,
        lineTotal: Decimal,
        y: CGFloat,
        confidence: Double
    ) -> ItemCandidate {
        let safeQuantity = max(1, quantity)
        return ItemCandidate(
            item: ParsedItem(
                name: name,
                price: lineTotal / Decimal(safeQuantity),
                quantity: safeQuantity,
                confidence: min(1, max(0, confidence))
            ),
            lineTotal: lineTotal,
            y: y
        )
    }

    private static func deduplicate(_ candidates: [ItemCandidate]) -> [ItemCandidate] {
        var result: [ItemCandidate] = []
        for candidate in candidates.sorted(by: {
            if abs($0.y - $1.y) > 0.008 { return $0.y > $1.y }
            return $0.item.confidence > $1.item.confidence
        }) {
            let duplicate = result.contains {
                abs($0.y - candidate.y) < 0.012 &&
                    normalize($0.item.name) == normalize(candidate.item.name)
            }
            if !duplicate { result.append(candidate) }
        }
        return result
    }

    private static func excludedRows(
        _ rows: [ReceiptRow],
        candidates: [ItemCandidate]
    ) -> [ExcludedReceiptLine] {
        rows.compactMap { row in
            guard row.text.filter(\.isLetter).count >= 2 else { return nil }
            guard !candidates.contains(where: { abs($0.y - row.midY) < 0.014 }) else {
                return nil
            }

            let amount = MoneyParser.last(in: row.text)
            let normalized = row.normalized
            if SemanticRules.isDiscount(normalized) { return nil }
            let reason: String
            if SemanticRules.isTableHeader(normalized) {
                reason = "Quantity or column header"
            } else if SemanticRules.isMetadata(normalized) {
                reason = "Total, payment, discount, or receipt metadata"
            } else if SemanticRules.isProductDetail(normalized) {
                reason = "Barcode or product detail"
            } else if amount == nil {
                return nil
            } else {
                reason = "Could not confidently match this name and price"
            }

            let suggested = MoneyParser.removingTrailingValue(from: row.text)
            return ExcludedReceiptLine(
                text: row.text,
                suggestedName: cleanWhitespace(suggested),
                amount: amount,
                reason: reason
            )
        }
    }
}

// MARK: - Totals

private struct ParsedTotals {
    var subtotal: Decimal?
    var tax: Decimal?
    var rounding: Decimal?
    var total: Decimal?
    var firstTotalsY: CGFloat?
    var confidence: Double
}

private enum TotalsExtractor {
    private enum Kind {
        case subtotal, tax, rounding, total
    }

    static func extract(from document: ReceiptDocument) -> ParsedTotals {
        var result = ParsedTotals(confidence: 0)
        var scores: [Double] = []

        for row in document.rows {
            guard let kind = kind(for: row.normalized) else { continue }
            let match = value(for: row, in: document)
            guard let match else { continue }
            result.firstTotalsY = max(result.firstTotalsY ?? 0, row.midY)
            scores.append(match.confidence)

            switch kind {
            case .subtotal:
                if result.subtotal == nil { result.subtotal = match.value }
            case .tax:
                if result.tax == nil { result.tax = match.value }
            case .rounding:
                if result.rounding == nil { result.rounding = match.value }
            case .total:
                if result.total == nil || match.value > (result.total ?? 0) {
                    result.total = match.value
                }
            }
        }

        result.confidence = scores.isEmpty ? 0 :
            scores.reduce(0, +) / Double(scores.count)
        return result
    }

    private static func kind(for text: String) -> Kind? {
        if SemanticRules.isSubtotal(text) { return .subtotal }
        if SemanticRules.isRounding(text) { return .rounding }
        if SemanticRules.isTax(text) { return .tax }
        if SemanticRules.isGrandTotal(text) { return .total }
        return nil
    }

    private static func value(
        for row: ReceiptRow,
        in document: ReceiptDocument
    ) -> (value: Decimal, confidence: Double)? {
        if let own = MoneyParser.last(in: row.text) {
            return (own, row.confidence)
        }
        let nearby = document.lines.filter {
            $0.page == row.page &&
                $0.minX >= max(0.48, row.maxX - 0.05) &&
                abs($0.midY - row.midY) <= max(0.018, document.medianHeight * 1.1) &&
                MoneyParser.last(in: $0.text) != nil
        }
        guard let line = nearby.min(by: {
            abs($0.midY - row.midY) < abs($1.midY - row.midY)
        }), let value = MoneyParser.last(in: line.text) else { return nil }
        let distance = Double(abs(line.midY - row.midY))
        return (value, max(0.45, 1 - distance / 0.03) * Double(line.confidence))
    }
}

// MARK: - Reconciliation

private enum ReceiptReconciler {
    struct Result {
        let items: [ParsedItem]
        let rejected: [ItemCandidate]
        let confidence: Double
        let warnings: [String]
    }

    static func reconcile(
        candidates: [ItemCandidate],
        subtotal: Decimal?
    ) -> Result {
        guard !candidates.isEmpty else {
            return Result(items: [], rejected: [], confidence: 0, warnings: [])
        }
        let allItems = candidates.sorted { $0.y > $1.y }.map(\.item)
        guard let subtotal else {
            return Result(
                items: allItems,
                rejected: [],
                confidence: max(0.55, allItems.averageConfidence * 0.85),
                warnings: ["Please check the items. The printed subtotal was not clearly detected."]
            )
        }

        let target = cents(subtotal)
        let allSum = candidates.reduce(0) { $0 + cents($1.lineTotal) }
        if abs(allSum - target) <= 1 {
            return Result(
                items: allItems,
                rejected: [],
                confidence: allItems.averageConfidence,
                warnings: []
            )
        }

        var combinations: [Int: (indices: [Int], score: Double)] = [0: ([], 0)]
        for (index, candidate) in candidates.enumerated() {
            let value = cents(candidate.lineTotal)
            guard value > 0, value <= target else { continue }
            for (sum, entry) in combinations.sorted(by: { $0.key > $1.key }) {
                let next = sum + value
                guard next <= target else { continue }
                let score = entry.score + candidate.item.confidence
                if combinations[next] == nil || score > combinations[next]!.score {
                    combinations[next] = (entry.indices + [index], score)
                }
            }
        }

        if let exact = combinations[target], !exact.indices.isEmpty {
            if exact.indices.count < max(1, candidates.count - 1) {
                return Result(
                    items: allItems,
                    rejected: [],
                    confidence: max(0.6, allItems.averageConfidence * 0.9),
                    warnings: ["Please check the items. The printed subtotal did not match every detected row."]
                )
            }

            let selectedIndices = Set(exact.indices)
            let selected = exact.indices.map { candidates[$0] }
            let items = selected
                .sorted { $0.y > $1.y }
                .map(\.item)
            let rejected = candidates.enumerated().compactMap {
                selectedIndices.contains($0.offset) ? nil : $0.element
            }
            let removed = candidates.count - items.count
            let warnings = removed > 0
                ? ["\(removed) OCR row\(removed == 1 ? " was" : "s were") excluded because the item total did not match the subtotal."]
                : []
            return Result(
                items: items,
                rejected: rejected,
                confidence: min(1, items.averageConfidence + 0.08),
                warnings: warnings
            )
        }

        return Result(
            items: allItems,
            rejected: [],
            confidence: max(0.55, allItems.averageConfidence * 0.82),
            warnings: ["Please check the items. The detected rows did not match the printed subtotal exactly."]
        )
    }
}

// MARK: - Currency and date

private enum CurrencyExtractor {
    static func extract(from document: ReceiptDocument) -> String {
        let text = document.rows.map(\.text).joined(separator: " ").uppercased()
        if text.range(
            of: #"(?:^|[^A-Z])(?:MYR|RM)\s*-?\s*\d"#,
            options: .regularExpression
        ) != nil || text.range(of: #"\bMYR\b"#, options: .regularExpression) != nil {
            return "MYR"
        }
        let mappings = [
            ("USD", "USD"),
            ("EUR", "EUR"), ("GBP", "GBP"), ("SGD", "SGD"),
            ("AUD", "AUD"), ("CAD", "CAD"), ("₩", "KRW"),
            ("€", "EUR"), ("£", "GBP")
        ]
        for (marker, code) in mappings where containsCurrencyMarker(marker, in: text) {
            return code
        }
        return text.contains("$") ? "USD" : ""
    }

    private static func containsCurrencyMarker(_ marker: String, in text: String) -> Bool {
        if marker.count == 1 { return text.contains(marker) }
        return text.range(
            of: #"\b\#(NSRegularExpression.escapedPattern(for: marker))\b"#,
            options: .regularExpression
        ) != nil
    }
}

private enum ReceiptDateExtractor {
    static func extract(from document: ReceiptDocument) -> Date? {
        let patterns = [
            "dd/MM/yyyy HH:mm", "dd/MM/yyyy",
            "dd-MM-yyyy HH:mm", "dd-MM-yyyy",
            "MM/dd/yyyy HH:mm", "MM/dd/yyyy",
            "dd-MMM-yy HH:mm", "dd-MMM-yy"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for row in document.rows {
            let candidates = dateCandidates(in: row.text)
            for candidate in candidates {
                for pattern in patterns {
                    formatter.dateFormat = pattern
                    if let date = formatter.date(from: candidate) { return date }
                }
            }
        }
        return nil
    }

    private static func dateCandidates(in text: String) -> [String] {
        let pattern = #"\d{1,2}[-/][A-Za-z]{3}[-/]\d{2,4}(?:\s+\d{1,2}:\d{2})?|\d{1,2}[-/]\d{1,2}[-/]\d{2,4}(?:\s+\d{1,2}:\d{2})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

// MARK: - Parsing helpers

private struct ParsedItemText {
    let name: String
    let quantity: Int
    let isValid: Bool
}

private enum ItemTextParser {
    static func parse(
        _ text: String,
        corrections: ReceiptCorrectionHints = ReceiptCorrectionHints()
    ) -> ParsedItemText {
        var cleaned = cleanWhitespace(text)
        cleaned = cleaned.replacingOccurrences(
            of: #"^\s*(?:MR|WT|SS|fn)\s+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^\s*\d{1,2}[.)]\s*"#,
            with: "",
            options: .regularExpression
        )
        let quantity = explicitQuantity(in: cleaned) ?? 1
        cleaned = cleaned.replacingOccurrences(
            of: #"^\s*\d{1,2}\s*(?:QTY|[xX×])\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^\s*\d{1,2}\s+(?=[A-Za-z])"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*\(\s*\d+(?:[.,]\d{2})\s*/\s*ea\s*\)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^\s*(?:MR|WT|SS|fn)\s+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+TT\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"^\s*\$\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleanWhitespace(cleaned)
        let normalized = normalize(cleaned)
        let correctionKey = correctionKey(cleaned)
        let explicitlyAccepted = corrections.acceptedNames.contains(correctionKey)
        let explicitlyRejected = corrections.rejectedNames.contains(correctionKey)
        let valid = !explicitlyRejected &&
            cleaned.filter(\.isLetter).count >= 3 &&
            (explicitlyAccepted || (
                !SemanticRules.isMetadata(normalized) &&
                !SemanticRules.isTableHeader(normalized) &&
                !SemanticRules.isCategory(normalized) &&
                !SemanticRules.isProductDetail(normalized)
            ))
        return ParsedItemText(name: cleaned, quantity: quantity, isValid: valid)
    }

    static func explicitQuantity(in text: String) -> Int? {
        let patterns = [
            #"^\s*(\d{1,2})\s+(?=[A-Za-z])"#,
            #"\b(?:QTY|[xX×])\s*(\d{1,2})\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: .caseInsensitive
            ) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text)
            else { continue }
            return Int(text[valueRange])
        }
        return nil
    }
}

private enum MoneyParser {
    static func all(in text: String) -> [Decimal] {
        let normalizedText = text
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(
                of: #"-\s*(RM|MYR|USD|SGD|\$|€|£)\s*"#,
                with: "$1-",
                options: [.regularExpression, .caseInsensitive]
            )
        let pattern = #"(?:RM|MYR|USD|SGD|\$|€|£)?\s*(-?\d{1,7}\s*[.,]\s*\d{2}-?)"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: .caseInsensitive
        ) else { return [] }
        return regex.matches(
            in: normalizedText,
            range: NSRange(normalizedText.startIndex..., in: normalizedText)
        )
            .compactMap { match in
                guard let range = Range(match.range(at: 1), in: normalizedText) else { return nil }
                var value = String(normalizedText[range])
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: ",", with: ".")
                let negative = value.hasPrefix("-") || value.hasSuffix("-")
                value = value.replacingOccurrences(of: "-", with: "")
                guard let decimal = Decimal(string: value) else { return nil }
                return negative ? -decimal : decimal
            }
    }

    static func last(in text: String) -> Decimal? { all(in: text).last }

    static func removingTrailingValue(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+-?\s*(?:RM|MYR|USD|SGD|\$|€|£)?\s*-?\d{1,7}\s*[.,]\s*\d{2}-?\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}

private enum SemanticRules {
    private static let metadata = [
        "subtotal", "sub total", "total", "balance", "tax", "sst", "gst", "vat",
        "rounding", "change", "cash", "credit", "debit", "visa", "mastercard",
        "payment", "tender", "amount due", "invoice", "receipt no", "cashier",
        "transaction", "approval", "authorization", "refund", "returnable",
        "thank you", "come again", "goods sold", "scan qr", "e-invoice",
        "regular price", "card saving", "card sav", "discount", "member",
        "customer", "wifi", "password", "rate us"
    ]
    private static let categories = [
        "grocery", "refrig frozen", "baked goods", "meat",
        "produce", "deli", "liquor", "miscellaneous"
    ]

    static func isMetadata(_ text: String) -> Bool {
        metadata.contains(where: text.contains) ||
            fuzzyContainsAny(text, terms: metadata) ||
            text.range(of: #"\*{3,}"#, options: .regularExpression) != nil
    }

    static func isDiscount(_ text: String) -> Bool {
        text.range(
            of: #"\b(?:discount|promo(?:tion)?|voucher|coupon|rebate|markdown)\b"#,
            options: .regularExpression
        ) != nil ||
            compactTokens(text).contains {
                fuzzyEquals($0, "discount", maximumDistance: 2)
            }
    }

    static func isAddress(_ text: String) -> Bool {
        ["jalan", "street", "road", "floor", "complex", "centre", "center",
         "sarawak", "kuching", "postcode", "zip"].contains(where: text.contains)
    }

    static func isTableHeader(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(
            of: #"[^a-z]"#,
            with: "",
            options: .regularExpression
        )
        let tokens = compactTokens(text)
        let headerSignalCount = tokens.filter {
            fuzzyEquals($0, "qty", maximumDistance: 1) ||
                fuzzyEquals($0, "quantity", maximumDistance: 2) ||
                fuzzyEquals($0, "item", maximumDistance: 1) ||
                fuzzyEquals($0, "price", maximumDistance: 1)
        }.count
        let fuzzyHeader = (tokens.count == 1 && headerSignalCount == 1) ||
            headerSignalCount >= 2
        return ["qty", "qly", "oty", "quantity", "item", "itemcount", "totalitem",
                "price", "pricemyr"].contains(compact) ||
            compact.hasSuffix("qty") ||
            compact.hasSuffix("qly") ||
            compact.hasSuffix("oty") ||
            fuzzyHeader && tokens.count <= 4 ||
            (text.contains("item") &&
                (text.contains("qty") || text.contains("quantity") || compact.contains("qly"))) ||
            (text.contains("description") && text.contains("price"))
    }

    static func isCategory(_ text: String) -> Bool {
        let lettersOnly = text.replacingOccurrences(
            of: #"[^a-z ]"#,
            with: " ",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        return categories.contains(lettersOnly)
    }

    static func isProductDetail(_ text: String) -> Bool {
        if hasUnitPrice(text) { return false }
        return text.range(of: #"\d{8,}"#, options: .regularExpression) != nil ||
            text.range(
                of: #"\b(?:pack|ea|btl|unit)\b"#,
                options: .regularExpression
            ) != nil
    }

    static func hasUnitPrice(_ text: String) -> Bool {
        text.range(
            of: #"(?:/|\bper\s+)(?:ea|each|kg|g|lb|unit)\b"#,
            options: .regularExpression
        ) != nil
    }

    static func isSubtotal(_ text: String) -> Bool {
        text.contains("subtotal") ||
            text.contains("sub total") ||
            compactTokens(text).contains { fuzzyEquals($0, "subtotal", maximumDistance: 2) }
    }

    static func isTax(_ text: String) -> Bool {
        text.range(
            of: #"\b(?:tax|sst|gst|vat)\b"#,
            options: .regularExpression
        ) != nil
    }

    static func isRounding(_ text: String) -> Bool {
        text.contains("rounding") ||
            compactTokens(text).contains { fuzzyEquals($0, "rounding", maximumDistance: 2) }
    }

    static func isGrandTotal(_ text: String) -> Bool {
        !isSubtotal(text) &&
            !text.contains("total item") &&
            (compactTokens(text).contains { fuzzyEquals($0, "total", maximumDistance: 1) } ||
                text.contains("balance") ||
                text.contains("amount due"))
    }

    private static func fuzzyContainsAny(_ text: String, terms: [String]) -> Bool {
        let words = compactTokens(text)
        return terms.contains { term in
            let termWords = compactTokens(term)
            guard termWords.count == 1, let target = termWords.first else { return false }
            let distance = target.count >= 8 ? 2 : 1
            return words.contains { fuzzyEquals($0, target, maximumDistance: distance) }
        }
    }
}

private extension Array where Element == ParsedItem {
    var lineTotal: Decimal {
        reduce(0) { $0 + $1.price * Decimal($1.quantity) }
    }

    var averageConfidence: Double {
        guard !isEmpty else { return 0 }
        return reduce(0) { $0 + $1.confidence } / Double(count)
    }
}

private func normalize(_ text: String) -> String {
    cleanWhitespace(text)
        .lowercased()
        .folding(options: [.diacriticInsensitive], locale: .current)
        .replacingOccurrences(
            of: #"[^a-z0-9%$€£₩./* -]"#,
            with: " ",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func cleanWhitespace(_ text: String) -> String {
    text.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func formatMoney(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
}

private func deduplicateExcluded(
    _ lines: [ExcludedReceiptLine]
) -> [ExcludedReceiptLine] {
    var seen = Set<String>()
    return lines.filter { line in
        let key = [
            correctionKey(line.suggestedName),
            line.amount.map { String(cents(abs($0))) } ?? "none"
        ].joined(separator: ":")
        guard !seen.contains(key) else { return false }
        seen.insert(key)
        return true
    }
}

private func correctionKey(_ text: String) -> String {
    normalize(text).replacingOccurrences(
        of: #"[^a-z0-9]"#,
        with: "",
        options: .regularExpression
    )
}

private func compactTokens(_ text: String) -> [String] {
    normalize(text)
        .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
        .split(separator: " ")
        .map(String.init)
}

private func fuzzyEquals(
    _ lhs: String,
    _ rhs: String,
    maximumDistance: Int
) -> Bool {
    if lhs == rhs { return true }
    guard abs(lhs.count - rhs.count) <= maximumDistance else { return false }
    return editDistance(lhs, rhs, stoppingAfter: maximumDistance) <= maximumDistance
}

private func editDistance(
    _ lhs: String,
    _ rhs: String,
    stoppingAfter limit: Int
) -> Int {
    let left = Array(lhs)
    let right = Array(rhs)
    var previous = Array(0...right.count)

    for (i, leftCharacter) in left.enumerated() {
        var current = [i + 1] + Array(repeating: 0, count: right.count)
        var rowMinimum = current[0]
        for (j, rightCharacter) in right.enumerated() {
            current[j + 1] = min(
                current[j] + 1,
                previous[j + 1] + 1,
                previous[j] + (leftCharacter == rightCharacter ? 0 : 1)
            )
            rowMinimum = min(rowMinimum, current[j + 1])
        }
        if rowMinimum > limit { return rowMinimum }
        previous = current
    }
    return previous[right.count]
}

private func cents(_ value: Decimal) -> Int {
    NSDecimalNumber(decimal: value * 100).rounding(
        accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
    ).intValue
}
