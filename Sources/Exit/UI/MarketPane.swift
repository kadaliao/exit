import AppKit
import SwiftUI

/// The desktop behind every demo window: the same dusk gradient as the market's previews.
private let duskBlue = Color(red: 0.24, green: 0.36, blue: 0.55)
private let duskViolet = Color(red: 0.47, green: 0.32, blue: 0.52)
private let dusk = LinearGradient(colors: [duskBlue, duskViolet], startPoint: .topLeading, endPoint: .bottomTrailing)

struct MarketPane: View {
    @ObservedObject var store = MarketStore.shared
    @ObservedObject var settings = Settings.shared
    @State private var showSources = false
    @State private var installedOnly = false

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 18, alignment: .top)]

    /// Newest first; the official market's effects before other sources'.
    private var items: [MarketItem] {
        store.items.sorted {
            if $0.source.isOfficial != $1.source.isOfficial { return $0.source.isOfficial }
            let a = $0.entry.added ?? "", b = $1.entry.added ?? ""
            return a != b ? a > b : $0.entry.displayName < $1.entry.displayName
        }
    }
    private var featured: [MarketItem] {
        Array(items.filter { $0.source.isOfficial && $0.entry.isCompatible }.prefix(5))
    }
    private func isInstalled(_ item: MarketItem) -> Bool {
        switch store.status(of: item) {
        case .installed, .updateAvailable: true
        default: false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                notices
                if items.isEmpty {
                    HStack { Spacer(); controls }
                    emptyState
                } else {
                    if !featured.isEmpty { FeaturedCarousel(items: featured) }
                    gallery
                }
                ShareCard()
                updates
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.refreshIfStale() }
        .sheet(isPresented: $showSources) { MarketSourcesSheet() }
    }

    /// Refresh and the "more" menu.
    private var controls: some View {
        HStack(spacing: 12) {
            if store.loading { ProgressView().controlSize(.small) }
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help(T("Check the market for new effects", "检查市场有没有新特效")).disabled(store.loading)
            Menu {
                Button(T("Sources…", "特效来源…")) { showSources = true }
                Button(T("Open the Website", "打开网页版")) {
                    if let url = store.homepage(for: .official) { NSWorkspace.shared.open(url) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(T("More", "更多"))
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var notices: some View {
        let lines: [(String, String, Color)] =
            store.sources.compactMap { s in store.errors[s.id].map { ("\(s.title): \($0)", "exclamationmark.triangle.fill", .orange) } }
            + (store.actionError.map { [($0, "exclamationmark.triangle.fill", .orange)] } ?? [])
            + (store.autoInstalled.isEmpty ? [] : [(T("Installed automatically: ", "已自动安装：")
                + store.autoInstalled.joined(separator: T(", ", "、")), "sparkles", .accentColor)])
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(lines.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        Image(systemName: lines[i].1).foregroundStyle(lines[i].2)
                        Text(lines[i].0).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if lines[i].0 == store.actionError {
                            Button(T("OK", "好")) { store.actionError = nil }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            .font(.callout)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if store.loading {
                ProgressView()
            } else {
                Image(systemName: "storefront").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
                Text(store.errors.isEmpty ? T("Nothing here yet.", "这里还什么都没有。") : T("The market can’t be reached right now.", "暂时连不上特效市场。"))
                    .font(.title3).foregroundStyle(.secondary)
                Button(T("Try Again", "重试")) { Task { await store.refresh() } }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var gallery: some View {
        let anyInstalled = items.contains(where: isInstalled)
        let shown = installedOnly && anyInstalled ? items.filter(isInstalled) : items
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(T("All Effects", "全部特效")).font(.title2.weight(.bold))
                Text("\(shown.count)").font(.title3).foregroundStyle(.secondary)
                Spacer()
                if anyInstalled {
                    Picker("", selection: $installedOnly) {
                        Text(T("All", "全部")).tag(false)
                        Text(T("Installed", "已安装")).tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                controls.padding(.leading, 6)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                ForEach(shown) { MarketCard(item: $0) }
            }
        }
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(T("Updates", "更新")).font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ToggleRow(title: T("Install new effects automatically", "自动安装新上架的特效"),
                          detail: T("Subscribe to the market: new arrivals are installed when Exit checks for news, every few hours.",
                                    "订阅特效市场：Exit 每隔几小时检查一次，新上架的特效会自动装上。"),
                          isOn: $settings.marketAutoInstall)
                Divider().padding(.leading, 14)
                ToggleRow(title: T("Keep installed effects up to date", "自动更新已安装的特效"),
                          detail: T("When an author improves an effect, your copy updates itself.", "作者改进了特效，你装的那份会自己更新。"),
                          isOn: $settings.marketAutoUpdate)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

// MARK: - Featured

/// The newest effects, one at a time, playing large.
private struct FeaturedCarousel: View {
    let items: [MarketItem]
    @State private var index = 0
    @State private var hovering = false
    private let timer = Timer.publish(every: 9, on: .main, in: .common).autoconnect()

    var body: some View {
        let i = min(index, items.count - 1)
        VStack(spacing: 12) {
            ZStack {
                FeaturedCard(item: items[i]).id(items[i].id).transition(.opacity)
            }
            .onHover { hovering = $0 }
            if items.count > 1 {
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { k in
                        Button { withAnimation(.easeInOut(duration: 0.4)) { index = k } } label: {
                            Capsule().fill(Color.primary.opacity(k == i ? 0.75 : 0.2))
                                .frame(width: k == i ? 18 : 7, height: 7)
                        }
                        .buttonStyle(.plain)
                        .help(items[k].entry.displayName)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onReceive(timer) { _ in
            guard items.count > 1, !hovering, !ThumbnailView.stillFrames else { return }
            withAnimation(.easeInOut(duration: 0.6)) { index = (i + 1) % items.count }
        }
    }
}

private struct FeaturedCard: View {
    let item: MarketItem
    @ObservedObject var store = MarketStore.shared

    private var entry: MarketEntry { item.entry }

    var body: some View {
        let preview = store.preview(for: item)
        ZStack(alignment: .trailing) {
            Rectangle().fill(dusk)
            if let preview, preview.isReady {
                LiveStage(effect: preview, windowWidth: 0.42, windowCenterX: 0.31)
            } else {
                ProgressView().controlSize(.small).tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.trailing, 280)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.38), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.isNew ? T("New in the Market", "新上架") : T("Featured", "精选"))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                Text(entry.displayName)
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                if let author = entry.author {
                    Text(T("by \(author)", "作者 \(author)")).font(.callout).foregroundStyle(.white.opacity(0.75))
                }
                Text(entry.displayDescription ?? "")
                    .foregroundStyle(.white.opacity(0.92)).lineLimit(3).padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 14)
                HStack(spacing: 10) {
                    MarketAction(item: item, onDark: true)
                    Button { tryIt(preview) } label: { Label(T("Try", "试玩"), systemImage: "play.fill") }
                        .buttonStyle(PillButtonStyle(kind: .glass, large: true))
                        .disabled(!(preview?.isReady ?? false))
                        .help(T("Play it on your screen", "在你的屏幕上播放"))
                }
            }
            .padding(.vertical, 26).padding(.trailing, 28)
            .frame(width: 270, alignment: .leading)
        }
        .frame(height: 290)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: duskViolet.opacity(0.2), radius: 16, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { tryIt(preview) }
        .onAppear { store.loadPreview(item) }
    }

    private func tryIt(_ preview: Effect?) {
        if let preview, preview.isReady { ExitEngine.shared.preview(preview) }
    }
}

/// A live thumbnail that follows its effect (compile state, guard).
private struct LiveStage: View {
    @ObservedObject var effect: Effect
    var replay = 0
    var windowWidth: CGFloat = 0.62
    var windowCenterX: CGFloat = 0.5
    var body: some View {
        EffectThumbnail(effect: effect, replay: replay, windowWidth: windowWidth, windowCenterX: windowCenterX)
    }
}

// MARK: - Cards

struct MarketCard: View {
    let item: MarketItem
    @ObservedObject var store = MarketStore.shared
    @State private var hovering = false
    @State private var replay = 0

    private var entry: MarketEntry { item.entry }
    private var preview: Effect? { store.preview(for: item) }
    /// Effects from the official market are reviewed; others only run when you ask.
    private var autoPreview: Bool { item.source.isOfficial }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .overlay(alignment: .bottomTrailing) {
                    if hovering, preview?.isReady ?? false {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 22)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.35))
                            .padding(8).transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if preview == nil { store.loadPreview(item) } else { tryIt() } }
                .onHover { h in
                    withAnimation(.easeOut(duration: 0.15)) { hovering = h }
                    if h { replay += 1 }
                }
                .help(preview == nil && !autoPreview ? T("This effect comes from a source you added. Click to load it.", "这个特效来自你添加的来源，点击加载。")
                      : T("Click to play it on your screen", "点击在屏幕上播放"))
                .onAppear { if autoPreview { store.loadPreview(item) } }

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName).font(.headline).lineLimit(1)
                    Text(entry.author ?? item.source.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                MarketAction(item: item)
            }
            Text(entry.displayDescription ?? " ")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .contextMenu {
            Button(T("Play on Screen", "在屏幕上播放")) { tryIt() }.disabled(!(preview?.isReady ?? false))
            if store.status(of: item) == .installed || store.status(of: item) == .updateAvailable {
                Button(T("Uninstall", "卸载")) { store.uninstall(id: entry.id) }
            }
            if let link = entry.webURL {
                Button(T("View Source", "查看源码")) { NSWorkspace.shared.open(link) }
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let preview, preview.isReady {
            LiveStage(effect: preview, replay: replay)
        } else if let error = store.previewError(for: item) ?? preview?.error {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    if let preview, preview.stoppedByGuard {
                        Button(T("Turn Back On", "重新启用")) { EffectLibrary.shared.reenable(preview) }.controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .background(Color.primary.opacity(0.05))
        } else if autoPreview || store.isLoadingPreview(item) {
            ZStack {
                Rectangle().fill(dusk)
                ProgressView().controlSize(.small).tint(.white)
            }
        } else {
            ZStack {
                Rectangle().fill(dusk.opacity(0.55))
                VStack(spacing: 6) {
                    Image(systemName: "play.circle").font(.title)
                    Text(T("Click to preview", "点击预览")).font(.caption)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func tryIt() {
        if let preview, preview.isReady { ExitEngine.shared.preview(preview) }
    }
}

/// Install / Update / Installed, as a pill.
private struct MarketAction: View {
    let item: MarketItem
    var onDark = false
    @ObservedObject var store = MarketStore.shared

    var body: some View {
        if store.busy.contains(item.id) {
            ProgressView().controlSize(.small).tint(onDark ? .white : nil).frame(minWidth: 60)
        } else {
            switch store.status(of: item) {
            case .notInstalled:
                Button(T("Install", "安装")) { store.installFromUI(item) }
                    .buttonStyle(PillButtonStyle(kind: onDark ? .light : .tinted, large: onDark))
            case .updateAvailable:
                Button(T("Update", "更新")) { store.installFromUI(item) }
                    .buttonStyle(PillButtonStyle(kind: onDark ? .light : .tinted, large: onDark))
            case .installed where !onDark:
                // On a card: a compact pill whose menu holds the rest.
                Menu {
                    Button(T("Play on Screen", "在屏幕上播放")) {
                        if let p = store.preview(for: item), p.isReady { ExitEngine.shared.preview(p) }
                    }
                    Divider()
                    Button(T("Uninstall", "卸载")) { store.uninstall(id: item.entry.id) }
                } label: {
                    Label(T("Installed", "已安装"), systemImage: "checkmark")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .controlSize(.small)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                .help(store.isShadowedByUser(item)
                      ? T("Your own copy in the Effects folder plays instead.", "你自己文件夹里的同名副本会代替它播放。")
                      : T("Installed. Click for more.", "已安装，点击查看更多操作。"))
            case .installed:
                HStack(spacing: 6) {
                    Label(T("Installed", "已安装"), systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: onDark ? 13 : 12, weight: .semibold))
                        .foregroundStyle(onDark ? Color.white : Color.secondary)
                    Button { store.uninstall(id: item.entry.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(onDark ? Color.white.opacity(0.8) : Color.secondary)
                        .help(T("Uninstall", "卸载"))
                }
                .help(store.isShadowedByUser(item)
                      ? T("Your own copy in the Effects folder plays instead.", "你自己文件夹里的同名副本会代替它播放。") : "")
            case .incompatible(let version):
                Text(T("Needs Exit \(version)+", "需要 Exit \(version)+")).font(.caption)
                    .foregroundStyle(onDark ? Color.white.opacity(0.8) : Color.secondary)
            case .otherSource:
                Text(T("From another source", "已从别处安装")).font(.caption)
                    .foregroundStyle(onDark ? Color.white.opacity(0.8) : Color.secondary)
                    .help(T("An effect with this name is installed from another source.", "已从别的来源装了同名特效。"))
            }
        }
    }
}

/// App Store–style capsule buttons.
private struct PillButtonStyle: ButtonStyle {
    enum Kind { case tinted, light, glass }
    var kind: Kind = .tinted
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13 : 12, weight: .semibold))
            .padding(.horizontal, large ? 16 : 13).padding(.vertical, large ? 6 : 4)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.65 : (isEnabled ? 1 : 0.45))
    }

    private var foreground: Color {
        switch kind {
        case .tinted: .accentColor
        case .light: .black
        case .glass: .white
        }
    }
    private var background: Color {
        switch kind {
        case .tinted: Color.primary.opacity(0.09)
        case .light: .white
        case .glass: Color.white.opacity(0.2)
        }
    }
}

// MARK: - Sharing

/// Submit your own effect in one click (the sheet does the checks and the GitHub part), or hand
/// the job to a coding agent, which runs `Exit --market submit`.
private struct ShareCard: View {
    @ObservedObject private var library = EffectLibrary.shared
    @EnvironmentObject private var nav: SettingsNavigation
    @State private var copied = false

    private var mine: [Effect] { library.effects.filter { $0.origin == .user } }

    private var prompt: String {
        T("Submit one of my Exit effects to the Exit effect market. Follow the guide at \(MarketSubmit.guide.absoluteString). My effects are in ~/Library/Application Support/Exit/Effects/; ask me which one if it isn’t clear.",
          "帮我把一个 Exit 特效投稿到 Exit 特效市场，按这份指南来：\(MarketSubmit.guide.absoluteString)。我的特效在 ~/Library/Application Support/Exit/Effects/ 里，不确定是哪个就问我。")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dusk)
                Image(systemName: "paperplane.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(T("Made one you like?", "做了满意的特效？")).font(.headline)
                Text(mine.isEmpty
                     ? T("Create one with AI, then submit it here in one click.", "先用 AI 生成一个，再在这里一键投稿。")
                     : T("Submit it in one click: Exit checks it, sends it from your GitHub account and tells you how it went.",
                         "一键投稿：Exit 会检查特效，用你的 GitHub 账号提交，再告诉你结果。"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if mine.isEmpty {
                Button(T("Create with AI", "AI 生成")) { nav.tab = .ai }.buttonStyle(PillButtonStyle())
            } else {
                Menu {
                    ForEach(mine) { e in
                        Button(e.meta.displayName) { SubmissionCenter.shared.present(e) }
                    }
                } label: {
                    Text(T("Submit…", "投稿…"))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 13).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.09)))
                .help(T("Pick one of your effects to submit", "选一个你的特效投稿"))
            }
            Menu {
                Button(copied ? T("Copied", "已复制") : T("Copy a Prompt for a Coding Agent", "复制给 coding agent 的提示词")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                Button(T("Submission Guide", "投稿指南")) { NSWorkspace.shared.open(MarketSubmit.guide) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .help(T("More ways to submit", "更多投稿方式"))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

/// Lists the markets Exit reads; the official one is always there.
struct MarketSourcesSheet: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store = MarketStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newURL = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(T("Market sources", "特效来源")).font(.title3.bold())
            Text(T("Anyone can run a market: a website folder with an index.json in the same format as the official one.",
                   "任何人都可以开一个特效市场：一个网站目录，里面放一份和官方格式相同的 index.json。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(store.sources) { source in
                    HStack {
                        Image(systemName: source.isOfficial ? "checkmark.seal.fill" : "globe")
                            .foregroundStyle(source.isOfficial ? Color.accentColor : .secondary)
                        VStack(alignment: .leading) {
                            Text(source.title)
                            if source.isOfficial { Text(source.base.absoluteString).font(.caption).foregroundStyle(.secondary) }
                            if let error = store.errors[source.id] { Text(error).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        if !source.isOfficial {
                            Button(role: .destructive) {
                                settings.marketSources.removeAll { MarketSource(string: $0) == source }
                                store.sourcesChanged()
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .frame(minHeight: 120)
            HStack {
                TextField(T("https://example.com/effects/index.json", "https://example.com/effects/index.json"), text: $newURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(T("Add", "添加"), action: add).disabled(newURL.isEmpty)
            }
            if invalid {
                Text(T("That doesn’t look like a web address.", "这看起来不是一个网址。")).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(T("Done", "完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }

    private func add() {
        guard let source = MarketSource(string: newURL) else { invalid = true; return }
        invalid = false
        if !store.sources.contains(source) { settings.marketSources.append(newURL.trimmingCharacters(in: .whitespaces)) }
        newURL = ""
        store.sourcesChanged()
    }
}
