# Slyy Shot

Personal screenshot tool, macOS 13+ (Apple Silicon + Intel). https://slyy.ai

Menu bar app: ⌘⇧5 area, ⌘⇧4 window, ⌘⇧3 screen (switch off the
macOS "Screenshots" keyboard shortcuts). Saves PNGs to
~/Pictures/Slyy Shot and copies them to the clipboard.

## Installation

Download
https://github.com/mySlyy/shot/releases/download/slyy-shot-latest/SlyyShot.dmg
(always the newest), open it, drag Slyy Shot to Applications (first launch: Privacy & Security > "Open Anyway").
Or from Terminal (no Gatekeeper prompt):

    curl -fsSL https://raw.githubusercontent.com/mySlyy/shot/main/snap-install.sh | sh

Remove: same command with `sh -s -- --uninstall`.

## Updates

The app checks for updates itself (menu > Check for Updates…; checksum and
signature verified). Updates and the installer accept only builds by the pinned signer
`snap/Resources/update_signer.req` (copy in `snap-install.sh` SIGNER_REQ; the release
workflow checks both match and refuses ad-hoc releases).

## Releases

Releases are the `slyy-snap-v*` tags (never "Latest"; the rolling `slyy-shot-latest`
release holds the newest DMG); source in `snap/`, built and published by
`.github/workflows/slyy-snap.yml`.
