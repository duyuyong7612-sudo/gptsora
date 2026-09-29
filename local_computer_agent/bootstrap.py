# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-7b236819012782c9a15e06011e0a1f7bd3511bd782bfc908a56ba0701a9781f6"
# Source-SHA256: "fdae08b351754c3ff544bb852349a5e7e8c09831aeebb551491ea3cd37cd0036"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
from __future__ import annotations

import logging
from .registry import get_registry

log = logging.getLogger('local_computer_agent')


def bootstrap_local_agent() -> None:
    reg = get_registry()
    try:
        data = reg.probe_and_persist()
        platform_name = data.get('system', {}).get('platform')
        apps = len(data.get('apps') or {})
        aliases = len(data.get('workspace_aliases') or {})
        log.info('[LocalAgent] boot probe complete platform=%s apps=%s aliases=%s', platform_name, apps, aliases)
    except Exception as e:
        log.warning('[LocalAgent] boot probe failed: %s', e)
