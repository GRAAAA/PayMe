import Foundation

struct AnalysisViewModel {
    let currencyCode: String
    let spending: SpendingAnalysis

    init(receipts: [Receipt], defaultCurrency: String, calendar: Calendar = .current, now: Date = .now) {
        currencyCode = receipts.first(where: { !($0.currencyCode ?? "").isEmpty })?.effectiveCurrencyCode
            ?? defaultCurrency
        spending = SpendingAnalysis(receipts: receipts, calendar: calendar, now: now)
    }
}
