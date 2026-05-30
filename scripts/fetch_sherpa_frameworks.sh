#!/bin/bash
# Fetches the sherpa-onnx macOS xcframework (and bundled onnxruntime.xcframework)
# into ./Frameworks/. Idempotent: skips work when the framework already exists,
# unless SHERPA_ONNX_FORCE_REFETCH=1.
#
# Override the version by exporting SHERPA_ONNX_VERSION before invoking.
# Asset name is resolved at runtime by querying the GitHub release manifest.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORKS_DIR="${REPO_ROOT}/Frameworks"
SHERPA_ONNX_VERSION="${SHERPA_ONNX_VERSION:-latest}"
FORCE_REFETCH="${SHERPA_ONNX_FORCE_REFETCH:-0}"

SHERPA_XCFW="${FRAMEWORKS_DIR}/sherpa-onnx.xcframework"
WRAPPER_DIR="${FRAMEWORKS_DIR}/swift-wrapper"
WRAPPER_SWIFT="${WRAPPER_DIR}/SherpaOnnx.swift"
WRAPPER_HEADER="${WRAPPER_DIR}/SherpaOnnx-Bridging-Header.h"

mkdir -p "$FRAMEWORKS_DIR" "$WRAPPER_DIR"

# Generate the bridging header — cheap, idempotent, no network.
cat > "$WRAPPER_HEADER" <<'EOF'
#ifndef SherpaOnnx_Bridging_Header_h
#define SherpaOnnx_Bridging_Header_h

#include "sherpa-onnx/c-api/c-api.h"

#endif
EOF

NEED_XCFW=1
NEED_WRAPPER=1
if [[ "$FORCE_REFETCH" != "1" && -d "$SHERPA_XCFW" ]]; then NEED_XCFW=0; fi
if [[ "$FORCE_REFETCH" != "1" && -f "$WRAPPER_SWIFT" ]]; then NEED_WRAPPER=0; fi

if [[ "$NEED_XCFW" -eq 0 && "$NEED_WRAPPER" -eq 0 ]]; then
    echo "✅ sherpa-onnx artifacts already present:"
    echo "   $SHERPA_XCFW"
    echo "   $WRAPPER_SWIFT"
    echo "   $WRAPPER_HEADER"
    exit 0
fi

# Resolve the asset URL from the GitHub release manifest. We accept any asset whose
# name matches both "macos" and "xcframework" so the script survives minor naming
# changes between sherpa-onnx releases. We always hit the manifest because we
# may need the tag name even when the xcframework itself is already cached.
if [[ "$SHERPA_ONNX_VERSION" == "latest" ]]; then
    RELEASE_URL="https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/latest"
else
    RELEASE_URL="https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/${SHERPA_ONNX_VERSION}"
fi

echo "🔎 Resolving sherpa-onnx macOS xcframework asset from $RELEASE_URL"

# Use Python (always present on macOS) to parse the JSON. We download to a temp
# file first to avoid EPIPE on large release manifests.
TMPDIR_REAL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_REAL"' EXIT

MANIFEST="${TMPDIR_REAL}/release.json"
curl -fsSL "$RELEASE_URL" \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    -o "$MANIFEST"

ASSET_URL=$(
    /usr/bin/python3 - "$MANIFEST" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)
candidates = []
for asset in data.get("assets", []):
    name = asset.get("name", "")
    lower = name.lower()
    if "macos" in lower and "xcframework" in lower and lower.endswith((".tar.bz2", ".tar.gz", ".tgz", ".zip")):
        candidates.append((name, asset.get("browser_download_url")))

# Static bundles include ONNX Runtime so there is exactly one xcframework to embed.
# Prefer "static" then "shared" if multiple variants ever ship.
def score(name):
    n = name.lower()
    s = 0
    if "static" in n: s += 3
    if "universal" in n: s += 2
    if "shared" in n: s += 1
    return s

candidates.sort(key=lambda c: score(c[0]), reverse=True)
if not candidates:
    sys.exit("no matching macOS xcframework asset found in release")

print(candidates[0][1])
PY
)

TAG_TO_FETCH=$(/usr/bin/python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('tag_name',''))" "$MANIFEST")

if [[ "$NEED_XCFW" -eq 1 ]]; then
    if [[ -z "$ASSET_URL" ]]; then
        echo "❌ Could not find a macOS xcframework asset in the sherpa-onnx release."
        echo "   Visit https://github.com/k2-fsa/sherpa-onnx/releases and set SHERPA_ONNX_VERSION."
        exit 1
    fi

    ARCHIVE="${TMPDIR_REAL}/$(basename "$ASSET_URL")"
    echo "⬇️  Downloading $ASSET_URL"
    curl -fL --progress-bar -o "$ARCHIVE" "$ASSET_URL"

    echo "📦 Extracting $(basename "$ARCHIVE")"
    case "$ARCHIVE" in
        *.tar.bz2) tar -xjf "$ARCHIVE" -C "$TMPDIR_REAL" ;;
        *.tar.gz|*.tgz) tar -xzf "$ARCHIVE" -C "$TMPDIR_REAL" ;;
        *.zip) unzip -q "$ARCHIVE" -d "$TMPDIR_REAL" ;;
        *) echo "❌ Unsupported archive type: $ARCHIVE"; exit 1 ;;
    esac

    # The "static" xcframework bundles ONNX Runtime, so only one xcframework is expected.
    SHERPA_SRC=$(find "$TMPDIR_REAL" -maxdepth 6 -type d -name "sherpa-onnx.xcframework" | head -n 1)

    if [[ -z "$SHERPA_SRC" ]]; then
        echo "❌ Extracted archive did not contain sherpa-onnx.xcframework."
        echo "   Inspect $TMPDIR_REAL"
        trap - EXIT
        exit 1
    fi

    rm -rf "$SHERPA_XCFW"
    mv "$SHERPA_SRC" "$SHERPA_XCFW"
fi

if [[ "$NEED_WRAPPER" -eq 1 && -n "$TAG_TO_FETCH" ]]; then
    echo "⬇️  Fetching SherpaOnnx.swift for tag $TAG_TO_FETCH"
    curl -fsSL "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/${TAG_TO_FETCH}/swift-api-examples/SherpaOnnx.swift" \
        -o "$WRAPPER_SWIFT"
fi

echo "✅ Installed:"
echo "   $SHERPA_XCFW"
echo "   $WRAPPER_SWIFT"
echo "   $WRAPPER_HEADER"
