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
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3"),
        .package(
            url: "https://github.com/liuliu/swift-sentencepiece.git",
            revision: "4c8baf1b03569428ab38dda7fdecf27886a16c1f"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(
            name: "PaperReaderKit",
            dependencies: ["CSQLite", "SwiftSoup", .product(name: "SentencePiece", package: "swift-sentencepiece")],
            resources: [
                .copy("Resources/ThirdPartyNotices.txt"), .copy("Resources/KaTeX"), .copy("Resources/Marked"),
                .copy("Resources/Prompts"), .copy("Resources/Samples"), .copy("Resources/Embeddings"),
            ]),
        .target(
            name: "PaperReaderUI", dependencies: ["PaperReaderKit"],
            exclude: [
                "Platform/HTML/NoteEditor/Editor.js", "Platform/HTML/NoteEditor/SummaryEditor.js",
                "Platform/HTML/NoteEditor/SummarySelection.js",
            ],
            resources: [
                .process("DesignSystem/ReaderAssets.xcassets"), .copy("Platform/HTML/ReaderWarmup.html"),
                .copy("Platform/HTML/NoteEditor/NoteEditor.bundle"),
            ]),
        .executableTarget(name: "ReaderSmoke", dependencies: ["PaperReaderKit", "SwiftSoup"]),
        .target(
            name: "PaperReaderTestSupport", path: "Tests/PaperReaderTestSupport",
            resources: [.copy("Resources/Understanding Attention.pdf")]),
        .testTarget(name: "PaperReaderKitTests", dependencies: ["PaperReaderKit", "PaperReaderTestSupport"]),
        .testTarget(
            name: "PaperReaderWorkflowTests",
            dependencies: ["PaperReaderKit", "PaperReaderUI", "PaperReaderTestSupport"]),
    ]
)
