import SwiftUI
import Charts

enum UsageFormat {
    static func tokens(_ count: Int64) -> String {
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.1fK", Double(count) / 1000) }
        return String(count)
    }
    static func money(_ value: Double) -> String { value > 0 && value < 0.01 ? "<$0.01" : String(format: "$%.2f", value) }
}

struct StatisticsView: View {
    @ObservedObject var store: AppStore
    @State private var days = 7
    @State private var metric = 0
    @State private var selectedModel: String?
    @State private var selectedDay: Date?
    @State private var showDetails = false

    var body: some View {
        let summary = store.statistics.summary(days: days, model: selectedModel)
        let trend = store.statistics.costTrend(days: days, model: selectedModel)
        VStack(alignment: .leading, spacing: 14) {
            Picker("统计范围", selection: $days) {
                Text("今天").tag(1); Text("7 天").tag(7); Text("30 天").tag(30)
            }.pickerStyle(.segmented).controlSize(.small).labelsHidden()
            if store.statisticsBusy {
                HStack(spacing: 7) { ProgressView().controlSize(.mini); Text(store.statisticsProgress).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if let error = store.statisticsError { Text(error).font(.system(size: 10)).foregroundStyle(Palette.coral) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("API 等价成本 · USD").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(summary.total.unpriced == summary.total.calls && summary.total.calls > 0 ? "未计价" : UsageFormat.money(summary.total.cost))
                            .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("按标准 API 单价估算").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("Token").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(UsageFormat.tokens(summary.total.tokens.total)).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("\(summary.total.calls) 条计量记录").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                if let trend {
                    HStack(spacing: 8) {
                        Text("当前速度 · 日均 " + UsageFormat.money(trend.dailyAverage) + " · 月化 " + UsageFormat.money(trend.monthlyProjection))
                        Spacer(minLength: 4)
                        if let change = trend.changePercent, let comparisonDays = trend.comparisonDays {
                            Text((comparisonDays == 1 ? "较昨日同期 " : "较前\(comparisonDays)天 ") + String(format: "%+.0f%%", change))
                                .foregroundStyle(change >= 25 ? Palette.coral : change <= -25 ? Palette.teal : Color.secondary)
                        }
                    }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.72)
                }
            }.padding(16).cardSurface()
            if summary.total.unpriced > 0 {
                Text("\(summary.total.unpriced) 条记录未计价；金额只包含已识别价格的部分。")
                    .font(.system(size: 10)).foregroundStyle(Palette.coral).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selectedModel ?? "每日用量").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Picker("图表指标", selection: $metric) { Text("费用").tag(0); Text("Token").tag(1) }
                        .pickerStyle(.segmented).controlSize(.mini).labelsHidden().frame(width: 112)
                }
                Chart(summary.daily) { day in
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value(metric == 0 ? "美元" : "Token", metric == 0 ? day.total.cost : Double(day.total.tokens.total)))
                        .foregroundStyle(Palette.teal.gradient).cornerRadius(3)
                    if let selectedDay {
                        RuleMark(x: .value("选中日期", selectedDay, unit: .day)).foregroundStyle(.secondary.opacity(0.35))
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: min(days, 5))) { _ in AxisValueLabel(format: .dateTime.month().day()) } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .chartXSelection(value: $selectedDay)
                .frame(height: 128)
                if let day = summary.daily.first(where: { Calendar.current.isDate($0.date, inSameDayAs: selectedDay ?? .distantPast) }) {
                    Text(day.date.formatted(.dateTime.month().day()) + " · " + UsageFormat.money(day.total.cost) + " · " + UsageFormat.tokens(day.total.tokens.total) + " token")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack {
                    Text("输入 " + UsageFormat.tokens(summary.total.tokens.input))
                    Spacer()
                    Text("输出 " + UsageFormat.tokens(summary.total.tokens.output))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Text("缓存命中 " + UsageFormat.tokens(summary.total.tokens.cached) + " · " + String(format: "%.0f%%", summary.total.tokens.input > 0 ? Double(summary.total.tokens.cached) / Double(summary.total.tokens.input) * 100 : 0))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(16).cardSurface()
            modelBreakdown
            if summary.total.calls == 0 && !store.statisticsBusy {
                Text("这个时间范围内没有本地计量记录。云端任务和未保留的日志不包含在内。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("统计口径", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("本机所有账号合计，保留最近 31 天。记录不含可靠的账号归属，也不代表精确的网络请求次数。")
                    Text("费用按当前标准 API 价格估算，并非订阅账单。不含工具费用、Fast 加价、地区价格与折扣。推理 token 已包含在输出中。")
                    Text("日均和月化按所选区间已经过的实际时长线性外推；今天和 7 天会与上一等长日内时段比较。30 天因本地仅保留 31 天记录，不显示伪精确同比。")
                    Text("价格核对：" + APIPrices.checked)
                    Link("查看官方价格", destination: APIPrices.source)
                }.font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 7)
            }.font(.system(size: 11))
            if store.statistics.skipped > 0 {
                Text("有 \(store.statistics.skipped) 项记录或文件无法解析，统计可能不完整。")
                    .font(.system(size: 10)).foregroundStyle(Palette.coral)
            }
            Text("仅在本机处理 · " + DisplayTime.relative(store.statistics.checkedAt))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .onChange(of: days) { selectedDay = nil }
        .onAppear { store.scanStatistics() }
    }

    private var modelBreakdown: some View {
        let models = store.statistics.summary(days: days).models
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("按模型").font(.system(size: 11, weight: .semibold))
                Spacer()
                if selectedModel != nil { Button("显示全部") { selectedModel = nil }.font(.system(size: 10)).buttonStyle(.plain) }
            }
            ForEach(models) { model in
                Button { selectedModel = selectedModel == model.id ? nil : model.id } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(model.id).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(model.unpriced == model.calls ? "未计价" : UsageFormat.money(model.cost)).font(.system(size: 11, design: .rounded)).monospacedDigit()
                        }
                        HStack {
                            Text("\(model.calls) 条 · " + UsageFormat.tokens(model.tokens.total) + " token" + (APIPrices.usesAstraEstimate(model.id) ? " · 按 Astra 费率估算" : ""))
                            Spacer()
                            if selectedModel == model.id { Text("已筛选") }
                        }.font(.system(size: 9)).foregroundStyle(.secondary)
                    }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedModel == model.id ? Palette.teal.opacity(0.08) : .primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityLabel("筛选模型 " + model.id)
            }
        }
    }
}

struct QuotaHistoryView: View {
    let points: [QuotaPoint]
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("周额度趋势 · 7 天", isExpanded: $expanded) {
            let recent = points.filter { $0.date >= Date().addingTimeInterval(-7 * 86400) }
            if recent.count < 2 {
                Text("从本次启用开始记录，至少两次刷新后显示趋势。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                Chart(recent) { point in
                    LineMark(x: .value("时间", point.date), y: .value("剩余百分比", point.remaining), series: .value("重置周期", point.cycle))
                        .foregroundStyle(Palette.teal).lineStyle(StrokeStyle(lineWidth: 1.7))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.month().day()) } }
                .frame(height: 100).padding(.top, 12)
                Text("每 5 分钟保存一次；不同重置周期分开显示。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 10)).padding(.horizontal, 3)
    }
}
