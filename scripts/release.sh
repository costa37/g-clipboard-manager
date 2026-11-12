#!/bin/bash
# Build and sign locally; only finished, signed artifacts leave this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
unset GH_TOKEN GITHUB_TOKEN
export GH_CONFIG_DIR="$HOME/.config/gh-costa37"
REPO=costa37/g-clipboard-manager
[ "$(gh api user --jq .login)" = costa37 ] || { echo 'Sign in using the dedicated costa37 profile.' >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo 'Commit all source changes before releasing.' >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(gh api "repos/$REPO/commits/main" --jq .sha)" ] || { echo 'Push this commit to main before releasing.' >&2; exit 1; }
VERSION=$(python3 -c 'import json; print(json.load(open("version.json"))["version"])')
TAG="v$VERSION"
if gh release view "$TAG" --repo "$REPO" --json isDraft --jq .isDraft > /dev/null 2>&1; then
    echo "Release $TAG already exists; inspect it before retrying." >&2
    exit 1
fi
python3 scripts/test-release-metadata.py
python3 scripts/test-appcast.py
CONFIGURATION=debug bash scripts/build.sh
dist/G-Clip.app/Contents/MacOS/GClip --self-test
bash scripts/build.sh
bash scripts/package.sh
(cd dist && shasum -a 256 -c "G-Clip-$VERSION-arm64.zip.sha256")
python3 - <<'PY'
import json, pathlib, re
version = json.loads(pathlib.Path('version.json').read_text())['version']
match = re.search(r'^## ' + re.escape(version) + r'(?: —[^\n]*)?\n(.*?)(?=^## |\Z)', pathlib.Path('CHANGELOG.md').read_text(), re.M | re.S)
if not match or not match[1].strip():
    raise ValueError('Missing release notes')
notes = match[1].strip() + '\n\n## Installation\n\nRequires Apple Silicon and macOS 13+. Users on 0.3.15 or earlier must download the app ZIP, quit G-Clip, unzip and replace the app in Applications once to get the updater. This build is ad-hoc signed and not notarized; macOS may require Open Anyway and renewed Accessibility permission. Future updates are available through the menu bar.\n\nLocal builds, automated app tests, and update signature checks passed. Live update/relaunch and permission recovery on a second Mac still require validation.\n'
pathlib.Path('dist/release-notes.txt').write_text(notes)
PY
gh release create "$TAG" --repo "$REPO" --target "$(git rev-parse HEAD)" --title "G-Clip $VERSION" --notes-file dist/release-notes.txt --draft
gh release upload "$TAG" --repo "$REPO" "dist/G-Clip-$VERSION-arm64.zip" "dist/G-Clip-$VERSION-arm64.zip.sha256" dist/appcast.xml
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
gh release view "$TAG" --repo "$REPO" --json url --jq .url
