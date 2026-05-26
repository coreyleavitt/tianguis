"""Build the static tianguis.dev site from index.json.

Reads <repo>/index.json + the static templates in site/templates/, emits
site/_build/ ready to upload to GH Pages. Pure stdlib; no dependencies.

Output structure:
  _build/
    index.html      — landing page + package list
    index.kdl       — copy of the canonical registry (milpa fetches this)
    index.json      — copy of the JSON projection
    robots.txt      — noindex hints during the soft-launch period
    CNAME           — for the custom domain
    style.css       — minimal styling
"""
from __future__ import annotations

import html
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SITE = Path(__file__).resolve().parents[1]
BUILD = SITE / "_build"
TEMPLATES = SITE / "templates"


def fmt_iso(ts: str) -> str:
    """Render an ISO 8601 UTC timestamp as YYYY-MM-DD for compactness."""
    try:
        return ts.split("T", 1)[0]
    except Exception:
        return ts


def render_package(pkg: dict) -> str:
    versions = pkg.get("versions", [])
    namespace = html.escape(pkg.get("namespace", ""))
    name = html.escape(pkg.get("name", ""))
    upstream = html.escape(pkg.get("upstream", ""))

    latest = versions[0] if versions else None
    version_count = len(versions)
    if latest:
        latest_ver = html.escape(latest.get("version", ""))
        attestation = html.escape(latest.get("attestation", "unknown"))
        att_class = "att-author" if attestation == "author-signed" else "att-vendored"
        published_at = fmt_iso(latest.get("published_at", ""))
        meta = f'<span class="{att_class}">{attestation}</span> · {published_at}'
    else:
        latest_ver = "—"
        meta = '<span class="att-vendored">no versions</span>'

    return f"""\
<li class="pkg" data-name="{name}" data-namespace="{namespace}">
  <div class="pkg-head">
    <span class="pkg-ns">{namespace}/</span><a class="pkg-name" href="{upstream}">{name}</a>
    <span class="pkg-ver">{latest_ver}</span>
  </div>
  <div class="pkg-meta">{meta} · {version_count} version{'s' if version_count != 1 else ''}</div>
</li>
"""


def build() -> None:
    index_json = REPO / "index.json"
    index_kdl = REPO / "index.kdl"
    if not index_json.exists():
        print(f"FATAL: {index_json} missing — run tianguis project first", file=sys.stderr)
        sys.exit(1)

    data = json.loads(index_json.read_text())
    packages = data.get("packages", [])
    # Sort by namespace/name for stable rendering.
    packages.sort(key=lambda p: (p.get("namespace", ""), p.get("name", "")))

    pkg_html = "\n".join(render_package(p) for p in packages)
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    last_commit = data.get("generated_at", "")

    tmpl = (TEMPLATES / "index.html").read_text()
    page = (
        tmpl
        .replace("{{PACKAGE_COUNT}}", str(len(packages)))
        .replace("{{PACKAGES}}", pkg_html)
        .replace("{{BUILD_TIME}}", html.escape(now_iso))
        .replace("{{LAST_COMMIT}}", html.escape(last_commit))
    )

    if BUILD.exists():
        shutil.rmtree(BUILD)
    BUILD.mkdir(parents=True)

    (BUILD / "index.html").write_text(page)
    shutil.copy(TEMPLATES / "style.css", BUILD / "style.css")
    shutil.copy(TEMPLATES / "robots.txt", BUILD / "robots.txt")
    shutil.copy(TEMPLATES / "CNAME", BUILD / "CNAME")
    # Serve the raw registry files at /index.kdl and /index.json so milpa
    # can use https://tianguis.dev/index.kdl as the canonical URL.
    shutil.copy(index_kdl, BUILD / "index.kdl")
    shutil.copy(index_json, BUILD / "index.json")

    print(f"built {BUILD}/ with {len(packages)} packages")


if __name__ == "__main__":
    build()
