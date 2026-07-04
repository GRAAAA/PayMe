import Foundation
import PhotosUI
import UIKit

@MainActor
final class SetupViewModel: ObservableObject {
    @Published var storeName = ""
    @Published var billMode = BillMode.split
    @Published var participantNames: [String] = []
    @Published var newName = ""
    @Published var isProcessing = false
    @Published var parsed: ParsedReceipt?
    @Published var errorMessage: String?
    @Published var selectedReviewItemIDs: Set<UUID> = []
    @Published var selectedReviewLineIDs: Set<UUID> = []
    @Published var selectedPhoto: PhotosPickerItem?
    @Published private var review = ReceiptScanReview.empty

    private let pipeline: ReceiptExtractionPipeline

    init(pipeline: ReceiptExtractionPipeline = ReceiptExtractionPipeline()) {
        self.pipeline = pipeline
    }

    var canContinue: Bool {
        billMode == .onMe || !participantNames.isEmpty
    }

    var primaryButtonTitle: String {
        parsed == nil ? "Next" : "Continue"
    }

    var scanStatus: String {
        guard parsed != nil else { return "Ready to scan" }
        let label = readyItemCount == 1 ? "item" : "items"
        guard !reviewItemsAreEmpty else {
            return "\(readyItemCount) \(label) ready"
        }
        return "\(readyItemCount) \(label) ready · \(reviewItemCount) to check"
    }

    func scanCurrencyCode(defaultCurrency: String) -> String {
        guard let code = parsed?.currencyCode, !code.isEmpty else {
            return defaultCurrency
        }
        return code
    }

    func addName() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !participantNames.contains(trimmed) else { return }
        participantNames.append(trimmed)
        newName = ""
    }

    func process(images: [UIImage]) async {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        do {
            apply(try await pipeline.parse(images: images))
        } catch {
            clearScan()
            errorMessage = "We couldn’t read that receipt. You can retry or enter the items manually."
        }
    }

    func process(photo: PhotosPickerItem) async {
        isProcessing = true
        errorMessage = nil
        defer {
            selectedPhoto = nil
            isProcessing = false
        }

        do {
            guard
                let data = try await photo.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                throw PhotoImportError.invalidImage
            }
            apply(try await pipeline.parse(images: [image]))
        } catch {
            clearScan()
            errorMessage = "We couldn’t read that image. Try a clearer receipt photo or enter the items manually."
        }
    }

    func makeReceipt(defaultCurrency: String) -> Receipt {
        ReceiptBuilder.build(
            from: ReceiptBuildInput(
                storeName: storeName,
                billMode: billMode,
                participantNames: participantNames,
                defaultCurrency: defaultCurrency,
                parsed: parsed,
                items: selectedReceiptItems
            )
        )
    }

    var automaticParsedItems: [ParsedItem] {
        review.automaticItems
    }

    var reviewParsedItems: [ParsedItem] {
        review.reviewItems
    }

    var reviewExcludedLines: [ExcludedReceiptLine] {
        review.reviewLines
    }

    var reviewItemsAreEmpty: Bool {
        reviewParsedItems.isEmpty && reviewExcludedLines.isEmpty
    }

    var reviewItemCount: Int {
        reviewParsedItems.count + reviewExcludedLines.count
    }

    var readyItemCount: Int {
        automaticParsedItems.count + selectedReviewCount
    }

    var automaticSubtotal: Decimal {
        review.automaticSubtotal
    }

    var readySubtotal: Decimal {
        let selectedItems = selectedParsedItems.reduce(Decimal.zero) {
            $0 + $1.price * Decimal($1.quantity)
        }
        let selectedLines = selectedReviewLines.reduce(Decimal.zero) { $0 + $1.amount }
        return selectedItems + selectedLines
    }

    var reviewSelectionButtonTitle: String {
        allReviewItemsSelected ? "Clear" : "Select all"
    }

    var editorExcludedLines: [ExcludedReceiptLine] {
        guard let parsed else { return [] }
        return parsed.excludedLines.filter {
            !selectedReviewLineIDs.contains($0.id)
        }
    }

    func toggleReviewItem(_ item: ParsedItem) {
        if selectedReviewItemIDs.contains(item.id) {
            selectedReviewItemIDs.remove(item.id)
        } else {
            selectedReviewItemIDs.insert(item.id)
        }
    }

    func toggleReviewLine(_ line: ExcludedReceiptLine) {
        if selectedReviewLineIDs.contains(line.id) {
            selectedReviewLineIDs.remove(line.id)
        } else {
            selectedReviewLineIDs.insert(line.id)
        }
    }

    func toggleAllReviewItems() {
        if allReviewItemsSelected {
            selectedReviewItemIDs = []
            selectedReviewLineIDs = []
        } else {
            selectedReviewItemIDs = Set(reviewParsedItems.map(\.id))
            selectedReviewLineIDs = Set(reviewExcludedLines.map(\.id))
        }
    }

    private func apply(_ receipt: ParsedReceipt) {
        parsed = receipt
        review = ReceiptScanReview(receipt: receipt)
        selectedReviewItemIDs = []
        selectedReviewLineIDs = []
        if storeName.isEmpty { storeName = receipt.storeName }

        var messages: [String] = []
        let confidenceLevel = ReceiptConfidenceLevel(confidence: receipt.confidence)
        if let confidenceMessage = confidenceLevel.message {
            messages.append(confidenceMessage)
        }
        if receipt.items.isEmpty {
            messages.append("No clear item rows were found. You can add items manually.")
        } else if confidenceLevel == .poor {
            messages.append("Please check the detected items.")
        }
        if reviewItemCount > 0 {
            messages.append("Low-confidence rows are waiting for your selection.")
        }
        messages.append(contentsOf: receipt.warnings)
        errorMessage = messages.isEmpty ? nil : Array(Set(messages)).sorted().joined(separator: "\n")
    }

    private func clearScan() {
        parsed = nil
        review = .empty
        selectedReviewItemIDs = []
        selectedReviewLineIDs = []
    }

    private var selectedReviewCount: Int {
        selectedReviewItemIDs.count + selectedReviewLineIDs.count
    }

    private var allReviewItemsSelected: Bool {
        reviewItemCount > 0 && selectedReviewCount == reviewItemCount
    }

    private var selectedParsedItems: [ParsedItem] {
        guard let parsed else { return [] }
        return parsed.items.filter {
            $0.confidence >= ReceiptScanPolicy.autoAcceptConfidence ||
                selectedReviewItemIDs.contains($0.id)
        }
    }

    private var selectedReceiptItems: [ReceiptItem] {
        selectedParsedItems.map(\.receiptItem) +
            selectedReviewLines.map { ReceiptItem(name: $0.name, unitPrice: $0.amount) }
    }

    private var selectedReviewLines: [(name: String, amount: Decimal)] {
        reviewExcludedLines.compactMap { line in
            guard selectedReviewLineIDs.contains(line.id), let amount = line.amount else {
                return nil
            }
            return (line.suggestedName, amount)
        }
    }
}

private enum PhotoImportError: Error {
    case invalidImage
}

private struct ReceiptScanReview {
    var automaticItems: [ParsedItem]
    var reviewItems: [ParsedItem]
    var reviewLines: [ExcludedReceiptLine]
    var automaticSubtotal: Decimal

    static let empty = ReceiptScanReview(
        automaticItems: [],
        reviewItems: [],
        reviewLines: [],
        automaticSubtotal: 0
    )

    init(
        automaticItems: [ParsedItem],
        reviewItems: [ParsedItem],
        reviewLines: [ExcludedReceiptLine],
        automaticSubtotal: Decimal
    ) {
        self.automaticItems = automaticItems
        self.reviewItems = reviewItems
        self.reviewLines = reviewLines
        self.automaticSubtotal = automaticSubtotal
    }

    init(receipt: ParsedReceipt) {
        automaticItems = receipt.items.filter {
            $0.confidence >= ReceiptScanPolicy.autoAcceptConfidence
        }
        reviewItems = receipt.items.filter {
            $0.confidence < ReceiptScanPolicy.autoAcceptConfidence &&
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                $0.price > 0
        }

        let existingKeys = Set(receipt.items.map { Self.reviewKey($0.name) })
        reviewLines = receipt.excludedLines.filter {
            !$0.suggestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                $0.amount != nil &&
                !existingKeys.contains(Self.reviewKey($0.suggestedName))
        }
        automaticSubtotal = automaticItems.reduce(0) { $0 + $1.price * Decimal($1.quantity) }
    }

    private static func reviewKey(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
