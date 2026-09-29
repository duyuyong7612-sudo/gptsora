// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-81e343285ed7eb676ff607c9c7af1377971ba5cc536edebcf8dc6c9338b2b4fc"
// Source-SHA256: "22621fc3742bbf90bba07e2e86a2d6b818d087ce3eac91c769c324de16c055d4"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useState } from "react";
import { postJson, readReply } from "../api/backendBase";
import { feedback } from "../utils/feedback";

/** 开发页：自动化编程任务入口（保留原行为，提交到 /api/adu/codex/run）。 */
export function DevPage() {
  const [task, setTask] = useState("");
  const [status, setStatus] = useState({ text: "Codex 接口待提交", kind: "" });

  async function submit() {
    const prompt = task.trim();
    if (!prompt) return;
    setStatus({ text: "正在提交 Codex 任务", kind: "warn-text" });
    try {
      const data = await postJson("/api/adu/codex/run", {
        prompt,
        task: prompt,
        project_id: "backend",
        source: "chatagi-adu-web",
      });
      setStatus({ text: `Codex 任务已提交 ${readReply(data) || ""}`.trim(), kind: "ok-text" });
      feedback("success");
    } catch (err: any) {
      setStatus({ text: `Codex 接口不可用 - ${err.message}`, kind: "danger-text" });
      feedback("error");
    }
  }

  return (
    <section className="glass page">
      <div className="page-head">
        <h2>开发</h2>
        <span className="muted">/api/adu/codex/run</span>
      </div>
      <div className="page-body cards">
        <div className="card">
          <h3>自动化编程任务</h3>
          <textarea id="devTask" placeholder="描述要开发、修复或重构的任务" value={task} onChange={(e) => setTask(e.target.value)}></textarea>
          <div className="button-row" style={{ marginTop: "10px" }}>
            <button className="primary-btn" id="devSubmit" onClick={submit}>提交任务</button>
          </div>
          <div className={`status-line ${status.kind}`} id="devStatus">{status.text}</div>
        </div>
        <div className="card">
          <h3>Codex / Claude</h3>
          <p className="muted">这里保留自动开发代理入口。后端接入后可从同一主页发起代码任务。</p>
          <div className="button-row">
            <button className="ghost-btn">Codex 入口</button>
            <button className="ghost-btn">Claude 入口</button>
          </div>
        </div>
      </div>
    </section>
  );
}
