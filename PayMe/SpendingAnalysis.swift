import Foundation

struct SpendingBucket: Identifiable {
    let id = UUID()
    let label: String
    let total: Decimal
}

struct SpendingSeries {
    var buckets: [SpendingBucket]
    var maxValue: Decimal

    init(buckets: [SpendingBucket]) {
        self.buckets = buckets
        maxValue = buckets.map(\.total).max() ?? 0
    }
}

struct PlaceSpend: Identifiable {
    let id = UUID()
    let name: String
    let total: Decimal
}

struct SpendingAnalysis {
    var today: Decimal = 0
    var week: Decimal = 0
    var month: Decimal = 0
    var year: Decimal = 0
    var allTime: Decimal = 0
    var receiptCount = 0
    var daily: SpendingSeries
    var weekly: SpendingSeries
    var monthly: SpendingSeries
    var yearly: SpendingSeries
    var topPlaces: [PlaceSpend]

    init(receipts: [Receipt], calendar: Calendar, now: Date) {
        let daySpecs = Self.bucketSpecs(
            count: 7,
            component: .day,
            calendar: calendar,
            now: now
        ) { offset, date in
            offset == 0 ? "Today" : date.formatted(.dateTime.weekday(.abbreviated))
        }
        let weekSpecs = Self.bucketSpecs(
            count: 8,
            component: .weekOfYear,
            calendar: calendar,
            now: now
        ) { offset, _ in
            offset == 0 ? "This" : "\(offset)w"
        }
        let monthSpecs = Self.bucketSpecs(
            count: 6,
            component: .month,
            calendar: calendar,
            now: now
        ) { _, date in
            date.formatted(.dateTime.month(.abbreviated))
        }
        let yearSpecs = Self.bucketSpecs(
            count: 4,
            component: .year,
            calendar: calendar,
            now: now
        ) { _, date in
            date.formatted(.dateTime.year())
        }

        var dailyTotals = Array(repeating: Decimal.zero, count: daySpecs.count)
        var weeklyTotals = Array(repeating: Decimal.zero, count: weekSpecs.count)
        var monthlyTotals = Array(repeating: Decimal.zero, count: monthSpecs.count)
        var yearlyTotals = Array(repeating: Decimal.zero, count: yearSpecs.count)
        var placeTotals: [String: Decimal] = [:]

        for receipt in receipts {
            let amount = receipt.grandTotal
            guard amount > 0 else { continue }

            receiptCount += 1
            allTime += amount
            if calendar.isDate(receipt.date, equalTo: now, toGranularity: .day) { today += amount }
            if calendar.isDate(receipt.date, equalTo: now, toGranularity: .weekOfYear) { week += amount }
            if calendar.isDate(receipt.date, equalTo: now, toGranularity: .month) { month += amount }
            if calendar.isDate(receipt.date, equalTo: now, toGranularity: .year) { year += amount }

            Self.add(amount, from: receipt.date, into: &dailyTotals, using: daySpecs)
            Self.add(amount, from: receipt.date, into: &weeklyTotals, using: weekSpecs)
            Self.add(amount, from: receipt.date, into: &monthlyTotals, using: monthSpecs)
            Self.add(amount, from: receipt.date, into: &yearlyTotals, using: yearSpecs)

            let place = receipt.storeName.trimmingCharacters(in: .whitespacesAndNewlines)
            placeTotals[place.isEmpty ? "New receipt" : place, default: 0] += amount
        }

        daily = SpendingSeries(buckets: Self.buckets(from: daySpecs, totals: dailyTotals))
        weekly = SpendingSeries(buckets: Self.buckets(from: weekSpecs, totals: weeklyTotals))
        monthly = SpendingSeries(buckets: Self.buckets(from: monthSpecs, totals: monthlyTotals))
        yearly = SpendingSeries(buckets: Self.buckets(from: yearSpecs, totals: yearlyTotals))
        topPlaces = placeTotals.map { PlaceSpend(name: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
            .prefix(5)
            .map { $0 }
    }

    private static func bucketSpecs(
        count: Int,
        component: Calendar.Component,
        calendar: Calendar,
        now: Date,
        label: (Int, Date) -> String
    ) -> [BucketSpec] {
        (0..<count).reversed().compactMap { offset in
            guard
                let date = calendar.date(byAdding: component, value: -offset, to: now),
                let interval = calendar.dateInterval(of: component, for: date)
            else { return nil }
            return BucketSpec(label: label(offset, date), interval: interval)
        }
    }

    private static func add(
        _ amount: Decimal,
        from date: Date,
        into totals: inout [Decimal],
        using specs: [BucketSpec]
    ) {
        guard let index = specs.firstIndex(where: { $0.interval.contains(date) }) else { return }
        totals[index] += amount
    }

    private static func buckets(from specs: [BucketSpec], totals: [Decimal]) -> [SpendingBucket] {
        zip(specs, totals).map {
            SpendingBucket(label: $0.0.label, total: $0.1)
        }
    }
}

private struct BucketSpec {
    let label: String
    let interval: DateInterval
}
