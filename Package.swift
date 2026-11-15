// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperReader",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PaperReaderKit", targets: ["PaperReaderKit"]),
        .library(name: "PaperReaderUI", targets: ["PaperReaderUI"]),
        .executable(name: "ReaderSmoke", targets: ["ReaderSmoke"]),
    ],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3")],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(
            name: "PaperReaderKit", dependencies: ["CSQLite", "SwiftSoup"],
            resources: [.copy("Resources/ThirdPartyNotices.txt"), .copy("Resources/KaTeX"), .copy("Resources/Marked")]),
        .target(
            name: "PaperReaderUI", dependencies: ["PaperReaderKit"],
            exclude: ["Platform/HTML/NoteEditor/Editor.js"],
            resources: [.copy("Platform/HTML/ReaderWarmup.html"), .copy("Platform/HTML/NoteEditor/NoteEditor.bundle")]),
        .executableTarget(name: "ReaderSmoke", dependencies: ["PaperReaderKit", "SwiftSoup"]),
        .testTarget(name: "PaperReaderKitTests", dependencies: ["PaperReaderKit"]),
        .testTarget(name: "PaperReaderWorkflowTests", dependencies: ["PaperReaderKit", "PaperReaderUI"]),
    ]
)
