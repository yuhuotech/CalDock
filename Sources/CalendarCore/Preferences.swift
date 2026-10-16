import Foundation

public enum StatusModule: String, Codable, CaseIterable, Identifiable {
    case icon, solar, lunar, weekday, time, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .icon: return "图标"
        case .solar: return "公历"
        case .lunar: return "农历"
        case .weekday: return "星期"
        case .time: return "时间"
        case .custom: return "自定义"
        }
    }
}

public struct AppPreferences: Codable, Equatable {
    public var shortcutEnabled = true
    public var shortcutKey: UInt32 = 7 // X
    public var shortcutModifiers: UInt32 = 4352 // control + command (Carbon)
    public var shortcutLabel = "⌃⌘X"
    public var animation = false
    public var showEventDots = true
    public var showHolidayBadges = true
    public var firstWeekday = 1
    public var holidayNotifications = false
    public var automaticallyUpdatesHolidays: Bool? = true
    public var hideLunar = false
    public var hideFooter = false
    public var openOnHover = false
    public var hoverDelay = 0.35
    public var showAgenda = false
    public var appearance = "system"
    public var panelWidth = 280.0
    public var rowHeight = 32.0
    public var fontScale = 0.85
    public var backgroundColor = "#EFEFEF"
    public var titleColor = "#777777"
    public var dateColor = "#36474F"
    public var weekendColor = "#8B9599"
    public var festivalColor = "#7894A0"
    public var todayColor = "#FF453A"
    public var eventColor = "#9B79D1"
    public var workColor = "#FF8B65"
    public var restColor = "#40C8DD"
    public var modules: [StatusModule] = StatusModule.allCases
    public var enabledModules: [StatusModule] = [.icon]
    public var iconMode = "auto"
    public var iconStyle = "date"
    public var solarFormat = "M月d日"
    public var lunarFormat = "day"
    public var timeFormat = "24"
    public var showSeconds = false
    public var customFormat = "yyyy-MM-dd"
    public var disabledCalendarIDs: [String] = []
    public var darkPalette: CalendarPalette?
    public var widget: WidgetPreferences?

    public init() {}

    public var needsSecondTicks: Bool {
        (enabledModules.contains(.time) && showSeconds)
            || (enabledModules.contains(.custom) && DatePattern.containsSeconds(customFormat))
    }

    public mutating func setEnabled(_ module: StatusModule, _ enabled: Bool) {
        if enabled && !enabledModules.contains(module) { enabledModules.append(module) }
        if !enabled { enabledModules.removeAll { $0 == module } }
        if enabledModules.isEmpty { enabledModules = [.icon] }
    }

    public func normalized() -> AppPreferences {
        var p = self
        p.panelWidth = min(500, max(260, p.panelWidth.isFinite ? p.panelWidth : 280))
        p.rowHeight = min(62, max(28, p.rowHeight.isFinite ? p.rowHeight : 32))
        p.fontScale = min(1.3, max(0.75, p.fontScale.isFinite ? p.fontScale : 0.85))
        p.firstWeekday = p.firstWeekday == 2 ? 2 : 1
        p.hoverDelay = min(2, max(0.15, p.hoverDelay.isFinite ? p.hoverDelay : 0.35))
        p.customFormat = String(p.customFormat.prefix(120))
        if !["system", "light", "dark"].contains(p.appearance) { p.appearance = "system" }
        if !["auto", "light", "dark"].contains(p.iconMode) { p.iconMode = "auto" }
        p.enabledModules = p.enabledModules.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        if var widget = p.widget {
            widget.firstWeekday = widget.firstWeekday == 2 ? 2 : 1
            widget.fontScale = min(1.1, max(0.75, widget.fontScale.isFinite ? widget.fontScale : 1))
            if !["system", "light", "dark"].contains(widget.appearance) { widget.appearance = "system" }
            p.widget = widget
        }
        p.modules = p.modules.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        for m in StatusModule.allCases where !p.modules.contains(m) { p.modules.append(m) }
        if p.enabledModules.isEmpty { p.enabledModules = [.icon] }
        return p
    }
}

public enum DatePattern {
    public static func containsSeconds(_ pattern: String) -> Bool {
        var quoted = false
        for char in pattern {
            if char == "'" { quoted.toggle() }
            else if !quoted && (char == "s" || char == "S" || char == "A") { return true }
        }
        return false
    }
}

public struct StatusFormatter {
    private let formatter: DateFormatter
    public init(timeZone: TimeZone = .autoupdatingCurrent) {
        formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
    }

    public func string(_ date: Date, pattern: String) -> String {
        formatter.dateFormat = String(pattern.prefix(120))
        return String(formatter.string(from: date).prefix(80))
    }

    public func text(date: Date, preferences p: AppPreferences, engine: CalendarEngine) -> String {
        p.modules.filter { p.enabledModules.contains($0) }.compactMap { module in
            switch module {
            case .icon: return nil
            case .solar: return string(date, pattern: p.solarFormat)
            case .lunar: return p.lunarFormat == "full" ? engine.lunarInfo(date).fullLabel : engine.lunarInfo(date).dayName
            case .weekday: return string(date, pattern: "EEE")
            case .time: return string(date, pattern: (p.timeFormat == "12" ? "a h:mm" : "HH:mm") + (p.showSeconds ? ":ss" : ""))
            case .custom: return string(date, pattern: p.customFormat)
            }
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
