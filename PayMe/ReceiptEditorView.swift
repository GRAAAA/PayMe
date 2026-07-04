import SwiftUI

struct ReceiptEditorView: View {
    @Bindable var receipt: Receipt
    var isNewReceipt = false
    var excludedLines: [ExcludedReceiptLine] = []
    var onFinish: (() -> Void)?
    @State private var showingAddItem = false
    @State private var recoveredLineIDs: Set<UUID> = []
    @State private var editingItem: ReceiptItem?

    private var currencyCode: String {
        receipt.effectiveCurrencyCode
    }

    private var visibleExcludedLines: [ExcludedReceiptLine] {
        excludedLines.filter { !recoveredLineIDs.contains($0.id) }
    }

    var body: some View {
        Form {
            Section("Receipt") {
                TextField("Store name", text: $receipt.storeName)
                DatePicker("Date", selection: $receipt.date, displayedComponents: .date)
            }

            Section {
                ForEach(receipt.items) { item in
                    detectedItemRow(item)
                }
                .onDelete { offsets in
                    for index in offsets where receipt.items.indices.contains(index) {
                        ReceiptCorrectionStore.rememberRejected(receipt.items[index].name)
                    }
                    receipt.items.remove(atOffsets: offsets)
                }
                Button("Add item", systemImage: "plus") { showingAddItem = true }
            } header: {
                Text("Items")
            } footer: {
                Text("Subtotal \(receipt.itemSubtotal.currency(code: currencyCode))")
            }

            if receipt.discount > 0 {
                Section {
                    TextField("Discount name", text: $receipt.discountLabel)
                        .textInputAutocapitalization(.words)
                    CurrencyField("Amount", value: $receipt.discount)
                    if receipt.billMode == .split {
                        Picker("Split discount", selection: Binding(
                            get: { receipt.discountSplitMode },
                            set: { receipt.discountSplitMode = $0 }
                        )) {
                            ForEach(ExtraSplitMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    }
                    HStack {
                        Text("After discount")
                        Spacer()
                        Text(max(0, receipt.itemSubtotal - receipt.discount)
                            .currency(code: currencyCode))
                            .fontWeight(.semibold)
                    }
                    Button("Remove discount", role: .destructive) {
                        receipt.discount = 0
                        receipt.discountLabel = "Discount"
                    }
                } header: {
                    Text("Discount")
                }
            }

            if !visibleExcludedLines.isEmpty {
                Section {
                    ForEach(visibleExcludedLines) { line in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(line.text)
                                    .lineLimit(2)
                                Spacer()
                                if let amount = line.amount {
                                    Text(amount.currency(code: currencyCode))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(line.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if line.amount != nil && !line.suggestedName.isEmpty {
                                Button("Restore as item") {
                                    restore(line)
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                } header: {
                    Text("Excluded scan lines")
                } footer: {
                    Text("These lines were not charged. Restore one only if it is a real purchased item.")
                }
            }

            if receipt.tax > 0 || receipt.tip > 0 {
                Section("Tax & tip") {
                    CurrencyField("Tax", value: $receipt.tax)
                    CurrencyField("Tip", value: $receipt.tip)
                    if receipt.billMode == .split {
                        Picker("Split extras", selection: Binding(
                            get: { receipt.extraSplitMode },
                            set: { receipt.extraSplitMode = $0 }
                        )) {
                            ForEach(ExtraSplitMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    }
                }
            }

            Section {
                if receipt.discount > 0 {
                    HStack {
                        Text(receipt.discountLabel.isEmpty ? "Discount" : receipt.discountLabel)
                        Spacer()
                        Text((-receipt.discount).currency(code: currencyCode))
                            .foregroundStyle(.green)
                    }
                }
                HStack {
                    Text("Total").fontWeight(.semibold)
                    Spacer()
                    Text(receipt.grandTotal.currency(code: currencyCode)).font(.title3.bold())
                }
            }

            if isNewReceipt {
                Section {
                    NavigationLink {
                        SummaryView(receipt: receipt, onFinished: onFinish)
                    } label: {
                        Label(
                            "Done",
                            systemImage: "checkmark.circle.fill"
                        )
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle(isNewReceipt ? "Check the scan" : "Edit receipt")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAddItem) {
            AddItemSheet { name, price, quantity in
                receipt.items.append(ReceiptItem(name: name, unitPrice: price, quantity: quantity))
                ReceiptCorrectionStore.rememberAccepted(name)
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $editingItem) { item in
            ItemEditorSheet(item: item)
                .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private func detectedItemRow(_ item: ReceiptItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.headline)
                    if item.quantity > 1 {
                        Text("\(item.quantity) × \(item.unitPrice.currency(code: currencyCode))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(item.lineTotal.currency(code: currencyCode))
                    .font(.headline.monospacedDigit())
                Button {
                    editingItem = item
                } label: {
                    Image(systemName: "pencil")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(item.name)")
            }

            if receipt.billMode == .split {
                AssignmentPills(item: item, participants: receipt.participants)
            }
        }
        .padding(.vertical, 6)
    }

    private func restore(_ line: ExcludedReceiptLine) {
        guard let amount = line.amount else { return }
        let name = line.suggestedName.isEmpty ? line.text : line.suggestedName
        receipt.items.append(ReceiptItem(name: name, unitPrice: amount))
        recoveredLineIDs.insert(line.id)
        ReceiptCorrectionStore.rememberAccepted(name)
    }
}
