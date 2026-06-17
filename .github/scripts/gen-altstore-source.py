#!/usr/bin/env python3
"""Generate an AltStore / SideStore / Feather / LiveContainer compatible source.

This script fetches GitHub Releases, finds iOS .ipa assets, and rebuilds
docs/source.json with full version history.

Usage:
    python3 .github/scripts/gen-altstore-source.py [output_path]
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request


DEFAULT_REPO = "emp0ry/AnimeShin"
RAW_BRANCH = "main"

IPA_NAME_RE = re.compile(r"\.ipa$", re.IGNORECASE)
IPA_VERSION_RE = re.compile(r"-v(\d+(?:\.\d+){1,3})", re.IGNORECASE)

SOURCE = {
    "name": "AnimeShin",
    "identifier": "com.emp0ry.animeshin.source",
    "subtitle": "A modern, unofficial AniList companion application.",
    "description": (
        "Official AltStore / SideStore / Feather / LiveContainer source for "
        "AnimeShin - track anime & manga, manage your library."
    ),
    "website": "https://github.com/emp0ry/AnimeShin",
    "tintColor": "8b5cf6",
}

APP = {
    "name": "AnimeShin",
    "bundleIdentifier": "com.emp0ry.animeshin",
    "developerName": "emp0ry",
    "subtitle": "A modern, unofficial AniList companion application.",
    "localizedDescription": (
        "A modern, unofficial AniList companion application. "
        "Track anime & manga, manage your library, "
        "and optionally open media using user-configured extensions."
    ),
    "tintColor": "8b5cf6",
    "category": "entertainment",
    "minOSVersion": "13.0",
    "iconURL": f"https://raw.githubusercontent.com/{DEFAULT_REPO}/{RAW_BRANCH}/assets/icons/about.png",
    "screenshots": [
        f"https://raw.githubusercontent.com/{DEFAULT_REPO}/{RAW_BRANCH}/assets/screenshots/1.PNG",
        f"https://raw.githubusercontent.com/{DEFAULT_REPO}/{RAW_BRANCH}/assets/screenshots/2.PNG",
        f"https://raw.githubusercontent.com/{DEFAULT_REPO}/{RAW_BRANCH}/assets/screenshots/3.PNG",
    ],
    "appPermissions": {
        "entitlements": [],
        "privacy": [],
    },
}


def detect_repo() -> str:
    repo = os.environ.get("GITHUB_REPOSITORY")
    if repo:
        return repo

    try:
        url = subprocess.check_output(
            ["git", "config", "--get", "remote.origin.url"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()

        match = re.search(r"github\.com[:/](.+?)(?:\.git)?$", url)
        if match:
            return match.group(1)
    except Exception:
        pass

    return DEFAULT_REPO


def next_link(headers) -> str | None:
    link = headers.get("Link")
    if not link:
        return None

    for part in link.split(","):
        match = re.search(r'<([^>]+)>;\s*rel="next"', part.strip())
        if match:
            return match.group(1)

    return None


def fetch_releases(repo: str) -> list[dict]:
    cached = os.environ.get("RELEASES_JSON")
    if cached:
        with open(cached, encoding="utf-8") as file:
            return json.load(file)

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")

    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "animeshin-altstore-source",
        "X-GitHub-Api-Version": "2022-11-28",
    }

    if token:
        headers["Authorization"] = f"Bearer {token}"

    url = f"https://api.github.com/repos/{repo}/releases?per_page=100"
    releases: list[dict] = []

    while url:
        request = urllib.request.Request(url, headers=headers)

        try:
            with urllib.request.urlopen(request) as response:
                releases.extend(json.load(response))
                url = next_link(response.headers)
        except urllib.error.HTTPError as error:
            message = error.read().decode(errors="replace")
            sys.exit(f"GitHub API error {error.code} for {url}: {message}")

    return releases


def clean_notes(body: str | None, fallback: str) -> str:
    if not body:
        return fallback

    text = body.replace("\r\n", "\n").replace("\r", "\n").strip()

    if "## What's New" in text:
        text = text.split("## What's New", 1)[-1].strip()

    if "\n\n## Highlights" in text:
        text = text.split("\n\n## Highlights", 1)[0].strip()

    if "\n\n<detail" in text:
        text = text.split("\n\n<detail", 1)[0].strip()

    return text or fallback


def build_versions(releases: list[dict]) -> list[dict]:
    versions: list[dict] = []

    for release in releases:
        if release.get("draft"):
            continue

        ipa = next(
            (
                asset
                for asset in release.get("assets", [])
                if IPA_NAME_RE.search(asset.get("name", ""))
            ),
            None,
        )

        if not ipa:
            continue

        match = IPA_VERSION_RE.search(ipa["name"])
        version = match.group(1) if match else (release.get("tag_name", "") or "").lstrip("v")

        if not version:
            continue

        published = release.get("published_at") or release.get("created_at") or ""
        date = published[:10] if published else ""

        versions.append(
            {
                "version": version,
                "date": date,
                "localizedDescription": clean_notes(
                    release.get("body"),
                    f"{APP['name']} {version}",
                ),
                "downloadURL": ipa["browser_download_url"],
                "size": int(ipa.get("size", 0)),
                "minOSVersion": APP["minOSVersion"],
                "_sort": published,
            }
        )

    versions.sort(key=lambda item: item.pop("_sort"), reverse=True)
    return versions


def build_source(repo: str, releases: list[dict]) -> dict:
    versions = build_versions(releases)

    if not versions:
        sys.exit("No releases with an iOS .ipa asset were found; nothing to generate.")

    latest = versions[0]

    app = {
        "name": APP["name"],
        "bundleIdentifier": APP["bundleIdentifier"],
        "developerName": APP["developerName"],
        "subtitle": APP["subtitle"],
        "localizedDescription": APP["localizedDescription"],
        "iconURL": APP["iconURL"],
        "tintColor": APP["tintColor"],
        "category": APP["category"],
        "screenshots": APP["screenshots"],
        "screenshotURLs": APP["screenshots"],
        "versions": versions,
        "version": latest["version"],
        "versionDate": latest["date"],
        "versionDescription": latest["localizedDescription"],
        "downloadURL": latest["downloadURL"],
        "size": latest["size"],
        "minOSVersion": APP["minOSVersion"],
        "appPermissions": APP["appPermissions"],
    }

    return {
        "name": SOURCE["name"],
        "identifier": SOURCE["identifier"],
        "subtitle": SOURCE["subtitle"],
        "description": SOURCE["description"],
        "iconURL": APP["iconURL"],
        "website": SOURCE["website"],
        "tintColor": SOURCE["tintColor"],
        "featuredApps": [APP["bundleIdentifier"]],
        "apps": [app],
        "news": [],
    }


def main() -> None:
    out_path = sys.argv[1] if len(sys.argv) > 1 else "docs/source.json"

    repo = detect_repo()
    releases = fetch_releases(repo)
    source = build_source(repo, releases)

    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(out_path, "w", encoding="utf-8") as file:
        json.dump(source, file, indent=2, ensure_ascii=False)
        file.write("\n")

    print(
        f"Wrote {out_path}: "
        f"{len(source['apps'][0]['versions'])} version(s), "
        f"latest {source['apps'][0]['version']}"
    )


if __name__ == "__main__":
    main()
