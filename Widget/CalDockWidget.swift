import CalendarCore
import SwiftUI
import WidgetKit

struct MonthEntry: TimelineEntry {
    let date: Date
    let preferences: WidgetPreferences
}

struct MonthProvider: TimelineProvider {
    func placeholder(in context: Context) -> MonthEntry { MonthEntry(date: Date(), preferences: WidgetPreferences()) }
    func getSnapshot(in context: Context, completion: @escaping (MonthEntry) -> Void) {
        completion(MonthEntry(date: Date(), preferences: SharedPreferences.read().widget ?? WidgetPreferences()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MonthEntry>) -> Void) {
        let settings = SharedPreferences.read().widget ?? WidgetPreferences()
        let now = Date()
        let calendar = Calendar.current
        let entries = (0..<8).map { offset in
            MonthEntry(date: offset == 0 ? now : calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!, preferences: settings)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct MonthWidgetView: View {
    let entry: MonthEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family
    private var dark: Bool { entry.preferences.appearance == "dark" || (entry.preferences.appearance == "system" && scheme == .dark) }
    private var palette: CalendarPalette { dark ? entry.preferences.dark : entry.preferences.light }
    private var engine: CalendarEngine { CalendarEngine(firstWeekday: entry.preferences.firstWeekday) }
    private var small: Bool { family == .systemSmall }

    var body: some View {
        VStack(spacing: small ? 4 : 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(StatusFormatter().string(entry.date, pattern: "yyyy / MM"))
                    .font(.system(size: (small ? 13 : 17) * entry.preferences.fontScale, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                if !entry.preferences.hideLunar {
                    Text(engine.lunarInfo(entry.date).fullLabel).font(.system(size: small ? 8 : 11))
                        .foregroundStyle(Color(hex: palette[.festival])).lineLimit(1).minimumScaleFactor(0.7)
                }
            }.foregroundStyle(Color(hex: palette[.title]))
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(names[(i + entry.preferences.firstWeekday - 1) % 7]).frame(maxWidth: .infinity)
                }
            }.font(.system(size: small ? 9 : 11)).foregroundStyle(Color(hex: palette[.title]))
            GeometryReader { geometry in
                let rows = engine.monthGrid(entry.date)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                    ForEach(rows) { day in
                        let today = engine.calendar.isDate(day.date, inSameDayAs: entry.date)
                        let color = today ? Color.white : Color(hex: palette[day.isWeekend ? .weekend : .date])
                        VStack(spacing: 0) {
                            Text("\(day.day)").font(.system(size: (small ? 10 : 14) * entry.preferences.fontScale, weight: today ? .bold : .medium, design: .rounded)).monospacedDigit()
                            if !small && !entry.preferences.hideLunar {
                                Text(day.label).font(.system(size: 8 * entry.preferences.fontScale))
                                    .foregroundStyle(today ? .white : Color(hex: palette[day.festival != nil || day.solarTerm != nil ? .festival : .date]))
                                    .lineLimit(1).minimumScaleFactor(0.6)
                            }
                        }
                        .foregroundStyle(color)
                        .frame(maxWidth: .infinity).frame(height: geometry.size.height / 6)
                        .background {
                            if today { Circle().fill(Color(hex: palette[.today])).frame(width: min(geometry.size.height / 6 - 1, small ? 20 : 34)) }
                        }
                        .overlay(alignment: .topTrailing) {
                            if entry.preferences.showHolidayBadges, let holiday = day.holiday {
                                Text(holiday.badge).font(.system(size: small ? 5 : 7))
                                    .foregroundStyle(Color(hex: palette[holiday.kind == .rest ? .rest : .work]))
                            }
                        }
                        .opacity(day.inMonth ? 1 : 0.3)
                    }
                }
            }
        }
        .padding(small ? 10 : 12)
        .containerBackground(Color(hex: palette[.background]), for: .widget)
        .widgetURL(URL(string: "caldock://today"))
    }
}

@main
struct CalDockMonthWidget: Widget {
    let kind = SharedPreferences.widgetKind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonthProvider()) { MonthWidgetView(entry: $0) }
            .configurationDisplayName("CalDock 月历")
            .description("紧凑月历、农历与节假日，点击打开菜单栏日历。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: .alphanumerics.inverted), radix: 16) ?? 0x777777
        self.init(.sRGB, red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}
