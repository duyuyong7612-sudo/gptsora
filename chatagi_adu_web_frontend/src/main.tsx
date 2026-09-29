// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-87864dd7910fa4fb515187d4cfb1ca610051cdae6089608712307cd5bf7d58ca"
// Source-SHA256: "5a8c43d116dacb28ddbe0cfddf68c1d69d09f4836a233d9de763b92936ab31b4"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles.css";

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(<App />);
}
