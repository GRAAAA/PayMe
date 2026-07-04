import SwiftUI
import SwiftData

struct AnalysisView: View {
    @Query(sort: \Receipt.date, order: .reverse) private var receipts: [Receipt]
    @AppStorage("payme.defaultCurrency") private var defaultCurrency = "MYR"

    private var viewModel: AnalysisViewModel {
        AnalysisViewModel(receipts: receipts, defaultCurrency: defaultCurrency)
    }

    var body: some View {
        let viewModel = viewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                overviewGrid(viewModel)
                trendSection(title: "Last 7 days", series: viewModel.spending.daily, currencyCode: viewModel.currencyCode)
                trendSection(title: "Last 8 weeks", series: viewModel.spending.weekly, currencyCode: viewModel.currencyCode)
                trendSection(title: "Last 6 months", series: viewModel.spending.monthly, currencyCode: viewModel.currencyCode)
                trendSection(title: "Last 4 years", series: viewModel.spending.yearly, currencyCode: viewModel.currencyCode)
                placesSection(viewModel)
            }
            .padding()
        }
        .background(PayMeTheme.canvas)
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func overviewGrid(_ viewModel: AnalysisViewModel) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricTile(title: "Today", value: viewModel.spending.today.currency(code: viewModel.currencyCode))
            MetricTile(title: "This week", value: viewModel.spending.week.currency(code: viewModel.currencyCode))
            MetricTile(title: "This month", value: viewModel.spending.month.currency(code: viewModel.currencyCode))
            MetricTile(title: "This year", value: viewModel.spending.year.currency(code: viewModel.currencyCode))
            MetricTile(title: "All time", value: viewModel.spending.allTime.currency(code: viewModel.currencyCode))
            MetricTile(title: "Receipts", value: "\(viewModel.spending.receiptCount)")
        }
    }

    private func trendSection(title: String, series: SpendingSeries, currencyCode: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(spacing: 10) {
                ForEach(series.buckets) { bucket in
                    SpendingBar(
                        bucket: bucket,
                        maxValue: series.maxValue,
                        currencyCode: currencyCode
                    )
                }
            }
            .padding(14)
            .payMeCard()
        }
    }

    @ViewBuilder
    private func placesSection(_ viewModel: AnalysisViewModel) -> some View {
        if viewModel.spending.topPlaces.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Top places")
                    .font(.headline)
                VStack(spacing: 0) {
                    ForEach(viewModel.spending.topPlaces) { place in
                        HStack {
                            Text(place.name)
                                .lineLimit(1)
                            Spacer()
                            Text(place.total.currency(code: viewModel.currencyCode))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                        if place.id != viewModel.spending.topPlaces.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .payMeCard()
            }
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .payMeCard()
    }
}

private struct SpendingBar: View {
    let bucket: SpendingBucket
    let maxValue: Decimal
    let currencyCode: String

    private var fraction: CGFloat {
        guard maxValue > 0 else { return 0 }
        let value = NSDecimalNumber(decimal: bucket.total).doubleValue
        let max = NSDecimalNumber(decimal: maxValue).doubleValue
        return CGFloat(max(0.06, min(1, value / max)))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(bucket.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PayMeTheme.subtleFill)
                    Capsule()
                        .fill(PayMeTheme.coral)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 9)
            Text(bucket.total.currency(code: currencyCode))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
