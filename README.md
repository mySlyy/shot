# Slyy Shot

Personal screenshot tool, macOS 13+ (Apple Silicon + Intel). https://slyy.ai

Menu bar app: ⌘⇧5 area, ⌘⇧4 window, ⌘⇧3 screen (switch off the
macOS "Screenshots" keyboard shortcuts, or map other keys under Options >
Keyboard Shortcuts…). Saves PNGs to
~/Pictures/Slyy Shot and copies them to the clipboard. ⌘⇧F brings open shots to the
front, ⌘⌥⇧O opens all shots of the folder; in the editor ⌘D trashes the shot.

Local test build (Command Line Tools only): `ARCH=host shot/scripts/build.sh <version>`,
optionally with `SIGN_IDENTITY` (keychain identity; else ad-hoc). Releases: CI only.

## Installation

Download
https://github.com/mySlyy/shot/releases/download/slyy-shot-latest/SlyyShot.dmg
(always the newest), open it, drag Slyy Shot to Applications (signed with Developer ID and notarized).
Or from Terminal (no Gatekeeper prompt):

    curl -fsSL https://raw.githubusercontent.com/mySlyy/shot/main/shot-install.sh | sh

Remove: same command with `sh -s -- --uninstall`.

From 1.x (bundle ID `ai.slyy.snap`): no automatic update to 2.x. Run the Terminal command
once; it replaces the old app. Settings carry over, Screen Recording must be allowed again.

## Updates

The app checks for updates itself (menu > Check for Updates…; checksum and
signature verified). Updates and the installer accept only builds by the pinned signer
`shot/Resources/update_signer.req` (copy in `shot-install.sh` SIGNER_REQ; the release
workflow checks both match and refuses ad-hoc releases).

Pinned signers: Developer ID Application team W5FXZ96W6V (releases from 2.4.2, notarized)
or the old self-signed "Slyy Snap Code Signing" root (up to 2.4.1). Drop the old root from
the pin once installs have updated past 2.4.1.

## Releases

Releases are the `slyy-shot-v*` tags (never "Latest"; the rolling `slyy-shot-latest`
release holds the newest DMG); source in `shot/`, built and published by
`.github/workflows/slyy-shot.yml`.
