# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-a42ad48f2c9a3d4b86ccbf6bbfe9a8d30c4bcd85df2d89f64e955884e7f51dd2"
# Source-SHA256: "433a141b64869b60ba2490689326f162c75b4f7d660c05e7fb995d9289b48799"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
SessionMapper - ChatAGI 用户 ↔ OpenClaw 会话映射
=================================================

每个 ChatAGI 用户在 OpenClaw Gateway 中有独立的 session，
保证会话隔离和上下文持久化。

映射规则:
  💬 Chat 模式:    agent:main:adu-{user_id}
  🔧 Project 模式:  agent:main:adu-proj-{user_id}-{project_hash}
"""

import hashlib


class SessionMapper:

    @staticmethod
    def chat_session(user_id: str) -> str:
        """
        💬 Chat 模式 session key

        >>> SessionMapper.chat_session("u_abc123")
        'agent:main:adu-u_abc123'
        """
        safe_id = _sanitize(user_id)
        return f"agent:main:adu-{safe_id}"

    @staticmethod
    def project_session(user_id: str, project_path: str) -> str:
        """
        🔧 Project Assistant 模式 session key

        用项目路径的 hash 做后缀，保证同一项目同一 session。

        >>> SessionMapper.project_session("u_abc", "~/Desktop/GPTsora/")
        'agent:main:adu-proj-u_abc-a1b2c3d4'
        """
        safe_id = _sanitize(user_id)
        proj_hash = hashlib.md5(project_path.encode()).hexdigest()[:8]
        return f"agent:main:adu-proj-{safe_id}-{proj_hash}"

    @staticmethod
    def is_chatagi_session(session_key: str) -> bool:
        """判断是否是 ChatAGI 创建的 session"""
        return "adu-" in session_key

    @staticmethod
    def extract_user_id(session_key: str) -> str:
        """从 session key 提取 user_id"""
        # agent:main:adu-{user_id} 或 agent:main:adu-proj-{user_id}-{hash}
        parts = session_key.split("adu-")
        if len(parts) < 2:
            return ""
        suffix = parts[1]
        if suffix.startswith("proj-"):
            # adu-proj-{user_id}-{hash}
            remainder = suffix[5:]  # 去掉 "proj-"
            return remainder.rsplit("-", 1)[0]
        return suffix


def _sanitize(s: str) -> str:
    """清理用户 ID，只保留安全字符"""
    return "".join(c for c in s if c.isalnum() or c in ("-", "_"))
