// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    targets: [
        // Library target: all testable business logic
        .target(
            name: "ClaudeUsageKit",
            path: "Sources/ClaudeUsageKit",
            swiftSettings: [
                .unsafeFlags(["-enable-library-evolution"], .when(configuration: .debug))
            ]
        ),
        // Executable target: SwiftUI views + @main app entry point
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: ["ClaudeUsageKit"],
            path: "Sources/ClaudeUsage",
            swiftSettings: [
                .unsafeFlags(["-enable-library-evolution"], .when(configuration: .debug))
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        // Test target: depends on library, not executable
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: ["ClaudeUsageKit"],
            path: "Tests/ClaudeUsageTests"
        ),
    ]
)
