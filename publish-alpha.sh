#!/usr/bin/env bash
set -Eeuo pipefail

# Otaku Prime development publisher
#
# Usage:
#   ./publish-alpha.sh              Publish Otaku Prime development alpha
#   ./publish-alpha.sh --Jellyui    Publish Jellyfin UI development alpha
#
# Version behavior:
#   0.1.0 + existing alpha7   -> 0.1.0~alpha8
#   0.1.1 + no existing alpha -> 0.1.1~alpha1

MODE="otaku"
case "${1:-}" in
    "")
        ;;
    --Jellyui|--jellyui)
        MODE="jellyui"
        shift
        ;;
    -h|--help)
        echo "Usage: $0 [--Jellyui]"
        echo
        echo "Without arguments: publish an Otaku Prime development alpha."
        echo "--Jellyui:         publish a Jellyfin UI development alpha."
        exit 0
        ;;
    *)
        echo "ERROR: Unknown option: $1" >&2
        echo "Usage: $0 [--Jellyui]" >&2
        exit 2
        ;;
esac

if (( $# > 0 )); then
    echo "ERROR: Unexpected argument: $1" >&2
    echo "Usage: $0 [--Jellyui]" >&2
    exit 2
fi

DIST_REPO="${DIST_REPO:-https://github.com/Halfe85/repository.otaku-prime.git}"
DIST_BRANCH="main"

if [[ "$MODE" == "jellyui" ]]; then
    SOURCE_REPO="${JELLY_UI_REPO:-https://github.com/Halfe85/kodi-jellyfin.UI.git}"
    SOURCE_BRANCH="${JELLY_UI_BRANCH:-main}"
    ADDON_ID="skin.jellyfin.ui"
    ADDON_DIR_REL="skin.jellyfin.ui"
    ADDON_REL="$ADDON_DIR_REL/addon.xml"
    PRODUCT_NAME="Jellyfin UI"
    SOURCE_NAME="kodi-jellyfin.UI"
else
    SOURCE_REPO="${SOURCE_REPO:-https://github.com/Halfe85/Otaku-Prime.git}"
    SOURCE_BRANCH="Otaku-Prime"
    ADDON_ID="plugin.video.otaku.prime"
    ADDON_DIR_REL="plugin.video.otaku.prime"
    ADDON_REL="$ADDON_DIR_REL/addon.xml"
    PRODUCT_NAME="Otaku Prime"
    SOURCE_NAME="Otaku-Prime"
fi

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

need git
need python3

echo "=============================================="
echo " $PRODUCT_NAME - publish development alpha"
echo "=============================================="
echo

read -r -p "Base version (example 0.1.0 or 0.1.1): " BASE_VERSION

if [[ ! "$BASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Version must use MAJOR.MINOR.PATCH, for example 0.1.0"
fi

WORKDIR="$(mktemp -d -t otaku-prime-alpha.XXXXXXXX)"
SOURCE_DIR="$WORKDIR/source"
DIST_DIR="$WORKDIR/distribution"

cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo
echo "Fetching current repositories..."

git clone --quiet --depth 1 --branch "$SOURCE_BRANCH" "$SOURCE_REPO" "$SOURCE_DIR"
git clone --quiet --branch "$DIST_BRANCH" "$DIST_REPO" "$DIST_DIR"

SOURCE_START_SHA="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
DIST_START_SHA="$(git -C "$DIST_DIR" rev-parse HEAD)"

ADDON_XML="$SOURCE_DIR/$ADDON_REL"
[[ -f "$ADDON_XML" ]] || die "Source addon.xml not found: $ADDON_REL in $SOURCE_NAME/$SOURCE_BRANCH"

if [[ "$MODE" == "otaku" ]]; then
    [[ -f "$DIST_DIR/tools/build_repository.py" ]] || die "Distribution build tool not found: tools/build_repository.py"
fi

ZIP_DIR="$DIST_DIR/repo/development/zips/$ADDON_ID"
mkdir -p "$ZIP_DIR"

# Find the highest alpha already published for exactly this addon/base version.
MAX_ALPHA=0
shopt -s nullglob
for package in "$ZIP_DIR/${ADDON_ID}-${BASE_VERSION}~alpha"*.zip; do
    filename="${package##*/}"
    number="${filename#${ADDON_ID}-${BASE_VERSION}~alpha}"
    number="${number%.zip}"

    if [[ "$number" =~ ^[0-9]+$ ]] && (( number > MAX_ALPHA )); then
        MAX_ALPHA="$number"
    fi
done
shopt -u nullglob

NEXT_ALPHA=$((MAX_ALPHA + 1))
FULL_VERSION="${BASE_VERSION}~alpha${NEXT_ALPHA}"

echo
if (( MAX_ALPHA > 0 )); then
    echo "Found latest $PRODUCT_NAME ${BASE_VERSION} build: alpha${MAX_ALPHA}"
else
    echo "No existing $PRODUCT_NAME alpha build found for ${BASE_VERSION}"
fi
echo "Next build: $FULL_VERSION"
echo

# Read the source addon's current base version.
CURRENT_BASE_VERSION="$(
python3 - "$ADDON_XML" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
root = ET.parse(path).getroot()
print(root.attrib["version"].split("~", 1)[0])
PY
)"

SOURCE_VERSION_CHANGED=0

# Keep source addon.xml on the requested base version. Alpha suffixes only exist
# in immutable repository packages.
if [[ "$CURRENT_BASE_VERSION" != "$BASE_VERSION" ]]; then
    echo "Updating source addon.xml:"
    echo "  $CURRENT_BASE_VERSION -> $BASE_VERSION"

    python3 - "$ADDON_XML" "$BASE_VERSION" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
version = sys.argv[2]
text = path.read_text(encoding="utf-8")

pattern = r'(<addon\b[^>]*\bversion=")[^"]+(")'
updated, count = re.subn(pattern, rf'\g<1>{version}\2', text, count=1)

if count != 1:
    raise SystemExit("Could not update the addon version attribute")

path.write_text(updated, encoding="utf-8")
PY

    git -C "$SOURCE_DIR" add "$ADDON_REL"
    git -C "$SOURCE_DIR" \
        -c user.name="Halfe85" \
        -c user.email="halfe85@users.noreply.github.com" \
        commit --quiet -m "Set development base version to $BASE_VERSION"

    SOURCE_VERSION_CHANGED=1
fi

SOURCE_SHA="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
EXPECTED_ZIP="$ZIP_DIR/${ADDON_ID}-${FULL_VERSION}.zip"

echo "Building $PRODUCT_NAME $FULL_VERSION..."

if [[ "$MODE" == "jellyui" ]]; then
    STAGING_ROOT="$WORKDIR/staging"
    STAGED_ADDON="$STAGING_ROOT/$ADDON_ID"
    mkdir -p "$STAGING_ROOT"
    cp -a "$SOURCE_DIR/$ADDON_DIR_REL" "$STAGED_ADDON"

    # The source keeps the clean base version. The repository ZIP receives the
    # immutable ~alphaN version used by Kodi's update system.
    python3 - "$STAGED_ADDON/addon.xml" "$FULL_VERSION" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
version = sys.argv[2]
tree = ET.parse(path)
root = tree.getroot()
root.set("version", version)
tree.write(path, encoding="UTF-8", xml_declaration=True)
PY

    # Build a deterministic Kodi ZIP with skin.jellyfin.ui as the top folder.
    python3 - "$STAGED_ADDON" "$EXPECTED_ZIP" <<'PY'
import hashlib
import sys
from pathlib import Path
import zipfile

source_dir = Path(sys.argv[1])
output = Path(sys.argv[2])
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

def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

if output.exists():
    if digest(output) == digest(tmp):
        tmp.unlink()
    else:
        tmp.unlink()
        raise SystemExit(f"Refusing to overwrite immutable package: {output}")
else:
    tmp.replace(output)
PY

    # Repository artwork sits beside the ZIP when the skin supplies it.
    for asset in icon.png fanart.jpg; do
        if [[ -f "$STAGED_ADDON/$asset" ]]; then
            cp -p "$STAGED_ADDON/$asset" "$ZIP_DIR/$asset"
        fi
    done

    FEED_XML="$DIST_DIR/repo/development/zips/addons.xml"
    FEED_MD5="$DIST_DIR/repo/development/zips/addons.xml.md5"

    # Merge/replace only the Jellyfin UI entry. Existing Otaku Prime and other
    # add-ons in the repository feed remain untouched.
    python3 - "$FEED_XML" "$STAGED_ADDON/addon.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

feed_path = Path(sys.argv[1])
addon_path = Path(sys.argv[2])
addon = ET.parse(addon_path).getroot()
addon_id = addon.attrib["id"]

if feed_path.exists():
    feed = ET.parse(feed_path).getroot()
else:
    feed = ET.Element("addons")

for child in list(feed):
    if child.attrib.get("id") == addon_id:
        feed.remove(child)

feed.append(addon)
feed[:] = sorted(feed, key=lambda item: item.attrib.get("id", ""))
data = ET.tostring(feed, encoding="UTF-8", xml_declaration=True) + b"\n"
feed_path.parent.mkdir(parents=True, exist_ok=True)
feed_path.write_bytes(data)
PY

    python3 - "$FEED_XML" "$FEED_MD5" <<'PY'
import hashlib
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
target.write_text(hashlib.md5(source.read_bytes()).hexdigest() + "\n", encoding="ascii")
PY

    python3 - "$DIST_DIR/repo/development/build-jellyui.json" \
        "$SOURCE_BRANCH" "$SOURCE_SHA" "$NEXT_ALPHA" "$ADDON_ID" "$FULL_VERSION" "$EXPECTED_ZIP" "$DIST_DIR" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

out = Path(sys.argv[1])
source_ref = sys.argv[2]
source_sha = sys.argv[3]
build_number = int(sys.argv[4])
addon_id = sys.argv[5]
version = sys.argv[6]
package = Path(sys.argv[7])
root = Path(sys.argv[8])

h = hashlib.sha256(package.read_bytes()).hexdigest()
meta = {
    "channel": "development",
    "source_repository": "Halfe85/kodi-jellyfin.UI",
    "source_ref": source_ref,
    "source_sha": source_sha,
    "build_number": build_number,
    "published": {
        "id": addon_id,
        "version": version,
        "zip": str(package.relative_to(root)),
        "sha256": h,
    },
}
out.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
else
    # build_repository.py normally suppresses another publication from an
    # unchanged source SHA. A manual alpha explicitly requests a new immutable
    # package from the current Otaku Prime source.
    rm -f "$DIST_DIR/.state/development.sha"

    # The repository installer is versioned separately and immutable. Preserve
    # its already-published bytes while building a new Otaku Prime alpha.
    REPO_INSTALLER="$DIST_DIR/repository.otaku-prime.dev-1.0.0.zip"
    REPO_INSTALLER_BACKUP="$WORKDIR/repository.otaku-prime.dev-1.0.0.zip.published"
    HAD_REPO_INSTALLER=0

    if [[ -f "$REPO_INSTALLER" ]]; then
        cp -p "$REPO_INSTALLER" "$REPO_INSTALLER_BACKUP"
        rm -f "$REPO_INSTALLER"
        HAD_REPO_INSTALLER=1
    fi

    python3 "$DIST_DIR/tools/build_repository.py" \
        --channel development \
        --source-root "$SOURCE_DIR" \
        --source-ref "$SOURCE_BRANCH" \
        --source-sha "$SOURCE_SHA" \
        --build-number "$NEXT_ALPHA"

    if (( HAD_REPO_INSTALLER == 1 )); then
        rm -f "$REPO_INSTALLER"
        mv "$REPO_INSTALLER_BACKUP" "$REPO_INSTALLER"
    fi
fi

[[ -f "$EXPECTED_ZIP" ]] || die "Expected package was not generated: $EXPECTED_ZIP"

git -C "$DIST_DIR" add -A

if git -C "$DIST_DIR" diff --cached --quiet; then
    die "Build completed but produced no repository changes"
fi

git -C "$DIST_DIR" \
    -c user.name="Halfe85" \
    -c user.email="halfe85@users.noreply.github.com" \
    commit --quiet -m "Publish $PRODUCT_NAME $FULL_VERSION"

# Make sure neither remote moved while the build was being prepared.
echo "Checking remote branches before publishing..."

git -C "$SOURCE_DIR" fetch --quiet origin "$SOURCE_BRANCH"
SOURCE_REMOTE_SHA="$(git -C "$SOURCE_DIR" rev-parse "origin/$SOURCE_BRANCH")"

if (( SOURCE_VERSION_CHANGED == 1 )); then
    if [[ "$SOURCE_REMOTE_SHA" != "$SOURCE_START_SHA" ]]; then
        die "$SOURCE_NAME/$SOURCE_BRANCH changed while building. Nothing was pushed. Run the script again."
    fi
fi

git -C "$DIST_DIR" fetch --quiet origin "$DIST_BRANCH"
DIST_REMOTE_SHA="$(git -C "$DIST_DIR" rev-parse "origin/$DIST_BRANCH")"

if [[ "$DIST_REMOTE_SHA" != "$DIST_START_SHA" ]]; then
    die "repository.otaku-prime/$DIST_BRANCH changed while building. Nothing was pushed. Run the script again."
fi

echo
echo "Publishing..."

# Push source first only when the requested base version changed.
if (( SOURCE_VERSION_CHANGED == 1 )); then
    git -C "$SOURCE_DIR" push origin "HEAD:$SOURCE_BRANCH"
fi

git -C "$DIST_DIR" push origin "HEAD:$DIST_BRANCH"

echo
echo "=============================================="
echo " Published successfully"
echo "=============================================="
echo "Product:     $PRODUCT_NAME"
echo "Version:     $FULL_VERSION"
echo "Source ref:  $SOURCE_BRANCH"
echo "Source SHA:  $SOURCE_SHA"
echo "Kodi repo:   development"
echo
echo "Package:"
echo "repo/development/zips/$ADDON_ID/${ADDON_ID}-${FULL_VERSION}.zip"
echo
echo "Kodi development repository installer:"
echo "https://raw.githubusercontent.com/Halfe85/repository.otaku-prime/main/repository.otaku-prime.dev-1.0.0.zip"
echo
