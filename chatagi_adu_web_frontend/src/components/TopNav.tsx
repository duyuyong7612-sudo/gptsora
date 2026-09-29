// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-8d9480cfcfbee67130aab4ec45886011d203673e11e572b006fb23dd143d4d4c"
// Source-SHA256: "17f3de589131fd60fa34f4c7920b26cdd96a4af4a91b13d4b63a462319580de4"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
export type ViewName = "home" | "chat" | "voice" | "computer" | "dev" | "settings";

const NAV: Array<[ViewName, string]> = [
  ["chat", "聊天"],
  ["voice", "实时语音"],
  ["computer", "电脑控制"],
  ["dev", "开发"],
  ["settings", "设置"],
];

export interface TopNavProps {
  activeView: ViewName;
  onNavigate: (view: ViewName) => void;
}

/** 顶部导航（视觉不变）。 */
export function TopNav({ activeView, onNavigate }: TopNavProps) {
  return (
    <header className="topbar">
      <div className="brand" onClick={() => onNavigate("home")}>
        <div className="brand-mark">A</div>
        <span>ChatAGI-阿杜</span>
      </div>
      <nav className="nav" aria-label="主导航">
        {NAV.map(([view, label]) => (
          <button
            key={view}
            className={activeView === view ? "active" : ""}
            onClick={() => onNavigate(view)}
          >
            {label}
          </button>
        ))}
      </nav>
      <div className="status-pill">
        <span className="dot"></span>
        <span id="globalStatus">本地入口已启动</span>
      </div>
    </header>
  );
}
