//
//  CellReaction.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  Кратковременная реакция ОДНОЙ клетки: вздрогнуть на ошибке, приподняться
//  в волне закрытого блока.
//
//  Почему это не часть `CellRenderState`. Render state описывает, как клетка
//  выглядит сейчас, и живёт до следующего хода. Реакция — событие: она длится
//  300 мс и не должна попадать ни в автосохранение, ни в VoiceOver. Смешать их
//  означало бы сохранять на диск «клетка сейчас дрожит».
//
//  Почему у реакции есть `token`. SwiftUI перезапускает анимацию по изменению
//  значения. Без токена вторая ошибка в той же клетке не вызвала бы ничего:
//  `kind` остался бы прежним, и с точки зрения SwiftUI ничего не поменялось.
//

import SwiftUI

public struct CellReaction: Equatable, Sendable {

    public enum Kind: String, Equatable, Sendable {
        case none
        /// Короткое горизонтальное дрожание — «бумага».
        case shake
        /// Мигание — «космос».
        case flicker
        /// Наклон и возврат пружиной — «роща».
        case wilt
        /// Приподнимание в волне закрытой группы.
        case lift
    }

    public var kind: Kind
    /// Идентификатор команды. Меняется — значит событие новое, даже если вид
    /// реакции тот же.
    public var token: UUID?
    /// Сдвиг начала для волны по клеткам группы.
    public var delay: Double

    public static let inactive = CellReaction(kind: .none, token: nil, delay: 0)

    public init(kind: Kind, token: UUID?, delay: Double = 0) {
        self.kind = kind
        self.token = token
        self.delay = delay
    }

    public var isActive: Bool { kind != .none && token != nil }

    public var duration: Double {
        switch kind {
        case .none: 0
        case .shake: 0.34
        case .flicker: 0.32
        case .wilt: 0.55
        case .lift: 0.42
        }
    }
}

public extension EffectPersonality {
    /// Как тема показывает ошибку в клетке. Во всех темах мягко: по ТЗ ошибка
    /// не наказывает, а сообщает.
    var errorReaction: CellReaction.Kind {
        switch self {
        case .ink: .shake
        case .cosmos: .flicker
        case .grove: .wilt
        // «Высокий контраст» обходится цветом и подчёркиванием: движение
        // мешает тем, кто выбрал эту тему ради разборчивости.
        case .plain: .none
        }
    }

    /// Реакция клеток закрытой группы. Волна одинакова во всех темах:
    /// это структурное событие, а не настроение.
    var groupReaction: CellReaction.Kind { self == .plain ? .none : .lift }
}

// MARK: - Геометрия дрожания

/// Затухающее горизонтальное дрожание.
///
/// `GeometryEffect`, а не `.offset`: сдвиг применяется на этапе отрисовки и
/// не трогает layout, поэтому 81 клетка не пересчитывается.
public struct ShakeEffect: GeometryEffect {

    public var amplitude: Double
    public var shakes: Double
    public var animatableData: Double

    public init(amplitude: Double = 3, shakes: Double = 2.5, progress: Double) {
        self.amplitude = amplitude
        self.shakes = shakes
        self.animatableData = progress
    }

    public func effectValue(size: CGSize) -> ProjectionTransform {
        // Затухание к концу: дрожание, обрывающееся на полной амплитуде,
        // выглядит как сбой отрисовки.
        let decay = 1 - animatableData
        let shift = amplitude * decay * sin(animatableData * .pi * shakes * 2)
        return ProjectionTransform(CGAffineTransform(translationX: shift, y: 0))
    }
}

/// Применяет реакцию к содержимому клетки.
public struct CellReactionModifier: ViewModifier {

    public let reaction: CellReaction
    public let reduceMotion: Bool

    @State private var progress: Double = 0
    @State private var activeKind: CellReaction.Kind = .none

    public init(reaction: CellReaction, reduceMotion: Bool) {
        self.reaction = reaction
        self.reduceMotion = reduceMotion
    }

    public func body(content: Content) -> some View {
        content
            .modifier(ShakeEffect(progress: activeKind == .shake ? progress : 0))
            .rotationEffect(.degrees(activeKind == .wilt ? wiltAngle : 0),
                            anchor: .bottom)
            .scaleEffect(activeKind == .lift ? liftScale : 1)
            .offset(y: activeKind == .lift ? liftOffset : 0)
            .opacity(activeKind == .flicker ? flickerOpacity : 1)
            .onChange(of: reaction.token) { _, _ in run() }
    }

    private var wiltAngle: Double {
        // Наклонился и вернулся: пик в первой трети.
        progress < 0.35 ? 7 * (progress / 0.35) : 7 * (1 - (progress - 0.35) / 0.65)
    }

    private var liftScale: Double { 1 + 0.06 * sin(progress * .pi) }
    private var liftOffset: Double { -4 * sin(progress * .pi) }
    private var flickerOpacity: Double {
        // Два коротких провала, а не плавное затухание.
        progress < 1 ? (sin(progress * .pi * 4) < 0 ? 0.35 : 1) : 1
    }

    private func run() {
        guard reaction.isActive, !reduceMotion else {
            activeKind = .none
            return
        }
        activeKind = reaction.kind
        progress = 0
        withAnimation(.linear(duration: reaction.duration).delay(reaction.delay)) {
            progress = 1
        }
        // Сброс после окончания: иначе клетка навсегда останется в конечном
        // состоянии анимации, и следующая реакция начнётся не с нуля.
        let total = reaction.duration + reaction.delay
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(total))
            guard progress >= 1 else { return }
            activeKind = .none
            progress = 0
        }
    }
}
