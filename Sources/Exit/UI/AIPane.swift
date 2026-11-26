import AppKit
import SwiftUI

struct AIPane: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject private var generator = EffectGenerator.shared
    @State private var showCode = false

    private let ideas: [String] = Lang.isChinese
        ? ["窗口像气球一样被戳破，碎片和彩带四散", "像一滴墨落进水里，晕开后消失", "黑客帝国式的绿色代码雨把窗口冲走",
           "窗口被折成纸飞机飞出屏幕", "像老式胶片烧穿，边缘卷曲发光", "被一圈圈涟漪荡开，最后归于平静"]
        : ["The window pops like a balloon, scraps and streamers flying", "Ink dropped in water: it blooms and dissolves",
           "Matrix-style green code rain washes it away", "Folds into a paper plane and flies off-screen",
           "Old film burning through, edges curling and glowing", "Rippled away by expanding rings until calm"]

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(T("Describe the effect you want", "描述你想要的效果")).font(.headline)
                    TextEditor(text: $generator.prompt)
                        .font(.body)
                        .frame(minHeight: 70, maxHeight: 110)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(ideas, id: \.self) { idea in
                                Button(idea) { generator.prompt = idea }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    HStack {
                        Picker("", selection: $generator.forOpen) {
                            Text(T("For closing / quitting", "用于关闭 / 退出")).tag(false)
                            Text(T("For opening (decorates)", "用于打开（装饰）")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        Spacer()
                        if generator.isWorking {
                            Text(T("Usually takes a few minutes", "通常需要几分钟"))
                                .font(.caption).foregroundStyle(.secondary)
                            ProgressView().controlSize(.small)
                            Button(T("Cancel", "取消")) { generator.cancel() }
                        } else {
                            Button {
                                generator.generate(description: generator.prompt,
                                                   events: generator.forOpen ? [.open] : [.close, .quit, .minimize])
                            } label: {
                                Label(T("Generate", "生成"), systemImage: "wand.and.stars")
                            }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(generator.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }

            if !generator.steps.isEmpty || generator.errorText != nil {
                Section(T("Progress", "进度")) {
                    ForEach(generator.steps) { step in
                        HStack(alignment: .top) {
                            Group {
                                switch step.ok {
                                case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                case .some(false): Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                                case .none: ProgressView().controlSize(.mini)
                                }
                            }
                            .frame(width: 18)
                            Text(step.text).font(.callout).textSelection(.enabled)
                        }
                    }
                    if let err = generator.errorText {
                        Text(err).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let id = generator.savedEffectID, let effect = EffectLibrary.shared.effect(id: id) {
                        GeneratedResult(effect: effect, forOpen: generator.resultForOpen)
                    }
                    if !generator.source.isEmpty {
                        DisclosureGroup(T("Shader source", "着色器源码"), isExpanded: $showCode) {
                            ScrollView {
                                Text(generator.source).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 260)
                        }
                    }
                }
            }

            AIServiceSection()
        }
        .formStyle(.grouped)
    }
}

struct GeneratedResult: View {
    @ObservedObject var effect: Effect
    let forOpen: Bool

    var body: some View {
        HStack(spacing: 14) {
            EffectThumbnail(effect: effect)
                .frame(width: 200, height: 125)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(effect.meta.displayName).font(.title3.bold())
                if let d = effect.meta.displayDescription { Text(d).foregroundStyle(.secondary) }
                HStack {
                    Button { ExitEngine.shared.preview(effect) } label: { Label(T("Play", "播放"), systemImage: "play.fill") }
                    Button {
                        let s = Settings.shared
                        if forOpen { s.assignments[.open] = .effect(effect.id) } else { s.assignments[.close] = .effect(effect.id) }
                    } label: {
                        Label(forOpen ? T("Use for opening", "设为打开特效") : T("Use for closing", "设为关闭特效"), systemImage: "checkmark")
                    }
                    Button { NSWorkspace.shared.open(effect.url) } label: { Label(T("Edit", "编辑"), systemImage: "pencil") }
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
