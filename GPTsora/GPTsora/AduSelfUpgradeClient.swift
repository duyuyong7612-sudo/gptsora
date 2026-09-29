// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-f2e0d287c5234889917efd07bdbd3ef04f34ab280c7d013b6aa7be0ca91a7120"
// Source-SHA256: "c235b4f7a3eb99e6389b0b933a2b569cbd57e0a38ea0c50a24a95207691ec13a"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Foundation

// MARK: - Adu Self Upgrade
//
// 唯一职责:封装后端的 POST /api/adu/self/upgrade/plan。
//
//   - 永远 mode=plan_only。第一版后端 v1 也只允许 plan_only。
//   - 不在 App 端把任何 .env / token 塞进 system_state。
//   - 不会自动触发 /api/adu/codex/run —— 该接口在 EngineeringAgentPanel
//     的 Run Codex 按钮里;本 client 只负责"拿计划"。

struct AduSelfUpgradeVerificationStep: Codable, Equatable, Identifiable {
    let tool: String
    let command: String
    let description: String?
    var id: String { tool + "::" + command }
}

struct AduSelfUpgradeRecommended: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let reason: String
    let capabilityId: String?
    let executor: String
    let projectId: String?
    let riskLevel: String
    let estimatedCostLevel: String
    let suggestedMode: String
    let mode: String
    let requiresUserConfirmation: Bool
    let codexPrompt: String
    let verificationSteps: [AduSelfUpgradeVerificationStep]
}

struct AduSelfUpgradeTodayPriority: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let riskLevel: String
    let executor: String
}

struct AduSelfUpgradeCapabilitySummary: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let status: String
    let stability: Double
}

struct AduSelfUpgradePlan: Codable, Equatable {
    let ok: Bool
    // V2 闭环:走 POST /api/adu/self/sessions 时后端会返回 session_id;
    // 老的 /upgrade/plan 不带这个字段 → 解为 nil。
    let sessionId: String?
    let identity: String
    let longTermGoals: [String]
    let coreParinciples: [String]?      // 后端拼写笔误兜底,如果出现就解到这里
    let corePrinciples: [String]?
    let hardConstraints: [String]?
    let goal: String?
    let surface: String?
    let modeRequested: String?
    let modeEffective: String?
    let currentState: [String]
    let capabilityBuckets: [String]
    let capabilityMapSummary: [AduSelfUpgradeCapabilitySummary]
    let findings: [String]
    let recommendedUpgrades: [AduSelfUpgradeRecommended]
    let todayPriorities: [AduSelfUpgradeTodayPriority]
    let evolutionMemorySummary: String?
    let evolutionMemoryCount: Int?
    let requiresUserConfirmation: Bool
    let autoExecuted: Bool
    let message: String

    var resolvedPrinciples: [String] {
        // 优先取正确拼写 corePrinciples;若后端历史返回 coreParinciples 也兼容。
        corePrinciples ?? coreParinciples ?? []
    }
}

struct AduSelfUpgradePlanResult: Equatable {
    let plan: AduSelfUpgradePlan?
    let httpStatus: Int
    let errorMessage: String?
}

enum AduSelfUpgradePlanError: LocalizedError {
    case invalidAPIBase
    case http(status: Int, body: String, endpoint: String)
    case decode(body: String, endpoint: String)
    case transport(message: String, endpoint: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIBase:
            return "invalid_api_base"
        case .http(let status, let body, let endpoint):
            if status == 404 {
                return "后端未挂载 /api/adu/self/upgrade/plan\nendpoint: \(endpoint)"
            }
            return "HTTP status: \(status)\nresponse body: \(body)\nendpoint: \(endpoint)"
        case .decode(let body, let endpoint):
            return "decode_failed\nresponse body: \(body)\nendpoint: \(endpoint)"
        case .transport(let message, let endpoint):
            return "\(message)\nendpoint: \(endpoint)"
        }
    }
}

extension AduSelfUpgradeVerificationStep {
    init(json: [String: Any]) {
        self.tool = AduSelfUpgradeJSON.string(json["tool"], fallback: "cmd")
        self.command = AduSelfUpgradeJSON.string(json["command"])
        self.description = AduSelfUpgradeJSON.optionalString(json["description"])
    }
}

extension AduSelfUpgradeRecommended {
    init(json: [String: Any], index: Int) {
        self.id = AduSelfUpgradeJSON.string(json["id"], fallback: "upgrade_\(index + 1)")
        self.title = AduSelfUpgradeJSON.string(json["title"], fallback: "未命名升级项")
        self.reason = AduSelfUpgradeJSON.string(json["reason"])
        self.capabilityId = AduSelfUpgradeJSON.optionalString(json["capability_id"] ?? json["capabilityId"])
        self.executor = AduSelfUpgradeJSON.string(json["executor"])
        self.projectId = AduSelfUpgradeJSON.optionalString(json["project_id"] ?? json["projectId"])
        self.riskLevel = AduSelfUpgradeJSON.string(json["risk_level"] ?? json["riskLevel"], fallback: "unknown")
        self.estimatedCostLevel = AduSelfUpgradeJSON.string(json["estimated_cost_level"] ?? json["estimatedCostLevel"], fallback: "unknown")
        let suggested = AduSelfUpgradeJSON.string(json["suggested_mode"] ?? json["suggestedMode"], fallback: "plan_only")
        self.suggestedMode = suggested
        self.mode = AduSelfUpgradeJSON.string(json["mode"], fallback: suggested)
        self.requiresUserConfirmation = AduSelfUpgradeJSON.bool(json["requires_user_confirmation"] ?? json["requiresUserConfirmation"], fallback: true)
        self.codexPrompt = AduSelfUpgradeJSON.string(json["codex_prompt"] ?? json["codexPrompt"])
        let rawSteps = json["verification_steps"] ?? json["verificationSteps"]
        self.verificationSteps = AduSelfUpgradeJSON.array(rawSteps).enumerated().compactMap { _, item in
            if let dict = item as? [String: Any] { return AduSelfUpgradeVerificationStep(json: dict) }
            if let text = item as? String {
                return AduSelfUpgradeVerificationStep(tool: "cmd", command: text, description: nil)
            }
            return nil
        }
    }
}

extension AduSelfUpgradeTodayPriority {
    init(json: [String: Any], index: Int) {
        self.id = AduSelfUpgradeJSON.string(json["id"], fallback: "priority_\(index + 1)")
        self.title = AduSelfUpgradeJSON.string(json["title"], fallback: AduSelfUpgradeJSON.string(json["summary"]))
        self.riskLevel = AduSelfUpgradeJSON.string(json["risk_level"] ?? json["riskLevel"], fallback: "unknown")
        self.executor = AduSelfUpgradeJSON.string(json["executor"])
    }
}

extension AduSelfUpgradeCapabilitySummary {
    init(json: [String: Any], index: Int) {
        let fallbackId = "capability_\(index + 1)"
        let parsedId = AduSelfUpgradeJSON.string(json["id"], fallback: fallbackId)
        self.id = parsedId
        self.name = AduSelfUpgradeJSON.string(json["name"], fallback: parsedId)
        self.status = AduSelfUpgradeJSON.string(json["status"], fallback: AduSelfUpgradeJSON.string(json["summary"]))
        self.stability = AduSelfUpgradeJSON.double(json["stability"], fallback: 0)
    }
}

extension AduSelfUpgradePlan {
    init(json: [String: Any]) {
        self.ok = AduSelfUpgradeJSON.bool(json["ok"], fallback: false)
        self.sessionId = AduSelfUpgradeJSON.optionalString(json["session_id"] ?? json["sessionId"])
        self.identity = AduSelfUpgradeJSON.string(json["identity"])
        self.longTermGoals = AduSelfUpgradeJSON.stringList(json["long_term_goals"] ?? json["longTermGoals"])
        self.coreParinciples = AduSelfUpgradeJSON.stringListOrNil(json["core_parinciples"] ?? json["coreParinciples"])
        self.corePrinciples = AduSelfUpgradeJSON.stringListOrNil(json["core_principles"] ?? json["corePrinciples"])
        self.hardConstraints = AduSelfUpgradeJSON.stringListOrNil(json["hard_constraints"] ?? json["hardConstraints"])
        self.goal = AduSelfUpgradeJSON.optionalString(json["goal"])
        self.surface = AduSelfUpgradeJSON.optionalString(json["surface"])
        self.modeRequested = AduSelfUpgradeJSON.optionalString(json["mode_requested"] ?? json["modeRequested"])
        self.modeEffective = AduSelfUpgradeJSON.optionalString(json["mode_effective"] ?? json["modeEffective"])
        self.currentState = AduSelfUpgradeJSON.stringList(json["current_state"] ?? json["currentState"])
        self.capabilityBuckets = AduSelfUpgradeJSON.stringList(json["capability_buckets"] ?? json["capabilityBuckets"])
        self.capabilityMapSummary = AduSelfUpgradeJSON.array(json["capability_map_summary"] ?? json["capabilityMapSummary"]).enumerated().compactMap { index, item in
            guard let dict = item as? [String: Any] else { return nil }
            return AduSelfUpgradeCapabilitySummary(json: dict, index: index)
        }
        self.findings = AduSelfUpgradeJSON.stringList(json["findings"])
        self.recommendedUpgrades = AduSelfUpgradeJSON.array(json["recommended_upgrades"] ?? json["recommendedUpgrades"]).enumerated().compactMap { index, item in
            guard let dict = item as? [String: Any] else { return nil }
            return AduSelfUpgradeRecommended(json: dict, index: index)
        }
        self.todayPriorities = AduSelfUpgradeJSON.array(json["today_priorities"] ?? json["todayPriorities"]).enumerated().compactMap { index, item in
            if let dict = item as? [String: Any] { return AduSelfUpgradeTodayPriority(json: dict, index: index) }
            if let text = item as? String {
                return AduSelfUpgradeTodayPriority(id: "priority_\(index + 1)", title: text, riskLevel: "unknown", executor: "")
            }
            return nil
        }
        self.evolutionMemorySummary = AduSelfUpgradeJSON.optionalString(json["evolution_memory_summary"] ?? json["evolutionMemorySummary"])
        self.evolutionMemoryCount = AduSelfUpgradeJSON.int(json["evolution_memory_count"] ?? json["evolutionMemoryCount"])
        self.requiresUserConfirmation = AduSelfUpgradeJSON.bool(json["requires_user_confirmation"] ?? json["requiresUserConfirmation"], fallback: true)
        self.autoExecuted = AduSelfUpgradeJSON.bool(json["auto_executed"] ?? json["autoExecuted"], fallback: false)
        self.message = AduSelfUpgradeJSON.string(json["message"])
    }
}

private enum AduSelfUpgradeJSON {
    static func string(_ value: Any?, fallback: String = "") -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let value { return compactJSONString(value) }
        return fallback
    }

    static func optionalString(_ value: Any?) -> String? {
        let s = string(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func bool(_ value: Any?, fallback: Bool) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "y": return true
            case "false", "0", "no", "n": return false
            default: break
            }
        }
        return fallback
    }

    static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func double(_ value: Any?, fallback: Double) -> Double {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let d = Double(s) { return d }
        return fallback
    }

    static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    static func stringListOrNil(_ value: Any?) -> [String]? {
        let items = stringList(value)
        return items.isEmpty ? nil : items
    }

    static func stringList(_ value: Any?) -> [String] {
        if let strings = value as? [String] { return strings }
        if let values = value as? [Any] {
            return values.map { string($0) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if let dict = value as? [String: Any] {
            return dict.keys.sorted().map { key in
                "\(key): \(string(dict[key]))"
            }
        }
        if let s = optionalString(value) { return [s] }
        return []
    }

    static func compactJSONString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        return s
    }
}

// MARK: - Evolution Memory client
//
// 唯一职责:封装 POST /api/adu/self/evolution-memory。
// 安全约束:
//   - 永远不上传完整 stdout / stderr —— 调用方必须只传摘要(单字段后端会再做 4 KB 截断)。
//   - 永远不上传 .env / token / credentials —— 后端 verifier 的 scrub 兜底,但这里也克制。
//   - 失败时静默(返回 ok=false + error),不阻塞 UI;调用方决定要不要在 timeline 留 tool_error。

struct AduEvolutionMemoryEvent: Codable, Equatable {
    let source: String       // "self_upgrade" | "codex" | "verifier" | "manual"
    let problem: String
    let rootCause: String
    let fix: String
    let verification: String
    let cost: String
    let risk: String
    let lesson: String
    let tags: [String]
}

struct AduEvolutionMemoryWriteResult: Equatable {
    let ok: Bool
    let httpStatus: Int
    let errorMessage: String?
}

enum AduEvolutionMemoryClient {
    static func write(apiBase: String,
                      event: AduEvolutionMemoryEvent) async -> AduEvolutionMemoryWriteResult {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/adu/self/evolution-memory") else {
            return AduEvolutionMemoryWriteResult(ok: false, httpStatus: -1, errorMessage: "invalid_api_base")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        // 后端 EvolutionMemoryEvent 是 snake_case;手工序列化避免 convertToSnakeCase 命名歧义
        let body: [String: Any] = [
            "source": event.source,
            "problem": event.problem,
            "root_cause": event.rootCause,
            "fix": event.fix,
            "verification": event.verification,
            "cost": event.cost,
            "risk": event.risk,
            "lesson": event.lesson,
            "tags": event.tags,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(code) {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let ok = (json?["ok"] as? Bool) ?? true
                return AduEvolutionMemoryWriteResult(ok: ok, httpStatus: code, errorMessage: ok ? nil : "ok_false")
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            return AduEvolutionMemoryWriteResult(ok: false, httpStatus: code,
                                                  errorMessage: "HTTP \(code) \(raw.prefix(120))")
        } catch {
            return AduEvolutionMemoryWriteResult(ok: false, httpStatus: -1,
                                                  errorMessage: "\(type(of: error)): \(error.localizedDescription)")
        }
    }
}

enum AduSelfUpgradeClient {
    private static let selfUpgradePlanPath = "/api/adu/self/upgrade/plan"

    static func requestAduSelfUpgradePlan(apiBase: String,
                                          goal: String,
                                          surface: String = "home_chat") async throws -> AduSelfUpgradePlan {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = base + selfUpgradePlanPath
        guard let url = URL(string: endpoint) else {
            throw AduSelfUpgradePlanError.invalidAPIBase
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        let body: [String: Any] = [
            "goal": goal,
            "surface": surface,
            "plan_only": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let raw = String(data: data, encoding: .utf8) ?? ""
            let bodySummary = String(raw.prefix(500))
            guard (200..<300).contains(code) else {
                throw AduSelfUpgradePlanError.http(status: code, body: bodySummary, endpoint: endpoint)
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw AduSelfUpgradePlanError.decode(body: bodySummary, endpoint: endpoint)
            }
            return AduSelfUpgradePlan(json: json)
        } catch let error as AduSelfUpgradePlanError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut {
                throw AduSelfUpgradePlanError.transport(message: "timeout: \(error.localizedDescription)", endpoint: endpoint)
            }
            throw AduSelfUpgradePlanError.transport(message: "\(type(of: error)): \(error.localizedDescription)", endpoint: endpoint)
        } catch {
            throw AduSelfUpgradePlanError.transport(message: "\(type(of: error)): \(error.localizedDescription)", endpoint: endpoint)
        }
    }

    static func fetchPlan(apiBase: String,
                          goal: String,
                          surface: String = "computer_control",
                          recentEvents: [[String: Any]] = [],
                          systemState: [String: Any] = [:]) async -> AduSelfUpgradePlanResult {
        do {
            let plan = try await requestAduSelfUpgradePlan(apiBase: apiBase, goal: goal, surface: surface)
            return AduSelfUpgradePlanResult(plan: plan, httpStatus: 200, errorMessage: nil)
        } catch let error as AduSelfUpgradePlanError {
            let status: Int
            if case .http(let code, _, _) = error {
                status = code
            } else {
                status = -1
            }
            return AduSelfUpgradePlanResult(plan: nil, httpStatus: status, errorMessage: error.localizedDescription)
        } catch {
            return AduSelfUpgradePlanResult(plan: nil, httpStatus: -1,
                                            errorMessage: "\(type(of: error)): \(error.localizedDescription)")
        }
    }

    // ─── V2 闭环 API ─────────────────────────────────────────────
    //
    //   1) createSession        POST /api/adu/self/sessions          -> plan + sessionId
    //   2) selectUpgrade        POST /api/adu/self/sessions/{id}/select-upgrade
    //   3) reportCodexResult    POST /api/adu/self/sessions/{id}/codex-result
    //
    // 安全:三个接口都不上传 stdout / stderr / 凭据。
    static func createSession(apiBase: String,
                              goal: String,
                              surface: String = "computer_control",
                              recentEvents: [[String: Any]] = [],
                              systemState: [String: Any] = [:]) async -> AduSelfUpgradePlanResult {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/adu/self/sessions") else {
            return AduSelfUpgradePlanResult(plan: nil, httpStatus: -1, errorMessage: "invalid_api_base")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        // V2.2:createSession 也显式带 auto_execute=false,wire 语义跟 fetchPlan 对齐。
        var body: [String: Any] = [
            "goal": goal,
            "surface": surface,
            "mode": "plan_only",
            "auto_execute": false,
        ]
        if !recentEvents.isEmpty { body["recent_events"] = recentEvents }
        if !systemState.isEmpty { body["system_state"] = systemState }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if (200..<300).contains(code) {
                if let plan = try? decoder.decode(AduSelfUpgradePlan.self, from: data) {
                    return AduSelfUpgradePlanResult(plan: plan, httpStatus: code, errorMessage: nil)
                }
                return AduSelfUpgradePlanResult(plan: nil, httpStatus: code, errorMessage: "decode_failed")
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            return AduSelfUpgradePlanResult(plan: nil, httpStatus: code,
                                            errorMessage: "HTTP \(code) \(raw.prefix(120))")
        } catch {
            return AduSelfUpgradePlanResult(plan: nil, httpStatus: -1,
                                            errorMessage: "\(type(of: error)): \(error.localizedDescription)")
        }
    }
}

// MARK: - select-upgrade
struct AduSelfUpgradeSelectResult: Equatable {
    let ok: Bool
    let stage: String?
    let currentCodexPrompt: String?
    let selectedUpgradeId: String?
    let httpStatus: Int
    let errorMessage: String?
}

extension AduSelfUpgradeClient {
    static func selectUpgrade(apiBase: String,
                              sessionId: String,
                              upgradeId: String) async -> AduSelfUpgradeSelectResult {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/adu/self/sessions/\(sessionId)/select-upgrade") else {
            return AduSelfUpgradeSelectResult(ok: false, stage: nil, currentCodexPrompt: nil,
                                              selectedUpgradeId: nil, httpStatus: -1,
                                              errorMessage: "invalid_api_base")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let body: [String: Any] = ["upgrade_id": upgradeId]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (200..<300).contains(code) {
                return AduSelfUpgradeSelectResult(
                    ok: (json["ok"] as? Bool) ?? true,
                    stage: json["stage"] as? String,
                    currentCodexPrompt: json["current_codex_prompt"] as? String,
                    selectedUpgradeId: json["selected_upgrade_id"] as? String,
                    httpStatus: code, errorMessage: nil
                )
            }
            let detail = (json["detail"] as? [String: Any]) ?? json
            let err = (detail["error"] as? String) ?? "HTTP \(code)"
            return AduSelfUpgradeSelectResult(ok: false, stage: nil, currentCodexPrompt: nil,
                                              selectedUpgradeId: nil, httpStatus: code, errorMessage: err)
        } catch {
            return AduSelfUpgradeSelectResult(ok: false, stage: nil, currentCodexPrompt: nil,
                                              selectedUpgradeId: nil, httpStatus: -1,
                                              errorMessage: "\(type(of: error)): \(error.localizedDescription)")
        }
    }
}

// MARK: - update-stage
struct AduSelfUpgradeStageUpdateResult: Equatable {
    let ok: Bool
    let stage: String?
    let httpStatus: Int
    let errorMessage: String?
}

extension AduSelfUpgradeClient {
    static func updateStage(apiBase: String,
                            sessionId: String,
                            stage: String,
                            message: String? = nil) async -> AduSelfUpgradeStageUpdateResult {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/adu/self/sessions/\(sessionId)/update-stage") else {
            return AduSelfUpgradeStageUpdateResult(ok: false, stage: nil, httpStatus: -1,
                                                   errorMessage: "invalid_api_base")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        var body: [String: Any] = ["stage": stage]
        if let message, !message.isEmpty { body["message"] = message }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (200..<300).contains(code) {
                return AduSelfUpgradeStageUpdateResult(
                    ok: (json["ok"] as? Bool) ?? true,
                    stage: json["stage"] as? String,
                    httpStatus: code,
                    errorMessage: nil
                )
            }
            let detail = (json["detail"] as? [String: Any]) ?? json
            let err = (detail["error"] as? String) ?? "HTTP \(code)"
            return AduSelfUpgradeStageUpdateResult(ok: false, stage: nil, httpStatus: code,
                                                   errorMessage: err)
        } catch {
            return AduSelfUpgradeStageUpdateResult(ok: false, stage: nil, httpStatus: -1,
                                                   errorMessage: "\(type(of: error)): \(error.localizedDescription)")
        }
    }
}

// MARK: - codex-result
struct AduSelfUpgradeCodexResultPayload {
    let ok: Bool
    let exitCode: Int?
    let duration: Double?
    let summary: String?
    let needsUserConfirmation: Bool
    let blockedTerms: [String]
    let error: String?
    let httpStatus: Int?
    // 注意:绝不在这里放 stdout / stderr。
}

struct AduSelfUpgradeReportResult: Equatable {
    let ok: Bool
    let stage: String?
    let verificationSummary: String?
    let verificationOutcome: String?
    let memoryWritten: Bool
    let memoryId: String?
    let memoryError: String?
    let nextRecommendationTitle: String?
    let nextRecommendationId: String?
    let nextRecommendationRisk: String?
    let nextRecommendation: SelfUpgradeNextRecommendationSnapshot?
    let verificationRecommendedSteps: [SelfUpgradeVerificationStepSnapshot]
    let httpStatus: Int
    let errorMessage: String?
}

extension AduSelfUpgradeClient {
    static func reportCodexResult(apiBase: String,
                                  sessionId: String,
                                  payload: AduSelfUpgradeCodexResultPayload) async -> AduSelfUpgradeReportResult {
        let base = apiBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/adu/self/sessions/\(sessionId)/codex-result") else {
            return AduSelfUpgradeReportResult(
                ok: false, stage: nil, verificationSummary: nil, verificationOutcome: nil,
                memoryWritten: false, memoryId: nil, memoryError: nil,
                nextRecommendationTitle: nil, nextRecommendationId: nil, nextRecommendationRisk: nil,
                nextRecommendation: nil, verificationRecommendedSteps: [],
                httpStatus: -1, errorMessage: "invalid_api_base"
            )
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20

        var body: [String: Any] = [
            "ok": payload.ok,
            "needs_user_confirmation": payload.needsUserConfirmation,
            "blocked_terms": payload.blockedTerms,
        ]
        if let v = payload.exitCode { body["exit_code"] = v }
        if let v = payload.duration { body["duration"] = v }
        if let v = payload.summary { body["summary"] = v }
        if let v = payload.error { body["error"] = v }
        if let v = payload.httpStatus { body["http_status"] = v }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (200..<300).contains(code) {
                let ver = (json["verification_result"] as? [String: Any]) ?? [:]
                let mw = (json["memory_write_result"] as? [String: Any]) ?? [:]
                let nr = (json["next_recommendation"] as? [String: Any]) ?? [:]
                let nextRecommendation: SelfUpgradeNextRecommendationSnapshot?
                if let title = nr["title"] as? String, !title.isEmpty {
                    nextRecommendation = SelfUpgradeNextRecommendationSnapshot(
                        id: nr["id"] as? String,
                        title: title,
                        reason: (nr["reason"] as? String) ?? "",
                        suggestedMode: nr["suggested_mode"] as? String,
                        riskLevel: nr["risk_level"] as? String,
                        projectId: nr["project_id"] as? String,
                        score: nr["score"] as? Int
                    )
                } else {
                    nextRecommendation = nil
                }
                let stepsRaw = (ver["recommended_steps"] as? [[String: Any]]) ?? []
                let steps = stepsRaw.compactMap { item -> SelfUpgradeVerificationStepSnapshot? in
                    let command = (item["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !command.isEmpty else { return nil }
                    return SelfUpgradeVerificationStepSnapshot(
                        tool: (item["tool"] as? String) ?? "cmd",
                        command: command,
                        description: item["description"] as? String
                    )
                }
                return AduSelfUpgradeReportResult(
                    ok: (json["ok"] as? Bool) ?? true,
                    stage: json["stage"] as? String,
                    verificationSummary: ver["summary"] as? String,
                    verificationOutcome: ver["outcome"] as? String,
                    memoryWritten: (mw["ok"] as? Bool) ?? false,
                    memoryId: mw["memory_id"] as? String,
                    memoryError: mw["error"] as? String,
                    nextRecommendationTitle: nr["title"] as? String,
                    nextRecommendationId: nr["id"] as? String,
                    nextRecommendationRisk: nr["risk_level"] as? String,
                    nextRecommendation: nextRecommendation,
                    verificationRecommendedSteps: steps,
                    httpStatus: code, errorMessage: nil
                )
            }
            let detail = (json["detail"] as? [String: Any]) ?? json
            let err = (detail["error"] as? String) ?? "HTTP \(code)"
            return AduSelfUpgradeReportResult(
                ok: false, stage: nil, verificationSummary: nil, verificationOutcome: nil,
                memoryWritten: false, memoryId: nil, memoryError: nil,
                nextRecommendationTitle: nil, nextRecommendationId: nil, nextRecommendationRisk: nil,
                nextRecommendation: nil, verificationRecommendedSteps: [],
                httpStatus: code, errorMessage: err
            )
        } catch {
            return AduSelfUpgradeReportResult(
                ok: false, stage: nil, verificationSummary: nil, verificationOutcome: nil,
                memoryWritten: false, memoryId: nil, memoryError: nil,
                nextRecommendationTitle: nil, nextRecommendationId: nil, nextRecommendationRisk: nil,
                nextRecommendation: nil, verificationRecommendedSteps: [],
                httpStatus: -1, errorMessage: "\(type(of: error)): \(error.localizedDescription)"
            )
        }
    }
}
