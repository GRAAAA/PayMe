import SwiftUI
import SwiftData
import PhotosUI

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var storeName = ""
    @State private var billMode = BillMode.split
    @State private var participantNames: [String] = []
    @State private var newName = ""
    @State private var showingScanner = false
    @State private var isProcessing = false
    @State private var parsed: ParsedReceipt?
    @State private var errorMessage: String?
    @State private var createdReceipt: Receipt?
    @State private var selectedPhoto: PhotosPickerItem?
    @AppStorage("payme.defaultCurrency") private var defaultCurrency = "MYR"

    var body: some View {
        NavigationStack {
            Form {
                optionSection
                scannerSection
                peopleSection
                billSection
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
                    excludedLines: []
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
                receiptSourceRow(
                    title: parsed == nil ? "Scan receipt" : "Scan again",
                    subtitle: "Camera",
                    systemImage: "viewfinder"
                )
            }
            .disabled(isProcessing)

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                receiptSourceRow(
                    title: "Choose photo",
                    subtitle: "Photos",
                    systemImage: "photo.on.rectangle"
                )
            }
            .disabled(isProcessing)
            .onChange(of: selectedPhoto) { _, newPhoto in
                guard let newPhoto else { return }
                process(newPhoto)
            }

            if isProcessing || parsed != nil {
                HStack {
                    Text(scanStatus)
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

    private func receiptSourceRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 42, height: 42)
                .foregroundStyle(.white)
                .background(PayMeTheme.coral)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
    }

    private var scanStatus: String {
        guard let parsed else { return "Ready to scan" }
        let itemLabel = parsed.items.count == 1 ? "item" : "items"
        if ReceiptConfidenceLevel(confidence: parsed.confidence) == .accepted {
            return "\(parsed.items.count) \(itemLabel) found"
        }
        return "\(parsed.items.count) \(itemLabel) found · check once"
    }

    @ViewBuilder
    private var scanAccessory: some View {
        if isProcessing {
            ProgressView()
        } else {
            Image(systemName: parsed == nil ? "chevron.right" : "checkmark.circle.fill")
                .foregroundStyle(parsed == nil ? Color.secondary : Color.green)
        }
    }

    private var billSection: some View {
        Section {
            TextField("Place name", text: $storeName)
        } header: {
            Text("Details")
        }
    }

    private var optionSection: some View {
        Section {
            Picker("Bill mode", selection: $billMode) {
                ForEach(BillMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var peopleSection: some View {
        if billMode == .split {
            Section {
                ForEach(participantNames, id: \.self) { name in
                    Text(name)
                }
                .onDelete { participantNames.remove(atOffsets: $0) }

                HStack {
                    TextField("Add person", text: $newName)
                        .textInputAutocapitalization(.words)
                        .onSubmit(addName)
                    Button(action: addName) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("People")
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage {
            Section("Check scan") {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var startSection: some View {
        Section {
            Button(primaryButtonTitle) { createReceipt() }
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
                .disabled(billMode == .split && participantNames.isEmpty)
        }
    }

    private var primaryButtonTitle: String {
        if parsed == nil {
            return billMode == .split ? "Continue" : "Save receipt"
        }
        return billMode == .split ? "Review items" : "Review receipt"
    }

    private func addName() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !participantNames.contains(trimmed) else { return }
        participantNames.append(trimmed)
        newName = ""
    }

    private func process(_ images: [UIImage]) {
        showingScanner = false
        isProcessing = true
        errorMessage = nil
        Task {
            do {
                let result = try await ReceiptExtractionPipeline().parse(images: images)
                await MainActor.run {
                    apply(result)
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "We couldn’t read that receipt. You can retry or enter the items manually."
                    isProcessing = false
                }
            }
        }
    }

    private func process(_ photo: PhotosPickerItem) {
        isProcessing = true
        errorMessage = nil
        Task {
            do {
                guard
                    let data = try await photo.loadTransferable(type: Data.self),
                    let image = UIImage(data: data)
                else {
                    throw PhotoImportError.invalidImage
                }
                let result = try await ReceiptExtractionPipeline().parse(images: [image])
                await MainActor.run {
                    apply(result)
                    selectedPhoto = nil
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "We couldn’t read that image. Try a clearer receipt photo or enter the items manually."
                    selectedPhoto = nil
                    isProcessing = false
                }
            }
        }
    }

    private func apply(_ receipt: ParsedReceipt) {
        parsed = receipt
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
        errorMessage = messages.isEmpty ? nil : Array(Set(messages)).sorted().joined(separator: "\n")
    }

    private func createReceipt() {
        let receipt = Receipt(storeName: storeName.isEmpty ? "New receipt" : storeName)
        receipt.currencyCode = defaultCurrency
        receipt.billMode = billMode
        if let parsedDate = parsed?.date {
            receipt.date = parsedDate
        }
        receipt.participants = billMode == .split
            ? participantNames.map(Participant.init)
            : [Participant(name: "Me")]
        if let parsed {
            receipt.tax = parsed.tax
            receipt.discount = parsed.discounts.reduce(0) { $0 + $1.amount }
            let discountNames = parsed.discounts.map(\.name)
            if !discountNames.isEmpty {
                receipt.discountLabel = discountNames.count == 1
                    ? discountNames[0]
                    : "Discounts"
            }
            if !parsed.currencyCode.isEmpty {
                receipt.currencyCode = parsed.currencyCode
            }
            receipt.items = parsed.items.map { ReceiptItem(name: $0.name, unitPrice: $0.price, quantity: $0.quantity) }
        }
        modelContext.insert(receipt)
        createdReceipt = receipt
    }
}

private enum PhotoImportError: Error {
    case invalidImage
}
