import SwiftUI
import SwiftData
import PhotosUI

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = SetupViewModel()
    @State private var showingScanner = false
    @State private var createdReceipt: Receipt?
    @AppStorage("payme.defaultCurrency") private var defaultCurrency = "MYR"

    var body: some View {
        NavigationStack {
            Form {
                scannerSection
                reviewItemsSection
                splitSection
                errorSection
                startSection
            }
            .navigationTitle("New split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                DocumentScanner { images in
                    process(images)
                } onCancel: {
                    showingScanner = false
                }
                .ignoresSafeArea()
            }
            .navigationDestination(item: $createdReceipt) { receipt in
                ReceiptEditorView(
                    receipt: receipt,
                    isNewReceipt: true,
                    excludedLines: viewModel.editorExcludedLines
                ) {
                    dismiss()
                }
            }
        }
    }

    private var scannerSection: some View {
        Section {
            Button {
                showingScanner = true
            } label: {
                Label(viewModel.parsed == nil ? "Scan receipt" : "Scan again", systemImage: "viewfinder")
            }
            .disabled(viewModel.isProcessing)

            PhotosPicker(selection: $viewModel.selectedPhoto, matching: .images) {
                Label("Choose photo", systemImage: "photo.on.rectangle")
            }
            .disabled(viewModel.isProcessing)
            .onChange(of: viewModel.selectedPhoto) { _, newPhoto in
                guard let newPhoto else { return }
                Task { await viewModel.process(photo: newPhoto) }
            }

            if viewModel.isProcessing || viewModel.parsed != nil {
                HStack {
                    Text(viewModel.scanStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    scanAccessory
                }
            }
        } header: {
            Text("Receipt")
        }
    }

    @ViewBuilder
    private var scanAccessory: some View {
        if viewModel.isProcessing {
            ProgressView()
        } else {
            Image(systemName: viewModel.parsed == nil ? "chevron.right" : "checkmark.circle.fill")
                .foregroundStyle(viewModel.parsed == nil ? Color.secondary : Color.green)
        }
    }

    private var scanCurrencyCode: String {
        viewModel.scanCurrencyCode(defaultCurrency: defaultCurrency)
    }

    @ViewBuilder
    private var reviewItemsSection: some View {
        if !viewModel.reviewItemsAreEmpty {
            Section {
                if viewModel.automaticParsedItems.count > 0 {
                    HStack {
                        Label("\(viewModel.automaticParsedItems.count) added", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(viewModel.automaticSubtotal.currency(code: scanCurrencyCode))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                ForEach(viewModel.reviewParsedItems) { item in
                    Button {
                        viewModel.toggleReviewItem(item)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .foregroundStyle(.primary)
                                if item.quantity > 1 {
                                    Text("\(item.quantity) × \(item.price.currency(code: scanCurrencyCode))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text((item.price * Decimal(item.quantity)).currency(code: scanCurrencyCode))
                                .foregroundStyle(.secondary)
                            Image(systemName: viewModel.selectedReviewItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(viewModel.selectedReviewItemIDs.contains(item.id) ? PayMeTheme.coral : .secondary)
                        }
                    }
                }
                ForEach(viewModel.reviewExcludedLines) { line in
                    Button {
                        viewModel.toggleReviewLine(line)
                    } label: {
                        HStack(spacing: 12) {
                            Text(line.suggestedName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if let amount = line.amount {
                                Text(amount.currency(code: scanCurrencyCode))
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: viewModel.selectedReviewLineIDs.contains(line.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(viewModel.selectedReviewLineIDs.contains(line.id) ? PayMeTheme.coral : .secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Check found items")
                    Spacer()
                    Button(viewModel.reviewSelectionButtonTitle) {
                        viewModel.toggleAllReviewItems()
                    }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
                }
            } footer: {
                Text("\(viewModel.readyItemCount) ready · \(viewModel.readySubtotal.currency(code: scanCurrencyCode))")
            }
        }
    }

    private var splitSection: some View {
        Section {
            Picker("Bill mode", selection: $viewModel.billMode) {
                ForEach(BillMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            TextField("Place name", text: $viewModel.storeName)

            if viewModel.billMode == .split {
                ForEach(viewModel.participantNames, id: \.self) { name in
                    Text(name)
                }
                .onDelete { viewModel.participantNames.remove(atOffsets: $0) }

                HStack {
                    TextField("Add person", text: $viewModel.newName)
                        .textInputAutocapitalization(.words)
                        .onSubmit(viewModel.addName)
                    Button(action: viewModel.addName) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(viewModel.newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("Split")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage = viewModel.errorMessage {
            Section("Check scan") {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var startSection: some View {
        Section {
            Button(viewModel.primaryButtonTitle) { createReceipt() }
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
                .disabled(!viewModel.canContinue)
        }
    }

    private func process(_ images: [UIImage]) {
        showingScanner = false
        Task {
            await viewModel.process(images: images)
        }
    }

    private func createReceipt() {
        let receipt = viewModel.makeReceipt(defaultCurrency: defaultCurrency)
        ReceiptStorage.insert(receipt, in: modelContext)
        createdReceipt = receipt
    }
}
