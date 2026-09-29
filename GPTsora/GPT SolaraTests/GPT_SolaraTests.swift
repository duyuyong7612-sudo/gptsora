//
//  GPT_SolaraTests.swift
//  GPT SolaraTests
//
//  Created by 12345 on 12/12/25.
//

// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-cf56e9a4cff76339c13dd7f690d6f5ecab1f546ae293d71f66f7794c04e91c0c"
// Source-SHA256: "3d687a42f2545783f8399c80238d9c3e1f79022d3346bdfabdc7a3f6cac57db0"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import Testing
@testable import GPT_Solara

struct GPT_SolaraTests {

    @Test func computerControlVoiceStatusTracksExecution() async throws {
        var status = ComputerControlVoiceStatus()
        #expect(status.executionState == .idle)
        #expect(status.isExecuting == false)

        status.executionState = .executing
        status.isRealtimeConnected = true
        status.realtimeStatus = "已连接"

        #expect(status.isExecuting)
        #expect(status.executionState.title == "正在执行")
        #expect(status.isRealtimeConnected)
    }

    @Test func unifiedComputerFormatterPrefersFinalText() async throws {
        let result = UnifiedResult(
            ok: true,
            route: "computer",
            raw: ["final_text": "Safari 已打开"],
            statusCode: 200
        )

        #expect(ComputerControlUnifiedResponseFormatter.finalText(from: result) == "Safari 已打开")
    }

    @Test func unifiedComputerFormatterFallsBackForComputerRoute() async throws {
        let result = UnifiedResult(
            ok: true,
            route: "computer",
            raw: [:],
            statusCode: 200
        )

        #expect(ComputerControlUnifiedResponseFormatter.finalText(from: result) == "电脑动作已执行。")
    }

}
