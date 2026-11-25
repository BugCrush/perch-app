#!/bin/sh
# Perch plugin setup step: Claude Code runs it at the start of every session, in the
# background (an async SessionStart hook), with sh (Git Bash on Windows). It keeps the
# Perch host installed and current:
#   1. quits at once when the host of this plugin's version is installed already, when
#      PERCH_NO_SETUP is set, or when this machine's autostart runs a host built from the
#      Perch repo (a developer's machine);
#   2. downloads the host build of this plugin's version for this machine from the GitHub
#      Release of the repository named in plugin.json ("repository"; PERCH_RELEASE_REPO
#      overrides it, PERCH_RELEASE_URL replaces the whole download address), with gh
#      when the plain download fails (a private repository);
#   3. checks its SHA-256 against the release's SHA256SUMS.txt (a mismatch installs nothing);
#   4. unpacks it into <state>/releases/<version>/ and runs `perch_host setup` from there:
#      autostart at log on, and the host started now (or switched to when it is idle).
# Everything goes to <state>/setup.log; nothing is printed into the session.
# PERCH_SETUP_DRY=1 downloads, checks and unpacks but does not run setup.
[ -n "$PERCH_NO_SETUP" ] && exit 0
here=$(cd "$(dirname "$0")" && pwd) || exit 0
v=$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$here/../.claude-plugin/plugin.json" | head -n 1)
[ -n "$v" ] || exit 0
d="${PERCH_STATE_DIR:-${APPDATA:+$APPDATA/perch}}"
d="${d:-$HOME/.perch}"
[ -f "$d/releases/$v/installed" ] && exit 0
# A developer's machine: autostart runs a host built from the repo; leave it alone.
if [ -f "$d/autostart.json" ] && ! grep -q '"release"' "$d/autostart.json"; then exit 0; fi
case "$OS" in
  Windows_NT) target=windows-x64; pack=zip; exe=perch_host.exe ;;
  *)
    case "$(uname -s)-$(uname -m)" in
      Darwin-arm64) target=macos-arm64; pack=tar.gz; exe=perch_host ;;
      *) exit 0 ;;
    esac ;;
esac
mkdir -p "$d/releases" || exit 0
lock="$d/releases/.lock"
# One setup at a time; a lock older than 30 minutes was left by a setup that died.
if ! mkdir "$lock" 2>/dev/null; then
  [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ] || exit 0
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null || exit 0
fi
trap 'rm -rf "$lock"' EXIT
{
  # The repository from plugin.json ("https://github.com/<owner>/<repo>"), so a fork changes it in one place.
  from=$(sed -n 's#.*"repository" *: *"https://github.com/\([^"]*\)".*#\1#p' "$here/../.claude-plugin/plugin.json" | head -n 1)
  from="${from%.git}"
  repo="${PERCH_RELEASE_REPO:-${from:-BugCrush/perch-app}}"
  echo "$(date) Perch $v for $target from $repo"
  base="${PERCH_RELEASE_URL:-https://github.com/$repo/releases/download}"
  asset="perch-host-$v-$target.$pack"
  tmp="$d/releases/.download-$v"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  if curl -fsSL --retry 2 -o "$tmp/$asset" "$base/v$v/$asset" &&
    curl -fsSL --retry 2 -o "$tmp/SHA256SUMS.txt" "$base/v$v/SHA256SUMS.txt"; then
    :
  elif command -v gh >/dev/null 2>&1 &&
    gh release download "v$v" --repo "$repo" -p "$asset" -p SHA256SUMS.txt -D "$tmp" --clobber; then
    :
  else
    echo "Could not download $asset from $base (a private repository needs gh signed in)."
    exit 1
  fi
  want=$(grep " \*\{0,1\}$asset\$" "$tmp/SHA256SUMS.txt" | cut -d' ' -f1)
  # From stdin: with a file name, GNU sha256sum escapes a Windows path's backslashes.
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum <"$tmp/$asset" | cut -d' ' -f1)
  else
    got=$(shasum -a 256 <"$tmp/$asset" | cut -d' ' -f1)
  fi
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "The SHA-256 of $asset does not match SHA256SUMS.txt: nothing installed."
    exit 1
  fi
  out="$d/releases/$v"
  rm -rf "$out.new"
  mkdir -p "$out.new"
  if [ "$pack" = zip ]; then
    # Windows' own tar (bsdtar) unpacks zip files; Git Bash's does not.
    "${SYSTEMROOT:-C:/Windows}/System32/tar.exe" -xf "$tmp/$asset" -C "$out.new"
  else
    tar -xzf "$tmp/$asset" -C "$out.new"
  fi || { echo "Could not unpack $asset."; exit 1; }
  rm -rf "$out" && mv "$out.new" "$out" && rm -rf "$tmp"
  echo "Unpacked into $out (SHA-256 $got)."
  if [ -n "$PERCH_SETUP_DRY" ]; then
    echo "Dry run: would run $out/$exe setup"
  else
    "$out/$exe" setup
  fi
} >>"$d/setup.log" 2>&1
