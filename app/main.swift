// Codex Switcher — 菜单式图形界面
// 由 app/build.sh 编译打包为 CodexSwitcher.app
//
// 编译: swiftc -swift-version 5 -parse-as-library -O \
//         -framework SwiftUI -framework AppKit -o CodexSwitcher main.swift

import SwiftUI
import AppKit

// MARK: - 数据模型

struct Provider: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let desc: String?
    let mode: String?
    let model: String?
    let baseUrl: String?
}

struct ProviderFile: Decodable {
    let providerId: String?
    let officialBaseUrl: String?
    let providers: [Provider]
}

// MARK: - 逻辑

final class Switcher: ObservableObject {
    @Published var providers: [Provider] = []
    @Published var currentId: String? = nil
    @Published var status: String = "读取中…"
    @Published var output: String = ""
    @Published var busy = false
    @Published var autoRestart = false
    @Published var skipVerify = false

    private var root: String {
        ProcessInfo.processInfo.environment["CODEX_SWITCHER_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex-switcher")
    }
    private var script: String { "\(root)/codex_switch.sh" }
    private var cfgPath: String {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        return (home as NSString).appendingPathComponent("config.toml")
    }
    private var providerId = "main"

    func load() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(root)/providers.json")),
           let file = try? JSONDecoder().decode(ProviderFile.self, from: data) {
            providers = file.providers
            providerId = file.providerId ?? "main"
        } else {
            output += "⚠️ 无法读取 \(root)/providers.json\n"
        }
        refresh()
    }

    /// 从 config.toml 判断当前生效的通道
    func refresh() {
        let cfg = (try? String(contentsOfFile: cfgPath, encoding: .utf8)) ?? ""
        guard !cfg.isEmpty else { status = "⚠️ 读不到 config.toml"; return }

        let pid = match(cfg, #"^model_provider = "([^"]+)""#) ?? providerId
        let block = section(cfg, pid)
        let base = match(block, #"base_url = "([^"]+)""#) ?? ""
        let hasToken = block.contains("experimental_bearer_token")
        let model = match(cfg, #"^model = "([^"]+)""#) ?? "?"

        var found: Provider?
        if hasToken {
            found = providers.first { ($0.baseUrl ?? "") == base }
        } else {
            found = providers.first { $0.mode == "chatgpt" }
        }
        currentId = found?.id

        var bits: [String] = []
        if let f = found { bits.append(f.name) }
        bits.append("provider \(pid)")
        bits.append("模型 \(model)")
        bits.append(hasToken ? "保留 ChatGPT 登录" : "官方登录")
        status = "当前: " + bits.joined(separator: "  ·  ")
    }

    func switchTo(_ p: Provider) {
        guard !busy else { return }
        busy = true
        output = ""
        var args = [p.id]
        if autoRestart { args.append("--restart") }
        if skipVerify { args.append("--no-verify") }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.output += s }
        }
        task.terminationHandler = { t in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self.output += "\n──────── 退出码 \(t.terminationStatus) ────────\n"
                self.busy = false
                self.refresh()
            }
        }
        do {
            try task.run()
        } catch {
            output += "❌ 无法运行脚本: \(error.localizedDescription)\n"
            busy = false
        }
    }

    func openLogs() { NSWorkspace.shared.open(URL(fileURLWithPath: "\(root)/logs")) }

    // MARK: 小工具

    private func match(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// 取出 `[model_providers.<id>]` 段的内容
    private func section(_ s: String, _ id: String) -> String {
        var out: [String] = []
        var inside = false
        for ln in s.components(separatedBy: "\n") {
            let t = ln.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                inside = (t == "[model_providers.\(id)]")
                continue
            }
            if inside { out.append(ln) }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - 界面

struct ContentView: View {
    @StateObject private var switcher = Switcher()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Codex Switcher").font(.title2).bold()
                Spacer()
                Button { switcher.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("重新读取当前通道")
                Button("日志") { switcher.openLogs() }.buttonStyle(.borderless)
            }

            Text(switcher.status)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(spacing: 8) {
                ForEach(switcher.providers) { p in
                    Button { switcher.switchTo(p) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: switcher.currentId == p.id ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(switcher.currentId == p.id ? .accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).fontWeight(switcher.currentId == p.id ? .bold : .regular)
                                if let d = p.desc { Text(d).font(.caption).foregroundColor(.secondary) }
                            }
                            Spacer()
                            if let m = p.model { Text(m).font(.caption).foregroundColor(.secondary) }
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(switcher.currentId == p.id ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(switcher.busy)
                }
            }

            Toggle("切换后自动退出并重启 Codex 桌面端", isOn: $switcher.autoRestart)
                .toggleStyle(.checkbox)
            Toggle("跳过真实请求验证（更快，秒级切完）", isOn: $switcher.skipVerify)
                .toggleStyle(.checkbox)

            if switcher.busy {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("正在切换…（正常情况下 2–10 秒）").font(.caption).foregroundColor(.secondary)
                }
            }

            ScrollView {
                Text(switcher.output.isEmpty ? "等待操作…" : switcher.output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
        }
        .padding(16)
        .frame(width: 480)
        .onAppear { switcher.load() }
    }
}

@main
struct CodexSwitcherApp: App {
    var body: some Scene {
        WindowGroup("Codex Switcher") { ContentView() }
    }
}
