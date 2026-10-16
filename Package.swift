// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CalDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CalDock", targets: ["CalDock"])],
    targets: [
        .target(name: "CalendarCore", resources: [.process("Resources")]),
        .executableTarget(name: "CalDock", dependencies: ["CalendarCore"]),
        .testTarget(name: "CalendarCoreTests", dependencies: ["CalendarCore"])
    ]
)
