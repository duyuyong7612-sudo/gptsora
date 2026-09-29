//
//  HexapodRobotModeView.swift
//  阿杜六足机器人模式 (v1: 状态栏 + 文本预览/执行 + 快捷键 + STOP)
//
//  数据来自 HexapodRobotService（统一走 AppConfig.API.apiBase → 后端 → 8081）。
//  先不做录音 / 实时语音 / Wi-Fi。
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a9c356d48d03f03b85d0548ab9b68b3d5894910ffc1e48539a965424328af3a5"
// Source-SHA256: "495556270d96ff9ef581ec5ae84c09bb1801292a5a33d419fa536997c68f7647"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

struct HexapodRobotModeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = HexapodRobotService()

    @State private var inputText: String = ""
    @State private var preview: HexResponse?
    @State private var resultLine: String = ""
    @State private var busy: Bool = false

    private let quickKeys: [(title: String, cmd: String, icon: String)] = [
        ("开机帅站", "BOOT_STAND", "figure.stand"),
        ("站立",     "STAND",      "arrow.up.circle"),
        ("趴下",     "SLEEP",      "arrow.down.circle"),
        ("回原位",   "HOME",       "house"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusBar
                    stopButton

                    Text("快捷动作").font(.headline)
                    quickGrid

                    Divider()

                    Text("文本控制").font(.headline)
                    Text("例：往前走三步，再左转，然后退回来")
                        .font(.caption).foregroundColor(.secondary)
                    inputRow

                    if let p = preview { previewCard(p) }

                    if !resultLine.isEmpty {
                        Text(resultLine).font(.footnote).foregroundColor(.secondary)
                    }

                    Text("安全限制：单步 ≤ 500ms，总动作 ≤ 60s，未识别不执行。")
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("阿杜六足机器人模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .overlay { if busy { ProgressView().scaleEffect(1.2) } }
            .task { await svc.refreshStatus() }
        }
    }

    // MARK: - Subviews

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(svc.connected ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            Text(svc.statusLine).font(.footnote).lineLimit(2)
            Spacer()
            Button { Task { await svc.refreshStatus() } } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var stopButton: some View {
        Button { stop() } label: {
            HStack { Image(systemName: "stop.fill"); Text("STOP 安全停止").bold() }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.red).foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var quickGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(quickKeys, id: \.cmd) { k in
                Button { send(k.cmd) } label: {
                    HStack { Image(systemName: k.icon); Text(k.title) }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }

    private var inputRow: some View {
        HStack {
            TextField("说点什么让六足做…", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Button("预览动作") { previewPlan() }
                .buttonStyle(.borderedProminent)
                .disabled(busy || inputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private func previewCard(_ p: HexResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let say = p.say, !say.isEmpty {
                Text("阿杜：\(say)").font(.subheadline).bold()
            }
            if let acts = p.actions, !acts.isEmpty {
                ForEach(acts) { a in
                    HStack {
                        Image(systemName: "chevron.right").font(.caption2)
                        Text(a.cmd + (a.duration_ms.map { " · \($0)ms" } ?? ""))
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            if p.need_confirm == true {
                Text("⚠️ 动作不明确或含未识别项，需确认后才执行。")
                    .font(.caption).foregroundColor(.orange)
            } else {
                Button { executePlan() } label: {
                    HStack { Image(systemName: "play.fill"); Text("执行动作") }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.green).foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(busy || (p.actions?.isEmpty ?? true))
            }
        }
        .padding()
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func previewPlan() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        busy = true; resultLine = ""
        Task {
            do {
                let r = try await svc.plan(text: text, execute: false)
                preview = r
            } catch {
                resultLine = "预览失败：\(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func executePlan() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        busy = true
        Task {
            do {
                let r = try await svc.plan(text: text, execute: true)
                resultLine = (r.executed == true) ? "已执行：\(r.say ?? "")"
                                                  : "未执行：\(r.message ?? "")"
            } catch {
                resultLine = "执行失败：\(error.localizedDescription)"
            }
            busy = false
        }
    }

    private func send(_ cmd: String) {
        busy = true
        Task {
            let r = await svc.command(cmd)
            resultLine = (r?.ok == true) ? "已发送 \(cmd)" : "发送失败 \(cmd)"
            busy = false
        }
    }

    private func stop() {
        busy = true
        Task {
            let r = await svc.command("STOP")
            resultLine = (r?.ok == true) ? "已发送 STOP（最高优先级）" : "STOP 发送失败"
            busy = false
        }
    }
}
