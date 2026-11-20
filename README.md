# Slyy Shot

Personal screenshot tool, macOS 13+ (Apple Silicon + Intel). https://slyy.ai

Menu bar app: ⌘⇧5 area, ⌘⇧4 window, ⌘⇧3 screen (switch off the
macOS "Screenshots" keyboard shortcuts, or map other keys under Options >
Keyboard Shortcuts…). Saves PNGs to
~/Pictures/Slyy Shot and copies them to the clipboard.

## Installation

Download
https://github.com/mySlyy/shot/releases/download/slyy-shot-latest/SlyyShot.dmg
(always the newest), open it, drag Slyy Shot to Applications (first launch: Privacy & Security > "Open Anyway").
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

## Releases

Releases are the `slyy-shot-v*` tags (never "Latest"; the rolling `slyy-shot-latest`
release holds the newest DMG); source in `shot/`, built and published by
`.github/workflows/slyy-shot.yml`.

## Release runner

The release job runs on the runner named in repo variable `SHOT_RUNNER` (JSON); unset =
GitHub-hosted `macos-15-intel`. Own Mac: `scripts/self_hosted_runner.py`.

- `sudo python3 scripts/self_hosted_runner.py install`: hidden user `ghrunner` (own group,
  not staff: cannot read your home), runner `slyy-shot-mac` (label `slyy-shot`, tarball
  SHA-256 checked) as LaunchDaemon `ai.slyy.ghrunner.shot`. `status`, `uninstall [--delete-user]`.
- Use it: `gh variable set SHOT_RUNNER -R mySlyy/shot --body '["self-hosted","macOS","ARM64","slyy-shot"]'`.
  Fall back: `gh variable delete SHOT_RUNNER -R mySlyy/shot`.
- Mac asleep/offline: release jobs wait in the queue (max 24 h).
- Public repo: only tags and manual runs start the job; fork PR workflows need approval
  (all outside contributors). Never add `pull_request` triggers on this runner.
