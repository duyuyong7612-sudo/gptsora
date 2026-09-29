// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-e13434909acae0bfce3425d024e2aed8ee8bdc0227caa920a3d6f9c90946dd0e"
// Source-SHA256: "49ebfa6af624b337460245845c02b46a3f09c2877960ffe95c029023f210abf7"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

// MARK: - Codex Agent API client
// 唯一职责:封装后端两个 endpoint 的 HTTP 调用,绝不直接调 Codex CLI / shell / git。
//   GET  /api/adu/codex/health   → 返回 {ok, codex_installed?, codex_version?, ...}
//   POST /api/adu/codex/run      body {task, project_dir, timeout}
//                                → 返回 {ok, exit_code, stdout, stderr, duration_sec,
//                                       needs_user_confirmation?, blocked_terms?, ...}
//
// 安全约束:
//   - App 永不持有 OpenAI / Anthropic key —— 全部由后端读 .env
//   - 不展示完整 key;后端如果返回 key 字面值,本 client 也不会特意打印
//   - needs_user_confirmation=true 时,调用方只展示,不继续执行(本 client 不做"自动继续")

struct CodexHealthResult: Equatable {
    let ok: Bool
    let codexInstalled: Bool?
    let codexVersion: String?
    let error: String?
    let httpStatus: Int
    let raw: String                 // 原始 JSON 字符串(供调试)

    static let empty = CodexHealthResult(
        ok: false, codexInstalled: nil, codexVersion: nil,
        error: nil, httpStatus: -1, raw: ""
    )
}

struct CodexRunResult: Equatable {
    let ok: Bool
    let exitCode: Int?
    let stdout: String
    let stderr: String
    let durationSec: Double?
    let needsUserConfirmation: Bool
    let blockedTerms: [String]
    let riskReason: String
    let error: String?
    let message: String?
    let httpStatus: Int
    // 阿杜自动选工程时,后端把解析结果回显在这里(项目 id + 落到磁盘的绝对路径)
    let projectId: String?
    let projectDir: String?
}

enum CodexAgentClient {

    static func health(apiBase: String) async -> CodexHealthResult {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/adu/codex/health") else {
            return CodexHealthResult(ok: false, codexInstalled: nil, codexVersion: nil,
                                     error: "invalid_api_base", httpStatus: -1, raw: "")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let raw = String(data: data, encoding: .utf8) ?? ""
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let okFromHTTP = (200..<300).contains(code)
            let ok = (json["ok"] as? Bool) ?? okFromHTTP
            // 后端 /api/adu/codex/health 真实返回(2026-05 抓包确认):
            //   ok, message, codex_path, version, auth_source,
            //   has_openai_api_key, has_codex_api_key, skip_git_repo_check, allow_paths
            // **不返回** codex_installed / installed —— 之前 iOS 一直 nil → 显示
            // "backend ok / codex ?",根因在此。
            // 语义:后端 ok=true 即"Codex CLI 可用"(message 也明说),直接用 ok 推导。
            let version = (json["codex_version"] as? String) ?? (json["version"] as? String)
            let installed: Bool? = {
                // 兼容字段(若以后后端真加上)
                if let explicit = (json["codex_installed"] as? Bool) ?? (json["installed"] as? Bool) {
                    return explicit
                }
                return ok
            }()
            let err: String? = {
                if !ok {
                    if let s = json["error"] as? String, !s.isEmpty { return s }
                    if let s = json["detail"] as? String, !s.isEmpty { return s }
                    if !okFromHTTP { return "HTTP \(code)" }
                }
                return nil
            }()
            return CodexHealthResult(ok: ok, codexInstalled: installed,
                                     codexVersion: version, error: err,
                                     httpStatus: code, raw: raw)
        } catch {
            // 网络失败 → 顶层固定为 "unreachable",详细原因塞进 raw 给调试用
            return CodexHealthResult(
                ok: false, codexInstalled: nil, codexVersion: nil,
                error: "unreachable",
                httpStatus: -1,
                raw: "\(type(of: error)): \(error.localizedDescription)"
            )
        }
    }

    static func run(apiBase: String,
                    task: String,
                    projectDir: String,
                    timeout: Int,
                    projectId: String? = nil) async -> CodexRunResult {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // ✅ 统一通道：Run Codex 不再直连 /api/adu/codex/run，
        //    改走 /api/adu/unified/input（coding 路由 → 后端 automation executor）。
        guard let url = URL(string: base + "/api/adu/unified/input") else {
            return CodexRunResult(
                ok: false, exitCode: nil, stdout: "", stderr: "",
                durationSec: nil, needsUserConfirmation: false,
                blockedTerms: [], riskReason: "",
                error: "invalid_api_base", message: nil, httpStatus: -1,
                projectId: nil, projectDir: nil
            )
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 留点 headroom:URLSession 超时 = 后端 timeout + 30 秒
        req.timeoutInterval = max(60, TimeInterval(timeout) + 30)

        // 统一入口参数（自动化编程任务，绝不触发电脑控制）：
        //   source=coding_button / surface=coding / intent_hint=coding
        //   requires_code_agent=true / requires_computer=false
        // 后端 coding 路由再转发到 automation executor(engine=codex)。
        var body: [String: Any] = [
            "source": "coding_button",
            "surface": "coding",
            "intent_hint": "coding",
            "requires_code_agent": true,
            "requires_computer": false,
            "text": task,
            "engine": "codex",
            "project_dir": projectDir,
        ]
        if let pid = projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !pid.isEmpty {
            body["project_id"] = pid
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            // 统一响应：真正的 codex 执行结果在 outer["result"] 里
            //（兼容后端直接返回 codex 结果的情况）。
            let inner = (outer["result"] as? [String: Any]) ?? outer
            return parse(json: inner, httpStatus: code,
                         fallbackRaw: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return CodexRunResult(
                ok: false, exitCode: nil, stdout: "", stderr: "",
                durationSec: nil, needsUserConfirmation: false,
                blockedTerms: [], riskReason: "",
                error: "network_error",
                message: "\(type(of: error)): \(error.localizedDescription)",
                httpStatus: -1,
                projectId: nil, projectDir: nil
            )
        }
    }

    private static func parse(json: [String: Any],
                              httpStatus: Int,
                              fallbackRaw: String) -> CodexRunResult {
        let ok = (json["ok"] as? Bool) ?? false
        let exit = (json["exit_code"] as? Int) ?? (json["exitCode"] as? Int)
        let stdout = (json["stdout"] as? String) ?? ""
        let stderr = (json["stderr"] as? String) ?? ""
        let dur: Double? = {
            if let d = json["duration_sec"] as? Double { return d }
            if let d = json["duration"] as? Double { return d }
            if let i = json["duration_sec"] as? Int { return Double(i) }
            if let i = json["duration"] as? Int { return Double(i) }
            return nil
        }()
        let needs = (json["needs_user_confirmation"] as? Bool) ?? false
        let blocked = (json["blocked_terms"] as? [String])
            ?? (json["blocked"] as? [String])
            ?? []
        let risk = (json["risk_reason"] as? String)
            ?? (json["reason"] as? String)
            ?? ""
        var err = json["error"] as? String
        if (err ?? "").isEmpty, !(200..<300).contains(httpStatus) {
            err = "HTTP \(httpStatus)"
        }
        let msg = (json["message"] as? String)
            ?? (json["final_text"] as? String)
            ?? (json.isEmpty && !fallbackRaw.isEmpty ? fallbackRaw : nil)
        let pid = (json["project_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let pdir = (json["project_dir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CodexRunResult(
            ok: ok, exitCode: exit, stdout: stdout, stderr: stderr,
            durationSec: dur, needsUserConfirmation: needs,
            blockedTerms: blocked, riskReason: risk,
            error: err, message: msg, httpStatus: httpStatus,
            projectId: pid, projectDir: pdir
        )
    }
}
