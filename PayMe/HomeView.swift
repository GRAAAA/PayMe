import SwiftUI
import SwiftData

struct HomeView: View {
    private enum ReceiptList: String, CaseIterable, Identifiable {
        case active = "Active"
        case archive = "Archive"
        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Receipt> { $0.archivedAt == nil },
        sort: \Receipt.date,
        order: .reverse
    ) private var activeReceipts: [Receipt]
    @Query(
        filter: #Predicate<Receipt> { $0.archivedAt != nil },
        sort: \Receipt.archivedAt,
        order: .reverse
    ) private var archivedReceipts: [Receipt]
    @State private var showingSetup = false
    @State private var showingSettings = false
    @State private var selectedList = ReceiptList.active

    private var displayedReceipts: [Receipt] {
        selectedList == .active ? activeReceipts : archivedReceipts
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PayMeTheme.canvas.ignoresSafeArea()
                if activeReceipts.isEmpty && archivedReceipts.isEmpty {
                    ContentUnavailableView {
                        Label("No splits yet", systemImage: "receipt")
                    } description: {
                        Text("Scan a receipt and turn table math into a thirty-second job.")
                    } actions: {
                        scanButton
                            .frame(width: 240)
                    }
                } else if displayedReceipts.isEmpty {
                    VStack(spacing: 18) {
                        Picker("Receipt list", selection: $selectedList) {
                            ForEach(ReceiptList.allCases) { list in
                                Text(list.rawValue).tag(list)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)

                        ContentUnavailableView {
                            Label(
                                selectedList == .active ? "No active splits" : "Archive is empty",
                                systemImage: selectedList == .active ? "checkmark.circle" : "archivebox"
                            )
                        } description: {
                            Text(selectedList == .active
                                ? "Start a new receipt, or restore one from Archive."
                                : "Completed splits will appear here.")
                        } actions: {
                            if selectedList == .active {
                                scanButton.frame(width: 240)
                            }
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            Picker("Receipt list", selection: $selectedList) {
                                ForEach(ReceiptList.allCases) { list in
                                    Text(list.rawValue).tag(list)
                                }
                            }
                            .pickerStyle(.segmented)

                            if selectedList == .active {
                                hero
                            }

                            ForEach(displayedReceipts) { receipt in
                                NavigationLink {
                                    if receipt.isArchived || receipt.billMode == .onMe {
                                        SummaryView(receipt: receipt)
                                    } else {
                                        AssignmentView(receipt: receipt)
                                    }
                                } label: {
                                    ReceiptCard(receipt: receipt)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if receipt.isArchived {
                                        Button("Restore", systemImage: "arrow.uturn.backward") {
                                            ReceiptStorage.restore(receipt, in: modelContext)
                                        }
                                    } else {
                                        Button("Archive", systemImage: "archivebox") {
                                            ReceiptStorage.archive(receipt, in: modelContext)
                                        }
                                    }
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        ReceiptStorage.delete(receipt, in: modelContext)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("PayMe")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        AnalysisView()
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .accessibilityLabel("Analysis")

                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")

                    Button { showingSetup = true } label: {
                        Image(systemName: "plus").fontWeight(.semibold)
                    }
                    .accessibilityLabel("New receipt")
                }
            }
            .sheet(isPresented: $showingSetup) {
                SetupView()
            }
            .sheet(isPresented: $showingSettings) {
                CurrencySettingsView()
                    .presentationDetents([.medium])
            }
        }
    }

    private var hero: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Who had what?")
                    .font(.title2.bold())
                Text("Scan it. Tap names. Done.")
                    .foregroundStyle(PayMeTheme.muted)
            }
            Spacer()
            Image(systemName: "fork.knife.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(PayMeTheme.coral)
        }
        .padding(20)
        .background(PayMeTheme.peach)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var scanButton: some View {
        Button { showingSetup = true } label: {
            Label("Scan new receipt", systemImage: "viewfinder")
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

struct CurrencyOption: Identifiable {
    let code: String
    let name: String
    var id: String { code }

    static let common = [
        CurrencyOption(code: "MYR", name: "Malaysian Ringgit"),
        CurrencyOption(code: "USD", name: "US Dollar"),
        CurrencyOption(code: "SGD", name: "Singapore Dollar"),
        CurrencyOption(code: "EUR", name: "Euro"),
        CurrencyOption(code: "GBP", name: "British Pound"),
        CurrencyOption(code: "AUD", name: "Australian Dollar"),
        CurrencyOption(code: "CAD", name: "Canadian Dollar"),
        CurrencyOption(code: "KRW", name: "South Korean Won")
    ]
}

private struct CurrencySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("payme.defaultCurrency") private var currencyCode = "MYR"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default currency", selection: $currencyCode) {
                        ForEach(CurrencyOption.common) { currency in
                            Text("\(currency.code) — \(currency.name)")
                                .tag(currency.code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text("Used for new receipts.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
