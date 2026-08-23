#!/usr/bin/env python3
"""Build deterministic Kodi repository packages for Otaku Prime.

The distribution repository has two channels:
  stable       <- Halfe85/Otaku-Prime:main
  development  <- Halfe85/Otaku-Prime:Otaku-Prime

Published ZIPs are immutable. If the same addon version already exists with
other bytes, the build fails rather than silently replacing it.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PRIME_ADDON_ID = "plugin.video.otaku.prime"
REPOSITORY_IDS = {
    "stable": "repository.otaku-prime",
    "development": "repository.otaku-prime.dev",
}


def md5_bytes(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def deterministic_zip(source_dir: Path, output: Path) -> None:
    """Create a reproducible ZIP with source_dir as the top-level folder."""
    output.parent.mkdir(parents=True, exist_ok=True)
    tmp = output.with_suffix(output.suffix + ".tmp")
    if tmp.exists():
        tmp.unlink()

    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in sorted(source_dir.rglob("*")):
            if path.is_dir():
                continue
            rel = Path(source_dir.name) / path.relative_to(source_dir)
            info = zipfile.ZipInfo(rel.as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            zf.writestr(info, path.read_bytes())

    if output.exists():
        if sha256_file(output) == sha256_file(tmp):
            tmp.unlink()
            return
        raise RuntimeError(f"Refusing to overwrite immutable package: {output}")
    tmp.replace(output)


def write_if_changed(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_bytes() == data:
        return
    path.write_bytes(data)


def build_repository_installer(channel: str) -> None:
    repo_id = REPOSITORY_IDS[channel]
    source = ROOT / repo_id
    if not (source / "addon.xml").exists():
        raise RuntimeError(f"Missing repository addon: {source / 'addon.xml'}")
    deterministic_zip(source, ROOT / f"{repo_id}-1.0.0.zip")


def ensure_feed_exists(channel: str) -> None:
    zips = ROOT / "repo" / channel / "zips"
    xml_path = zips / "addons.xml"
    md5_path = zips / "addons.xml.md5"
    if not xml_path.exists():
        data = b'<?xml version="1.0" encoding="UTF-8"?>\n<addons />\n'
        write_if_changed(xml_path, data)
        write_if_changed(md5_path, (md5_bytes(data) + "\n").encode())


def parse_addon(addon_xml: Path) -> ET.Element:
    return ET.parse(addon_xml).getroot()


def discover_addons(source_root: Path) -> list[Path]:
    addons: list[Path] = []
    for child in sorted(source_root.iterdir()):
        if child.is_dir() and (child / "addon.xml").exists():
            addons.append(child)
    return addons


def make_build_version(base_version: str, channel: str, build_number: int) -> str:
    if channel == "stable":
        if "~" in base_version:
            raise RuntimeError(f"Stable source version cannot be prerelease: {base_version}")
        return base_version
    clean = base_version.split("~", 1)[0]
    return f"{clean}~beta{build_number}"


def stage_addon(source_dir: Path, channel: str, build_number: int, staging_root: Path) -> tuple[str, str, Path, ET.Element]:
    addon = parse_addon(source_dir / "addon.xml")
    addon_id = addon.attrib["id"]
    source_version = addon.attrib["version"]

    target = staging_root / addon_id
    shutil.copytree(source_dir, target)

    staged_xml = target / "addon.xml"
    staged_root = parse_addon(staged_xml)
    version = source_version
    if addon_id == PRIME_ADDON_ID:
        version = make_build_version(source_version, channel, build_number)
        staged_root.set("version", version)
        ET.ElementTree(staged_root).write(staged_xml, encoding="UTF-8", xml_declaration=True)
        staged_root = parse_addon(staged_xml)

    return addon_id, version, target, staged_root


def publish_source(channel: str, source_root: Path, source_ref: str, source_sha: str, build_number: int) -> bool:
    state_dir = ROOT / ".state"
    state_dir.mkdir(exist_ok=True)
    state_path = state_dir / f"{channel}.sha"

    if state_path.exists() and state_path.read_text().strip() == source_sha:
        print(f"{channel}: source SHA unchanged; nothing to publish")
        return False

    addon_dirs = discover_addons(source_root)
    prime_dirs = [p for p in addon_dirs if parse_addon(p / "addon.xml").attrib.get("id") == PRIME_ADDON_ID]
    if not prime_dirs:
        print(
            f"{channel}: {PRIME_ADDON_ID} is not present in source yet; "
            "repository bootstrap remains valid but no Prime addon build is published."
        )
        return False

    staging_root = ROOT / ".build" / channel
    if staging_root.exists():
        shutil.rmtree(staging_root)
    staging_root.mkdir(parents=True)

    metadata_roots: list[ET.Element] = []
    published: list[dict[str, str]] = []
    channel_zips = ROOT / "repo" / channel / "zips"

    for source_dir in addon_dirs:
        addon_id, version, staged_dir, addon_root = stage_addon(
            source_dir, channel, build_number, staging_root
        )

        # Only publish the Prime addon and dependencies shipped in the source tree.
        # The root folder name of every ZIP is the addon id Kodi expects.
        addon_output = channel_zips / addon_id
        addon_output.mkdir(parents=True, exist_ok=True)
        package = addon_output / f"{addon_id}-{version}.zip"
        deterministic_zip(staged_dir, package)

        for asset in ("icon.png", "fanart.jpg"):
            src = staged_dir / asset
            if src.exists():
                shutil.copy2(src, addon_output / asset)

        metadata_roots.append(copy.deepcopy(addon_root))
        published.append({
            "id": addon_id,
            "version": version,
            "zip": str(package.relative_to(ROOT)),
            "sha256": sha256_file(package),
        })

    addons_root = ET.Element("addons")
    for addon_root in metadata_roots:
        addons_root.append(addon_root)
    xml_data = ET.tostring(addons_root, encoding="UTF-8", xml_declaration=True) + b"\n"
    write_if_changed(channel_zips / "addons.xml", xml_data)
    write_if_changed(
        channel_zips / "addons.xml.md5",
        (md5_bytes(xml_data) + "\n").encode(),
    )

    build_meta = {
        "channel": channel,
        "source_repository": "Halfe85/Otaku-Prime",
        "source_ref": source_ref,
        "source_sha": source_sha,
        "github_run_number": build_number,
        "published": published,
    }
    write_if_changed(
        ROOT / "repo" / channel / "build.json",
        (json.dumps(build_meta, indent=2, sort_keys=True) + "\n").encode(),
    )
    state_path.write_text(source_sha + "\n")
    shutil.rmtree(staging_root, ignore_errors=True)
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel", choices=("stable", "development"), required=True)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--source-ref", default="")
    parser.add_argument("--source-sha", default="")
    parser.add_argument("--build-number", type=int, default=0)
    args = parser.parse_args()

    build_repository_installer(args.channel)
    ensure_feed_exists(args.channel)

    if args.source_root:
        if not args.source_sha:
            raise RuntimeError("--source-sha is required when --source-root is used")
        publish_source(
            args.channel,
            args.source_root.resolve(),
            args.source_ref,
            args.source_sha,
            args.build_number,
        )

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
