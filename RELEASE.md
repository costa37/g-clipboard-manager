# Releases

## Automatic publishing

To publish a new app version:

1. Update the code.
2. Increase `version` and `build` in `version.json` (for example, `0.3.16` and `36`).
3. Add a matching version section to `CHANGELOG.md` and update the version/download filename in `README.md`.
4. Commit and push to `main`.

GitHub Actions detects an increased version, builds on Apple Silicon, runs the debug self-tests with assertions enabled, builds the release app, packages it, and verifies the extracted app signature and checksum. It then creates the matching version tag and publishes the ZIP and SHA256 checksum as the latest GitHub Release. No personal token or signing secret is needed; the workflow uses GitHub's temporary repository token.

A push without a version change does not publish a release. Both version and build must increase for a release. Failed checks prevent publishing. Inspect the Actions tab and use **Re-run failed jobs** after a temporary failure; published releases are left unchanged and unfinished drafts can be completed by rerunning the same job. For a code fix after failure, bump the version again to trigger another release.

## Local build and packaging

Run `CONFIGURATION=debug bash scripts/build.sh`, `.build/debug/GClip --self-test`, `bash scripts/build.sh`, then `bash scripts/package.sh` on an Apple Silicon Mac with Xcode Command Line Tools. Use the debug binary for tests because release builds disable Swift assertions.

The app is ad-hoc signed, not notarized. GitHub's generated source archives are not installable apps; download the app ZIP instead. Test installation before sharing. Updates remain manual: users download a release and replace the app in Applications.

Keep the bundle identifier stable. Never publish Signing/, private keys, credentials, clipboard history, .build/, or local development logs. Sparkle integration and an appcast are not configured.
