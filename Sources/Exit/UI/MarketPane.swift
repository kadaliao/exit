import AppKit
import SwiftUI

struct MarketPane: View {
    @ObservedObject var store = MarketStore.shared
    @ObservedObject var settings = Settings.shared
    @State private var showSources = false

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 300), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(T("Effects made by other Exit users. Try one on screen, install the ones you like.",
                           "其他 Exit 用户做的特效。可以先在屏幕上试玩，喜欢再安装。"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.loading { ProgressView().controlSize(.small) }
                    Button { Task { await store.refresh() } } label: { Label(T("Refresh", "刷新"), systemImage: "arrow.clockwise") }
                        .disabled(store.loading)
                    Button { showSources = true } label: { Label(T("Sources", "来源"), systemImage: "list.bullet") }
                    Button {
                        if let url = store.homepage(for: .official) { NSWorkspace.shared.open(url) }
                    } label: { Label(T("Website", "网页版"), systemImage: "safari") }
                }

                HStack(spacing: 24) {
                    Toggle(isOn: $settings.marketAutoInstall) {
                        Text(T("Install new effects automatically", "自动安装新上架的特效"))
                    }
                    .help(T("Subscribe: effects added to the market from now on are installed when Exit checks for news (every few hours).",
                            "订阅：从现在起上架的新特效，会在 Exit 定期检查（每隔几小时）时自动装上。"))
                    Toggle(isOn: $settings.marketAutoUpdate) {
                        Text(T("Keep installed effects up to date", "自动更新已安装的特效"))
                    }
                    Spacer()
                }
                .toggleStyle(.checkbox)

                SubmitHint()

                ForEach(store.sources) { source in
                    if let error = store.errors[source.id] {
                        Label("\(source.title): \(error)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                }
                if let error = store.actionError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                        Button(T("OK", "好")) { store.actionError = nil }.buttonStyle(.borderless)
                    }
                }
                if !store.autoInstalled.isEmpty {
                    Label(T("Installed automatically: ", "已自动安装：") + store.autoInstalled.joined(separator: T(", ", "、")),
                          systemImage: "sparkles").font(.callout).foregroundStyle(.secondary)
                }

                if store.items.isEmpty {
                    VStack(spacing: 8) {
                        if store.loading {
                            ProgressView()
                        } else {
                            Image(systemName: "storefront").font(.largeTitle).foregroundStyle(.tertiary)
                            Text(T("Nothing here yet.", "这里还什么都没有。")).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.items) { item in
                            MarketCard(item: item)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.refreshIfStale() }
        .sheet(isPresented: $showSources) { MarketSourcesSheet() }
    }
}

/// How to share your own effect.
private struct SubmitHint: View {
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            Text(T("Made one you like? Submit it from its card in Effects.", "做了满意的特效？在“特效”页它的卡片上点投稿。"))
                .foregroundStyle(.secondary)
            Button(T("Go to Effects", "去特效页")) { nav.tab = .effects }.buttonStyle(.link)
            Spacer()
        }
        .font(.callout)
    }
}

struct MarketCard: View {
    let item: MarketItem
    @ObservedObject var store = MarketStore.shared

    private var entry: MarketEntry { item.entry }
    private var preview: Effect? { store.preview(for: item) }
    /// Effects from the official market are reviewed; others only run when you ask.
    private var autoPreview: Bool { item.source.isOfficial }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let preview, preview.isReady {
                    MarketThumbnail(effect: preview)
                } else if let error = store.previewError(for: item) ?? preview?.error {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            if let preview, preview.stoppedByGuard {
                                Button(T("Turn Back On", "重新启用")) { EffectLibrary.shared.reenable(preview) }.controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .background(Color.secondary.opacity(0.06))
                } else if autoPreview || store.isLoadingPreview(item) {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "play.circle").font(.title)
                        Text(T("Click to preview", "点击预览")).font(.caption)
                    }
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.06))
                }
            }
            .frame(height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .contentShape(Rectangle())
            .onTapGesture { if preview == nil { store.loadPreview(item) } else { tryIt() } }
            .help(preview == nil && !autoPreview ? T("This effect comes from a source you added. Click to load it.", "这个特效来自你添加的来源，点击加载。")
                  : T("Click to try it on screen", "点击在屏幕上试玩"))
            .onAppear { if autoPreview { store.loadPreview(item) } }

            HStack(spacing: 6) {
                Text(entry.displayName).font(.headline).lineLimit(1)
                if let author = entry.author {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                ForEach(entry.windowEvents) { e in
                    Image(systemName: e.symbol).font(.caption).foregroundStyle(.secondary).help(e.title)
                }
            }
            Text(entry.displayDescription ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)

            HStack(spacing: 8) {
                action
                Spacer()
                Button { tryIt() } label: { Image(systemName: "play.fill") }
                    .help(T("Try it on screen", "在屏幕上试玩")).disabled(!(preview?.isReady ?? false))
                if let link = entry.webURL {
                    Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                        .help(T("View the source", "查看源码"))
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
    }

    @ViewBuilder private var action: some View {
        let status = store.status(of: item)
        if store.busy.contains(item.id) {
            ProgressView().controlSize(.small)
        } else {
            switch status {
            case .notInstalled:
                Button { store.installFromUI(item) } label: { Label(T("Install", "安装"), systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .updateAvailable:
                Button { store.installFromUI(item) } label: { Label(T("Update", "更新"), systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .installed:
                HStack(spacing: 6) {
                    Label(T("Installed", "已安装"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    Button { store.uninstall(id: entry.id) } label: { Image(systemName: "trash") }
                        .help(T("Uninstall", "卸载"))
                }
                .help(store.isShadowedByUser(item)
                      ? T("Your own copy in the Effects folder plays instead.", "你自己文件夹里的同名副本会代替它播放。") : "")
            case .incompatible(let version):
                Text(T("Needs Exit \(version)+", "需要 Exit \(version)+")).font(.caption).foregroundStyle(.secondary)
            case .otherSource:
                Text(T("Same name installed from another source", "已从别的来源装了同名特效")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tryIt() {
        if let preview, preview.isReady { ExitEngine.shared.preview(preview) }
    }
}

/// The live thumbnail used by the Effects pane, for a market preview.
private struct MarketThumbnail: View {
    @ObservedObject var effect: Effect
    var body: some View { EffectThumbnail(effect: effect) }
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
