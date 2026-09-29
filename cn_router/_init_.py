# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-d20c2e78ca681e4e3bc57fd28c3de255e54de5fa523f78f0238e64dffd272be8"
# Source-SHA256: "5b4f38b73e02416ddfc77590f34ccdd5a069c734a5226ebfa88bb2a1756a52c9"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
ChatAGI-Adu 智能路由 v2
基于实际 .env 配置：DeepSeek + 硅基流动 + OpenAI + Anthropic + Google
"""
from .cn_smart_router import (
    SmartRouter,
    ModelRegistry,
    ModelConfig,
    ModelCaller,
    Router,
    QualityGuard,
    ContextManager,
    RoutingDecision,
    Intent,
    Complexity,
)

__all__ = [
    "SmartRouter", "ModelRegistry", "ModelConfig", "ModelCaller",
    "Router", "QualityGuard", "ContextManager",
    "RoutingDecision", "Intent", "Complexity",
]

