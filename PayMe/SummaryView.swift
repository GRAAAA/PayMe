import SwiftUI
import UIKit

struct SummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var receipt: Receipt
    var onFinished: (() -> Void)?
    @State private var copied = false
    @State private var showingDeleteConfirmation = false
    private var breakdowns: [PersonBreakdown] { SplitCalculator.breakdowns(for: receipt) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.green)
                    Text(receipt.billMode == .onMe ? "On you" : "All squared up")
                        .font(.title.bold())
                    Text("\(receipt.storeName) · \(receipt.grandTotal.currency(code: receipt.currencyCode ?? "USD"))")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)

                ForEach(breakdowns) { breakdown in
                    BreakdownCard(breakdown: breakdown)
                }
            }
            .padding()
        }
        .background(PayMeTheme.canvas)
        .navigationTitle(receipt.billMode == .onMe ? "Receipt" : "The split")
        .confirmationDialog(
            "Delete this archived receipt?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                modelContext.delete(receipt)
                try? modelContext.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = SplitCalculator.summary(for: receipt)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy summary", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(PrimaryButtonStyle())

                if receipt.isArchived {
                    HStack(spacing: 12) {
                        Button {
                            receipt.restore()
                            try? modelContext.save()
                            if let onFinished {
                                onFinished()
                            } else {
                                dismiss()
                            }
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Button {
                        receipt.archive()
                        try? modelContext.save()
                        if let onFinished {
                            onFinished()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Label("Finish & Archive", systemImage: "archivebox.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                ShareLink(item: SplitCalculator.summary(for: receipt)) {
                    Label("Share summary", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }
}
