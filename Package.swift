// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CalDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CalDock", targets: ["CalDock"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "CalendarCore", resources: [.process("Resources")]),
        .executableTarget(name: "CalDock", dependencies: ["CalendarCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "CalendarCoreTests", dependencies: ["CalendarCore"], resources: [.copy("Fixtures")])
    ]
)
