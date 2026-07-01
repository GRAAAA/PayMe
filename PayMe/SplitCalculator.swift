import Foundation

struct PersonBreakdown: Identifiable {
    let participant: Participant
    let itemShares: [ItemShare]
    let discountShare: Decimal
    let taxShare: Decimal
    let tipShare: Decimal

    var id: UUID { participant.id }
    var itemsTotal: Decimal { itemShares.reduce(0) { $0 + $1.amount } }
    var total: Decimal { max(0, itemsTotal - discountShare + taxShare + tipShare) }
}

struct ItemShare: Identifiable {
    let item: ReceiptItem
    let peopleCount: Int
    let amount: Decimal
    var id: UUID { item.id }
}

enum SplitCalculator {
    static func breakdowns(for receipt: Receipt) -> [PersonBreakdown] {
        let people = receipt.participants
        guard !people.isEmpty else { return [] }

        if receipt.billMode == .onMe {
            let payer = people[0]
            let shares = receipt.items.map {
                ItemShare(item: $0, peopleCount: 1, amount: $0.lineTotal)
            }
            return [
                PersonBreakdown(
                    participant: payer,
                    itemShares: shares,
                    discountShare: receipt.discount,
                    taxShare: receipt.tax,
                    tipShare: receipt.tip
                )
            ]
        }

        let itemTotals: [UUID: Decimal] = Dictionary(uniqueKeysWithValues: people.map { person in
            let total = receipt.items.reduce(Decimal.zero) { result, item in
                let assigned = item.assignedParticipants(from: people)
                guard assigned.contains(where: { $0.id == person.id }), !assigned.isEmpty else { return result }
                return result + item.lineTotal / Decimal(assigned.count)
            }
            return (person.id, total)
        })

        return people.map { person in
            let shares = receipt.items.compactMap { item -> ItemShare? in
                let assigned = item.assignedParticipants(from: people)
                guard assigned.contains(where: { $0.id == person.id }), !assigned.isEmpty else { return nil }
                return ItemShare(item: item, peopleCount: assigned.count, amount: item.lineTotal / Decimal(assigned.count))
            }
            let itemTotal = itemTotals[person.id, default: 0]
            let discountShare = extraShare(
                receipt.discount,
                itemTotal: itemTotal,
                subtotal: receipt.itemSubtotal,
                people: people.count,
                mode: receipt.discountSplitMode
            )
            let taxShare = extraShare(receipt.tax, itemTotal: itemTotal, subtotal: receipt.itemSubtotal, people: people.count, mode: receipt.extraSplitMode)
            let tipShare = extraShare(receipt.tip, itemTotal: itemTotal, subtotal: receipt.itemSubtotal, people: people.count, mode: receipt.extraSplitMode)
            return PersonBreakdown(
                participant: person,
                itemShares: shares,
                discountShare: discountShare,
                taxShare: taxShare,
                tipShare: tipShare
            )
        }
    }

    private static func extraShare(_ amount: Decimal, itemTotal: Decimal, subtotal: Decimal, people: Int, mode: ExtraSplitMode) -> Decimal {
        guard amount != 0 else { return 0 }
        if mode == .proportional, subtotal > 0 {
            return amount * itemTotal / subtotal
        }
        return amount / Decimal(people)
    }

    static func summary(for receipt: Receipt) -> String {
        let date = receipt.date.formatted(date: .abbreviated, time: .omitted)
        let currencyCode = receipt.currencyCode ?? Locale.current.currency?.identifier ?? "USD"
        if receipt.billMode == .onMe {
            return "Receipt for \(receipt.storeName) on \(date):\nOn me: \(receipt.grandTotal.currency(code: currencyCode))"
        }
        let lines = breakdowns(for: receipt).map { "\($0.participant.name): \($0.total.currency(code: currencyCode))" }
        return "Hey! Here’s the split for \(receipt.storeName) on \(date):\n" + lines.joined(separator: "\n") + "\n\nTotal: \(receipt.grandTotal.currency(code: currencyCode))"
    }
}

extension Decimal {
    func currency(code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = currencyLocale(for: code)
        formatter.currencyCode = code.uppercased()
        if code.uppercased() == "MYR" {
            formatter.currencySymbol = "RM"
        }
        return formatter.string(from: self as NSDecimalNumber) ?? "$0.00"
    }
}

private func currencyLocale(for code: String) -> Locale {
    switch code.uppercased() {
    case "MYR": Locale(identifier: "ms_MY")
    case "SGD": Locale(identifier: "en_SG")
    case "USD": Locale(identifier: "en_US")
    case "GBP": Locale(identifier: "en_GB")
    case "EUR": Locale(identifier: "en_IE")
    case "AUD": Locale(identifier: "en_AU")
    case "CAD": Locale(identifier: "en_CA")
    case "KRW": Locale(identifier: "ko_KR")
    default: Locale.current
    }
}
