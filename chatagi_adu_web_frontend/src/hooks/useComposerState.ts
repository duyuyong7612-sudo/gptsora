// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-db04a13e640b011c72a5395d17c775b39dc82a27fdeb56ea392744a6c778e3ba"
// Source-SHA256: "55bc3b114e98da3325c4cef6a67d73a2aa74c13e4ef2ba1481f1c01534ea4a5c"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { useState } from "react";

export interface ComposerStatus {
  text: string;
  kind: string; // "" | "ok-text" | "warn-text" | "danger-text"
}

/** 底部输入栏的本地状态：文本、+ 菜单开关、状态行。 */
export function useComposerState() {
  const [text, setText] = useState("");
  const [menuOpen, setMenuOpen] = useState(false);
  const [status, setStatus] = useState<ComposerStatus>({ text: "", kind: "" });
  return { text, setText, menuOpen, setMenuOpen, status, setStatus };
}
