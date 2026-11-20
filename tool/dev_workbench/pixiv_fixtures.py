"""Deterministic Pixiv App API / Ajax / Web / Media fixtures for loopback mode."""

from __future__ import annotations

import io
import json
import struct
import urllib.parse
import zipfile
import zlib
from dataclasses import dataclass, field


def make_png_bytes(width: int, height: int, rgb: tuple[int, int, int]) -> bytes:
    """Builds a minimal valid solid-color RGBA PNG with clean gradient stripes."""
    r, g, b = rgb

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0
        stripe = 24 if ((y // 8) % 2 == 0) else 0
        rr = min(255, r + stripe)
        gg = min(255, g + (y * 64 // max(1, height)))
        bb = min(255, b + (stripe // 2))
        row = bytes((rr, gg, bb, 255)) * width
        raw.extend(row)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(raw), level=6)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", idat)
        + chunk(b"IEND", b"")
    )


def make_ugoira_zip_bytes() -> bytes:
    """Builds a stored ZIP archive of 3 deterministic PNG frames."""
    buf = io.BytesIO()
    colors = [(58, 122, 214), (104, 178, 132), (224, 128, 86)]
    with zipfile.ZipFile(buf, mode="w", compression=zipfile.ZIP_STORED) as zf:
        for idx, color in enumerate(colors):
            zf.writestr(f"00000{idx}.png", make_png_bytes(160, 120, color))
    return buf.getvalue()


_SAMPLE_COLORS: dict[int, tuple[int, int, int]] = {
    900001: (54, 114, 198),
    900002: (196, 92, 134),
    900003: (72, 168, 136),
    900004: (212, 148, 68),
    900005: (128, 96, 192),
    900006: (64, 152, 176),
}


def _user_obj(
    user_id: int,
    name: str,
    account: str,
    *,
    followed: bool = False,
) -> dict[str, object]:
    return {
        "id": user_id,
        "name": name,
        "account": account,
        "profile_image_urls": {
            "medium": f"https://s.pximg.net/user-profile/avatar_{user_id}.png",
        },
        "is_followed": followed,
    }


def _image_urls(illust_id: int, page: int = 0) -> dict[str, str]:
    suffix = f"{illust_id}_p{page}.png"
    return {
        "square_medium": f"https://i.pximg.net/c/360x360_70/img-master/img/{suffix}",
        "medium": f"https://i.pximg.net/c/540x540_70/img-master/img/{suffix}",
        "large": f"https://i.pximg.net/img-master/img/{suffix}",
    }


def _make_illust(
    illust_id: int,
    title: str,
    user: dict[str, object],
    *,
    work_type: str = "illust",
    page_count: int = 1,
    width: int = 1200,
    height: int = 900,
    tags: list[tuple[str, str | None]] | None = None,
    series: dict[str, object] | None = None,
    bookmarked: bool = False,
) -> dict[str, object]:
    img_urls = _image_urls(illust_id, 0)
    if page_count == 1:
        meta_single = {
            "original_image_url": f"https://i.pximg.net/img-original/img/{illust_id}_p0.png",
        }
        meta_pages: list[dict[str, object]] = []
    else:
        meta_single = {}
        meta_pages = [
            {
                "image_urls": {
                    **_image_urls(illust_id, p),
                    "original": f"https://i.pximg.net/img-original/img/{illust_id}_p{p}.png",
                },
                "width": width,
                "height": height,
            }
            for p in range(page_count)
        ]
    return {
        "id": illust_id,
        "title": title,
        "type": work_type,
        "image_urls": img_urls,
        "caption": f"Loopback fixture artwork #{illust_id} ({work_type})",
        "restrict": 0,
        "user": user,
        "tags": [
            {"name": name, "translated_name": tr}
            for name, tr in (tags or [("landscape", "风景"), ("original", "原创")])
        ],
        "tools": ["Clip Studio Paint"],
        "create_date": "2026-11-15T10:00:00+09:00",
        "page_count": page_count,
        "width": width,
        "height": height,
        "sanity_level": 2,
        "x_restrict": 0,
        "series": series,
        "meta_single_page": meta_single,
        "meta_pages": meta_pages,
        "total_view": 1000 + illust_id % 500,
        "total_bookmarks": 120 + illust_id % 90,
        "is_bookmarked": bookmarked,
        "visible": True,
        "is_muted": False,
        "illust_ai_type": 0,
    }


def _make_novel(
    novel_id: int,
    title: str,
    user: dict[str, object],
    *,
    series: dict[str, object] | None = None,
    bookmarked: bool = False,
) -> dict[str, object]:
    body = (
        f"Chapter 1 — {title}\n\n"
        "[newpage]\n"
        "The morning light crossed the drafting desk while the local workbench "
        "captured every interactive transition across desktop and mobile.\n\n"
        "End of loopback chapter."
    )
    return {
        "id": novel_id,
        "title": title,
        "caption": f"Loopback novel fixture #{novel_id}",
        "restrict": 0,
        "x_restrict": 0,
        "is_original": True,
        "image_urls": {
            "square_medium": f"https://i.pximg.net/novel-cover/{novel_id}_sq.png",
            "medium": f"https://i.pximg.net/novel-cover/{novel_id}_m.png",
            "large": f"https://i.pximg.net/novel-cover/{novel_id}_l.png",
        },
        "create_date": "2026-11-15T09:30:00+09:00",
        "tags": [{"name": "sci-fi", "translated_name": "科幻", "added_by_uploaded_user": True}],
        "page_count": 2,
        "text_length": len(body),
        "user": user,
        "series": series or {},
        "is_bookmarked": bookmarked,
        "total_bookmarks": 45,
        "total_view": 380,
        "total_comments": 2,
        "visible": True,
        "is_muted": False,
        "is_mypixiv_only": False,
        "is_x_restricted": False,
        "novel_ai_type": 0,
        "content": body,
    }


@dataclass
class PixivLoopbackState:
    authors: list[dict[str, object]] = field(default_factory=list)
    illusts: list[dict[str, object]] = field(default_factory=list)
    novels: list[dict[str, object]] = field(default_factory=list)
    ai_show: bool = True
    restricted_mode: bool = False
    _comment_seq: int = 7000
    _dev_user: dict[str, object] = field(
        default_factory=lambda: _user_obj(900001, "Parfait Dev", "parfait_dev")
    )

    def __post_init__(self) -> None:
        if not self.authors:
            self.authors = [
                _user_obj(910001, "Atelier Aoi", "atelier_aoi", followed=True),
                _user_obj(910002, "Kuroha Studio", "kuroha_studio", followed=False),
                _user_obj(910003, "Minato Works", "minato_works", followed=True),
            ]
        series_ref = {"id": 8801, "title": "Loopback Sketchbook"}
        if not self.illusts:
            self.illusts = [
                _make_illust(
                    900001,
                    "Harbor Dawn Study",
                    self.authors[0],
                    work_type="illust",
                    page_count=1,
                    width=1280,
                    height=880,
                    tags=[("harbor", "港口"), ("morning", "清晨")],
                    series=series_ref,
                ),
                _make_illust(
                    900002,
                    "Multi-Page Comic Rough",
                    self.authors[1],
                    work_type="manga",
                    page_count=3,
                    width=960,
                    height=1280,
                    tags=[("manga", "漫画"), ("rough", "草稿")],
                ),
                _make_illust(
                    900003,
                    "Clockwork Windmill (Ugoira)",
                    self.authors[2],
                    work_type="ugoira",
                    page_count=1,
                    width=640,
                    height=480,
                    tags=[("ugoira", "动图"), ("motion", "动态")],
                ),
                _make_illust(
                    900004,
                    "Night Tram Platform",
                    self.authors[0],
                    work_type="illust",
                    page_count=1,
                    width=1000,
                    height=1400,
                    tags=[("night", "夜景"), ("city", "都市")],
                ),
                _make_illust(
                    900005,
                    "Botanical Conservatory",
                    self.authors[1],
                    work_type="illust",
                    page_count=2,
                    width=1100,
                    height=900,
                    tags=[("greenhouse", "温室"), ("architecture", "建筑")],
                ),
                _make_illust(
                    900006,
                    "Observatory Sketch Series #2",
                    self.authors[0],
                    work_type="manga",
                    page_count=2,
                    width=1024,
                    height=768,
                    series=series_ref,
                ),
            ]
        if not self.novels:
            novel_series = {"id": 6601, "title": "Signal Across Mirrors"}
            self.novels = [
                _make_novel(
                    800001,
                    "Orbit Calibration Log",
                    self.authors[2],
                    series=novel_series,
                ),
                _make_novel(
                    800002,
                    "Notes from the Wet Dock",
                    self.authors[1],
                ),
            ]

    def _find_illust(self, illust_id: int) -> dict[str, object] | None:
        for item in self.illusts:
            if item["id"] == illust_id:
                return item
        return None

    def _find_novel(self, novel_id: int) -> dict[str, object]:
        for item in self.novels:
            if item["id"] == novel_id:
                return item
        return self.novels[0]

    def _find_author(self, user_id: int) -> dict[str, object]:
        for author in self.authors:
            if author["id"] == user_id:
                return author
        if user_id == 900001:
            return self._dev_user
        return _user_obj(user_id, f"User {user_id}", f"user_{user_id}")

    @staticmethod
    def _next_url_for(
        path: str,
        params: dict[str, list[str]],
        offset: int,
        total: int,
        page_size: int,
    ) -> str | None:
        if offset + page_size >= total:
            return None
        merged = {k: v[-1] for k, v in params.items() if v}
        merged["offset"] = str(offset + page_size)
        return f"https://app-api.pixiv.net{path}?{urllib.parse.urlencode(merged)}"

    def handle_request(
        self,
        method: str,
        target_host: str,
        path: str,
        query: str,
        body: bytes,
    ) -> tuple[int, str, bytes]:
        params = urllib.parse.parse_qs(query, keep_blank_values=True)
        form = urllib.parse.parse_qs(body.decode("utf-8", errors="replace")) if method == "POST" else {}

        # Binary media & ugoira zip on pximg hosts
        if target_host in ("i.pximg.net", "s.pximg.net") or path.endswith((".png", ".jpg", ".jpeg", ".zip")):
            if path.endswith(".zip"):
                return 200, "application/zip", make_ugoira_zip_bytes()
            color_seed = sum(ord(ch) for ch in path) % len(_SAMPLE_COLORS)
            rgb = list(_SAMPLE_COLORS.values())[color_seed]
            width, height = (360, 360) if "360x360" in path else (960, 720)
            if "avatar" in path or "user-profile" in path:
                width, height = 160, 160
            return 200, "image/png", make_png_bytes(width, height, rgb)

        # Spotlight article HTML (www.pixivision.net)
        if target_host == "www.pixivision.net" or path.startswith(("/a/", "/en/a/", "/zh/a/")):
            html_doc = (
                "<!doctype html><html><head><title>Loopback Spotlight</title></head>"
                "<body><article>"
                "<h1 class='am__title'>Loopback Spotlight Feature</h1>"
                "<p class='am__description'>Deterministic feature article inside Dev Workbench.</p>"
                "<div class='am__body'>"
                "<p>Explore curated works such as "
                "<a href='https://www.pixiv.net/artworks/900001'>Harbor Dawn Study</a> "
                "by <a href='https://www.pixiv.net/users/910001'>Atelier Aoi</a>.</p>"
                "<img src='https://i.pximg.net/img-master/img/900001_p0.png' />"
                "</div></article></body></html>"
            )
            return 200, "text/html; charset=utf-8", html_doc.encode("utf-8")

        # OAuth token endpoint
        if path == "/auth/token":
            payload = {
                "access_token": "dev-loopback-access",
                "expires_in": 3600,
                "token_type": "bearer",
                "scope": "",
                "refresh_token": "dev-loopback-refresh",
                "user": {
                    "id": "900001",
                    "name": "Parfait Dev",
                    "account": "parfait_dev",
                    "mail_address": "dev@example.invalid",
                    "is_premium": True,
                    "profile_image_urls": {
                        "px_16x16": "https://s.pximg.net/user-profile/avatar_900001.png",
                        "px_50x50": "https://s.pximg.net/user-profile/avatar_900001.png",
                        "px_170x170": "https://s.pximg.net/user-profile/avatar_900001.png",
                    },
                },
            }
            return self._json(200, payload)

        # Network probe
        if path == "/v1/illust/prime":
            return self._json(200, {"illusts": []})

        # Illust lists & paging
        if path in (
            "/v1/illust/recommended",
            "/v1/illust/ranking",
            "/v2/illust/follow",
            "/v1/illust/new",
            "/v2/illust/mypixiv",
            "/v2/illust/related",
            "/v1/user/illusts",
            "/v1/user/bookmarks/illust",
            "/v1/search/illust",
            "/v1/search/popular-preview/illust",
        ):
            offset = int((params.get("offset") or ["0"])[0] or "0")
            items = self.illusts
            word = (params.get("word") or [""])[0].strip().lower()
            if word:
                filtered = [
                    it for it in items
                    if word in str(it["title"]).lower()
                    or any(word in t["name"].lower() for t in it["tags"])
                ]
                items = filtered or items
            page = items[offset : offset + 4]
            next_url = self._next_url_for(path, params, offset, len(items), 4)
            extra = {"ranking_illusts": self.illusts[:2]} if path == "/v1/illust/recommended" else {}
            return self._json(200, {"illusts": page, "next_url": next_url, **extra})

        if path == "/v1/illust/detail":
            iid = int((params.get("illust_id") or ["900001"])[0])
            illust = self._find_illust(iid)
            if illust is None:
                return self._json(404, {"error": {"user_message": "Artwork not found"}})
            return self._json(200, {"illust": illust})

        if path.startswith("/ajax/illust/") and path.endswith("/pages"):
            parts = [p for p in path.split("/") if p]
            iid = int(parts[2]) if len(parts) >= 4 and parts[2].isdigit() else 900001
            illust = self._find_illust(iid)
            if illust is None:
                return self._json(404, {"error": True, "message": "Artwork not found", "body": []})
            count = int(illust["page_count"])
            w = int(illust["width"])
            h = int(illust["height"])
            pages = [
                {
                    "width": w,
                    "height": h,
                    "urls": {
                        "original": f"https://i.pximg.net/img-original/img/{iid}_p{idx}.png",
                    },
                }
                for idx in range(count)
            ]
            return self._json(200, {"error": False, "message": "", "body": pages})

        if path == "/v1/ugoira/metadata":
            iid = int((params.get("illust_id") or ["900003"])[0])
            return self._json(
                200,
                {
                    "ugoira_metadata": {
                        "zip_urls": {
                            "medium": f"https://i.pximg.net/img-zip-ugoira/img/{iid}_ugoira600x600.zip",
                        },
                        "frames": [
                            {"file": "000000.png", "delay": 100},
                            {"file": "000001.png", "delay": 100},
                            {"file": "000002.png", "delay": 100},
                        ],
                    },
                },
            )

        # Series endpoints
        if path == "/v1/illust/series":
            series_works = [i for i in self.illusts if i.get("series")]
            return self._json(
                200,
                {
                    "illust_series_detail": {
                        "id": 8801,
                        "title": "Loopback Sketchbook",
                        "caption": "Curated multi-part drawing notebook.",
                        "user": self.authors[0],
                        "series_work_count": len(series_works),
                        "watchlist_added": False,
                        "is_concluded": False,
                    },
                    "illust_series_first_illust": series_works[0],
                    "illust_series_latest_illust": series_works[-1],
                    "illusts": series_works,
                    "next_url": None,
                },
            )

        if path == "/v1/illust-series/illust":
            series_works = [i for i in self.illusts if i.get("series")]
            return self._json(
                200,
                {
                    "illust_series_detail": {
                        "id": 8801,
                        "title": "Loopback Sketchbook",
                        "user": self.authors[0],
                        "series_work_count": len(series_works),
                    },
                    "illust_series_context": {
                        "series_id": 8801,
                        "content_order": 1,
                        "prev": None,
                        "next": series_works[-1],
                    },
                },
            )

        if path == "/v1/user/illust-series":
            return self._json(
                200,
                {
                    "illust_series_details": [
                        {
                            "id": 8801,
                            "title": "Loopback Sketchbook",
                            "user": self.authors[0],
                            "series_work_count": 2,
                        },
                    ],
                    "next_url": None,
                },
            )

        # Novels
        if path in (
            "/v1/novel/recommended",
            "/v1/novel/ranking",
            "/v1/novel/follow",
            "/v1/novel/new",
            "/v1/novel/mypixiv",
            "/v1/user/novels",
            "/v1/user/bookmarks/novel",
            "/v1/search/novel",
            "/v1/search/popular-preview/novel",
        ):
            return self._json(200, {"novels": self.novels, "next_url": None})

        if path == "/v2/novel/detail":
            nid = int((params.get("novel_id") or ["800001"])[0])
            return self._json(200, {"novel": self._find_novel(nid)})

        if path == "/webview/v2/novel":
            nid = int((params.get("id") or ["800001"])[0])
            novel = self._find_novel(nid)
            bootstrap = json.dumps(
                {
                    "novel": {
                        "id": str(novel["id"]),
                        "title": novel["title"],
                        "text": novel["content"],
                        "images": {},
                        "illusts": {},
                        "seriesNavigation": {},
                        "marker": None,
                    }
                },
                ensure_ascii=False,
            )
            html_doc = (
                "<!doctype html><html><head><title>Novel</title></head><body>"
                f"<script>Object.defineProperty(window, 'pixiv', {{ value: {bootstrap} }});</script>"
                "</body></html>"
            )
            return 200, "text/html; charset=utf-8", html_doc.encode("utf-8")

        if path == "/v2/novel/series":
            return self._json(
                200,
                {
                    "novel_series_detail": {
                        "id": 6601,
                        "title": "Signal Across Mirrors",
                        "caption": "Loopback novel series fixture.",
                        "is_original": True,
                        "is_concluded": False,
                        "content_count": 1,
                        "total_character_count": len(str(self.novels[0]["content"])),
                        "user": self.authors[2],
                        "watchlist_added": False,
                    },
                    "novels": [self.novels[0]],
                    "next_url": None,
                },
            )

        if path == "/v2/novel/markers":
            return self._json(200, {"marked_novels": [], "next_url": None})

        # Users
        if path == "/v1/user/detail":
            uid = int((params.get("user_id") or ["910001"])[0])
            author = self._find_author(uid)
            return self._json(
                200,
                {
                    "user": author,
                    "profile": {
                        "webpage": None,
                        "twitter_url": None,
                        "pawoo_url": None,
                        "background_image_url": None,
                        "total_follow_users": 12,
                        "total_mypixiv_users": 0,
                        "total_illusts": 4,
                        "total_manga": 2,
                        "total_novels": 2,
                        "total_illust_bookmarks_public": 18,
                        "total_illust_series": 1,
                        "total_novel_series": 1,
                    },
                },
            )

        if path in (
            "/v1/user/recommended",
            "/v1/user/following",
            "/v1/user/follower",
            "/v1/user/mypixiv",
            "/v1/search/user",
        ):
            previews = [
                {
                    "user": author,
                    "illusts": self.illusts[:2],
                    "novels": [],
                    "is_muted": False,
                }
                for author in self.authors
            ]
            return self._json(200, {"user_previews": previews, "next_url": None})

        if path == "/v1/user/follow/detail":
            uid = int((params.get("user_id") or ["910001"])[0])
            author = self._find_author(uid)
            return self._json(
                200,
                {
                    "follow_detail": {
                        "is_followed": bool(author.get("is_followed", False)),
                        "restrict": "public",
                    },
                },
            )

        if path == "/v1/user/follow/add" and method == "POST":
            uid = int((form.get("user_id") or ["0"])[0])
            author = self._find_author(uid)
            author["is_followed"] = True
            return self._json(200, {})

        if path == "/v1/user/follow/delete" and method == "POST":
            uid = int((form.get("user_id") or ["0"])[0])
            author = self._find_author(uid)
            author["is_followed"] = False
            return self._json(200, {})

        # Bookmarks
        if path in ("/v2/illust/bookmark/detail", "/v2/novel/bookmark/detail"):
            return self._json(
                200,
                {
                    "bookmark_detail": {
                        "is_bookmarked": False,
                        "restrict": "public",
                        "tags": [{"name": "landscape", "is_registered": False}],
                    },
                },
            )

        if path in ("/v1/user/bookmark-tags/illust", "/v1/user/bookmark-tags/novel"):
            return self._json(
                200,
                {
                    "bookmark_tags": [{"name": "landscape", "count": 3}],
                    "next_url": None,
                },
            )

        if path in (
            "/v2/illust/bookmark/add",
            "/v1/illust/bookmark/delete",
            "/v2/novel/bookmark/add",
            "/v1/novel/bookmark/delete",
        ) and method == "POST":
            is_add = path.endswith("/add")
            if "illust_id" in form:
                item = self._find_illust(int(form["illust_id"][0]))
                if item is None:
                    return self._json(404, {"error": {"user_message": "Artwork not found"}})
                item["is_bookmarked"] = is_add
            return self._json(200, {})

        # Search metadata
        if path == "/v2/search/autocomplete":
            word = (params.get("word") or ["harbor"])[0]
            return self._json(
                200,
                {
                    "tags": [
                        {"name": word, "translated_name": None},
                        {"name": f"{word}_study", "translated_name": None},
                    ],
                },
            )

        if path in ("/v1/trending-tags/illust", "/v1/trending-tags/novel"):
            return self._json(
                200,
                {
                    "trend_tags": [
                        {
                            "tag": "harbor",
                            "translated_name": "港口",
                            "illust": self.illusts[0],
                        },
                        {
                            "tag": "ugoira",
                            "translated_name": "动图",
                            "illust": self.illusts[2],
                        },
                    ],
                },
            )

        # Spotlight
        if path == "/v1/spotlight/articles":
            return self._json(
                200,
                {
                    "spotlight_articles": [
                        {
                            "id": 4401,
                            "title": "Loopback Harbor Feature",
                            "pure_title": "Harbor Feature",
                            "category": "spotlight",
                            "article_url": "https://www.pixivision.net/en/a/4401",
                            "thumbnail": "https://i.pximg.net/img-master/img/900001_p0.png",
                            "publish_date": "2026-11-15T00:00:00+09:00",
                            "subcategory_label": "Illustration",
                        },
                    ],
                    "next_url": None,
                },
            )

        # Comments
        if path in ("/v3/illust/comments", "/v3/novel/comments", "/v2/illust/comment/replies", "/v2/novel/comment/replies"):
            return self._json(
                200,
                {
                    "total_comments": 1,
                    "comments": [
                        {
                            "id": 7001,
                            "comment": "Clean composition in loopback fixture.",
                            "date": "2026-11-15T10:30:00+09:00",
                            "user": self.authors[1],
                            "has_replies": False,
                            "parent_comment_id": None,
                            "stamp": None,
                        },
                    ],
                    "next_url": None,
                },
            )

        if path in ("/v1/illust/comment/add", "/v1/novel/comment/add") and method == "POST":
            self._comment_seq += 1
            text = (form.get("comment") or [""])[0]
            return self._json(
                200,
                {
                    "comment": {
                        "id": self._comment_seq,
                        "comment": text,
                        "date": "2026-11-15T11:00:00+09:00",
                        "user": self._find_author(900001),
                        "has_replies": False,
                        "parent_comment_id": None,
                        "stamp": None,
                    },
                },
            )

        if path in ("/v1/illust/comment/delete", "/v1/novel/comment/delete") and method == "POST":
            return self._json(200, {})

        # Watchlist, Mute, Server display settings, History, Profile edit
        if path in ("/v1/watchlist/manga", "/v1/watchlist/novel"):
            return self._json(200, {"series": [], "next_url": None})

        if path == "/v1/mute/list":
            return self._json(
                200,
                {"muted_tags": [], "muted_users": [], "mute_limit_count": 500},
            )

        if path == "/v1/user/ai-show-settings":
            return self._json(200, {"show_ai": self.ai_show})

        if path == "/v1/user/ai-show-settings/edit" and method == "POST":
            self.ai_show = (form.get("show_ai") or ["true"])[0] == "true"
            return self._json(200, {"show_ai": self.ai_show})

        if path == "/v1/user/restricted-mode-settings":
            if method == "POST":
                self.restricted_mode = (
                    form.get("is_restricted_mode_enabled") or ["false"]
                )[0] == "true"
            return self._json(200, {"is_restricted_mode_enabled": self.restricted_mode})

        if method == "POST":
            return self._json(200, {})

        return self._json(404, {"error": {"message": f"unknown loopback path: {path}"}})

    @staticmethod
    def _json(status: int, obj: object) -> tuple[int, str, bytes]:
        return status, "application/json; charset=utf-8", json.dumps(obj, ensure_ascii=False).encode("utf-8")
