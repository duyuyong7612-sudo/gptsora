// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-93ccd84ea73e9114f80dff4fe4ebe61d86c25e986eb69d95bf6eaa320a478f03"
// Source-SHA256: "4a91a80d380819147b291d25277a96cfb6b9ebadbd38004ee28661855e7b3785"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";

// 关键：
// - viteSingleFile 把 JS/CSS 全部内联进单个 index.html
//   → 产物仍是一个自包含 index.html，由 server_session.py 的 /chatagi-adu 直接 FileResponse 返回，
//     不依赖 /chatagi-adu/assets 挂载，也不需要重启后端。
// - outDir 指向后端的 _media/chatagi_adu_app，build 后 /chatagi-adu 立即生效。
// - emptyOutDir=false：不清空目录（保留 index.html.bak.* 备份）。
export default defineConfig({
  plugins: [react(), viteSingleFile()],
  base: "./",
  build: {
    outDir: "../_media/chatagi_adu_app",
    emptyOutDir: false,
    assetsInlineLimit: 100000000,
    cssCodeSplit: false,
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
      },
    },
  },
});
