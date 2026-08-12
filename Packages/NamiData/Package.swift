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
    name: "NamiData",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NamiData", targets: ["NamiData"])
    ],
    dependencies: [
        .package(path: "../NamiDomain")
    ],
    targets: [
        .target(
            name: "NamiData",
            dependencies: ["NamiDomain"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Слой хранения считался непроверяемым: SwiftData якобы требует
        // запущенного приложения. Не требует — `ModelContainer` с
        // `isStoredInMemoryOnly` поднимается в обычном SwiftPM-тесте за
        // миллисекунды. Целостность прогресса проверяется здесь, а не руками
        // на устройстве: цена ошибки в этом слое — рейтинг игрока.
        //
        // Запуск: swift test --package-path Packages/NamiData либо вместе со
        // всеми через xcodebuild test. Состав таргетов задан списком
        // `TEST_TARGETS` в Tools/generate_xcodeproj.py, а Tools/verify_project.py
        // сверяет его с каталогами на диске: тестовый файл мимо проекта
        // означал бы «зелёный» прогон, который его не запускал.
        .testTarget(
            name: "NamiDataTests",
            dependencies: ["NamiData"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
