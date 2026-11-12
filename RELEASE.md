# Releases

## One-time signing setup

G-Clip uses Sparkle without an Apple Developer account. The app remains ad-hoc signed and not notarized; Ed25519 signatures authenticate update archives but do not preserve macOS Accessibility grants.

The project's public key is committed in `updates/public-key.txt`. Its matching private key is stored in the release Mac's login Keychain under Sparkle account `local.gclip.manager`. Do not generate a new key for each release or replace the public key after distributing updater-enabled builds. Keep a secure backup of the private key; without Apple signing, losing this key can require users to reinstall manually.

The private key stays on this Mac. No GitHub Actions signing secret is required or configured. For a secure backup, export it to a protected file with Sparkle’s `generate_keys --account local.gclip.manager -x PATH` and store it in a password manager. Never commit the export or attach it to a release. Another release Mac can import that same key with `generate_keys --account local.gclip.manager -f PATH`.

## Keep personal and work GitHub accounts separate

Use a dedicated CLI profile for this repository; leave the default work profile unchanged:

```sh
env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$HOME/.config/gh-costa37" gh auth login --hostname github.com --git-protocol https --web
```

Answer **No** to “Authenticate Git with your GitHub credentials?” so login does not modify global Git credentials. Authorize **costa37** in the browser. Prefix subsequent G-Clip GitHub CLI commands with the same environment settings; verify `gh api user --jq .login` returns `costa37` before changing secrets or publishing. This profile does not change the account connected to Codex or other projects. Git pushes need repository-scoped credentials separately; do not use global `gh auth setup-git` or switch the default work account.

## Publish from this Mac

1. Update code, increase both `version` and `build` in `version.json`, add matching `CHANGELOG.md` notes, and update the README version/download filename.
2. Commit and push to `main`, using GitHub Desktop as costa37 or repository-scoped credentials. GitHub Actions validates and builds the source but does not publish or receive the signing key.
3. Run `bash scripts/release.sh` on this Mac. It checks the account and pushed commit, runs the tests, builds and signs locally, verifies the signature, uploads the ZIP/checksum/appcast to a draft, and then publishes it as latest.

The feed URL is `https://github.com/costa37/g-clipboard-manager/releases/latest/download/appcast.xml`. No GitHub Pages or separate server is needed. Every future latest release must include its appcast. The single-item feed supports Apple Silicon/macOS 13+; revisit feed history before raising the minimum OS version.

The script refuses to overwrite an existing release. If an upload fails, inspect the draft, upload any missing artifacts from the same verified build, then publish it. Never modify an already published archive in place.

## Local build and packaging

```sh
CONFIGURATION=debug bash scripts/build.sh
dist/G-Clip.app/Contents/MacOS/GClip --self-test
python3 scripts/test-release-metadata.py
python3 scripts/test-appcast.py
bash scripts/build.sh
bash scripts/package.sh
```

Run the tests from the debug app bundle, which contains Sparkle. Release builds disable Swift assertions. Packaging reads the signing key from the Keychain, or from `SPARKLE_PRIVATE_KEY` when explicitly supplied, and produces the ZIP, checksum and feed in `dist/`. It rejects a key that does not match the public key embedded in the app.

## Verify before distributing

- Install the first updater-enabled version manually in Applications. Existing 0.3.15 and older installations cannot discover updates themselves.
- Test on a separate Mac or macOS test account using two increasing builds and a staging HTTPS feed. Confirm Check for Updates, declining/accepting automatic checks, Install and Relaunch, and preserved clipboard history/settings.
- Confirm Accessibility controls disappear when granted and reappear when revoked. An ad-hoc update may require removing and re-adding G-Clip in Accessibility. Never change the user's permissions automatically.
- Confirm a modified ZIP is rejected. Keep the bundle identifier stable. Check that app launches and nested framework signatures verify after extraction.

A successful local build and signature check do not prove the full macOS install/relaunch/permission path. Complete that live test before distributing broadly. Preview mode and self-tests do not start the updater. Ordinary launches ask about automatic checks using Sparkle's standard consent flow; automatic installation and system profiling are disabled.
