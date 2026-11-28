import AppKit
import SwiftUI

/// Submit one of your effects to the official market: local checks, GitHub sign-in, consent,
/// one button, then the bot's answer.
struct SubmitSheet: View {
    @ObservedObject var effect: Effect
    @ObservedObject private var center = SubmissionCenter.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft: MarketSubmit.Draft?
    @State private var marketID = ""
    @State private var author = ""
    @State private var notes = ""
    @State private var agreed = false
    @State private var checking = true
    @State private var problems: [String] = []
    @State private var error: String?
    /// Showing the result of this sheet's submission rather than the form.
    @State private var sent = false

    private var sending: Bool { center.sending.contains(effect.id) }
    private var idProblem: String? { MarketSubmit.idProblem(marketID) }
    /// An effect with this id is already in the market (from someone, maybe you).
    private var replaces: MarketItem? {
        MarketStore.shared.items.first { $0.source.isOfficial && $0.entry.id == marketID }
    }
    private var canSubmit: Bool {
        draft != nil && !checking && problems.isEmpty && idProblem == nil && agreed && center.account != nil && !sending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if sent, let record = center.record(for: effect.id) {
                        SubmissionStatusView(record: record, large: true)
                    } else {
                        if let record = center.record(for: effect.id) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(T("Last time", "上次投稿")).font(.headline)
                                SubmissionStatusView(record: record)
                            }
                        }
                        checks
                        details
                        account
                        consent
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 600, height: 540)
        .task { await load() }
        .task { await center.refreshAccount() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            EffectThumbnail(effect: effect)
                .frame(width: 176, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
            VStack(alignment: .leading, spacing: 5) {
                Text(sent ? T("Submitted", "已投稿") : T("Submit to the Effect Market", "投稿到特效市场"))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(effect.meta.displayName).font(.title2.bold()).lineLimit(2)
                if let d = effect.meta.displayDescription {
                    Text(d).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                if let draft {
                    Text("\(marketID.isEmpty ? "?" : marketID).metal · \(String(format: "%.1f", Double(draft.byteCount) / 1024)) KB")
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var checks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("Checks", "检查")).font(.headline)
            if checking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(T("Compiling and test-rendering on this Mac…", "正在这台 Mac 上编译并试渲染…")).foregroundStyle(.secondary)
                }
            } else if problems.isEmpty && idProblem == nil {
                Label(T("Passes the market's checks on this Mac: compiles, starts as the untouched window, ends clean, fast enough.",
                        "在这台 Mac 上通过了市场的检查：能编译、从原窗口开始、干净结束、速度够快。"),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach((problems + (idProblem.map { [$0] } ?? [])), id: \.self) { p in
                        Label { Text(p).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                            icon: { Image(systemName: "xmark.circle.fill").foregroundStyle(.orange) }
                            .font(.callout)
                    }
                    HStack {
                        Text(T("Fix the file, then check again.", "改好文件后再检查一次。")).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button(T("Edit", "编辑")) { NSWorkspace.shared.open(effect.url) }
                        Button(T("Check Again", "重新检查")) { Task { await load() } }
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text(T("Market ID", "市场 ID")).gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 3) {
                    TextField("paper-plane", text: $marketID).textFieldStyle(.roundedBorder).font(.body.monospaced())
                    if let replaces {
                        Text(T("The market already has “\(replaces.entry.displayName)” under this id. Submitting replaces it, so only use it for your own effect.",
                               "市场里已经有一个叫这个 ID 的特效「\(replaces.entry.displayName)」。投稿会替换它，只有它是你的作品时才这样做。"))
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(T("The file name in the market: lowercase letters, digits and dashes.", "在市场里的文件名：小写字母、数字和短横线。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text(T("Author", "作者"))
                VStack(alignment: .leading, spacing: 3) {
                    TextField(center.account?.login ?? T("Your name", "你的名字"), text: $author).textFieldStyle(.roundedBorder)
                    Text(T("Shown on the effect in the market. Leave it empty to use your GitHub user name.",
                           "显示在市场里的作者名。留空就用你的 GitHub 用户名。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text(T("Note", "备注"))
                TextField(T("Optional, for the reviewer", "可选，写给审核的人"), text: $notes).textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder private var account: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
            if let signIn = center.signIn {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(T("Enter this code on GitHub:", "在 GitHub 页面上输入这个验证码："))
                        Text(signIn.userCode).font(.title3.monospaced().bold()).textSelection(.enabled)
                    }
                    Text(T("It's on the clipboard. Waiting for you to approve on github.com…", "已复制到剪贴板。等你在 github.com 上确认…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView().controlSize(.small)
                Button(T("Open GitHub", "打开 GitHub")) { NSWorkspace.shared.open(signIn.url) }
                Button(T("Cancel", "取消")) { center.cancelSignIn() }
            } else if let a = center.account {
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Submitting as @\(a.login)", "以 @\(a.login) 的身份投稿"))
                    Text(a.source == .gh ? T("Signed in through the GitHub CLI.", "通过 GitHub CLI 登录。")
                                         : T("Exit may only open issues in the market's repository.", "Exit 只能在特效市场的仓库里开 issue。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if a.source == .exit { Button(T("Sign Out", "退出登录")) { center.signOut() } }
            } else if center.accountLoading {
                ProgressView().controlSize(.small)
                Text(T("Looking for your GitHub account…", "正在查找你的 GitHub 账号…")).foregroundStyle(.secondary)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Submissions are sent from your GitHub account.", "投稿会以你的 GitHub 账号发出。"))
                    Text(center.signInError ?? T("You'll enter a code on github.com once. Exit may only open issues in the market's repository.",
                                                 "只需在 github.com 上输入一次验证码。Exit 只能在特效市场的仓库里开 issue。"))
                        .font(.caption).foregroundStyle(center.signInError == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(T("Sign in with GitHub", "用 GitHub 登录")) { center.startSignIn() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private var consent: some View {
        Toggle(isOn: $agreed) {
            Text(T("I made this effect (or may share it) and release it under the MIT License. Its code is posted publicly on GitHub from my account.",
                   "这是我做的特效（或我有权分享），同意以 MIT 许可证发布。代码会以我的账号公开发布在 GitHub 上。"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }

    private var footer: some View {
        HStack {
            if !sent {
                Button(T("Guide", "说明")) { NSWorkspace.shared.open(MarketSubmit.guide) }.buttonStyle(.link)
            }
            Spacer()
            if sent {
                Button(T("Done", "完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button(T("Cancel", "取消")) { center.cancelSignIn(); dismiss() }.keyboardShortcut(.cancelAction)
                Button { send() } label: {
                    if sending { ProgressView().controlSize(.small).frame(width: 60) } else { Text(T("Submit", "投稿")).frame(minWidth: 60) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
    }

    // MARK: Actions

    private func load() async {
        checking = true
        error = nil
        problems = []
        do {
            var d = try MarketSubmit.load(effect.url)
            // Keep an id the person typed; otherwise reuse the one sent last time.
            if marketID.isEmpty { marketID = center.record(for: effect.id)?.marketID ?? d.id }
            if draft == nil {
                author = MarketSubmit.realAuthor(d.meta) ?? UserDefaults.standard.string(forKey: "submit.author") ?? ""
            }
            d.id = marketID
            draft = d
            let checked = d
            // Compiling and test-rendering takes a moment: off the main thread.
            // The id is checked live as it's typed, so leave it out here.
            problems = await Task.detached(priority: .userInitiated) {
                let idProblem = MarketSubmit.idProblem(checked.id)
                return MarketSubmit.problems(checked).filter { $0 != idProblem }
            }.value
        } catch {
            self.error = error.localizedDescription
        }
        checking = false
    }

    private func send() {
        guard var d = draft else { return }
        d.id = marketID
        let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(name, forKey: "submit.author")
        error = nil
        Task {
            do {
                try await center.submit(effectID: effect.id, draft: d, author: name, notes: notes)
                sent = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// What became of a submission, as the bot and the review left it.
struct SubmissionStatusView: View {
    let record: SubmissionCenter.Record
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                icon.font(.system(size: large ? 30 : 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(large ? .title3.bold() : .headline)
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let url = record.webURL {
                        Button(T("View on GitHub (#\(record.number))", "在 GitHub 上查看（#\(record.number)）")) { NSWorkspace.shared.open(url) }
                            .buttonStyle(.link).font(.callout)
                    }
                }
            }
            if let report = record.report {
                let lines = SubmissionCenter.checkLines(report)
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lines, id: \.self) { l in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: l.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(l.ok ? .green : .orange)
                                Text(l.check).frame(width: 124, alignment: .leading)
                                Text(l.result).foregroundStyle(.secondary).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch record.status {
        case .checking: ProgressView().controlSize(large ? .regular : .small)
        case .accepted: Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .needsChanges: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .merged: Image(systemName: "storefront.fill").foregroundStyle(.green)
        case .declined: Image(systemName: "archivebox").foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch record.status {
        case .checking: T("Sent. The market's bot is checking it…", "已发送，特效市场的机器人正在检查…")
        case .accepted: T("Checks passed, waiting for review", "检查通过，等待审核")
        case .needsChanges: T("Needs changes", "需要修改")
        case .merged: T("In the market", "已上架")
        case .declined: T("Not accepted", "未收录")
        }
    }

    private var detail: String {
        switch record.status {
        case .checking:
            T("It renders a preview on a GitHub Mac and answers in about five minutes. You can close this; Exit keeps watching and shows the answer on the effect's card.",
              "它会在 GitHub 的 Mac 上渲染预览，大约五分钟后回复。可以先关掉这个窗口，Exit 会继续留意，结果显示在特效卡片上。")
        case .accepted:
            T("This one waits for the maintainer, usually because it replaces an effect someone else added; the bot's reply says why. Once it's merged, the effect reaches everyone's Market within minutes.",
              "这份投稿要等维护者处理，通常是因为它会替换别人添加的特效，原因见机器人的回复。合并后几分钟内，所有人的特效市场里都能看到它。")
        case .needsChanges:
            T("Fix what's marked below in the file, then press Submit again: it updates the same submission.",
              "按下面标出的问题改好文件，再点一次「投稿」，会更新同一份投稿。")
        case .merged:
            T("Merged: everyone can install it from the Market. Right after a merge it takes a few minutes to show up there.",
              "已合并，所有人都能在特效市场里安装它。刚合并时要过几分钟才会出现在市场里。")
        case .declined:
            T("The submission was closed without being merged. The issue on GitHub says why.",
              "投稿没有合并就关闭了，原因见 GitHub 上的 issue。")
        }
    }
}
