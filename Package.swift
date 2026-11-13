// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperReader",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PaperReaderKit", targets: ["PaperReaderKit"]),
        .library(name: "PaperReaderUI", targets: ["PaperReaderUI"]),
        .executable(name: "ReaderSmoke", targets: ["ReaderSmoke"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "PaperReaderKit", dependencies: ["CSQLite"]),
        .target(name: "PaperReaderUI", dependencies: ["PaperReaderKit"]),
        .executableTarget(name: "ReaderSmoke", dependencies: ["PaperReaderKit"]),
        .testTarget(name: "PaperReaderKitTests", dependencies: ["PaperReaderKit"]),
        .testTarget(name: "PaperReaderWorkflowTests", dependencies: ["PaperReaderKit", "PaperReaderUI"])
    ]
)
