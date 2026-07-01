import Foundation
import SwiftData

enum ExtraSplitMode: String, Codable, CaseIterable, Identifiable {
    case proportional = "By spending"
    case equal = "Evenly"
    var id: String { rawValue }
}

enum BillMode: String, Codable, CaseIterable, Identifiable {
    case split = "Split bill"
    case onMe = "On me"

    var id: String { rawValue }
}

@Model
final class Receipt {
    var id: UUID
    var storeName: String
    var date: Date
    var archivedAt: Date?
    var tax: Decimal
    var tip: Decimal
    var discount: Decimal = 0
    var discountLabel: String = "Discount"
    var currencyCode: String?
    var billModeRaw: String = BillMode.split.rawValue
    var extraSplitModeRaw: String
    var discountSplitModeRaw: String = ExtraSplitMode.proportional.rawValue
    @Relationship(deleteRule: .cascade, inverse: \ReceiptItem.receipt) var items: [ReceiptItem]
    @Relationship(deleteRule: .cascade, inverse: \Participant.receipt) var participants: [Participant]

    init(storeName: String, date: Date = .now, tax: Decimal = 0, tip: Decimal = 0) {
        id = UUID()
        self.storeName = storeName
        self.date = date
        archivedAt = nil
        self.tax = tax
        self.tip = tip
        discount = 0
        discountLabel = "Discount"
        self.currencyCode = Locale.current.currency?.identifier ?? "USD"
        billModeRaw = BillMode.split.rawValue
        extraSplitModeRaw = ExtraSplitMode.proportional.rawValue
        discountSplitModeRaw = ExtraSplitMode.proportional.rawValue
        items = []
        participants = []
    }

    var billMode: BillMode {
        get { BillMode(rawValue: billModeRaw) ?? .split }
        set { billModeRaw = newValue.rawValue }
    }

    var extraSplitMode: ExtraSplitMode {
        get { ExtraSplitMode(rawValue: extraSplitModeRaw) ?? .proportional }
        set { extraSplitModeRaw = newValue.rawValue }
    }

    var discountSplitMode: ExtraSplitMode {
        get { ExtraSplitMode(rawValue: discountSplitModeRaw) ?? .proportional }
        set { discountSplitModeRaw = newValue.rawValue }
    }

    var itemSubtotal: Decimal { items.reduce(0) { $0 + $1.lineTotal } }
    var grandTotal: Decimal { max(0, itemSubtotal - discount + tax + tip) }
    var isArchived: Bool { archivedAt != nil }

    func archive() {
        archivedAt = .now
    }

    func restore() {
        archivedAt = nil
    }
}

@Model
final class ReceiptItem {
    var id: UUID
    var name: String
    var unitPrice: Decimal
    var quantity: Int
    var assignedParticipantIDs: [UUID]
    var receipt: Receipt?

    init(name: String, unitPrice: Decimal, quantity: Int = 1) {
        id = UUID()
        self.name = name
        self.unitPrice = unitPrice
        self.quantity = quantity
        assignedParticipantIDs = []
    }

    var lineTotal: Decimal { unitPrice * Decimal(quantity) }

    func isAssigned(to participant: Participant, allParticipants: [Participant]) -> Bool {
        assignedParticipantIDs.isEmpty || assignedParticipantIDs.contains(participant.id)
    }

    func toggle(_ participant: Participant, allParticipants: [Participant]) {
        if assignedParticipantIDs.isEmpty {
            assignedParticipantIDs = [participant.id]
        } else if let index = assignedParticipantIDs.firstIndex(of: participant.id) {
            assignedParticipantIDs.remove(at: index)
            if assignedParticipantIDs.count == allParticipants.count {
                assignedParticipantIDs = []
            }
        } else {
            assignedParticipantIDs.append(participant.id)
            if assignedParticipantIDs.count == allParticipants.count {
                assignedParticipantIDs = []
            }
        }
    }

    func assignedParticipants(from all: [Participant]) -> [Participant] {
        assignedParticipantIDs.isEmpty ? all : all.filter { assignedParticipantIDs.contains($0.id) }
    }
}

@Model
final class Participant {
    var id: UUID
    var name: String
    var receipt: Receipt?

    init(name: String) {
        id = UUID()
        self.name = name
    }

    var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
