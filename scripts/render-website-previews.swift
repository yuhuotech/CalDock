import AppKit
import CalendarCore
import SwiftUI

// Render the production calendar view with in-memory settings and public demo data.
@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var value = AppPreferences()
}
extension Notification.Name {
    static let calDockShowSettings = Notification.Name("CalDockShowSettings")
}
extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0x777777
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}
@main struct WebsitePreviews {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let model = CalendarModel()
        model.month = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
        model.selected = model.month
        model.days = model.engine.monthGrid(model.month)
        for dark in [false, true] {
            AppSettings.shared.value.appearance = dark ? "dark" : "light"
            let view = CalendarView(model: model).environment(\.colorScheme, dark ? .dark : .light)
                .fixedSize(horizontal: false, vertical: true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fatalError("Unable to render calendar preview")
            }
            let name = dark ? "calendar-dark.png" : "calendar-light.png"
            try png.write(to: destination.appendingPathComponent(name))
            print("Rendered \(name): \(image.width) x \(image.height)")
        }
    }
}
