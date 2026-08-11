//
//  SudokuTechnique.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Закреплённая таблица техник. Порядок кейсов = порядок применения в
//  HumanSolver и одновременно порядок возрастания рейтинга.
//  Версия таблицы совпадает с `HumanSolver.raterVersion` и обязана меняться
//  вместе с ней (раздел 8.3: «порядок техник и версии solver-а меняют solve path»).
//

import Foundation

public enum SudokuTechnique: Int, CaseIterable, Sendable, Codable, Comparable {
    case fullHouse = 0
    case hiddenSingleBox
    case hiddenSingleLine
    case directPointing
    case directHiddenPair
    case nakedSingle
    case directHiddenTriple
    case pointing
    case claiming
    case nakedPair
    case xWing
    case hiddenPair
    case nakedTriple
    case swordfish
    case hiddenTriple
    case xyWing
    case xyzWing
    case nakedQuad
    case jellyfish
    case hiddenQuad
    case turbotFish

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// SE-совместимый рейтинг техники.
    public var rating: Double {
        switch self {
        case .fullHouse: 1.0
        case .hiddenSingleBox: 1.2
        case .hiddenSingleLine: 1.5
        case .directPointing: 1.7
        case .directHiddenPair: 2.0
        case .nakedSingle: 2.3
        case .directHiddenTriple: 2.5
        case .pointing: 2.6
        case .claiming: 2.8
        case .nakedPair: 3.0
        case .xWing: 3.2
        case .hiddenPair: 3.4
        case .nakedTriple: 3.6
        case .swordfish: 3.8
        case .hiddenTriple: 4.0
        case .xyWing: 4.2
        case .xyzWing: 4.4
        case .nakedQuad: 5.0
        case .jellyfish: 5.2
        case .hiddenQuad: 5.4
        case .turbotFish: 6.6
        }
    }

    /// Вес шага в духе HoDoKu — из них складывается `workScore`.
    public var weight: Int {
        switch self {
        case .fullHouse: 4
        case .hiddenSingleBox: 14
        case .hiddenSingleLine: 15
        case .directPointing: 20
        case .directHiddenPair: 25
        case .nakedSingle: 4
        case .directHiddenTriple: 35
        case .pointing: 50
        case .claiming: 50
        case .nakedPair: 60
        case .xWing: 100
        case .hiddenPair: 70
        case .nakedTriple: 80
        case .swordfish: 140
        case .hiddenTriple: 100
        case .xyWing: 160
        case .xyzWing: 180
        case .nakedQuad: 130
        case .jellyfish: 470
        case .hiddenQuad: 150
        case .turbotFish: 140
        }
    }

    /// Стабильный ключ для JSON-каталога и аналитики.
    public var catalogKey: String {
        switch self {
        case .fullHouse: "fullHouse"
        case .hiddenSingleBox: "hiddenSingleBox"
        case .hiddenSingleLine: "hiddenSingleLine"
        case .directPointing: "directPointing"
        case .directHiddenPair: "directHiddenPair"
        case .directHiddenTriple: "directHiddenTriple"
        case .nakedSingle: "nakedSingle"
        case .pointing: "pointing"
        case .claiming: "claiming"
        case .nakedPair: "nakedPair"
        case .xWing: "xWing"
        case .hiddenPair: "hiddenPair"
        case .nakedTriple: "nakedTriple"
        case .swordfish: "swordfish"
        case .hiddenTriple: "hiddenTriple"
        case .xyWing: "xyWing"
        case .xyzWing: "xyzWing"
        case .nakedQuad: "nakedQuad"
        case .jellyfish: "jellyfish"
        case .hiddenQuad: "hiddenQuad"
        case .turbotFish: "turbotFish"
        }
    }

    public static func from(catalogKey: String) -> SudokuTechnique? {
        allCases.first { $0.catalogKey == catalogKey }
    }

    /// Ключ локализации названия техники (слой 2 подсказки).
    public var nameKey: String { "technique.\(catalogKey).name" }
    /// Ключ локализации объяснения логики (слой 3 подсказки).
    public var explanationKey: String { "technique.\(catalogKey).explanation" }

    /// Ставит ли техника цифру (иначе — только исключает кандидатов).
    public var placesDigit: Bool {
        switch self {
        case .fullHouse, .hiddenSingleBox, .hiddenSingleLine, .nakedSingle: true
        default: false
        }
    }
}
