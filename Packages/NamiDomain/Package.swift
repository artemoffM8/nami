// swift-tools-version: 6.0
import PackageDescription

// Языковой режим Swift 5.
// Код писался под правила Swift 6: все value-типы Sendable, слои изолированы
// на @MainActor, общего изменяемого состояния нет. Первый билд полезнее
// видеть без стены ошибок, поэтому режим v5; строгие проверки включает
// SWIFT_STRICT_CONCURRENCY = complete в app-таргете.
// Переход на Swift 6: .v5 -> .v6 здесь и SWIFT_VERSION -> "6.0"
// в Tools/generate_xcodeproj.py.


let package = Package(
    name: "NamiDomain",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NamiDomain", targets: ["NamiDomain"])
    ],
    targets: [
        .target(
            name: "NamiDomain",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NamiDomainTests",
            dependencies: ["NamiDomain"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
