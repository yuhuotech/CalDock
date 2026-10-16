import Foundation

public enum PaletteRole: String, CaseIterable, Codable {
    case background, title, date, weekend, festival, today, event, work, rest
}

public struct CalendarPalette: Codable, Equatable {
    public var colors: [PaletteRole: String]
    public init(dark: Bool = false) {
        colors = [.background: dark ? "#25272B" : "#EFEFEF", .title: dark ? "#A6AFB5" : "#777777",
                  .date: dark ? "#E4E8EA" : "#36474F", .weekend: dark ? "#929DA5" : "#8B9599",
                  .festival: dark ? "#9DB9C5" : "#7894A0", .today: "#FF453A", .event: "#9B79D1",
                  .work: "#FF8B65", .rest: "#40C8DD"]
    }
    public subscript(_ role: PaletteRole) -> String {
        get { colors[role] ?? CalendarPalette().colors[role]! }
        set { colors[role] = newValue }
    }
}

public struct WidgetPreferences: Codable, Equatable {
    public var appearance = "system"
    public var firstWeekday = 1
    public var hideLunar = false
    public var showHolidayBadges = true
    public var fontScale = 1.0
    public var light = CalendarPalette()
    public var dark = CalendarPalette(dark: true)
    public init() {}
}

public extension AppPreferences {
    func palette(dark: Bool) -> CalendarPalette {
        if dark { return darkPalette ?? CalendarPalette(dark: true) }
        var palette = CalendarPalette()
        palette.colors = [.background: backgroundColor, .title: titleColor, .date: dateColor,
                          .weekend: weekendColor, .festival: festivalColor, .today: todayColor,
                          .event: eventColor, .work: workColor, .rest: restColor]
        return palette
    }

    mutating func setColor(_ color: String, role: PaletteRole, dark: Bool) {
        if dark {
            var palette = darkPalette ?? CalendarPalette(dark: true)
            palette[role] = color
            darkPalette = palette
        } else {
            switch role {
            case .background: backgroundColor = color
            case .title: titleColor = color
            case .date: dateColor = color
            case .weekend: weekendColor = color
            case .festival: festivalColor = color
            case .today: todayColor = color
            case .event: eventColor = color
            case .work: workColor = color
            case .rest: restColor = color
            }
        }
    }

    var effectiveRowHeight: Double { max(rowHeight, ceil(32 * fontScale)) }
}

public enum SharedPreferences {
    public static let groupID = "3BH46GJY6D.com.yuhuo.caldock"
    public static let widgetKind = "CalDock.MonthCalendar"
    public static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("Library/Application Support/CalDock/preferences.json")
    }
    public static func read() -> AppPreferences {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(AppPreferences.self, from: data) else { return AppPreferences() }
        return value.normalized()
    }
    public static func write(_ value: AppPreferences) throws {
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
