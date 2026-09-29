// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-a8be81c0132c22c050fe79e863cb47b4d6638c1738d46d45e0dbe01fc5b89b2a"
// Source-SHA256: "80d5459a8112e3862e14dccd3eaa1e72cf4f32a3419747209a05911bc8233251"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useState } from "react";
import { readReply } from "../api/backendBase";
import {
  computerConfig,
  computerScreenshot,
  computerMove,
  computerClick,
  computerType,
  computerPress,
  computerAction,
} from "../api/computerApi";
import { feedback } from "../utils/feedback";

const RISK_WORDS = ["rm", "sudo", "kill", "delete", "删除", "付款", "购买", "发送邮件", "关闭程序", "格式化", "清空", "转账"];

function isRisky(text: string): boolean {
  const lower = text.toLowerCase();
  return RISK_WORDS.some((w) => lower.includes(w.toLowerCase()));
}

function imageSrcFrom(data: any): string {
  const raw = data && (data.base64 || data.image || data.url || data.screenshot || data.data);
  if (!raw) return "";
  if (typeof raw === "object") return imageSrcFrom(raw);
  if (/^data:image\//.test(raw) || /^https?:\/\//.test(raw) || raw.startsWith("/")) return raw;
  return `data:image/png;base64,${raw}`;
}

const PRESET_KEYS = ["cmd+space", "enter", "esc"];

/** 电脑控制页：截图 / 鼠标 / 键盘 / 自然语言任务，全部走后端 /api/brain/computer/*。 */
export function ComputerControlPage() {
  const [status, setStatus] = useState({ text: "状态：待命", kind: "" });
  const [shot, setShot] = useState<{ src?: string; msg?: string }>({});
  const [moveX, setMoveX] = useState("");
  const [moveY, setMoveY] = useState("");
  const [clickX, setClickX] = useState("");
  const [clickY, setClickY] = useState("");
  const [typeText, setTypeText] = useState("");
  const [task, setTask] = useState("");

  function num(v: string): number {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  }

  async function withStatus(fn: () => Promise<any>, okText: string) {
    setStatus({ text: "状态：正在发送控制请求", kind: "warn-text" });
    try {
      const data = await fn();
      setStatus({ text: `状态：${okText} ${readReply(data) || ""}`.trim(), kind: "ok-text" });
      feedback("success");
    } catch (err: any) {
      setStatus({ text: `状态：请求失败 - ${err.message}`, kind: "danger-text" });
      feedback("error");
    }
  }

  async function loadShot() {
    setStatus({ text: "状态：正在获取截图", kind: "warn-text" });
    try {
      const data = await computerScreenshot();
      const src = imageSrcFrom(data);
      if (!src) throw new Error("截图响应中没有 base64、url 或 image 字段");
      setShot({ src });
      setStatus({ text: "状态：截图已更新", kind: "ok-text" });
      feedback("success");
    } catch (err: any) {
      setShot({ msg: err.message });
      setStatus({ text: `状态：截图不可用 - ${err.message}`, kind: "danger-text" });
      feedback("error");
    }
  }

  async function loadConfig() {
    try {
      const data = await computerConfig();
      setStatus({ text: `状态：配置已读取 ${readReply(data) || ""}`.trim(), kind: "ok-text" });
      feedback("success");
    } catch (err: any) {
      setStatus({ text: `状态：配置不可用 - ${err.message}`, kind: "danger-text" });
      feedback("error");
    }
  }

  function runTask() {
    const t = task.trim();
    if (!t) return;
    if (isRisky(t) && !window.confirm("这是高风险电脑任务，确认继续执行？")) return;
    void withStatus(() => computerAction(t), "自然语言任务已提交");
  }

  return (
    <section className="glass page">
      <div className="page-head">
        <h2>电脑控制</h2>
        <button className="ghost-btn" id="loadConfigBtn" onClick={loadConfig}>读取配置</button>
      </div>
      <div className="page-body control-grid">
        <div className="stack">
          <div className="card">
            <h3>截图</h3>
            <div className="button-row">
              <button className="primary-btn" id="screenshotBtn" onClick={loadShot}>查看截图</button>
              <button className="ghost-btn" id="refreshShotBtn" onClick={loadShot}>刷新截图</button>
            </div>
          </div>
          <div className="card">
            <h3>鼠标</h3>
            <div className="form-grid">
              <input id="moveX" inputMode="numeric" placeholder="移动 x" value={moveX} onChange={(e) => setMoveX(e.target.value)} />
              <input id="moveY" inputMode="numeric" placeholder="移动 y" value={moveY} onChange={(e) => setMoveY(e.target.value)} />
              <input id="clickX" inputMode="numeric" placeholder="点击 x" value={clickX} onChange={(e) => setClickX(e.target.value)} />
              <input id="clickY" inputMode="numeric" placeholder="点击 y" value={clickY} onChange={(e) => setClickY(e.target.value)} />
            </div>
            <div className="button-row" style={{ marginTop: "10px" }}>
              <button className="ghost-btn" id="moveBtn" onClick={() => withStatus(() => computerMove(num(moveX), num(moveY)), "鼠标已移动")}>鼠标移动 x/y</button>
              <button className="ghost-btn" id="clickBtn" onClick={() => withStatus(() => computerClick(num(clickX), num(clickY)), "点击已发送")}>点击 x/y</button>
            </div>
          </div>
          <div className="card">
            <h3>键盘</h3>
            <input id="typeText" placeholder="输入文字" value={typeText} onChange={(e) => setTypeText(e.target.value)} />
            <div className="button-row" style={{ marginTop: "10px" }}>
              <button className="ghost-btn" id="typeBtn" onClick={() => withStatus(() => computerType(typeText), "文字已输入")}>输入文字</button>
              {PRESET_KEYS.map((k) => (
                <button key={k} className="mini-btn" data-key={k} onClick={() => withStatus(() => computerPress(k), "快捷键已发送")}>{k}</button>
              ))}
            </div>
          </div>
          <div className="card">
            <h3>自然语言电脑任务</h3>
            <textarea id="computerTask" placeholder="例如：打开浏览器并搜索天气" value={task} onChange={(e) => setTask(e.target.value)}></textarea>
            <div className="button-row" style={{ marginTop: "10px" }}>
              <button className="primary-btn" id="actionBtn" onClick={runTask}>执行任务</button>
            </div>
            <div className={`status-line ${status.kind}`} id="computerStatus">{status.text}</div>
          </div>
        </div>
        <div className="stack">
          <div className="screenshot" id="screenshotBox">
            {shot.src ? (
              <img alt="电脑截图" src={shot.src} />
            ) : (
              <span className="muted">{shot.msg || "截图预览区域"}</span>
            )}
          </div>
        </div>
      </div>
    </section>
  );
}
