import SwiftUI
import UIKit
import Darwin

@MainActor
@Observable
final class LabModel {
    var status = "下载模型后，可在本机测试短文本。"
    var output = ""
    var busy = false
    var ready = false
    var cellular = false
    var selection = 0
    var reports: [ProbeReport] = []
    var export: URL?
    private var directory: URL?
    private var store: ModelStore?
    private let runner = ProbeRunner()
    private var task: Task<Void, Never>?
    private var control = ProbeControl()

    init() {
        do { store = try ModelStore() }
        catch { status = "无法读取模型清单，请重新安装验证版。" }
    }
    func download() {
        guard !busy, let store else { return }
        busy = true; ready = false; control = ProbeControl()
        let control = control, cellular = cellular
        task = Task {
            defer { busy = false; task = nil }
            do {
                directory = try await store.prepare(cellular: cellular, control: control) { [weak self] text in
                    Task { @MainActor in self?.status = text }
                }
                ready = true; status = "模型已校验，可以开始测试。"
            } catch {
                status = Self.message(control.reason ?? (error as? ProbeFailure) ?? (error is CancellationError ? .cancelled : .network))
            }
        }
    }
    func run(rounds: Int) {
        guard !busy, ready, let directory, let store else { return }
        busy = true; output = ""; control = ProbeControl()
        let control = control, prompt = ProbePolicy.prompts[selection]
        var machine = utsname(); uname(&machine)
        let device = withUnsafeBytes(of: &machine.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let os = UIDevice.current.systemVersion
        task = Task {
            defer { busy = false; task = nil }
            for round in 1...rounds {
                if control.reason != nil { break }
                status = "第 \(round) / \(rounds) 轮 · 每轮重新加载并释放"
                let report = await runner.run(directory: directory, revision: store.manifest.revision,
                    prompt: prompt, device: device, os: os, control: control) { [weak self] text in
                    Task { @MainActor in self?.output = text }
                }
                reports.append(report)
                // Keep export and visible history bounded.
                if reports.count > 20 { reports.removeFirst(reports.count - 20) }
                status = report.stop.map(Self.message) ?? "本轮完成，模型已释放。"
                if report.stop != nil { break }
            }
            saveReport()
        }
    }
    func stop(_ reason: ProbeFailure) {
        guard busy else { return }
        control.stop(reason); task?.cancel()
        status = "正在停止并释放…加载或首轮计算期间可能需要稍等。"
    }
    private func saveReport() {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("milo-mlx-report.json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(reports).write(to: url, options: .atomic)
            export = url
        } catch { status += " 报告保存失败。" }
    }
    static func message(_ error: ProbeFailure) -> String {
        switch error {
        case .cancelled: "已停止；已校验完成的文件会保留。"
        case .background: "进入后台，测试已停止。回到前台后可重新开始。"
        case .memoryWarning: "系统发出内存警告，已停止推理并释放模型。请导出报告。"
        case .budget: "输入超出 2K 总预算，本次没有开始推理。"
        case .integrity: "文件校验失败，请重新下载或检查模型清单。"
        case .network: "下载未完成，请检查网络后重试。当前大文件会重新下载。"
        case .diskSpace: "存储空间不足，请清理空间后重试。"
        case .runtime: "MLX 加载或推理失败，请导出报告。"
        case .busy: "上一项任务尚未结束。"
        }
    }
}

@main
struct MiloLabApp: App {
    @State private var model = LabModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            LabView(model: model)
                .onChange(of: phase) { _, next in if next == .background { model.stop(.background) } }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    model.stop(.memoryWarning)
                }
        }
    }
}

struct LabView: View {
    @Bindable var model: LabModel
    @State private var page = 0
    var body: some View {
        TabView(selection: $page) {
            screen(0).tabItem { Label("准备", systemImage: "arrow.down.circle") }.tag(0)
            screen(1).tabItem { Label("测试", systemImage: "bubble.left") }.tag(1)
            screen(2).tabItem { Label("报告", systemImage: "chart.bar") }.tag(2)
        }.tint(.blue)
    }
    private func screen(_ page: Int) -> some View {
        NavigationStack {
            List {
                if page == 0 {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image("Milo").resizable().scaledToFit().frame(width: 96, height: 96).accessibilityHidden(true)
                        Text("先聊一句").font(.largeTitle.bold())
                        Text("独立验证 MLX 在这台 iPhone 上的表现。\n不会读取 Moveliq 的记录。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }
                Section("1 · 准备模型") {
                    LabeledContent("Qwen3.5 · 2B · 4bit", value: "约 1.74 GB")
                    Text("来自 ModelScope。请保持 App 在前台；中断后保留已完成文件，未完成的大文件需重新下载。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("允许使用蜂窝网络下载", isOn: $model.cellular).disabled(model.busy)
                    Button(model.ready ? "重新校验模型" : "下载 / 校验模型", action: model.download).disabled(model.busy)
                }
                }
                if page == 1 {
                Section("2 · 短文本测试") {
                    Picker("测试内容", selection: $model.selection) {
                        Text("打个招呼").tag(0); Text("整理一句记录").tag(1); Text("训练常识").tag(2)
                    }.disabled(model.busy)
                    Text(ProbePolicy.prompts[model.selection]).font(.subheadline)
                    Text("2K 总预算 · 最多 256 tokens · 关闭思考 · 无联网请求")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("开始测试") { model.run(rounds: 1) }.disabled(!model.ready || model.busy)
                    Button("连续测试 5 轮") { model.run(rounds: 5) }.disabled(!model.ready || model.busy)
                    if !model.output.isEmpty { Text(model.output).textSelection(.enabled) }
                }
                }
                if page != 2 {
                Section {
                    if model.busy { ProgressView() }
                    Text(model.status).font(.subheadline).accessibilityIdentifier("labStatus")
                    if model.busy { Button("停止并释放", role: .destructive) { model.stop(.cancelled) } }
                }
                }
                if page == 2 {
                Section("3 · 内存报告") {
                    if let last = model.reports.last {
                        LabeledContent("加载", value: seconds(last.loadSeconds))
                        LabeledContent("首字（不含加载）", value: seconds(last.firstTokenSeconds))
                        LabeledContent("生成速度", value: last.tokensPerSecond.map { String(format: "%.1f tokens/s", $0) } ?? "—")
                        LabeledContent("进程采样峰值", value: last.sampledPeakFootprint.map { String(format: "%.0f MB", Double($0) / 1_000_000) } ?? "—")
                        LabeledContent("停止原因", value: last.stop?.rawValue ?? "正常完成")
                        NavigationLink("查看内存阶段") {
                            List(last.samples.filter { $0.stage != "sample" }, id: \.elapsed) { point in
                                VStack(alignment: .leading) {
                                    Text(point.stage)
                                    Text("MLX 活跃 \(point.mlxActive / 1_000_000) MB · 缓存 \(point.mlxCache / 1_000_000) MB · 峰值 \(point.mlxPeak / 1_000_000) MB")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.navigationTitle("内存阶段")
                        }
                        if let url = model.export { ShareLink("导出诊断报告", item: url) }
                    } else { Text("完成一次测试后，在这里查看结果。").foregroundStyle(.secondary) }
                    Text("报告包含设备、耗时与内存，不包含提问或回复。采样峰值可能遗漏瞬时峰值。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
            }
            .navigationTitle(["Milo Lab", "短文本测试", "内存报告"][page])
            .tint(.blue)
        }
    }
    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f 秒", $0) } ?? "—" }
}
