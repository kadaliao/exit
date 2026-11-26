import AppKit
import Metal

/// Turns a sentence into a working effect: asks the chosen model for a shader, compiles it,
/// renders test frames to check the rules (seamless start, clean finish, speed), and feeds
/// any problems back to the model until it passes.
@MainActor
final class EffectGenerator: ObservableObject {
    /// Shared by the settings window, so a run (and the text being typed) outlives tab switches.
    static let shared = EffectGenerator()

    enum Status: Equatable { case idle, working, done, failed }

    struct Step: Identifiable {
        let id = UUID()
        let text: String
        var ok: Bool?
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var steps: [Step] = []
    @Published private(set) var source = ""
    @Published private(set) var savedEffectID: String?
    @Published private(set) var errorText: String?
    /// The description box and the closing/opening switch in the AI pane.
    @Published var prompt = ""
    @Published var forOpen = false
    /// Whether the last run was for opening, for the "Use for…" button on its result.
    @Published private(set) var resultForOpen = false

    private var task: Task<Void, Never>?
    private let maxRepairs = 3

    var isWorking: Bool { status == .working }

    func cancel() {
        task?.cancel()
        task = nil
        if status == .working {
            status = .failed
            errorText = T("Cancelled.", "已取消。")
        }
    }

    func generate(description: String, events: Set<WindowEvent>) {
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty, !isWorking else { return }
        status = .working
        steps = []
        source = ""
        savedEffectID = nil
        errorText = nil
        resultForOpen = events == [.open]
        task = Task { await run(desc, events: events.isEmpty ? [.close, .quit] : events) }
    }

    private func step(_ text: String) { steps.append(Step(text: text)) }
    private func finishStep(_ ok: Bool) { if !steps.isEmpty { steps[steps.count - 1].ok = ok } }

    private func run(_ description: String, events: Set<WindowEvent>) async {
        do {
            let provider = Settings.shared.aiProvider
            let model = try AIService.model(for: provider)
            let effort = provider.supportsEffort ? Settings.shared.aiEffort : ""
            let who = provider.title
            // Finding a CLI may ask the login shell; keep that off the main thread.
            if case .cli(let agent) = provider { _ = await Task.detached { CLILocator.locate(agent) }.value }
            let backend = try AIService.backend(for: provider)
            let system = Self.systemPrompt()
            let eventList = events.map(\.key).sorted().joined(separator: ", ")
            var messages = [ChatMessage(role: .user, text: """
                Create a new Exit effect.

                What the user wants (may be in any language): \(description)

                Use `// @events \(eventList)`. Reply with the complete .metal file in one ```metal code block.
                """)]

            for attempt in 0...maxRepairs {
                try Task.checkCancellation()
                step(attempt == 0 ? T("\(who) is writing the shader…", "\(who) 正在编写着色器…")
                                   : T("\(who) is fixing it (round \(attempt))…", "\(who) 正在修改（第 \(attempt) 轮）…"))
                let reply = try await backend.send(system: system, messages: messages, model: model, effort: effort)
                try Task.checkCancellation()
                finishStep(true)
                guard let code = Self.extractCode(reply) else {
                    messages.append(ChatMessage(role: .assistant, text: reply))
                    messages.append(ChatMessage(role: .user, text: "I couldn't find a ```metal code block with `float4 effect(` in your reply. Send the complete file."))
                    continue
                }
                source = code

                step(T("Compiling and test-rendering…", "编译并试渲染…"))
                let problems = await Task.detached(priority: .userInitiated) { Self.validate(code) }.value
                if problems.isEmpty {
                    finishStep(true)
                    try save(code)
                    status = .done
                    return
                }
                finishStep(false)
                for p in problems { steps.append(Step(text: "· " + p.prefix(220), ok: false)) }
                messages.append(ChatMessage(role: .assistant, text: "```metal\n\(code)\n```"))
                messages.append(ChatMessage(role: .user, text: """
                    The effect does not pass the automatic checks yet:

                    \(problems.map { "- " + $0 }.joined(separator: "\n"))

                    Fix every problem and send the complete corrected file in one ```metal code block.
                    """))
            }
            // Keep the last attempt if it at least compiles, so the user can fix it by hand.
            if EffectLibrary.shared.compile(source: source, fileName: "draft.metal").pipeline != nil {
                try save(source)
                errorText = T("Saved, but it still has issues listed above. You can edit the file or try again.",
                              "已保存，但上面列出的问题还没完全解决。可以手动修改文件，或换个描述再试。")
                status = .done
            } else {
                throw AIError.process(T("Couldn't get a version that compiles. Try describing it differently.",
                                            "没能得到可编译的版本，换个描述再试试。"))
            }
        } catch is CancellationError {
            status = .failed
            errorText = T("Cancelled.", "已取消。")
        } catch {
            finishStep(false)
            status = .failed
            errorText = error.localizedDescription
        }
    }

    private func save(_ code: String) throws {
        let lib = EffectLibrary.shared
        let meta = EffectMeta.parse(source: code, fallbackName: "ai-effect")
        let id = lib.uniqueUserID(base: meta.name)
        guard lib.saveUserEffect(id: id, source: code) != nil else {
            throw AIError.process(T("Couldn't write the effect file.", "无法写入特效文件。"))
        }
        savedEffectID = id
        step(T("Saved as \(id).metal", "已保存为 \(id).metal"))
        finishStep(true)
        // Compile synchronously so the preview can play right away.
        if let e = lib.effect(id: id) {
            lib.compile(e, synchronously: true)
            ExitEngine.shared.preview(e)
        }
    }

    // MARK: Prompt

    static func systemPrompt() -> String {
        let guide = (try? String(contentsOf: Paths.authoringGuide, encoding: .utf8)) ?? ""
        var examples = ""
        for name in ["oldtv", "burn", "confetti"] {
            let url = Paths.builtInEffects.appendingPathComponent("\(name).metal")
            if let src = try? String(contentsOf: url, encoding: .utf8) {
                examples += "\n<example file=\"\(name).metal\">\n\(src)\n</example>\n"
            }
        }
        return """
            You write visual effects for Exit, a macOS app that plays a GPU animation on top of a \
            window when it closes, opens, is minimized, or when its app quits. Each effect is one \
            Metal fragment-shader file following the guide below. Your effects should look polished \
            and delightful, like something a high-end paid app would ship: considered timing and \
            easing, tasteful color, small details (glints, trails, secondary motion), and they must \
            follow the rules in the guide exactly.

            <guide>
            \(guide)
            </guide>

            Reference effects that ship with the app:
            \(examples)

            Output format: reply with exactly one ```metal code block containing the complete file — \
            the `// @` header (pick a short evocative English @name, a natural Chinese @name.zh, \
            one-line descriptions in both languages, a fitting duration and padding), any helper \
            functions (give them a unique prefix), and `float4 effect(float2 p, constant Exit& u, \
            texture2d<float> tex)`. Do not redefine anything from the prelude.
            """
    }

    static func extractCode(_ reply: String) -> String? {
        let pattern = "```(?:metal|cpp|c\\+\\+|msl)?\\s*\\n([\\s\\S]*?)```"
        if let re = try? NSRegularExpression(pattern: pattern) {
            let ns = reply as NSString
            let matches = re.matches(in: reply, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let code = ns.substring(with: m.range(at: 1))
                if code.contains("effect(") { return code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
            }
        }
        return reply.contains("float4 effect(") ? reply : nil
    }

    // MARK: Validation

    /// Compiles and renders test frames. Returns human-readable problems (empty = good).
    nonisolated static func validate(_ code: String) -> [String] {
        let lib = EffectLibrary.shared
        let result = lib.compile(source: code, fileName: "effect.metal")
        guard let pipeline = result.pipeline else {
            return ["It does not compile:\n" + (result.error ?? "unknown error")]
        }
        let meta = EffectMeta.parse(source: code, fallbackName: "effect")
        let isOpen = meta.events == [.open]
        var problems: [String] = []

        // Small test canvas: a 360x230 pt window at 1x with the effect's padding.
        let winPt = CGSize(width: 360, height: 230)
        let screenPt = CGSize(width: 900, height: 620)
        let pad = meta.padding ?? 1000
        let canvasW = Int(min(screenPt.width, winPt.width + 2 * pad))
        let canvasH = Int(min(screenPt.height, winPt.height + 2 * pad))
        guard let snap = Images.demoWindow(size: winPt, scale: 1),
              let tex = Renderer.shared.makeTexture(from: snap),
              let off = OffscreenRenderer(width: canvasW, height: canvasH) else { return [] }

        var u = ExitUniforms()
        u.size = SIMD2(Float(canvasW), Float(canvasH))
        let wx = (CGFloat(canvasW) - winPt.width) / 2, wy = (CGFloat(canvasH) - winPt.height) / 2
        u.win = SIMD4(Float(wx), Float(wy), Float(winPt.width), Float(winPt.height))
        u.cursor = SIMD2(Float(wx + 26), Float(wy + 24))
        u.duration = Float(meta.duration)
        u.scale = 1
        u.seed = 0.42
        u.corner = Float(Images.demoCorner)
        u.event = Int32(isOpen ? WindowEvent.open.rawValue : WindowEvent.close.rawValue)

        func frame(_ p: Float) -> [UInt8]? {
            u.progress = p
            u.time = p * u.duration
            return off.renderBytes(pipeline, uniforms: u, texture: tex)
        }

        // Expected first frame: the window, untouched, on a transparent canvas.
        var expected = [UInt8](repeating: 0, count: canvasW * canvasH * 4)
        expected.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: canvasW, height: canvasH, bitsPerComponent: 8,
                                      bytesPerRow: canvasW * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.draw(snap, in: CGRect(x: wx, y: CGFloat(canvasH) - wy - winPt.height, width: winPt.width, height: winPt.height))
        }

        func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var sum = 0
            for i in 0..<min(a.count, b.count) { sum += abs(Int(a[i]) - Int(b[i])) }
            return Double(sum) / Double(max(a.count, 1)) / 255
        }
        func alphaStats(_ a: [UInt8]) -> (mean: Double, max: UInt8) {
            var sum = 0, mx: UInt8 = 0
            var i = 3
            while i < a.count { sum += Int(a[i]); mx = max(mx, a[i]); i += 4 }
            return (Double(sum) / Double(a.count / 4) / 255, mx)
        }
        func lightStats(_ a: [UInt8]) -> Double {
            var sum = 0
            for i in stride(from: 0, to: a.count, by: 4) { sum += Int(a[i]) + Int(a[i + 1]) + Int(a[i + 2]) }
            return Double(sum) / Double(a.count / 4 * 3) / 255
        }

        guard let f0 = frame(0), let fMid = frame(0.45), let f1 = frame(1) else {
            return ["Rendering failed on the GPU (possibly an infinite loop or out-of-bounds access)."]
        }

        if isOpen {
            let a0 = alphaStats(f0), a1 = alphaStats(f1)
            if a0.max > 8 || lightStats(f0) > 0.004 { problems.append("At progress 0 the canvas must be fully transparent (it is an open effect that decorates a visible window).") }
            if a1.max > 8 || lightStats(f1) > 0.004 { problems.append("At progress 1 the canvas must be fully transparent.") }
            if alphaStats(fMid).mean > 0.35 { problems.append("Mid-way the canvas is too opaque (mean alpha \(String(format: "%.2f", alphaStats(fMid).mean))). An open effect must only add light and accents over the window, never cover it.") }
            if lightStats(fMid) < 0.002 && alphaStats(fMid).mean < 0.002 { problems.append("Mid-way nothing visible is drawn.") }
        } else {
            let d0 = meanDiff(f0, expected)
            if d0 > 0.006 {
                problems.append(String(format: "At progress 0 the output differs from the untouched window (mean difference %.3f). It must be exactly sampleWindow(tex, u, p) with nothing else drawn, so the hand-off from the real window is invisible.", d0))
            }
            let a1 = alphaStats(f1)
            if a1.max > 6 || lightStats(f1) > 0.004 {
                problems.append("At progress 1 the canvas is not fully transparent (max alpha \(a1.max)/255). Everything must be gone by the end.")
            }
            if meanDiff(fMid, f0) < 0.002 { problems.append("At progress 0.45 the output still looks like the untouched window; the effect should be well underway.") }
        }

        // Speed at a realistic Retina size.
        let bigW = Int(min(2560, 1440 + 2 * pad * 2)), bigH = Int(min(1600, 920 + 2 * pad * 2))
        if let big = OffscreenRenderer(width: bigW, height: bigH) {
            var ub = u
            ub.size = SIMD2(Float(bigW), Float(bigH))
            ub.scale = 2
            ub.win = SIMD4(Float(bigW - 1440) / 2, Float(bigH - 920) / 2, 1440, 920)
            ub.corner = Float(Images.demoCorner * 2)
            let ms = big.benchmark(pipeline, uniforms: ub, texture: tex, frames: 12)
            if ms > 7 {
                problems.append(String(format: "Too slow: %.1f ms per frame at %dx%d on this Mac (budget 7 ms). Shorten loops and skip work early.", ms, bigW, bigH))
            }
        }
        return problems
    }
}
