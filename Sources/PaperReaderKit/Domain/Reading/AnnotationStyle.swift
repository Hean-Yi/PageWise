public enum AnnotationStyle: String, Codable, Sendable, CaseIterable {
    case highlight, underline
}

public enum AnnotationColor: String, Codable, Sendable, CaseIterable {
    case yellow, red, green, blue, purple, pink, orange, gray

    public var label: String {
        switch self {
        case .yellow: "黄色"
        case .red: "红色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .pink: "粉色"
        case .orange: "橙色"
        case .gray: "灰色"
        }
    }

    /// The same paper pigments are used for the palette and saved ink in each reader.
    public var rgb: UInt32 {
        switch self {
        case .yellow: 0xf2d36b
        case .red: 0xf5aaa6
        case .green: 0xb7db9e
        case .blue: 0xb5d5f8
        case .purple: 0xcbb7ed
        case .pink: 0xedbdd8
        case .orange: 0xf5c28f
        case .gray: 0xd1d4d7
        }
    }

    public var hex: String {
        let value = String(rgb, radix: 16)
        return "#" + String(repeating: "0", count: 6 - value.count) + value
    }
}
