import SwiftUI

struct ReceiptCard: View {
    let receipt: Receipt

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "receipt.fill")
                .font(.title2)
                .foregroundStyle(PayMeTheme.coral)
                .frame(width: 48, height: 48)
                .background(PayMeTheme.peach)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(receipt.storeName).font(.headline)
                    if receipt.isArchived {
                        Text("ARCHIVED")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(receipt.billMode == .onMe ? "On you" : "\(receipt.participants.count) people") · \(receipt.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(receipt.grandTotal.currency(code: receipt.effectiveCurrencyCode)).fontWeight(.semibold)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .payMeCard(cornerRadius: 20)
    }
}

struct ItemAssignmentCard: View {
    let item: ReceiptItem
    let participants: [Participant]
    let onEdit: () -> Void

    private var currencyCode: String {
        item.receipt?.effectiveCurrencyCode ?? Receipt.defaultCurrencyCode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.headline)
                    if item.quantity > 1 {
                        Text("\(item.quantity) × \(item.unitPrice.currency(code: currencyCode))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(item.lineTotal.currency(code: currencyCode)).font(.headline.monospacedDigit())
                Button(action: onEdit) {
                    Image(systemName: "pencil").foregroundStyle(.secondary)
                }
            }
            AssignmentPills(item: item, participants: participants, style: .initials)
        }
        .padding(16)
        .payMeCard(cornerRadius: 20)
    }
}

struct AssignmentPills: View {
    enum Style: Equatable {
        case initials
        case names
    }

    @Bindable var item: ReceiptItem
    let participants: [Participant]
    var style: Style = .names

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(
                    title: style == .initials ? "ALL" : "All",
                    selected: item.assignedParticipantIDs.isEmpty
                ) {
                    item.assignedParticipantIDs = []
                }

                ForEach(participants) { person in
                    let selected = !item.assignedParticipantIDs.isEmpty &&
                        item.assignedParticipantIDs.contains(person.id)
                    pill(title: label(for: person), selected: selected) {
                        item.toggle(person, allParticipants: participants)
                    }
                    .accessibilityLabel(person.name)
                }
            }
        }
    }

    private func label(for participant: Participant) -> String {
        style == .initials ? participant.initials : participant.name
    }

    private func pill(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(
                    width: style == .initials ? 42 : nil,
                    height: style == .initials ? 42 : nil
                )
                .padding(.horizontal, style == .initials ? 0 : 12)
                .padding(.vertical, style == .initials ? 0 : 8)
                .background(selected ? PayMeTheme.coral : PayMeTheme.subtleFill)
                .foregroundStyle(selected ? .white : .primary)
                .clipShape(style == .initials ? AnyShape(Circle()) : AnyShape(Capsule()))
        }
        .buttonStyle(.plain)
    }
}

struct BreakdownCard: View {
    let breakdown: PersonBreakdown

    private var currencyCode: String {
        breakdown.participant.receipt?.effectiveCurrencyCode ?? Receipt.defaultCurrencyCode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(breakdown.participant.initials)
                    .font(.caption.bold())
                    .frame(width: 38, height: 38)
                    .foregroundStyle(.white)
                    .background(PayMeTheme.ink)
                    .clipShape(Circle())
                Text(breakdown.participant.name).font(.title3.bold())
                Spacer()
                Text(breakdown.total.currency(code: currencyCode)).font(.title3.bold().monospacedDigit())
            }
            Divider()
            ForEach(breakdown.itemShares) { share in
                HStack {
                    Text(share.peopleCount > 1 ? "1/\(share.peopleCount) \(share.item.name)" : share.item.name)
                    Spacer()
                    Text(share.amount.currency(code: currencyCode)).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if breakdown.discountShare > 0 {
                line(
                    breakdown.participant.receipt?.discountLabel ?? "Discount",
                    amount: -breakdown.discountShare
                )
                .foregroundStyle(.green)
            }
            if breakdown.taxShare > 0 {
                line("Tax", amount: breakdown.taxShare)
            }
            if breakdown.tipShare > 0 {
                line("Tip", amount: breakdown.tipShare)
            }
        }
        .padding(18)
        .payMeCard(cornerRadius: 20)
    }

    private func line(_ label: String, amount: Decimal) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount.currency(code: currencyCode)).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

struct AnyShape: Shape {
    private let path: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        path = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        path(rect)
    }
}

struct CurrencyField: View {
    let title: String
    @Binding var value: Decimal
    @State private var text = ""

    init(_ title: String, value: Binding<Decimal>) {
        self.title = title
        _value = value
        _text = State(initialValue: NSDecimalNumber(decimal: value.wrappedValue).stringValue)
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0.00", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .onChange(of: text) { _, newValue in
                    value = Decimal(string: newValue) ?? 0
                }
        }
    }
}

struct ItemEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var item: ReceiptItem

    var body: some View {
        NavigationStack {
            ItemEditorForm(item: item)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct ItemEditorForm: View {
    @Bindable var item: ReceiptItem

    var body: some View {
        Form {
            TextField("Item name", text: $item.name)
            CurrencyField("Unit price", value: $item.unitPrice)
            Stepper("Quantity: \(item.quantity)", value: $item.quantity, in: 1...99)
        }
        .navigationTitle("Edit item")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (String, Decimal, Int) -> Void
    @State private var name = ""
    @State private var price: Decimal = 0
    @State private var quantity = 1

    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $name)
                CurrencyField("Unit price", value: $price)
                Stepper("Quantity: \(quantity)", value: $quantity, in: 1...99)
            }
            .navigationTitle("Add item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(name, price, quantity)
                        dismiss()
                    }
                    .disabled(name.isEmpty || price <= 0)
                }
            }
        }
    }
}
