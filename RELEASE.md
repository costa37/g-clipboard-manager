# Personal releases (no automatic updater)

Run `bash scripts/build.sh`, `.build/release/GClip --self-test`, then `bash scripts/package.sh` on an Apple Silicon Mac with Xcode Command Line Tools. The app is ad-hoc signed, not notarized.

Create a GitHub release with a matching version tag. Upload the app ZIP and SHA256 checksum from dist; GitHub's generated source archives are not installable apps. Include release notes and the macOS 13+/Apple Silicon requirement. Test extraction and installation before sharing.

For future releases, increment CFBundleShortVersionString and CFBundleVersion in scripts/build.sh and update the README/changelog. Keep the bundle identifier stable. Never publish Signing/, private keys, credentials, clipboard history, .build/, or local development logs.

Sparkle integration, signed update archives and an appcast on GitHub Pages are deferred. No updater or Pages feed is configured in this release.
