import Foundation

struct ReceiptBuildInput {
    var storeName: String
    var billMode: BillMode
    var participantNames: [String]
    var defaultCurrency: String
    var parsed: ParsedReceipt?
    var items: [ReceiptItem]
}

enum ReceiptBuilder {
    static func build(from input: ReceiptBuildInput) -> Receipt {
        let receipt = Receipt(storeName: input.storeName.isEmpty ? "New receipt" : input.storeName)
        receipt.currencyCode = input.defaultCurrency
        receipt.billMode = input.billMode
        receipt.participants = input.billMode == .split
            ? input.participantNames.map(Participant.init)
            : [Participant(name: "Me")]

        guard let parsed = input.parsed else {
            return receipt
        }

        if let parsedDate = parsed.date {
            receipt.date = parsedDate
        }
        receipt.tax = parsed.tax
        receipt.discount = parsed.discounts.reduce(0) { $0 + $1.amount }

        let discountNames = parsed.discounts.map(\.name)
        if !discountNames.isEmpty {
            receipt.discountLabel = discountNames.count == 1 ? discountNames[0] : "Discounts"
        }
        if !parsed.currencyCode.isEmpty {
            receipt.currencyCode = parsed.currencyCode
        }
        receipt.items = input.items
        return receipt
    }
}

extension ParsedItem {
    var receiptItem: ReceiptItem {
        ReceiptItem(name: name, unitPrice: price, quantity: quantity)
    }
}
