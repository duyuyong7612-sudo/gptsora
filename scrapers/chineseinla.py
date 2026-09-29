# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-36f460509691c21a70924f74fcac091d00661c7b644c028d0de7b8c783ba0500"
# Source-SHA256: "f523326ac431c346526a30dbebfefa30ada36bbfaaf6b60f5588c82e799f7d18"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""
chineseinla.py — chineseinla.com 爬虫

策略:
1) 启动时访问首页或论坛根页面,自动解析所有版块的 f_XX 编号(从 HTML 链接里找)
2) 按版块名映射到我们的 category(找工/招人/租房/二手/生意买卖)
3) 逐版块爬第 1 页(最新帖子列表)
4) 对每个新帖子,翻入正文页解析:标题、正文、发布时间、电话/微信、薪资等
5) 写入 SQLite

合规做法:
- User-Agent 写明身份
- 每个请求间睡 1-3 秒(随机)
- 遵守 robots.txt(已确认 /f/page_viewtopic/ 没被禁)
- 不爬被 robots.txt 禁的路径
- 单次运行限制总请求数(避免误把站点搞死)
"""

from __future__ import annotations

import logging
import random
import re
import sqlite3
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

from db import (
    db_connect, finish_run, init_db, make_job_id, now_iso, start_run, upsert_job,
)

logger = logging.getLogger("scrapers.chineseinla")

# -----------------------------------------------------------------------------
# 常量
# -----------------------------------------------------------------------------

BASE_URL = "https://www.chineseinla.com"
SOURCE_NAME = "chineseinla"

# 我们关心的版块名 → 我们自己的 category 映射
# (站点版块名 → 我们的归类)
# 抓到的版块名只要包含 key 字符串就归到对应 category
FORUM_CATEGORY_MAP = [
    # 找工 / 招聘类(全归到"找工",招人是后面 5 类业务再细分)
    ("工作求职", "找工"),
    ("IT招聘",  "找工"),
    ("餐厅酒吧", "找工"),
    ("按摩",    "找工"),
    ("月嫂家政", "找工"),
    ("儿童看护", "找工"),
    # 租房
    ("房屋出租", "租房"),
    ("民宿月子", "租房"),
    ("旅馆短租", "租房"),
    ("寄宿家庭", "租房"),
    # 生意买卖
    ("店铺租售", "生意买卖"),
    ("买房卖房", "生意买卖"),
    ("汽车买卖", "生意买卖"),
    # 二手
    ("二手商品", "二手"),
    ("新品买卖", "二手"),
]

# 礼貌的浏览器伪装 + 身份声明
HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        "Version/17.0 Safari/605.1.15 "
        "HuarenAILocal/1.0"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    "Accept-Encoding": "gzip, deflate, br",
    "Connection": "keep-alive",
}

# 限速参数
SLEEP_BETWEEN_REQUESTS = (1.0, 2.5)   # 随机区间
MAX_REQUESTS_PER_RUN = 200            # 单次运行总请求数硬上限
HTTP_TIMEOUT = 20                     # 秒

# -----------------------------------------------------------------------------
# HTTP 工具
# -----------------------------------------------------------------------------

class RequestCounter:
    """全局请求计数,达上限就停"""
    def __init__(self, limit: int):
        self.limit = limit
        self.count = 0

    def check_and_inc(self) -> bool:
        if self.count >= self.limit:
            return False
        self.count += 1
        return True


def fetch(url: str, counter: RequestCounter, session: requests.Session) -> Optional[str]:
    """带限速 + 限次 + 异常处理的 GET。返回 HTML 字符串或 None"""
    if not counter.check_and_inc():
        logger.warning("Request limit reached, skipping %s", url)
        return None

    # 随机延时
    sleep_sec = random.uniform(*SLEEP_BETWEEN_REQUESTS)
    time.sleep(sleep_sec)

    try:
        resp = session.get(url, timeout=HTTP_TIMEOUT, allow_redirects=True)
    except Exception as e:
        logger.warning("Request failed for %s: %s", url, e)
        return None

    if resp.status_code != 200:
        logger.warning("HTTP %d for %s", resp.status_code, url)
        return None

    # 编码探测
    if resp.encoding == "ISO-8859-1":
        resp.encoding = resp.apparent_encoding or "utf-8"

    return resp.text


# -----------------------------------------------------------------------------
# 步骤 1: 探测版块编号
# -----------------------------------------------------------------------------

# 形如 /f/page_viewforum/f_25/ 的链接,版块编号在 f_XX 部分
FORUM_LINK_RE = re.compile(r"/f/page_viewforum/f_(\d+)")


def discover_forums(html: str) -> List[Dict[str, str]]:
    """
    从论坛首页 HTML 里解析所有版块。
    返回 list of {forum_id, name, url}

    特别说明:同一个 forum_id 可能有多个链接(一个是版块名,一个是"主题数"等),
    我们都保留候选,后续 map_forum_to_category 用 substring match 找关键词。
    """
    soup = BeautifulSoup(html, "html.parser")
    # forum_id → 所有候选文本
    candidates: Dict[str, List[str]] = {}

    for a in soup.find_all("a", href=True):
        href = a["href"]
        m = FORUM_LINK_RE.search(href)
        if not m:
            continue

        forum_id = m.group(1)
        name = a.get_text(strip=True)
        if not name:
            continue
        candidates.setdefault(forum_id, []).append(name)

    # 把每个 forum_id 的最干净版块名挑出来(优先短的,但不超长)
    found: List[Dict[str, str]] = []
    for forum_id, names in candidates.items():
        # 优先选: 不含"主题:"/"帖子:"/数字开头 + 长度 2-15 字的
        clean = [n for n in names if not any(
            k in n for k in ["主题:", "帖子:", "最后发表"]
        ) and 2 <= len(n) <= 20]

        # 取最短的干净名字;如果没有干净的,取最短的任意名字
        if clean:
            name = min(clean, key=len)
        else:
            name = min(names, key=len)

        full_url = urljoin(BASE_URL, f"/f/page_viewforum/f_{forum_id}/")
        found.append({
            "forum_id": forum_id,
            "name": name,
            "url": full_url,
            # debug: 保留所有候选名字方便排查
            "all_names": names,
        })

    return found


def map_forum_to_category(forum: Dict[str, Any]) -> Optional[Tuple[str, str]]:
    """
    把版块映射到我们的 category。

    forum: dict 包含 'name' 和可选 'all_names'(候选别名列表)
    返回 (category, sub_category) 或 None
    """
    # 把所有候选名字拼起来搜
    haystack = forum.get("name", "")
    for alt in forum.get("all_names", []):
        haystack += " " + alt

    for key, cat in FORUM_CATEGORY_MAP:
        if key in haystack:
            return (cat, key)   # sub_category 用我们标准化的名字
    return None


# -----------------------------------------------------------------------------
# 步骤 2: 爬版块列表页
# -----------------------------------------------------------------------------

# 单个帖子链接 /f/page_viewtopic/t_3063113.html
TOPIC_LINK_RE = re.compile(r"/f/page_viewtopic/t_(\d+)")


def parse_forum_listing(html: str) -> List[Dict[str, str]]:
    """
    从版块列表页 HTML 解析出所有帖子的 URL 和 title。
    返回 list of {source_id, source_url, title}

    过滤:
    - 跳过 /bdidw_xxx 这种广告位链接(不是真帖子,是商家广告)
    - 跳过纯数字标题(楼层号)
    """
    soup = BeautifulSoup(html, "html.parser")
    results: Dict[str, Dict[str, str]] = {}

    for a in soup.find_all("a", href=True):
        href = a["href"]
        # 跳过广告位
        if "/bdidw_" in href or "bdidw" in href:
            continue

        m = TOPIC_LINK_RE.search(href)
        if not m:
            continue

        topic_id = m.group(1)
        if topic_id in results:
            continue

        title = a.get_text(strip=True)
        if not title:
            continue
        if title.isdigit() or len(title) < 3:
            continue

        full_url = urljoin(BASE_URL, href)
        results[topic_id] = {
            "source_id": topic_id,
            "source_url": full_url,
            "title": title,
        }

    return list(results.values())


# -----------------------------------------------------------------------------
# 步骤 3: 爬帖子正文 + 解析字段
# -----------------------------------------------------------------------------

# 电话号码:北美格式 (xxx) xxx-xxxx 或 xxx-xxx-xxxx
PHONE_RE = re.compile(r"""
    (?:\+?1[-.\s]?)?           # 可选 +1
    \(?\d{3}\)?                 # 区号
    [-.\s]?                     # 分隔符
    \d{3}                       # 中间 3 位
    [-.\s]?                     # 分隔符
    \d{4}                       # 末尾 4 位
""", re.VERBOSE)

# 微信号(简单匹配:wechat/微信 + 号码或字母数字组合)
WECHAT_RE = re.compile(r"(?:微信|WeChat|wechat|VX|vx)\s*[:：]?\s*([A-Za-z0-9_-]{4,30})")

# 薪资:严格版本 —— 必须有明确的"时薪/周薪/月薪/日薪/年薪/小时/周/月/天/年"等关键词
# 不再匹配单独的 $58(避免误抓房价/电话区号)
SALARY_RE = re.compile(
    r"""(
        # 模式 A: $数字/(单位)  例如 "$1500/周" "$22 / 小时"
        [\$¥]\s*\d{2,6}(?:[,.]\d+)?\s*(?:/|每)?\s*
        (?:小时|时|周|月|日|天|年|hour|hr|week|wk|month|mo|day|year)
        |
        # 模式 B: (类型词) $数字   例如 "时薪 $22" "周薪 $1500" "月薪 $5000"
        (?:时薪|周薪|月薪|日薪|年薪|底薪)\s*[\$¥]?\s*\d{2,6}
        |
        # 模式 C: 数字 + 元/刀/美元 + 单位词  "1500 美元/周"
        \d{2,6}\s*(?:元|刀|美元)\s*(?:/|每)?\s*(?:小时|时|周|月|日|天|年)
        |
        # 模式 D: "税前/税后 $数字 + /周月日时" 等
        (?:税前|税后)\s*[\$¥]?\s*\d{2,6}\s*/?\s*(?:小时|时|周|月|日|天|年)
    )""",
    re.VERBOSE | re.IGNORECASE,
)

# 发布/更新时间(chineseinla 帖子页都用 "发布于: 2025/03/25   10:44 am"、
# "更新于: 2026/05/11,  6:12 pm" 这种格式)
POSTED_AT_RE = re.compile(
    r"发布于[:\s]*(\d{4}[/\-]\d{1,2}[/\-]\d{1,2})\s*(\d{1,2}:\d{2})?\s*(am|pm|AM|PM)?"
)
UPDATED_AT_RE = re.compile(
    r"更新于[:\s]*(\d{4}[/\-]\d{1,2}[/\-]\d{1,2})\s*(\d{1,2}:\d{2})?\s*(am|pm|AM|PM)?"
)


def parse_chineseinla_datetime(date_str: str, time_str: Optional[str], ampm: Optional[str]) -> Optional[str]:
    """把 chineseinla 风格的日期时间转成 ISO8601 字符串(UTC,虽然不准确但够用)"""
    try:
        # 日期归一: 2025/03/25 或 2025-03-25
        date_str = date_str.replace("/", "-")
        parts = date_str.split("-")
        if len(parts) != 3:
            return None
        y, m, d = int(parts[0]), int(parts[1]), int(parts[2])

        hour, minute = 0, 0
        if time_str:
            t_parts = time_str.split(":")
            if len(t_parts) == 2:
                hour = int(t_parts[0])
                minute = int(t_parts[1])
                if ampm and ampm.lower() == "pm" and hour != 12:
                    hour += 12
                elif ampm and ampm.lower() == "am" and hour == 12:
                    hour = 0

        dt = datetime(y, m, d, hour, minute, 0, tzinfo=timezone.utc)
        return dt.isoformat()
    except Exception:
        return None


# 包食宿
PACKAGED_KEYWORDS = ["包食宿", "包吃住", "包住", "提供住宿"]

# 工作类型
PART_TIME_KEYWORDS = ["兼职", "part time", "part-time", "parttime", "PT"]
FULL_TIME_KEYWORDS = ["全职", "full time", "full-time", "fulltime", "FT"]


def parse_topic(html: str, source_url: str, source_id: str) -> Optional[Dict[str, Any]]:
    """
    解析单个帖子页,提取所有字段。
    返回字典(可以直接传给 upsert_job),或 None(解析失败)
    """
    soup = BeautifulSoup(html, "html.parser")

    # 标题(优先 <title>,再退到 h1/h2)
    title = ""
    title_tag = soup.find("title")
    if title_tag:
        title = title_tag.get_text(strip=True)
        # chineseinla 的 <title> 一般是 "帖子标题 - 洛杉矶华人资讯网"
        # 截掉站点后缀
        for sep in [" - 洛杉矶华人", " - ChineseInLA", " | "]:
            if sep in title:
                title = title.split(sep)[0].strip()
                break

    if not title:
        h1 = soup.find("h1") or soup.find("h2")
        if h1:
            title = h1.get_text(strip=True)

    if not title:
        return None  # 没标题就丢

    # 正文:多种启发式策略,从精确到兜底
    # 重要:必须排除新闻轮播/导航/侧栏(这些 div 也包含"content"字眼,会误抓)
    body_text = ""
    body_html = ""

    # 黑名单:这些 class/id 名包含的 div 一定不是帖子正文
    BLACKLIST_KEYS = [
        "news", "sidebar", "nav", "menu", "header", "footer",
        "banner", "ad", "advert", "related", "recommend",
        "hot", "popular", "rank", "tag", "category-list",
        "breadcrumb", "comment-form", "reply-form",
    ]

    def is_blacklisted(el) -> bool:
        """检查一个 element 的 class/id 是否在黑名单"""
        attrs = []
        if el.get("class"):
            attrs.extend(el.get("class"))
        if el.get("id"):
            attrs.append(el.get("id"))
        attrs_text = " ".join(attrs).lower()
        return any(k in attrs_text for k in BLACKLIST_KEYS)

    # 策略 A: 精确选择 — chineseinla 帖子常用的 class 名
    POST_BODY_HINTS = ["postbody", "post-content", "post_content", "topicbody", "topic_body", "msg_body", "message-body"]
    for hint in POST_BODY_HINTS:
        el = soup.find(class_=lambda c: c and hint in c.lower())
        if el and not is_blacklisted(el):
            text = el.get_text(separator="\n", strip=True)
            if len(text) > 50:
                body_text = text
                body_html = str(el)[:5000]
                break

    # 策略 B: 找最大的 div/td(排除黑名单 + 含 post/content/body/message 字眼)
    if not body_text:
        candidates = soup.find_all(["div", "td"], class_=lambda c: c and any(
            k in c.lower() for k in ["post", "content", "body", "message", "topic"]
        ))
        # 过滤黑名单
        candidates = [c for c in candidates if not is_blacklisted(c)]
        if candidates:
            best = max(candidates, key=lambda x: len(x.get_text()))
            body_text = best.get_text(separator="\n", strip=True)
            body_html = str(best)[:5000]

    if not body_text:
        # 退路:取整个页面文本前 2000 字
        body_text = soup.get_text(separator="\n", strip=True)[:2000]

    # 截断正文(避免 DB 过大)
    body_text = body_text[:2000]

    # 字段抽取
    phone = ""
    m = PHONE_RE.search(body_text)
    if m:
        phone = m.group(0)

    wechat = ""
    m = WECHAT_RE.search(body_text)
    if m:
        wechat = m.group(1)

    salary_text = ""
    m = SALARY_RE.search(body_text)
    if m:
        salary_text = m.group(0)

    packaged: Optional[int] = None
    for kw in PACKAGED_KEYWORDS:
        if kw in body_text:
            packaged = 1
            break

    work_type = ""
    for kw in PART_TIME_KEYWORDS:
        if kw.lower() in body_text.lower():
            work_type = "parttime"
            break
    if not work_type:
        for kw in FULL_TIME_KEYWORDS:
            if kw.lower() in body_text.lower():
                work_type = "fulltime"
                break

    # 发布/更新时间(从正文里抽)
    posted_at = None
    m = POSTED_AT_RE.search(body_text)
    if m:
        posted_at = parse_chineseinla_datetime(m.group(1), m.group(2), m.group(3))

    updated_at = None
    m = UPDATED_AT_RE.search(body_text)
    if m:
        updated_at = parse_chineseinla_datetime(m.group(1), m.group(2), m.group(3))

    return {
        "source": SOURCE_NAME,
        "source_id": source_id,
        "source_url": source_url,
        "title": title,
        "body": body_text,
        "phone": phone or None,
        "wechat": wechat or None,
        "salary_text": salary_text or None,
        "packaged": packaged,
        "work_type": work_type or None,
        "posted_at": posted_at,
        "updated_at_src": updated_at,
        "scraped_at": now_iso(),
        "raw_text": body_html or body_text[:5000],
    }


# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------

def is_recent_enough(parsed: Dict[str, Any], days_threshold: int) -> bool:
    """
    判断帖子是否在最近 days_threshold 天以内(只看发布时间 posted_at)。

    重要变化(v3):
    - 抓不到任何时间 → 默认 False(跳过)
    - 与之前不同:之前是"宁可错杀保留",现在是"宁可错杀跳过",避免老帖污染
    - posted_at 在 N 天内 → True
    - posted_at 太老 → 看 updated 兜底,updated 也太老就 False
    """
    from datetime import datetime, timezone, timedelta
    cutoff = datetime.now(timezone.utc) - timedelta(days=days_threshold)

    posted_at = parsed.get("posted_at")
    updated = parsed.get("updated_at_src")

    if posted_at:
        try:
            dt = datetime.fromisoformat(posted_at.replace("Z", "+00:00"))
            if dt >= cutoff:
                return True
            # posted 太老,继续看 updated 兜底
        except Exception:
            pass

    if updated:
        try:
            dt = datetime.fromisoformat(updated.replace("Z", "+00:00"))
            return dt >= cutoff
        except Exception:
            pass

    # 都没有 → 严格跳过(不再宁可错杀保留)
    return False


# -----------------------------------------------------------------------------
# 基于内容重判 category(覆盖版块 mapping)
# -----------------------------------------------------------------------------

# 5 类业务的关键词,按优先级排
# 先匹配到的优先(更精确的放前面)

CATEGORY_KEYWORDS = [
    # 招人(雇主端):很强的招聘信号词
    ("招人", [
        "招聘", "诚聘", "诚招", "招收", "招熟手", "急招",
        "找人", "请人", "雇", "聘请", "招工",
    ]),
    # 求职(求职端)
    ("找工", [
        "求职", "找工", "找份", "想做", "应聘",
        "希望找", "我会", "本人会", "有经验",
    ]),
    # 生意买卖(店转让 + 房产)
    # 注意:这一类要在"二手"前面,避免"独栋出售"被归到"二手/出售"
    ("生意买卖", [
        "店转让", "生意转让", "生意出售", "店出兑", "出兑",
        "店铺转让", "公司出售", "工厂转让", "工厂出售",
        "店面转让", "店出让", "美甲店转让", "餐馆转让", "外卖店转让",
        "超市转让", "店铺出售", "买生意", "卖公司",
        # 房产
        "独栋", "联排", "公寓出售", "房屋出售", "买房", "卖房",
        "学区房", "别墅出售", "新上市", "屋出售",
    ]),
    # 租房
    ("租房", [
        "出租", "招租", "出租屋", "整租", "雅房", "套房",
        "短租", "长租", "日租", "民宿",
    ]),
    # 二手 (动产类小件)
    ("二手", [
        "二手", "转卖", "求购",
        # 注意:不放"卖"和"出售",太宽松会抢"生意买卖"
    ]),
]


def reclassify_category(title: str, body: str, fallback_category: Optional[str], fallback_sub: Optional[str]) -> Tuple[str, str]:
    """
    基于标题 + 正文前 500 字符的关键词,重新判定 category。
    fallback_* 是版块 mapping 给的结果,用作没匹配上时的回退。

    优先级:招人 > 找工 > 生意买卖 > 租房 > 二手
    特殊处理:同时含"招聘"和"转让"的,以"转让"为主(因为是商家发的)
    """
    combined = (title or "") + " " + (body or "")[:500]

    # 特殊优先级:如果同时含"转让/出兑/出售"和"招聘",这是生意转让
    transfer_keywords = ["转让", "出兑", "出让", "生意出售", "店出售", "店铺出售"]
    has_transfer = any(k in combined for k in transfer_keywords)
    if has_transfer:
        return ("生意买卖", fallback_sub or "生意转让")

    # 按 CATEGORY_KEYWORDS 顺序匹配
    for cat, keywords in CATEGORY_KEYWORDS:
        for kw in keywords:
            if kw in combined:
                # 用版块 sub_category 作为细分(如果有),否则用 keyword
                sub = fallback_sub if fallback_sub and cat == fallback_category else kw
                return (cat, sub or kw)

    # 完全没匹配 → 用版块 mapping 的结果
    return (fallback_category or "其他", fallback_sub or "其他")



def run(
    max_forums: int = 5,           # 一次运行最多扫几个版块
    max_topics_per_forum: int = 15, # 每个版块最多抓几条帖子
    recent_days: int = 7,          # 只保留发布/更新在 N 天内的(0 = 不过滤)
    db_path=None,
) -> Dict[str, Any]:
    """
    主入口。返回这次运行的统计字典。
    """
    init_db(db_path)
    session = requests.Session()
    session.headers.update(HEADERS)
    counter = RequestCounter(MAX_REQUESTS_PER_RUN)

    stats = {
        "discovered_forums": 0,
        "scanned_forums": 0,
        "topics_seen": 0,
        "new": 0,
        "updated": 0,
        "skipped": 0,
        "errors": 0,
    }

    with db_connect(db_path) as conn:
        run_id = start_run(conn, SOURCE_NAME, note=f"max_forums={max_forums}")

        try:
            # ---- 步骤 1: 探测版块 ----
            logger.info("Step 1: Discovering forums on %s ...", BASE_URL)
            home_html = fetch(BASE_URL + "/", counter, session)
            if not home_html:
                # 退路:试 /f/
                home_html = fetch(BASE_URL + "/f/", counter, session)
            if not home_html:
                raise RuntimeError("Failed to fetch homepage")

            forums = discover_forums(home_html)
            stats["discovered_forums"] = len(forums)
            logger.info("Discovered %d forums", len(forums))

            # 过滤:只留我们关心的版块
            interesting = []
            for f in forums:
                mapped = map_forum_to_category(f)
                if mapped:
                    f["category"], f["sub_category"] = mapped
                    interesting.append(f)

            logger.info("Of those, %d are interesting (matched our categories)", len(interesting))
            for f in interesting:
                logger.info("  - [%s] %s (f_%s) → %s/%s",
                            f["forum_id"], f["name"], f["forum_id"],
                            f["category"], f["sub_category"])

            # ---- 步骤 2: 爬版块列表 + 帖子 ----
            for forum in interesting[:max_forums]:
                logger.info("Step 2: Scraping forum %s (f_%s)", forum["name"], forum["forum_id"])
                forum_html = fetch(forum["url"], counter, session)
                if not forum_html:
                    stats["errors"] += 1
                    continue

                topics = parse_forum_listing(forum_html)
                logger.info("  found %d topics on first page", len(topics))
                stats["topics_seen"] += len(topics)
                stats["scanned_forums"] += 1

                # 抓正文
                for topic in topics[:max_topics_per_forum]:
                    # 先看库里有没有
                    existing = conn.execute(
                        "SELECT id FROM jobs WHERE source = ? AND source_id = ?",
                        (SOURCE_NAME, topic["source_id"]),
                    ).fetchone()

                    if existing:
                        # 已有,只更新 scraped_at(标记还在版块第一页 = 仍 active)
                        conn.execute(
                            "UPDATE jobs SET scraped_at = ?, is_active = 1 WHERE source = ? AND source_id = ?",
                            (now_iso(), SOURCE_NAME, topic["source_id"]),
                        )
                        conn.commit()
                        stats["skipped"] += 1
                        continue

                    # 新帖,翻进去
                    topic_html = fetch(topic["source_url"], counter, session)
                    if not topic_html:
                        stats["errors"] += 1
                        continue

                    parsed = parse_topic(
                        topic_html,
                        source_url=topic["source_url"],
                        source_id=topic["source_id"],
                    )
                    if not parsed:
                        stats["errors"] += 1
                        continue

                    # 合并版块给的标题(列表页的标题往往更干净)
                    if topic.get("title") and len(topic["title"]) > 3:
                        parsed["title"] = topic["title"]

                    # 基于内容重判 category(覆盖版块 mapping,因为论坛版块
                    # 实际上经常和帖子内容脱节,例如"按摩专区"里全是店铺转让)
                    new_cat, new_sub = reclassify_category(
                        title=parsed.get("title", ""),
                        body=parsed.get("body", ""),
                        fallback_category=forum["category"],
                        fallback_sub=forum["sub_category"],
                    )
                    parsed["category"] = new_cat
                    parsed["sub_category"] = new_sub

                    # 时效过滤:超过 recent_days 天的帖子直接跳过
                    if recent_days > 0 and not is_recent_enough(parsed, recent_days):
                        stats["skipped"] += 1
                        continue

                    result = upsert_job(conn, parsed)
                    conn.commit()

                    if result == "new":
                        stats["new"] += 1
                    elif result == "updated":
                        stats["updated"] += 1
                    else:
                        stats["skipped"] += 1

            finish_run(
                conn, run_id, "success",
                new_count=stats["new"],
                updated_count=stats["updated"],
                skipped_count=stats["skipped"],
                error_count=stats["errors"],
            )

        except Exception as e:
            logger.exception("Run failed: %s", e)
            finish_run(
                conn, run_id, "failed",
                new_count=stats["new"],
                updated_count=stats["updated"],
                skipped_count=stats["skipped"],
                error_count=stats["errors"] + 1,
                error_message=str(e)[:500],
            )
            stats["errors"] += 1

    stats["requests_made"] = counter.count
    return stats


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    print("Starting chineseinla scraper (v2)...")
    print("Filters: max_forums=8, max_topics_per_forum=15, recent_days=7")
    print()
    result = run(max_forums=8, max_topics_per_forum=15, recent_days=7)
    print()
    print("=" * 60)
    print("Run finished. Stats:")
    for k, v in result.items():
        print(f"  {k}: {v}")
    print("=" * 60)

