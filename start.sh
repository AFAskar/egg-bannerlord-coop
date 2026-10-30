#!/bin/sh
# Bannerlord Coop dedicated server launcher. The Windows dedicated server build
# comes from the Bannerlord Coop GitHub releases at boot; no Steam account is
# needed and no game files are baked in.
set -u

COOP_REPO=Bannerlord-Coop-Team/BannerlordCoop
# "latest" follows the newest stable release. A tag such as v0.1.6 pins one.
COOP_VERSION=${COOP_VERSION:-latest}

GAME_DIR=${GAME_DIR:-/home/container/game}
DATA_DIR=${DATA_DIR:-/home/container/data}
# Modules in this folder are linked into engine/Modules and loaded after Coop.
MODS_DIR=${MODS_DIR:-$DATA_DIR/mods}
WINEPREFIX=${WINEPREFIX:-/home/container/.wine}
AUTO_UPDATE=${AUTO_UPDATE:-1}
# The engine's own custom-server port and region. Not the port players join on.
ENGINE_PORT=${ENGINE_PORT:-7210}
REGION=${REGION:-EU}
export WINEPREFIX

log()  { echo "[coop] $*"; }
warn() { echo "[coop] WARNING: $*" >&2; }
die()  { echo "[coop] ERROR: $*" >&2; exit 1; }

# Docker Desktop's 9p mount can return EEXIST for a missing dir, so test the result.
ensure_dir() { mkdir -p "$1" 2>/dev/null; [ -d "$1" ] || die "cannot create $1"; }

# server-config.json is JSONC, so sed, not a parser. esc() prefixes & \ | for sed.
esc() { printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'; }
set_cfg() {
  grep -qE "\"$1\"[[:space:]]*:" "$cfg" 2>/dev/null || return 0
  sed -i -E "s|(\"$1\"[[:space:]]*:[[:space:]]*)[^,}]*|\1$(esc "$2")|" "$cfg"
}

# wings sends its primary allocation here, and 0 when the server has none. A bad
# port strands the server with no way in, so check before downloading the release.
check_port() {
  # 1-65534, since the mod also uses port+1. awk compares without overflowing on a
  # long digit string, and [1-9] first means no leading zero and no need for a
  # lower-bound test.
  awk -v p="${1:-}" 'BEGIN{exit !(p ~ /^[1-9][0-9]*$/ && p+0<=65534)}' ||
    die "${2:-SERVER_PORT}=${1:-} is not a port in 1-65534. Pelican sends 0 when the
server has no primary allocation: give it two consecutive free UDP ports."
}

# --- extra modules ----------------------------------------------------------
# The engine activates only what its _MODULES_ argument names, so a mod has to be
# linked into Modules and added to the list built in section 5. Modules live in
# MODS_DIR (data/mods by default), one folder per module, so a game update does
# not delete them. A mod also needs bin/Win64_Shipping_Server; a client-only
# build loads no code.

# The declared id, not the folder name: Coop's folder declares "Coop" or "CoopNightly".
module_id() { sed -n 's/.*<Id[[:space:]]*value="\([^"]*\)".*/\1/p' "$1" | head -1; }

# stage_mods <mods root> <modules dir> - prints the ids it staged, in folder order.
stage_mods() {
  ws=$1; dir=$2; staged=
  [ -d "$ws" ] || return 0
  for src in "$ws"/*; do
    [ -d "$src" ] || continue
    sub=$src/SubModule.xml
    # Some uploads nest the module one level down.
    [ -f "$sub" ] || sub=$(find "$src" -maxdepth 2 -name SubModule.xml 2>/dev/null | head -1)
    if [ -z "$sub" ] || [ ! -f "$sub" ]; then
      warn "module folder $(basename "$src") has no SubModule.xml - not loaded"
      continue
    fi
    mid=$(module_id "$sub")
    if [ -z "$mid" ]; then
      warn "module folder $(basename "$src") declares no module Id - not loaded"
      continue
    fi
    link=$dir/$mid
    # Only ever replace a link of our own, never one of the shipped modules.
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      warn "$mid is a real folder under Modules, leaving it as it is"
      continue
    fi
    if ! ln -sfn "$(dirname "$sub")" "$link"; then
      warn "could not link $mid into Modules"
      continue
    fi
    staged="$staged $mid"
  done
  printf '%s' "${staged# }"
}

# prune_mods <modules dir> <ids to keep> - drops modules no longer in MODS_DIR,
# by removing only our own links.
prune_mods() {
  for link in "$1"/*; do
    [ -L "$link" ] || continue
    case " $2 " in
      *" $(basename "$link") "*) continue ;;
    esac
    rm -f "$link"
  done
}

# The release manifest is an asset on every v0.1.6+ release, so "latest" can
# resolve it without the GitHub API and without a rate limit.
manifest_url() {
  case ${1:-latest} in
    latest) printf 'https://github.com/%s/releases/latest/download/manifest.json' "$COOP_REPO" ;;
    v*)     printf 'https://github.com/%s/releases/download/%s/manifest.json' "$COOP_REPO" "$1" ;;
    *)      printf 'https://github.com/%s/releases/download/v%s/manifest.json' "$COOP_REPO" "$1" ;;
  esac
}

# `sh start.sh --self-test` checks both round trips. CI runs it.
if [ "${1:-}" = "--self-test" ]; then
  cfg=$(mktemp) || exit 1
  printf '{\n  "port": 4200, // trailing comment\n  "password": "old",\n}\n' > "$cfg"
  set_cfg password '"a|b&c\d"'
  want='  "password": "a|b&c\d",'
  got=$(grep password "$cfg"); rm -f "$cfg"
  [ "$got" = "$want" ] || die "self-test: got [$got] want [$want]"
  for bad in "" 0 abc 04200 65535 99999999999999999999; do
    ( check_port "$bad" ) 2>/dev/null && die "self-test: check_port took [$bad]"
  done
  check_port 4200 || die "self-test: check_port rejected 4200"

  [ "$(manifest_url latest)" = "https://github.com/$COOP_REPO/releases/latest/download/manifest.json" ] ||
    die "self-test: wrong latest manifest url"
  [ "$(manifest_url v0.1.6)" = "https://github.com/$COOP_REPO/releases/download/v0.1.6/manifest.json" ] ||
    die "self-test: wrong pinned manifest url"
  [ "$(manifest_url 0.1.6)" = "https://github.com/$COOP_REPO/releases/download/v0.1.6/manifest.json" ] ||
    die "self-test: version without v did not normalize"

  # A nested module stages under its declared id, and unstages when dropped.
  ws=$(mktemp -d) || exit 1
  md=$(mktemp -d) || exit 1
  mkdir -p "$ws/123/Inner"
  printf '<Module>\n  <Id value="TestMod" />\n</Module>\n' > "$ws/123/Inner/SubModule.xml"
  : > "$md/RealModule"
  got=$(stage_mods "$ws" "$md")
  [ "$got" = TestMod ] || die "self-test: stage_mods got [$got] want [TestMod]"
  [ -f "$md/TestMod/SubModule.xml" ] || die "self-test: TestMod did not stage"
  # MSYS ln -s copies, so assert prune_mods only where symlinks are real. CI is.
  if ln -s . "$md/.probe" 2>/dev/null && [ -L "$md/.probe" ]; then
    rm -f "$md/.probe"
    prune_mods "$md" ""
    [ -L "$md/TestMod" ] && die "self-test: prune_mods kept a dropped mod"
    [ -e "$md/RealModule" ] || die "self-test: prune_mods removed a real module"
  else
    log "self-test: no symlink support here, skipped the prune_mods check"
  fi
  rm -rf "$ws" "$md"

  echo "self-test ok"; exit 0
fi

[ -z "${SERVER_PORT:-}" ] || check_port "$SERVER_PORT"

# --- 1. game files ----------------------------------------------------------
# Every release publishes manifest.json with the Windows dedicated server URL
# and its SHA-256. The archive is the full server: engine/, the Coop module and
# server-data/default_new_game.sav. No Steam login is involved.

game_installed_at() {
  [ -f "$1/BannerlordCoopServer.exe" ] &&
    [ -d "$1/engine/bin/Win64_Shipping_Server" ] &&
    [ -f "$1/engine/Modules/Coop/SubModule.xml" ]
}

game_installed() { game_installed_at "$GAME_DIR"; }

update_game() {
  if [ "$AUTO_UPDATE" != 1 ]; then
    log "AUTO_UPDATE=0 - not checking GitHub"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { warn "jq is not installed - rebuild the image"; return 1; }
  command -v 7z >/dev/null 2>&1 || { warn "7z is not installed - rebuild the image"; return 1; }

  # Keep the manifest, partial download and staging area next to the game dir,
  # on the same volume, so a big download never fills the container filesystem.
  work_dir=$(dirname "$GAME_DIR")/.bannerlord-coop
  mkdir -p "$work_dir" 2>/dev/null
  [ -d "$work_dir" ] || { warn "cannot create $work_dir"; return 1; }
  manifest=$work_dir/manifest.json
  old=$work_dir/game.old

  # A previous update may have left only its backup behind. Put it back before
  # touching the network, so a failed download never loses the only copy.
  if [ -d "$old" ] && [ ! -d "$GAME_DIR" ]; then
    warn "restoring the game files left by a failed update"
    mv "$old" "$GAME_DIR" || { warn "could not restore $old"; return 1; }
  fi

  url=$(manifest_url "$COOP_VERSION")
  log "checking $COOP_VERSION release"
  if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 "$url" -o "$manifest"; then
    warn "could not fetch the release manifest from $url"
    return 1
  fi

  win_url=$(jq -er '.windows.url' "$manifest" 2>/dev/null) ||
    { warn "release manifest has no windows.url"; return 1; }
  win_sha=$(jq -er '.windows.sha256' "$manifest" 2>/dev/null) ||
    { warn "release manifest has no windows.sha256"; return 1; }
  win_name=$(jq -er '.windows.name' "$manifest" 2>/dev/null) ||
    { warn "release manifest has no windows.name"; return 1; }
  win_name=$(basename "$win_name")
  [ -n "$win_name" ] || { warn "release manifest names an empty archive"; return 1; }

  current=$(cat "$GAME_DIR/.coop-release" 2>/dev/null || true)
  if game_installed && [ "$current" = "$win_sha" ]; then
    log "game files are current ($win_name)"
    return 0
  fi

  archive=$work_dir/$win_name
  if [ -f "$archive" ] &&
     printf '%s  %s\n' "$win_sha" "$archive" | sha256sum -c - >/dev/null 2>&1; then
    log "using verified download $archive"
  else
    rm -f "$archive"
    log "downloading $win_name (~4.2 GB) from the GitHub release"
    if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 -o "$archive" "$win_url"; then
      warn "could not download $win_name"
      return 1
    fi
  fi

  actual=$(sha256sum "$archive" | awk '{print $1}') ||
    { warn "could not hash $archive"; return 1; }
  if [ "$actual" != "$win_sha" ]; then
    warn "SHA-256 mismatch for $win_name: got $actual, want $win_sha"
    rm -f "$archive"
    return 1
  fi

  staging=$work_dir/game.new
  rm -rf "$staging"
  mkdir -p "$staging" 2>/dev/null
  [ -d "$staging" ] || { warn "cannot create $staging"; return 1; }
  log "extracting $win_name"
  if ! 7z x -y -bso0 -bsp0 -o"$staging" "$archive"; then
    warn "could not extract $win_name"
    rm -rf "$staging"
    return 1
  fi
  rm -f "$archive"
  if ! game_installed_at "$staging"; then
    warn "release archive did not contain BannerlordCoopServer.exe and engine/"
    rm -rf "$staging"
    return 1
  fi

  rm -rf "$old"
  if [ -d "$GAME_DIR" ] && ! mv "$GAME_DIR" "$old"; then
    warn "could not move $GAME_DIR aside for the update"
    rm -rf "$staging"
    return 1
  fi
  if ! mv "$staging" "$GAME_DIR"; then
    warn "could not move the new game files into $GAME_DIR"
    [ -d "$old" ] && mv "$old" "$GAME_DIR"
    return 1
  fi
  rm -rf "$old"
  printf '%s\n' "$win_sha" > "$GAME_DIR/.coop-release" ||
    warn "could not write the release marker"
  log "game files installed from $win_name"
  return 0
}

if ! update_game; then
  # A GitHub outage or a bad tag must never brick a server that already works.
  if ! game_installed; then
    # Slow the wings restart loop down to one attempt a minute.
    sleep 60
    die "no game files found and the GitHub release could not be installed.
Looked for BannerlordCoopServer.exe in $GAME_DIR.
Set COOP_VERSION to a release tag that publishes manifest.json, check the
network, or point GAME_DIR at an existing copy and set AUTO_UPDATE=0."
  fi
  warn "continuing with the game files already present"
fi
game_installed || die "BannerlordCoopServer.exe is missing from $GAME_DIR after the update step."
log "game files: $GAME_DIR"

ensure_dir "$DATA_DIR"
ensure_dir "$MODS_DIR"

# --- 1b. link the extra modules in ------------------------------------------
MODULES_DIR=$GAME_DIR/engine/Modules
[ -d "$MODULES_DIR" ] || die "no engine module folder at $MODULES_DIR"

MODS=$(stage_mods "$MODS_DIR" "$MODULES_DIR")
prune_mods "$MODULES_DIR" "$MODS"
[ -z "$MODS" ] || log "extra modules: $MODS"

# --- 2. wine prefix ---------------------------------------------------------
if [ ! -f "$WINEPREFIX/system.reg" ]; then
  log "creating wine prefix at $WINEPREFIX (~2 min)"
  ensure_dir "$WINEPREFIX"
  xvfb-run -a wineboot -i >/dev/null 2>&1
  wineserver -k 2>/dev/null
  [ -f "$WINEPREFIX/system.reg" ] || die "could not create a wine prefix at $WINEPREFIX"
fi

# --- 3. mod-config.json must land in the data dir ---------------------------
# COOP_DATA_DIR below already points the mod here; this covers anything the engine
# still resolves through Wine's Documents. The uid has no passwd entry, so glob.
for docs in "$WINEPREFIX"/drive_c/users/*/Documents; do
  [ -d "$docs" ] || continue
  ensure_dir "$docs/Mount and Blade II Bannerlord"
  link="$docs/Mount and Blade II Bannerlord/CoopData"
  [ -L "$link" ] && rm -f "$link"
  [ -e "$link" ] || ln -s "$DATA_DIR" "$link"
done

# --- 4. server-config.json --------------------------------------------------
# Seeded before launch, or the mod writes its own with port 4200.
cfg=$DATA_DIR/server-config.json

if [ ! -f "$cfg" ]; then
  log "seeding $cfg"
  cat > "$cfg" <<CFG
{
  "port": ${SERVER_PORT:-4200},
  "saveName": "${SAVE_NAME:-saveauto1}",
  "password": "${SERVER_PASSWORD:-}",
  "autosaveMinutes": ${AUTOSAVE_MINUTES:-5},
  "logFile": true,
  "steam": false
}
CFG
else
  [ -n "${SERVER_PORT:-}" ]       && set_cfg port "$SERVER_PORT"
  [ -n "${SAVE_NAME:-}" ]         && set_cfg saveName "\"$SAVE_NAME\""
  [ -n "${SERVER_PASSWORD+x}" ]   && set_cfg password "\"$SERVER_PASSWORD\""
  [ -n "${AUTOSAVE_MINUTES:-}" ]  && set_cfg autosaveMinutes "$AUTOSAVE_MINUTES"
fi

# Nothing downstream rejects a stored 0, so the file gets the panel's check too.
check_port "$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$cfg" | head -1)" \
           "server-config.json port"

# --- 4b. first-boot world ---------------------------------------------------
# The engine loads the configured save and will not create one, so seed it here the
# way BannerlordCoopServer.exe did.
save_name=$(sed -n 's/.*"saveName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | head -1)
[ -n "$save_name" ] || save_name=${SAVE_NAME:-saveauto1}
ensure_dir "$DATA_DIR/Game Saves"
if [ ! -f "$DATA_DIR/Game Saves/$save_name.sav" ]; then
  seed="$GAME_DIR/server-data/Game Saves/default_new_game.sav"
  [ -f "$seed" ] ||
    die "save '$save_name' does not exist and there is no default_new_game.sav at $seed"
  log "new world '$save_name' from default_new_game.sav"
  cp "$seed" "$DATA_DIR/Game Saves/$save_name.sav" || die "could not seed $save_name.sav"
fi

# --- 5. go -------------------------------------------------------------------
win_data=$(winepath -w "$DATA_DIR" 2>/dev/null)
[ -n "$win_data" ] || die "winepath could not map $DATA_DIR to a Windows path"

# This list, in this order, and nothing else. Mods go after Coop, which they depend on.
coop_id=$(module_id "$MODULES_DIR/Coop/SubModule.xml")
[ -n "$coop_id" ] || die "cannot read the Coop module id from $MODULES_DIR/Coop/SubModule.xml"
token=_MODULES_
for m in Native SandBoxCore Sandbox "$coop_id" $MODS DedicatedServer.Windows; do
  token="$token*$m"
done
token="$token*_MODULES_"

log "starting: $token"
cd "$GAME_DIR/engine/bin/Win64_Shipping_Server" ||
  die "cannot enter $GAME_DIR/engine/bin/Win64_Shipping_Server"

dotnet_root=$(winepath -w "$GAME_DIR/engine/dotnet" 2>/dev/null)
[ -n "$dotnet_root" ] || die "winepath could not map $GAME_DIR/engine/dotnet"
# BANNERLORD_USER_DIR: server-config.json, Game Saves, logs. COOP_DATA_DIR:
# mod-config.json. This egg keeps both in the data dir.
export DOTNET_ROOT="$dotnet_root" DOTNET_MULTILEVEL_LOOKUP=0
export BANNERLORD_USER_DIR="$win_data" COOP_DATA_DIR="$win_data"

# A no-op for wings, which sends LF; keeps the console usable from a real terminal.
stty inlcr 2>/dev/null || true

# Xvfb is already on $DISPLAY. exec puts wine one hop from wings' stdin and signals.
exec wine "$GAME_DIR/engine/dotnet/dotnet.exe" TaleWorlds.Starter.DotNetCore.dll \
     "$token" /dedicatedcustomserver "$ENGINE_PORT" "$REGION" 0 "$@"
