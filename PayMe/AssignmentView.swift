import SwiftUI

struct AssignmentView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var receipt: Receipt
    @State private var editingItem: ReceiptItem?

    private var breakdowns: [PersonBreakdown] { SplitCalculator.breakdowns(for: receipt) }

    var body: some View {
        VStack(spacing: 0) {
            if receipt.items.isEmpty {
                ContentUnavailableView("No items yet", systemImage: "list.bullet.rectangle", description: Text("Add the first item to start splitting."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(receipt.items) { item in
                            ItemAssignmentCard(item: item, participants: receipt.participants) {
                                editingItem = item
                            }
                        }
                    }
                    .padding()
                }
            }
            totalsBar
        }
        .background(PayMeTheme.canvas)
        .navigationTitle(receipt.storeName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    ReceiptEditorView(receipt: receipt)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                NavigationLink {
                    SummaryView(receipt: receipt)
                } label: {
                    Text("Done").fontWeight(.semibold)
                }
            }
        }
        .sheet(item: $editingItem) { item in
            ItemEditorSheet(item: item)
                .presentationDetents([.medium])
        }
        .onChange(of: receipt.isArchived) { _, isArchived in
            if isArchived { dismiss() }
        }
    }

    private var totalsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(breakdowns) { breakdown in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(breakdown.participant.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(breakdown.total.currency(code: receipt.effectiveCurrencyCode))
                            .font(.headline.monospacedDigit())
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 14)
        .background(.regularMaterial)
        .animation(.snappy, value: breakdowns.map(\.total))
    }
}
