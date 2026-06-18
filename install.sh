#!/usr/bin/env bash
#
# sod-installer — one-click installer for the Season of Discovery AzerothCore
# modules and the RuneEngraver client addon.
#
#   Components (pick any; "Everything" is the default):
#     - Rune Engraving : mod-rune-engraving engine + the RuneEngraver client addon
#     - SoD World      : mod-sod-world (shared Awakened Lich encounter)
#     - SoD Mage       : mod-sod-mage (mage spells & runes)
#
#   It clones the chosen modules into <server>/modules/, builds the client MPQ
#   patches, and clones the addon into <client>/Interface/AddOns/. You then build
#   the worldserver yourself. Works on native Linux and WSL.
#
#   Usage:
#     ./install.sh                 interactive install
#     ./install.sh --update        refresh an existing install (git pull + rebuild patches)
#     ./install.sh --uninstall     remove modules/addon/patches (DB is left untouched)
#     ./install.sh --dry-run       print every action without doing anything
#     ./install.sh --all --server DIR --client DIR    non-interactive (CI)
#     ./install.sh --components rune,world,mage        choose components non-interactively
#     ./install.sh --docker | --source                set build method (else asked once)
#     ./install.sh --uninstall --force                also remove repos with local changes
#     ./install.sh --yes                              answer yes to all prompts (automation)
#
# Non-destructive: only ever `git clone` (missing) or `git pull --ff-only`
# (existing); never reset/clean/force/delete.

set -uo pipefail

# ── configuration ────────────────────────────────────────────────────────────
GH_BASE="https://github.com/bennybroseph"
BRANCH="main"
ADDON_REPO="RuneEngraver"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sod-installer"
CONFIG_FILE="$CONFIG_DIR/config"

# ── globals ──────────────────────────────────────────────────────────────────
DRY_RUN=0
FORCE=0                  # uninstall: delete repos even if they have local changes
ASSUME_YES=0            # answer "yes" to every confirm (non-interactive automation)
ACTION="install"
SERVER=""; CLIENT=""
BUILD_METHOD=""          # "source" (cmake) or "docker"; remembered in config
PRESET_SERVER=""; PRESET_CLIENT=""; PRESET_COMPONENTS=""; PRESET_BUILD=""
SEL_RUNE=0; SEL_WORLD=0; SEL_MAGE=0
SUDO=""; PKG_INSTALL=""; PKG_REFRESH=":"; PKG_REFRESHED=0
PATCH_PY=""
DOCKER_COMPOSE=""        # "docker compose" or "docker-compose" once detected
DID_BUILD=0              # set when the Docker auto-rebuild actually ran

# ── output helpers ───────────────────────────────────────────────────────────
if [ -t 1 ]; then
    c_reset=$'\033[0m'; c_info=$'\033[1;36m'; c_warn=$'\033[1;33m'
    c_err=$'\033[1;31m'; c_ok=$'\033[1;32m'
    c_blue=$'\033[1;34m'; c_gray=$'\033[90m'; c_gold=$'\033[38;5;220m'
else
    c_reset=""; c_info=""; c_warn=""; c_err=""; c_ok=""
    c_blue=""; c_gray=""; c_gold=""
fi
log()  { printf '%s::%s %s\n' "$c_info" "$c_reset" "$*"; }
ok()   { printf '%s ✓%s %s\n' "$c_ok" "$c_reset" "$*"; }
warn() { printf '%s!!%s %s\n' "$c_warn" "$c_reset" "$*" >&2; }
die()  { printf '%sxx%s %s\n' "$c_err" "$c_reset" "$*" >&2; exit 1; }
# run a command, or just print it under --dry-run
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '   dry: %s\n' "$*"; else "$@"; fi; }

# ── environment detection ────────────────────────────────────────────────────
is_wsl() { grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; }

setup_pkg_mgr() {
    [ "$(id -u)" -eq 0 ] || SUDO="sudo"
    if   command -v apt-get >/dev/null 2>&1; then PKG_INSTALL="apt-get install -y"; PKG_REFRESH="apt-get update"
    elif command -v dnf     >/dev/null 2>&1; then PKG_INSTALL="dnf install -y"
    elif command -v pacman  >/dev/null 2>&1; then PKG_INSTALL="pacman -S --needed --noconfirm"; PKG_REFRESH="pacman -Sy"
    elif command -v zypper  >/dev/null 2>&1; then PKG_INSTALL="zypper install -y"
    else PKG_INSTALL=""; fi
}

# ensure_cmd <command> [package]: install <package> only if <command> is missing
ensure_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    [ -n "$PKG_INSTALL" ] || die "Missing '$cmd' and no supported package manager found. Install '$pkg' and re-run."
    if [ "$PKG_REFRESH" != ":" ] && [ "$PKG_REFRESHED" -eq 0 ]; then
        run $SUDO $PKG_REFRESH >/dev/null 2>&1 || true; PKG_REFRESHED=1
    fi
    log "Installing $pkg (provides '$cmd')…"
    run $SUDO $PKG_INSTALL "$pkg" || true
    [ "$DRY_RUN" -eq 1 ] && return 0
    command -v "$cmd" >/dev/null 2>&1 || die "Failed to install '$cmd'."
}

# ── interactive helpers ──────────────────────────────────────────────────────
ask_yn() { # ask_yn "question" [Y|N default]
    local q="$1" def="${2:-Y}" ans
    [ "$ASSUME_YES" -eq 1 ] && return 0          # --yes: auto-accept every prompt
    if [ "$def" = "Y" ]; then read -r -p "$q [Y/n] " ans || true; ans="${ans:-y}"
    else read -r -p "$q [y/N] " ans || true; ans="${ans:-n}"; fi
    case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# pick_dir "title (no apostrophes)" → echoes a Linux/WSL path
pick_dir() {
    local title="$1" dir=""
    if is_wsl && command -v powershell.exe >/dev/null 2>&1; then
        dir="$(wsl_pick_dir "$title")"
    elif command -v zenity >/dev/null 2>&1; then
        dir="$(zenity --file-selection --directory --title="$title" 2>/dev/null)" || true
    elif command -v kdialog >/dev/null 2>&1; then
        dir="$(kdialog --getexistingdirectory "$HOME" --title "$title" 2>/dev/null)" || true
    fi
    [ -z "$dir" ] && { read -e -r -p "$title"$'\n> ' dir || true; }
    printf '%s' "$dir"
}

# WSL: native Windows folder picker → converted to a WSL path (handles both the
# \\wsl.localhost server tree and E:\ client drives).
wsl_pick_dir() {
    local ps win
    ps="Add-Type -AssemblyName System.Windows.Forms | Out-Null; \$d = New-Object System.Windows.Forms.FolderBrowserDialog; \$d.Description = '$1'; \$d.ShowNewFolderButton = \$true; if (\$d.ShowDialog() -eq 'OK') { \$d.SelectedPath }"
    win="$(powershell.exe -NoProfile -STA -Command "$ps" 2>/dev/null | tr -d '\r')"
    [ -n "$win" ] && wslpath -u "$win" 2>/dev/null
}

# resolve_path VARNAME PRESET "title" "must_contain"
resolve_path() {
    local var="$1" preset="$2" title="$3" must="$4"
    local dir="$preset"
    while :; do
        [ -z "$dir" ] && dir="$(pick_dir "$title")"
        dir="${dir%/}"
        if [ -n "$dir" ] && [ -d "$dir" ] && { [ -z "$must" ] || [ -e "$dir/$must" ]; }; then
            printf -v "$var" '%s' "$dir"; return 0
        fi
        warn "Directory not found or missing '$must': ${dir:-<empty>}"
        dir=""
    done
}

# ── components ───────────────────────────────────────────────────────────────
choose_components() {
    SEL_RUNE=0; SEL_WORLD=0; SEL_MAGE=0
    if [ -n "$PRESET_COMPONENTS" ]; then
        case ",$PRESET_COMPONENTS," in *,all,*) SEL_RUNE=1; SEL_WORLD=1; SEL_MAGE=1 ;; esac
        case ",$PRESET_COMPONENTS," in *,rune,*)  SEL_RUNE=1  ;; esac
        case ",$PRESET_COMPONENTS," in *,world,*) SEL_WORLD=1 ;; esac
        case ",$PRESET_COMPONENTS," in *,mage,*)  SEL_MAGE=1  ;; esac
    else
        echo
        echo "What would you like to install?"
        echo "  1) Everything   (Rune Engraving + SoD World + SoD Mage + addon)   [recommended]"
        echo "  2) Custom       (choose components)"
        local choice; read -r -p "Choice [1]: " choice || true; choice="${choice:-1}"
        if [ "$choice" = "1" ]; then
            SEL_RUNE=1; SEL_WORLD=1; SEL_MAGE=1
        else
            ask_yn "Install Rune Engraving (engine + RuneEngraver addon)?" Y && SEL_RUNE=1
            ask_yn "Install SoD World (shared Awakened Lich encounter)?"   Y && SEL_WORLD=1
            ask_yn "Install SoD Mage (mage spells & runes)?"               Y && SEL_MAGE=1
        fi
    fi
    [ $((SEL_RUNE + SEL_WORLD + SEL_MAGE)) -gt 0 ] || die "No components selected."
    resolve_deps
}

resolve_deps() {
    if [ "$SEL_MAGE" -eq 1 ] && [ "$SEL_WORLD" -eq 0 ]; then
        warn "SoD Mage without SoD World: mage item icons won't be patched and Mass"
        warn "Regeneration's in-game Lich drop is unavailable (the spell is still"
        warn "learnable via GM '.learn 412510')."
        if [ -n "$PRESET_COMPONENTS" ] || ask_yn "Add SoD World?" Y; then SEL_WORLD=1; fi
    fi
    if [ "$SEL_MAGE" -eq 1 ] && [ "$SEL_RUNE" -eq 0 ]; then
        warn "SoD Mage without Rune Engraving: spells work via GM '.learn', but you"
        warn "won't be able to engrave them as runes."
    fi
}

# ── git ──────────────────────────────────────────────────────────────────────
# clone_or_update <repo-name> <dest-dir>
clone_or_update() {
    local repo="$1" dest="$2" url="$GH_BASE/$1.git"
    if [ -d "$dest/.git" ]; then
        log "Updating $repo (git pull --ff-only)…"
        if [ "$DRY_RUN" -eq 1 ]; then printf '   dry: git -C %s pull --ff-only\n' "$dest"; return 0; fi
        if git -C "$dest" pull --ff-only --quiet 2>/dev/null; then ok "$repo updated."
        else warn "$repo: left as-is (local changes or divergence — not touched)."; fi
    elif [ -e "$dest" ]; then
        warn "$repo: '$dest' exists but is not a git checkout — skipping."
    else
        log "Cloning $repo → $dest"
        run git clone --quiet --branch "$BRANCH" "$url" "$dest" && ok "$repo cloned." || warn "$repo: clone failed."
    fi
}

# ── client patches ───────────────────────────────────────────────────────────
ensure_patch_python() {
    PATCH_PY=""
    local candidates=() py
    if is_wsl; then candidates=(python.exe python3); else candidates=(python3); fi
    # 1) a python that already imports pympq
    for py in "${candidates[@]}"; do
        command -v "$py" >/dev/null 2>&1 || continue
        if "$py" -c "import pympq" >/dev/null 2>&1; then PATCH_PY="$py"; return 0; fi
    done
    # 2) otherwise install python3+pip on Linux, then pip-install pympq into a candidate
    if ! is_wsl; then ensure_cmd python3; ensure_pip python3; fi
    for py in "${candidates[@]}"; do
        command -v "$py" >/dev/null 2>&1 || continue
        log "Installing pympq for $py…"
        run "$py" -m pip install --user pympq >/dev/null 2>&1 || true
        [ "$DRY_RUN" -eq 1 ] && { PATCH_PY="$py"; return 0; }
        if "$py" -c "import pympq" >/dev/null 2>&1; then PATCH_PY="$py"; return 0; fi
    done
    return 1
}

ensure_pip() { # ensure_pip <python>
    "$1" -m pip --version >/dev/null 2>&1 && return 0
    ensure_cmd pip3 python3-pip 2>/dev/null || true
    "$1" -m ensurepip --user >/dev/null 2>&1 || true
}

# build_patch <module-dir> <tool-relpath> <label>
build_patch() {
    local tool="$2" label="$3" script="$1/$2"
    [ -f "$script" ] || { warn "$label: $tool not found — skipping."; return 0; }
    local client_arg="$CLIENT" script_arg="$script"
    if is_wsl && [ "$PATCH_PY" = "python.exe" ]; then
        client_arg="$(wslpath -w "$CLIENT")"; script_arg="$(wslpath -w "$script")"
    fi
    log "Building $label client patch…"
    run "$PATCH_PY" "$script_arg" --client "$client_arg" || warn "$label: patch build failed."
}

print_manual_patch_cmds() {
    warn "Build the client patch(es) yourself once pympq/StormLib is available:"
    [ "$SEL_WORLD" -eq 1 ] && printf '     python %s/modules/mod-sod-world/tools/build_sod_world_patch.py --client "%s"\n' "$SERVER" "$CLIENT"
    [ "$SEL_MAGE"  -eq 1 ] && printf '     python %s/modules/mod-sod-mage/tools/build_sod_mage_patch.py  --client "%s"\n' "$SERVER" "$CLIENT"
}

build_patches() {
    [ "$SEL_WORLD" -eq 1 ] || [ "$SEL_MAGE" -eq 1 ] || return 0
    if ensure_patch_python; then
        warn "Close the WoW client first — it locks the MPQ files while running."
        [ "$SEL_WORLD" -eq 1 ] && build_patch "$SERVER/modules/mod-sod-world" "tools/build_sod_world_patch.py" "SoD World (item icons)"
        [ "$SEL_MAGE"  -eq 1 ] && build_patch "$SERVER/modules/mod-sod-mage"  "tools/build_sod_mage_patch.py"  "SoD Mage (spells)"
    else
        warn "No Python with pympq available — skipping the MPQ patch build."
        print_manual_patch_cmds
    fi
}

# ── addon ────────────────────────────────────────────────────────────────────
addons_dir() {
    local d
    for d in "Interface/AddOns" "Interface/Addons" "interface/addons" "Interface/addons"; do
        [ -d "$CLIENT/$d" ] && { printf '%s' "$CLIENT/$d"; return 0; }
    done
    printf '%s' "$CLIENT/Interface/AddOns"
}

install_addon() {
    local ad; ad="$(addons_dir)"
    run mkdir -p "$ad"
    clone_or_update "$ADDON_REPO" "$ad/RuneEngraver"
}

# enus_dir → the client locale dir where the build scripts write the patch MPQs
# (build_sod_*_patch.py use <client>/data/enus). Probe case variants, then fall
# back to the lowercase path the builders use.
enus_dir() {
    local d
    for d in "data/enus" "Data/enus" "Data/Enus" "data/Enus"; do
        [ -d "$CLIENT/$d" ] && { printf '%s' "$CLIENT/$d"; return 0; }
    done
    printf '%s' "$CLIENT/data/enus"
}

# ── config persistence ───────────────────────────────────────────────────────
save_config() {
    run mkdir -p "$CONFIG_DIR"
    [ "$DRY_RUN" -eq 1 ] && { printf '   dry: write %s\n' "$CONFIG_FILE"; return 0; }
    { printf 'server=%s\n' "$SERVER"; printf 'client=%s\n' "$CLIENT"
      printf 'build=%s\n' "$BUILD_METHOD"
      printf 'rune=%s\n' "$SEL_RUNE"; printf 'world=%s\n' "$SEL_WORLD"; printf 'mage=%s\n' "$SEL_MAGE"
    } > "$CONFIG_FILE"
}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 1
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            server) SERVER="$v" ;; client) CLIENT="$v" ;; build) BUILD_METHOD="$v" ;;
            rune) SEL_RUNE="$v" ;; world) SEL_WORLD="$v" ;; mage) SEL_MAGE="$v" ;;
        esac
    done < "$CONFIG_FILE"
    return 0
}

# ── build method ─────────────────────────────────────────────────────────────
# A Docker install and a native cmake build use the same source tree (the
# AzerothCore checkout always ships docker-compose.yml), so we can't infer intent
# from files — ask once and remember it. --docker/--source skip the prompt.
resolve_build_method() {
    [ -n "$PRESET_BUILD" ] && BUILD_METHOD="$PRESET_BUILD"
    [ -n "$BUILD_METHOD" ] && return 0          # from flag or saved config
    if [ ! -t 0 ]; then BUILD_METHOD="source"; return 0; fi
    echo
    echo "How do you build and run your server?"
    echo "  1) Source build   (cmake + make)        [default]"
    echo "  2) Docker         (docker compose)"
    local c; read -r -p "Choice [1]: " c || true; c="${c:-1}"
    [ "$c" = "2" ] && BUILD_METHOD="docker" || BUILD_METHOD="source"
}

# print_rebuild_cmd: the one command line that recompiles the worldserver with
# the freshly-cloned modules, for whichever build method is in effect.
print_rebuild_cmd() {
    if [ "$BUILD_METHOD" = "docker" ]; then
        echo "       cd \"$SERVER\" && docker compose build && docker compose up -d"
    else
        echo "       cd <build> && cmake .. -DMODULES=static && make -j\$(nproc) && make install"
    fi
}

# ── docker auto-build (opt-in) ───────────────────────────────────────────────
detect_compose() {
    DOCKER_COMPOSE=""
    command -v docker >/dev/null 2>&1 || return 1
    if   docker compose version >/dev/null 2>&1; then DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then DOCKER_COMPOSE="docker-compose"
    else return 1; fi
    return 0
}

# dc <args…>: run a compose subcommand from the server root (so docker-compose.yml
# and docker-compose.override.yml are both picked up), honoring --dry-run.
dc() { run sh -c "cd \"$SERVER\" && $DOCKER_COMPOSE $*"; }

# docker_rebuild: the actual work — stop the stack, recompile the worldserver
# image, bring it back up, then follow the worldserver log. Assumes DOCKER_COMPOSE
# is set. Sets DID_BUILD on success. Honors --dry-run. (Split from the interactive
# wrapper so it can be unit-tested without a TTY.)
docker_rebuild() {
    if [ "$DRY_RUN" -ne 1 ] && ! docker info >/dev/null 2>&1; then
        warn "Can't reach the Docker daemon (is it running? are you in the 'docker' group?)."
        warn "Skipping the auto-rebuild — run it yourself when ready:"
        print_rebuild_cmd
        return 0
    fi
    log "Stopping containers ($DOCKER_COMPOSE down)…"
    dc down
    log "Recompiling the worldserver image ($DOCKER_COMPOSE build) — output streams below…"
    if ! dc build; then
        warn "Build failed; containers are left stopped. Fix the error and re-run:"
        print_rebuild_cmd
        return 1
    fi
    log "Starting containers ($DOCKER_COMPOSE up -d)…"
    dc up -d
    DID_BUILD=1
    ok "Containers are up. Following the worldserver log — Ctrl-C to stop watching"
    echo "   (the server keeps running after you detach)."
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   dry: cd "%s" && %s logs -f ac-worldserver\n' "$SERVER" "$DOCKER_COMPOSE"
        return 0
    fi
    sh -c "cd \"$SERVER\" && $DOCKER_COMPOSE logs -f ac-worldserver" || true
}

# offer_docker_build: opt-in wrapper around docker_rebuild. No-op unless the build
# method is Docker and we have an interactive terminal; prompts before doing work.
offer_docker_build() {
    [ "$BUILD_METHOD" = "docker" ] || return 0
    [ -t 0 ] || return 0
    if ! detect_compose; then
        warn "Docker / compose not found — skipping the auto-rebuild offer."
        return 0
    fi
    echo
    warn "This restarts your server: the running containers are stopped, the"
    warn "worldserver is recompiled with the new modules, then brought back up."
    ask_yn "Rebuild and restart the worldserver in Docker now?" N || return 0
    docker_rebuild
}

# ── next steps ───────────────────────────────────────────────────────────────
print_next_steps() {
    echo
    ok "Done."
    echo
    if [ "$BUILD_METHOD" = "docker" ]; then
        if [ "$DID_BUILD" -eq 1 ]; then
            echo "Next steps:"
            echo "  1. Worldserver was rebuilt and restarted above — modules are live."
            echo "     (Each module defaults to ENABLED in code; SQL auto-applied on container start.)"
        else
            echo "Next steps (you rebuild the worldserver image):"
            echo "  1. Recompile the worldserver with the new modules and recreate the containers:"
            print_rebuild_cmd
            echo "     Each module defaults to ENABLED in code, so they run with no config editing."
            echo "  2. Module SQL auto-applies on container start (the acore DB auto-updater)."
        fi
    else
        echo "Next steps (you build the worldserver):"
        echo "  1. Build AzerothCore with the modules statically linked:"
        print_rebuild_cmd
        echo "     The build installs each module's <name>.conf.dist to etc/modules/, and every"
        echo "     module defaults to ENABLED in code — so they run with no config editing."
        echo "  2. Module SQL auto-applies on first start (DB auto-updater), or apply"
        echo "     modules/*/data/sql/db-world/base/*.sql to acore_world manually."
    fi
    [ "$SEL_RUNE" -eq 1 ] && echo "  3. In-game: open the Rune Engraver panel from the character sheet (top-right)."
    if [ "$BUILD_METHOD" != "docker" ]; then
        echo
        echo "  Optional — to tweak a setting, materialize editable .conf copies after building:"
        echo "       for f in etc/modules/*.conf.dist; do cp -n \"\$f\" \"\${f%.dist}\"; done"
    fi
    echo
    echo "  Re-run with --update any time to pull the latest and rebuild the patches."
}

# ── status overview ──────────────────────────────────────────────────────────
clear_screen() { if command -v clear >/dev/null 2>&1; then clear; else printf '\033[2J\033[3J\033[H'; fi; }

print_banner() {
    printf '%s════════════════════════════════════════════════════════════%s\n' "$c_info" "$c_reset"
    printf '%s  Season of Discovery — module & addon installer%s\n' "$c_info" "$c_reset"
    printf '   %s%s%s\n' "$c_gray" "$( is_wsl && echo 'WSL' || echo 'Linux' )$( [ "$DRY_RUN" -eq 1 ] && echo '  ·  dry-run' )" "$c_reset"
    printf '%s════════════════════════════════════════════════════════════%s\n\n' "$c_info" "$c_reset"
}

# repo_status <git-dir> → echoes: notinstalled | installed | update | local
repo_status() {
    local dir="$1" head remote base
    [ -d "$dir/.git" ] || { echo notinstalled; return; }
    [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] || { echo local; return; }
    git -C "$dir" fetch --quiet origin "$BRANCH" 2>/dev/null || { echo installed; return; }
    head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    remote="$(git -C "$dir" rev-parse FETCH_HEAD 2>/dev/null)" || { echo installed; return; }
    base="$(git -C "$dir" merge-base HEAD FETCH_HEAD 2>/dev/null)"
    if   [ "$head" = "$remote" ]; then echo installed
    elif [ "$head" = "$base"   ]; then echo update
    else echo local
    fi
}

print_status_row() { # <name> <status>
    local name="$1" st="$2" label color
    case "$st" in
        installed)    label="Installed";        color="$c_ok"   ;;
        update)       label="Update Available"; color="$c_blue" ;;
        notinstalled) label="Not Installed";    color="$c_gray" ;;
        local)        label="Local Changes";    color="$c_gold" ;;
    esac
    printf '  %-26s %s%s%s\n' "$name" "$color" "$label" "$c_reset"
}

show_status() {
    echo "Current install status:"
    print_status_row "Rune Engraving (engine)" "$(repo_status "$SERVER/modules/mod-rune-engraving")"
    print_status_row "RuneEngraver addon"      "$(repo_status "$(addons_dir)/RuneEngraver")"
    print_status_row "SoD World"               "$(repo_status "$SERVER/modules/mod-sod-world")"
    print_status_row "SoD Mage"                "$(repo_status "$SERVER/modules/mod-sod-mage")"
    echo
}

# explain_pick <title-line> <tree-line>...  — describe what folder we want and
# show the expected layout with an arrow at the folder to select, then pause so
# the picker doesn't pop up unannounced.
explain_pick() {
    local title="$1"; shift
    echo
    printf '%s%s%s\n' "$c_info" "$title" "$c_reset"
    local line
    for line in "$@"; do printf '   %s\n' "$line"; done
    echo
    if [ -t 0 ]; then read -r -p "Press Enter to open the folder picker… " _ || true; fi
}

# Resolve the server + client paths (saved config or the picker) up front, so the
# status check can inspect both the modules and the addon.
resolve_paths() {
    if ! is_wsl && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && ! command -v zenity >/dev/null 2>&1; then
        ensure_cmd zenity zenity || true
    fi
    # An explicit --server/--client flag overrides whatever load_config restored.
    [ -n "$PRESET_SERVER" ] && SERVER="$PRESET_SERVER"
    [ -n "$PRESET_CLIENT" ] && CLIENT="$PRESET_CLIENT"
    if ! { [ -n "$SERVER" ] && [ -d "$SERVER/modules" ]; }; then
        if [ -z "$PRESET_SERVER" ]; then
            explain_pick "Where is your AzerothCore SERVER? Select its root folder — the one that contains 'modules':" \
                "${c_gray}# the WoW emulator source tree${c_reset}" \
                "azeroth-server/        ${c_ok}<- select this folder${c_reset}" \
                "├── apps/" \
                "├── src/" \
                "└── modules/"
        fi
        resolve_path SERVER "$PRESET_SERVER" "Select your AzerothCore server root (the folder that contains modules)" "modules"
    fi
    if ! { [ -n "$CLIENT" ] && [ -d "$CLIENT/Data" ]; }; then
        if [ -z "$PRESET_CLIENT" ]; then
            explain_pick "Where is your WoW 3.3.5a CLIENT? Select its root folder — the one that contains 'Data' and 'Interface':" \
                "${c_gray}# your 3.3.5a client install${c_reset}" \
                "World of Warcraft/      ${c_ok}<- select this folder${c_reset}" \
                "├── Wow.exe" \
                "├── Data/             ${c_gray}# patch MPQs go here${c_reset}" \
                "└── Interface/        ${c_gray}# the addon goes here${c_reset}"
        fi
        resolve_path CLIENT "$PRESET_CLIENT" "Select your WoW 3.3.5a client root (the folder that contains Data and Interface)" "Data"
    fi
}

startup() {
    [ "$DRY_RUN" -eq 1 ] || clear_screen
    print_banner
    ensure_cmd git
    load_config || true
    resolve_paths
    save_config          # persist paths now, so exiting later still remembers them
    [ "$DRY_RUN" -eq 1 ] || { clear_screen; print_banner; }
    show_status
}

# ── flows ────────────────────────────────────────────────────────────────────
do_install() {
    choose_components
    resolve_build_method
    save_config
    [ "$SEL_RUNE"  -eq 1 ] && clone_or_update mod-rune-engraving "$SERVER/modules/mod-rune-engraving"
    [ "$SEL_WORLD" -eq 1 ] && clone_or_update mod-sod-world      "$SERVER/modules/mod-sod-world"
    [ "$SEL_MAGE"  -eq 1 ] && clone_or_update mod-sod-mage       "$SERVER/modules/mod-sod-mage"
    build_patches
    [ "$SEL_RUNE" -eq 1 ] && install_addon
    offer_docker_build
    print_next_steps
}

do_update() {
    # paths + status already established by startup(); discover what's installed
    SEL_RUNE=0; SEL_WORLD=0; SEL_MAGE=0
    [ -d "$SERVER/modules/mod-rune-engraving/.git" ] && SEL_RUNE=1
    [ -d "$SERVER/modules/mod-sod-world/.git" ]      && SEL_WORLD=1
    [ -d "$SERVER/modules/mod-sod-mage/.git" ]       && SEL_MAGE=1
    [ $((SEL_RUNE + SEL_WORLD + SEL_MAGE)) -gt 0 ] || die "No installed modules found under $SERVER/modules — run an install first."
    [ -n "$PRESET_BUILD" ] && BUILD_METHOD="$PRESET_BUILD"   # honor a flag; else keep saved value
    save_config
    log "Updating installed components…"
    [ "$SEL_RUNE"  -eq 1 ] && clone_or_update mod-rune-engraving "$SERVER/modules/mod-rune-engraving"
    [ "$SEL_WORLD" -eq 1 ] && clone_or_update mod-sod-world      "$SERVER/modules/mod-sod-world"
    [ "$SEL_MAGE"  -eq 1 ] && clone_or_update mod-sod-mage       "$SERVER/modules/mod-sod-mage"
    build_patches
    if [ "$SEL_RUNE" -eq 1 ]; then
        local ad; ad="$(addons_dir)"
        [ -d "$ad/RuneEngraver/.git" ] && clone_or_update "$ADDON_REPO" "$ad/RuneEngraver"
    fi
    offer_docker_build
    if [ "$DID_BUILD" -eq 1 ]; then
        echo; ok "Update complete — worldserver rebuilt and restarted."
    else
        echo; ok "Update complete. Rebuild your worldserver to pick up module changes:"
        print_rebuild_cmd
    fi
}

# ── uninstall ────────────────────────────────────────────────────────────────
# remove_repo <name> <dir>: safety-gated delete of a cloned checkout. Skips a
# non-checkout, and (unless --force) skips a repo with local changes / unpushed
# commits — repo_status returns "local" for those, the same signal the status
# table shows. Honors --dry-run via run.
remove_repo() {
    local name="$1" dir="$2" st
    [ -e "$dir" ] || { warn "$name: not present — nothing to remove."; return 0; }
    if [ ! -d "$dir/.git" ]; then
        warn "$name: '$dir' is not a git checkout — leaving it alone."
        return 0
    fi
    st="$(repo_status "$dir")"
    if [ "$st" = "local" ] && [ "$FORCE" -ne 1 ]; then
        warn "$name: has local changes or unpushed commits — skipping (use --force to remove)."
        return 0
    fi
    log "Removing $name → $dir"
    run rm -rf "$dir"
}

remove_addon() {
    remove_repo "$ADDON_REPO addon" "$(addons_dir)/RuneEngraver"
}

# remove_patches: delete only our own generated MPQ letters; base client data is
# never touched. World owns patch-enus-y (items), Mage owns patch-enus-z (spells).
remove_patches() {
    local ed; ed="$(enus_dir)"
    if [ "$SEL_WORLD" -eq 1 ] && [ -f "$ed/patch-enus-y.mpq" ]; then
        log "Removing item patch → $ed/patch-enus-y.mpq"; run rm -f "$ed/patch-enus-y.mpq"
    fi
    if [ "$SEL_MAGE" -eq 1 ] && [ -f "$ed/patch-enus-z.mpq" ]; then
        log "Removing spell patch → $ed/patch-enus-z.mpq"; run rm -f "$ed/patch-enus-z.mpq"
    fi
}

# choose what to remove: option 1 = everything installed (default), option 2 =
# custom. Honors --all / --components. Defaults each component to "installed".
choose_uninstall_components() {
    SEL_RUNE=0; SEL_WORLD=0; SEL_MAGE=0
    local have_rune=0 have_world=0 have_mage=0
    [ -d "$SERVER/modules/mod-rune-engraving/.git" ] && have_rune=1
    [ -d "$SERVER/modules/mod-sod-world/.git" ]      && have_world=1
    [ -d "$SERVER/modules/mod-sod-mage/.git" ]       && have_mage=1

    if [ -n "$PRESET_COMPONENTS" ]; then
        case ",$PRESET_COMPONENTS," in *,all,*) SEL_RUNE=1; SEL_WORLD=1; SEL_MAGE=1 ;; esac
        case ",$PRESET_COMPONENTS," in *,rune,*)  SEL_RUNE=1  ;; esac
        case ",$PRESET_COMPONENTS," in *,world,*) SEL_WORLD=1 ;; esac
        case ",$PRESET_COMPONENTS," in *,mage,*)  SEL_MAGE=1  ;; esac
    elif [ ! -t 0 ]; then
        SEL_RUNE=$have_rune; SEL_WORLD=$have_world; SEL_MAGE=$have_mage
    else
        echo
        echo "What would you like to remove?"
        echo "  1) Everything installed   [default]"
        echo "  2) Custom                 (choose components)"
        local choice; read -r -p "Choice [1]: " choice || true; choice="${choice:-1}"
        if [ "$choice" = "1" ]; then
            SEL_RUNE=$have_rune; SEL_WORLD=$have_world; SEL_MAGE=$have_mage
        else
            [ "$have_rune" -eq 1 ]  && { ask_yn "Remove Rune Engraving (engine + addon)?" Y && SEL_RUNE=1; }
            [ "$have_world" -eq 1 ] && { ask_yn "Remove SoD World?"                        Y && SEL_WORLD=1; }
            [ "$have_mage" -eq 1 ]  && { ask_yn "Remove SoD Mage?"                         Y && SEL_MAGE=1; }
        fi
    fi
    [ $((SEL_RUNE + SEL_WORLD + SEL_MAGE)) -gt 0 ] || die "Nothing selected to remove."
    resolve_remove_deps
}

# warnings only (reverse of resolve_deps): point out when a partial removal leaves
# SoD Mage depending on a piece that's going away. Never changes the selection.
resolve_remove_deps() {
    local mage_stays=0
    [ "$SEL_MAGE" -eq 0 ] && [ -d "$SERVER/modules/mod-sod-mage/.git" ] && mage_stays=1
    if [ "$mage_stays" -eq 1 ] && [ "$SEL_WORLD" -eq 1 ]; then
        warn "Removing SoD World while SoD Mage stays: mage item icons lose their"
        warn "patch (patch-enus-y.mpq) and the Mass Regeneration Lich drop is gone."
    fi
    if [ "$mage_stays" -eq 1 ] && [ "$SEL_RUNE" -eq 1 ]; then
        warn "Removing Rune Engraving while SoD Mage stays: the spells still work via"
        warn "GM '.learn', but they can no longer be engraved as runes."
    fi
}

do_uninstall() {
    choose_uninstall_components

    # Full uninstall = removing every SoD piece currently installed → also drop
    # the saved config so a future install starts clean.
    local remove_config=0
    if [ ! -d "$SERVER/modules/mod-rune-engraving/.git" -o "$SEL_RUNE" -eq 1 ] \
    && [ ! -d "$SERVER/modules/mod-sod-world/.git" -o "$SEL_WORLD" -eq 1 ] \
    && [ ! -d "$SERVER/modules/mod-sod-mage/.git" -o "$SEL_MAGE" -eq 1 ]; then
        remove_config=1
    fi

    local ad ed; ad="$(addons_dir)"; ed="$(enus_dir)"
    echo
    echo "The following will be removed:"
    [ "$SEL_RUNE"  -eq 1 ] && echo "  - $SERVER/modules/mod-rune-engraving"
    [ "$SEL_RUNE"  -eq 1 ] && echo "  - $ad/RuneEngraver"
    [ "$SEL_WORLD" -eq 1 ] && echo "  - $SERVER/modules/mod-sod-world"
    [ "$SEL_WORLD" -eq 1 ] && [ -f "$ed/patch-enus-y.mpq" ] && echo "  - $ed/patch-enus-y.mpq"
    [ "$SEL_MAGE"  -eq 1 ] && echo "  - $SERVER/modules/mod-sod-mage"
    [ "$SEL_MAGE"  -eq 1 ] && [ -f "$ed/patch-enus-z.mpq" ] && echo "  - $ed/patch-enus-z.mpq"
    [ "$remove_config" -eq 1 ] && [ -f "$CONFIG_FILE" ] && echo "  - $CONFIG_FILE  (saved installer config)"
    echo
    echo "Your database is NOT touched (see the note below). Repos with local changes"
    echo "are skipped unless --force."
    echo

    if [ "$DRY_RUN" -ne 1 ]; then
        ask_yn "Delete these now? This cannot be undone." N || { warn "Aborted — nothing removed."; return 0; }
    fi

    [ "$SEL_RUNE"  -eq 1 ] && { remove_repo "mod-rune-engraving" "$SERVER/modules/mod-rune-engraving"; remove_addon; }
    [ "$SEL_WORLD" -eq 1 ] && remove_repo "mod-sod-world" "$SERVER/modules/mod-sod-world"
    [ "$SEL_MAGE"  -eq 1 ] && remove_repo "mod-sod-mage"  "$SERVER/modules/mod-sod-mage"
    remove_patches

    if [ "$remove_config" -eq 1 ] && [ -f "$CONFIG_FILE" ]; then
        log "Removing saved config → $CONFIG_FILE"; run rm -f "$CONFIG_FILE"
    fi

    # Rebuild the worldserver WITHOUT the removed modules so the removal takes
    # effect (docker: offer it; source: print the note via the fall-through).
    offer_docker_build

    echo
    ok "Uninstall complete."
    echo
    echo "Database note: the modules' custom rows in acore_world (spell_dbc, items,"
    echo "the Awakened Lich, rune catalog entries) are left in place. They become"
    echo "inert once the worldserver is rebuilt without the modules' scripts. Drop"
    echo "them manually only if you want a pristine DB."
    if [ "$DID_BUILD" -ne 1 ]; then
        echo
        echo "Rebuild your worldserver (without the modules) to finish:"
        print_rebuild_cmd
    fi
}

usage() {
    # print the header comment block (lines after the shebang, up to the first
    # non-comment line) with the leading "# " stripped. BASH_SOURCE (not $0) so it
    # works whether the script is executed or sourced (e.g. by the test suite).
    awk 'NR>1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "${BASH_SOURCE[0]}"
    exit 0
}

# ── argument parsing ─────────────────────────────────────────────────────────
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)    DRY_RUN=1 ;;
            --install)    ACTION="install" ;;
            --update)     ACTION="update" ;;
            --uninstall)  ACTION="uninstall" ;;
            --force)      FORCE=1 ;;
            --yes|-y)     ASSUME_YES=1 ;;
            --all)        PRESET_COMPONENTS="all" ;;
            --docker)     PRESET_BUILD="docker" ;;
            --source|--cmake) PRESET_BUILD="source" ;;
            --components) PRESET_COMPONENTS="${2:-}"; shift ;;
            --components=*) PRESET_COMPONENTS="${1#*=}" ;;
            --server)     PRESET_SERVER="${2:-}"; shift ;;
            --server=*)   PRESET_SERVER="${1#*=}" ;;
            --client)     PRESET_CLIENT="${2:-}"; shift ;;
            --client=*)   PRESET_CLIENT="${1#*=}" ;;
            -h|--help)    usage ;;
            *) die "Unknown argument: $1 (try --help)" ;;
        esac
        shift
    done
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    # Support `curl … | bash`: stdin is the piped script, so reconnect it to the
    # terminal (if there is one) so interactive prompts and the picker work.
    [ -t 0 ] || { [ -r /dev/tty ] && exec < /dev/tty; }
    setup_pkg_mgr
    startup
    case "$ACTION" in
        install)   do_install ;;
        update)    do_update ;;
        uninstall) do_uninstall ;;
    esac
}

# Run main only when executed directly; when sourced (e.g. by the test suite),
# expose the functions without running anything.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
