// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-617e94bf439fd5235b4679915eaee1d19673bb434215ae78475d432fbf353652"
// Source-SHA256: "693d51dd732c4335809641edeafc136f621a81d40f3fe512ed79ea4320f71a7e"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { feedback } from "../utils/feedback";

export interface SettingsPageProps {
  backendInfo: string;
  buttonSoundEnabled: boolean;
  hapticEnabled: boolean;
  onButtonSoundChange: (enabled: boolean) => void;
  onHapticChange: (enabled: boolean) => void;
}

/** 设置页：后端地址自检结果（小字，不放大白框）。 */
export function SettingsPage({
  backendInfo,
  buttonSoundEnabled,
  hapticEnabled,
  onButtonSoundChange,
  onHapticChange,
}: SettingsPageProps) {
  return (
    <section className="glass page">
      <div className="page-head">
        <h2>设置</h2>
        <span className="muted">本地优先</span>
      </div>
      <div className="page-body cards">
        <div className="card">
          <h3>后端地址</h3>
          <p className="muted" id="backendInfo">{backendInfo}</p>
        </div>
        <div className="card">
          <h3>产品状态</h3>
          <p className="muted">当前版本是 ChatAGI-阿杜独立前端，底部输入栏对齐 iOS HomeChat。</p>
        </div>
        <div className="card">
          <h3>按键反馈</h3>
          <label className="setting-toggle">
            <span>
              <b>按键声音</b>
              <small>点击、成功、失败和实时语音起止提示音</small>
            </span>
            <input
              type="checkbox"
              checked={buttonSoundEnabled}
              onChange={(e) => {
                onButtonSoundChange(e.target.checked);
                feedback(e.target.checked ? "success" : "stopVoice");
              }}
            />
          </label>
          <label className="setting-toggle">
            <span>
              <b>触感反馈</b>
              <small>手机浏览器支持时轻震确认</small>
            </span>
            <input
              type="checkbox"
              checked={hapticEnabled}
              onChange={(e) => {
                onHapticChange(e.target.checked);
                feedback(e.target.checked ? "success" : "tap");
              }}
            />
          </label>
        </div>
      </div>
    </section>
  );
}
