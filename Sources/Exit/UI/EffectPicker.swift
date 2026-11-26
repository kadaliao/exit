import SwiftUI

/// One "what plays when…" row: a live preview of the current choice that opens a visual chooser.
struct EffectAssignmentRow: View {
    let event: WindowEvent
    @ObservedObject var settings = Settings.shared
    @ObservedObject var library = EffectLibrary.shared
    @State private var choosing = false

    var body: some View {
        let current = settings.assignment(for: event)
        LabeledContent {
            Button { choosing = true } label: {
                HStack(spacing: 10) {
                    AssignmentArt(assignment: current)
                        .frame(width: 84, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(current)).foregroundStyle(.primary)
                        Text(Self.subtitle(current)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(width: 210, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(T("Choose with previews", "看着预览来选"))
            .popover(isPresented: $choosing, arrowEdge: .leading) {
                EffectChooser(event: event) { choosing = false }
            }
        } label: {
            Label(event.title, systemImage: event.symbol)
        }
    }

    static func title(_ a: Assignment) -> String {
        switch a {
        case .off: T("Off", "关闭")
        case .random: T("Shuffle", "随机")
        case .effect(let id): EffectLibrary.shared.effect(id: id)?.meta.displayName ?? id
        }
    }

    static func subtitle(_ a: Assignment) -> String {
        switch a {
        case .off: T("Nothing plays.", "不播放特效。")
        case .random: T("A different effect each time.", "每次随机换一个特效。")
        case .effect(let id): EffectLibrary.shared.effect(id: id)?.meta.displayDescription ?? ""
        }
    }
}

/// Popover grid of every effect for an event, each one playing on a loop.
struct EffectChooser: View {
    let event: WindowEvent
    var done: () -> Void
    @ObservedObject var settings = Settings.shared
    @ObservedObject var library = EffectLibrary.shared

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 12)]

    var body: some View {
        let current = settings.assignment(for: event)
        let effects = library.effects.filter { $0.isReady && $0.meta.events.contains(event) }
        let shuffled = effects.filter { !settings.shuffleExcluded.contains($0.id) }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(event.title, systemImage: event.symbol).font(.headline)
                Spacer()
                Text(T("Hover to replay · ▶ plays it on your screen", "悬停可重播 · ▶ 在屏幕上实际播放"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ChoiceTile(selected: current == .off, title: T("Off", "关闭"),
                               subtitle: T("Nothing plays.", "不播放特效。"),
                               art: { SymbolArt(symbol: "nosign", muted: true) },
                               action: { pick(.off) })
                    ChoiceTile(selected: current == .random, title: T("Shuffle", "随机"),
                               subtitle: T("A different one of \(shuffled) effects each time. Pick which in Effects.",
                                           "每次从 \(shuffled) 个特效里随机挑一个，可在“特效”页调整。"),
                               art: { SymbolArt(symbol: "shuffle", muted: false) },
                               action: { pick(.random) })
                    ForEach(effects) { e in
                        EffectTile(effect: e, event: event, selected: current == .effect(e.id)) { pick(.effect(e.id)) }
                    }
                }
                .padding(2)
            }
        }
        .padding(14)
        .frame(width: 610, height: 540)
    }

    private func pick(_ a: Assignment) {
        settings.assignments[event] = a
        done()
    }
}

private struct EffectTile: View {
    @ObservedObject var effect: Effect
    let event: WindowEvent
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var replay = 0

    var body: some View {
        ChoiceTile(selected: selected, hovering: hovering, title: effect.meta.displayName,
                   subtitle: effect.meta.displayDescription ?? "",
                   art: {
                       ZStack(alignment: .bottomTrailing) {
                           EffectThumbnail(effect: effect, replay: replay)
                           if hovering {
                               Button { ExitEngine.shared.preview(effect, event: event) } label: {
                                   Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                                       .foregroundStyle(.white).frame(width: 24, height: 24)
                                       .background(Circle().fill(.black.opacity(0.45)))
                               }
                               .buttonStyle(.plain)
                               .padding(6)
                               .help(T("Play on screen", "在屏幕上播放"))
                           }
                       }
                   },
                   action: action)
            .onHover { h in
                hovering = h
                if h { replay += 1 }
            }
    }
}

private struct ChoiceTile<Art: View>: View {
    let selected: Bool
    var hovering = false
    let title: String
    let subtitle: String
    @ViewBuilder let art: () -> Art
    let action: () -> Void
    @State private var ownHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            art()
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 1))
            HStack(spacing: 4) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(
            selected ? Color.accentColor.opacity(0.12) : (hovering || ownHover) ? Color.primary.opacity(0.06) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: action)
        .onHover { ownHover = $0 }
    }
}

/// Preview art for the current choice.
struct AssignmentArt: View {
    let assignment: Assignment

    var body: some View {
        switch assignment {
        case .off: SymbolArt(symbol: "nosign", muted: true)
        case .random: SymbolArt(symbol: "shuffle", muted: false)
        case .effect(let id):
            if let e = EffectLibrary.shared.effect(id: id), e.isReady {
                EffectThumbnail(effect: e)
            } else {
                SymbolArt(symbol: "questionmark", muted: true)
            }
        }
    }
}

/// The thumbnail backdrop with a symbol on it, for "Off" and "Shuffle".
struct SymbolArt: View {
    let symbol: String
    let muted: Bool

    var body: some View {
        ZStack {
            if muted {
                Color.primary.opacity(0.06)
            } else {
                LinearGradient(colors: [Color(red: 0.24, green: 0.36, blue: 0.55), Color(red: 0.47, green: 0.32, blue: 0.52)],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
            }
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.92)))
        }
    }
}
