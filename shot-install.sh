#!/bin/sh
# Slyy Shot installer (macOS 13+, Apple Silicon + Intel):
#
#   curl -fsSL https://raw.githubusercontent.com/mySlyy/shot/main/shot-install.sh | sh
#
# Installs the newest Slyy Shot release (tags slyy-shot-v*) from
# github.com/mySlyy/shot, verified against the release's SHA256SUMS and the
# pinned signer (SIGNER_REQ), to /Applications (if writable) or ~/Applications, then starts it.
# Run it again to update (the app also updates itself from its menu).
#
# Uninstall (app + settings; your screenshots are kept):
#   curl -fsSL https://raw.githubusercontent.com/mySlyy/shot/main/shot-install.sh | sh -s -- --uninstall
#
# Environment (optional):
#   SHOT_VERSION       install this version (e.g. 1.0.0) instead of the newest
#   SHOT_INSTALL_DIR   target directory for "Slyy Shot.app"
#   SHOT_RELEASES_API  release feed API base (mirrors, tests; https or loopback)
set -eu

API="${SHOT_RELEASES_API:-https://api.github.com/repos/mySlyy/shot}"
TAG_PREFIX="slyy-shot-v"
APP="Slyy Shot.app"
BUNDLE_ID="ai.slyy.shot"
PROC="SlyyShot"
# Pinned signer: must equal shot/Resources/update_signer.req (checked by the release workflow).
# SHA256SUMS comes from the same release, so only this proves who built the app.
SIGNER_REQ='identifier "ai.slyy.shot" and certificate root = H"e794d64fa8c843fbd7c75c2fca5a23afda3ba74c"'

say() { printf 'shot-install: %s\n' "$*"; }
die() { printf 'shot-install: error: %s\n' "$*" >&2; exit 1; }

# Legacy 1.x (bundle ID ai.slyy.snap, process SlyySnap): no update path to 2.x, users reinstall with this
# script. Quit it too (else two apps hold the hotkeys); the app copies its settings on first launch.
LEGACY_BUNDLE_ID="ai.slyy.snap"
LEGACY_PROC="SlyySnap"

# quit_one <bundle id> <process name>
quit_one() {
	if pgrep -xq "$2" 2>/dev/null; then
		osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 || true
		i=0
		while pgrep -xq "$2" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
		pkill -x "$2" 2>/dev/null || true
	fi
}

quit_running() {
	quit_one "$BUNDLE_ID" "$PROC"
	quit_one "$LEGACY_BUNDLE_ID" "$LEGACY_PROC"
}

uninstall() {
	quit_running
	removed=""
	for dir in ${SHOT_INSTALL_DIR:-} /Applications "$HOME/Applications"; do
		[ -d "$dir/$APP" ] || continue
		if rm -rf "${dir:?}/$APP" 2>/dev/null; then removed="$removed $dir/$APP"; else say "cannot remove $dir/$APP (permissions)"; fi
	done
	defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
	defaults delete "$LEGACY_BUNDLE_ID" >/dev/null 2>&1 || true
	if [ -n "$removed" ]; then say "removed$removed and its settings"; else say "Slyy Shot is not installed"; fi
	say "kept your screenshots (~/Pictures/Slyy Shot or your chosen folder)"
}

# Wrapped in main so a truncated download (curl | sh) never runs half a script.
main() {
	case "${1:-}" in
	--uninstall) uninstall; return 0 ;;
	"") ;;
	*) die "unknown argument '$1' (only --uninstall)" ;;
	esac
	[ "$(uname -s)" = Darwin ] || die "Slyy Shot is a macOS app"
	case "$API" in
	https://*) proto='=https' ;;
	http://127.0.0.1:* | http://localhost:*) proto='=https,http' ;;
	*) die "SHOT_RELEASES_API must be https: $API" ;;
	esac
	fetch() { curl -fsSL --proto "$proto" --proto-redir "$proto" "$@"; }

	if [ -n "${SHOT_VERSION:-}" ]; then
		ver="${SHOT_VERSION#v}"
	else
		ver=$(fetch "$API/releases?per_page=100" |
			grep -o "\"tag_name\": *\"${TAG_PREFIX}[0-9]*\.[0-9]*\.[0-9]*\"" |
			sed "s/.*${TAG_PREFIX}//; s/\"//g" |
			sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1) || true
		[ -n "$ver" ] || die "could not find a Slyy Shot release (network, or GitHub API rate limit)"
	fi
	case "$ver" in
	*[!0-9.]* | "") die "invalid version '$ver'" ;;
	esac

	file="SlyyShot-${ver}.zip"
	case "$API" in
	https://api.github.com/repos/*) base="https://github.com/${API#https://api.github.com/repos/}/releases/download" ;;
	*) base="${API%/repos/*}/download" ;;
	esac
	url="$base/${TAG_PREFIX}${ver}"

	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT INT TERM
	say "downloading Slyy Shot $ver"
	fetch -o "$tmp/$file" "$url/$file" || die "download failed: $url/$file"
	fetch -o "$tmp/SHA256SUMS" "$url/SHA256SUMS" || die "download failed: $url/SHA256SUMS"
	want=$(awk -v f="$file" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
	[ -n "$want" ] || die "SHA256SUMS lists no $file"
	got=$(shasum -a 256 "$tmp/$file" | cut -d' ' -f1)
	[ "$got" = "$want" ] || die "checksum mismatch for $file (got $got, want $want): not installed"

	ditto -x -k "$tmp/$file" "$tmp/x" || die "corrupt archive"
	[ -d "$tmp/x/$APP" ] || die "archive holds no app"
	reported=$(defaults read "$tmp/x/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null) || true
	[ "$reported" = "$ver" ] || die "downloaded app reports '$reported', expected $ver"
	codesign --verify --deep --strict -R="$SIGNER_REQ" "$tmp/x/$APP" ||
		die "code signature invalid or not the pinned Slyy Shot signer: not installed"

	if [ -n "${SHOT_INSTALL_DIR:-}" ]; then
		dir="$SHOT_INSTALL_DIR"
	elif [ -w /Applications ]; then
		dir=/Applications
	else
		dir="$HOME/Applications"
	fi
	mkdir -p "$dir" || die "cannot create $dir"
	quit_running
	# Stage on the target volume, then swap.
	rm -rf "${dir:?}/$APP.new"
	ditto "$tmp/x/$APP" "$dir/$APP.new" || die "cannot write to $dir"
	rm -rf "${dir:?}/$APP"
	mv "$dir/$APP.new" "$dir/$APP"
	# Drop the stale 1.x Screen Recording entry (same name in System Settings, other bundle ID).
	tccutil reset ScreenCapture "$LEGACY_BUNDLE_ID" >/dev/null 2>&1 || true
	xattr -dr com.apple.quarantine "$dir/$APP" 2>/dev/null || true
	say "installed $dir/$APP ($ver)"
	open "$dir/$APP"
	say "running: camera icon in the menu bar. ⌘⇧5 area, ⌘⇧4 window, ⌘⇧3 screen."
	say "first capture: allow Slyy Shot under System Settings > Privacy & Security > Screen Recording, then relaunch it."
}

main "$@"
