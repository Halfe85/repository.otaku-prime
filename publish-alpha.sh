#!/usr/bin/env bash
set -Eeuo pipefail

# Otaku Prime development publisher
#
# Publishes:
#   Halfe85/Otaku-Prime:Otaku-Prime
#        ->
#   Halfe85/repository.otaku-prime:main
#        ->
#   Kodi development repository
#
# Version behavior:
#   0.1.0 + existing alpha7  -> 0.1.0~alpha8
#   0.1.1 + no existing alpha -> 0.1.1~alpha1

SOURCE_REPO="${SOURCE_REPO:-https://github.com/Halfe85/Otaku-Prime.git}"
DIST_REPO="${DIST_REPO:-https://github.com/Halfe85/repository.otaku-prime.git}"

SOURCE_BRANCH="Otaku-Prime"
DIST_BRANCH="main"
ADDON_ID="plugin.video.otaku.prime"
ADDON_REL="plugin.video.otaku.prime/addon.xml"

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
echo " Otaku Prime - publish development alpha"
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
[[ -f "$ADDON_XML" ]] || die "Source addon.xml not found: $ADDON_REL"
[[ -f "$DIST_DIR/tools/build_repository.py" ]] || die "Distribution build tool not found: tools/build_repository.py"

ZIP_DIR="$DIST_DIR/repo/development/zips/$ADDON_ID"
mkdir -p "$ZIP_DIR"

# Find the highest alpha already published for exactly this base version.
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
    echo "Found latest ${BASE_VERSION} build: alpha${MAX_ALPHA}"
else
    echo "No existing alpha build found for ${BASE_VERSION}"
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

# If a new base version was selected, update addon.xml in the source branch.
# This keeps Git provenance consistent with the version being packaged.
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

# build_repository.py normally suppresses another publication from an unchanged
# source SHA. For an explicitly requested manual alpha build we intentionally
# permit a new immutable alpha package from the current source.
rm -f "$DIST_DIR/.state/development.sha"

echo "Building $FULL_VERSION..."

# The repository installer itself is versioned separately and immutable.
# build_repository.py always tries to regenerate repository.otaku-prime.dev-1.0.0.zip,
# which can legitimately differ from the already-published installer bytes.
# Preserve the published installer while building a new addon alpha.
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

# Do not silently replace the already-published repository installer.
if (( HAD_REPO_INSTALLER == 1 )); then
    rm -f "$REPO_INSTALLER"
    mv "$REPO_INSTALLER_BACKUP" "$REPO_INSTALLER"
fi

EXPECTED_ZIP="$ZIP_DIR/${ADDON_ID}-${FULL_VERSION}.zip"
[[ -f "$EXPECTED_ZIP" ]] || die "Expected package was not generated: $EXPECTED_ZIP"

git -C "$DIST_DIR" add -A

if git -C "$DIST_DIR" diff --cached --quiet; then
    die "Build completed but produced no repository changes"
fi

git -C "$DIST_DIR" \
    -c user.name="Halfe85" \
    -c user.email="halfe85@users.noreply.github.com" \
    commit --quiet -m "Publish Otaku Prime $FULL_VERSION"

# Make sure neither remote moved while the build was being prepared.
echo "Checking remote branches before publishing..."

git -C "$SOURCE_DIR" fetch --quiet origin "$SOURCE_BRANCH"
SOURCE_REMOTE_SHA="$(git -C "$SOURCE_DIR" rev-parse "origin/$SOURCE_BRANCH")"

if (( SOURCE_VERSION_CHANGED == 1 )); then
    if [[ "$SOURCE_REMOTE_SHA" != "$SOURCE_START_SHA" ]]; then
        die "Otaku-Prime/$SOURCE_BRANCH changed while building. Nothing was pushed. Run the script again."
    fi
fi

git -C "$DIST_DIR" fetch --quiet origin "$DIST_BRANCH"
DIST_REMOTE_SHA="$(git -C "$DIST_DIR" rev-parse "origin/$DIST_BRANCH")"

if [[ "$DIST_REMOTE_SHA" != "$DIST_START_SHA" ]]; then
    die "repository.otaku-prime/$DIST_BRANCH changed while building. Nothing was pushed. Run the script again."
fi

echo
echo "Publishing..."

# Push source first only when the base version changed.
if (( SOURCE_VERSION_CHANGED == 1 )); then
    git -C "$SOURCE_DIR" push origin "HEAD:$SOURCE_BRANCH"
fi

git -C "$DIST_DIR" push origin "HEAD:$DIST_BRANCH"

echo
echo "=============================================="
echo " Published successfully"
echo "=============================================="
echo "Version:     $FULL_VERSION"
echo "Source SHA:  $SOURCE_SHA"
echo "Kodi repo:   development"
echo
echo "Package:"
echo "repo/development/zips/$ADDON_ID/${ADDON_ID}-${FULL_VERSION}.zip"
echo
echo "Kodi development repository installer:"
echo "https://raw.githubusercontent.com/Halfe85/repository.otaku-prime/main/repository.otaku-prime.dev-1.0.0.zip"
echo
