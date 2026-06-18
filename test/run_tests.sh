#!/usr/bin/env bash
#
# Unit tests for ../install.sh
#
# install.sh is sourced (its `main` is guarded behind a BASH_SOURCE check, so
# sourcing just defines the functions). Each test resets the globals it touches,
# works in its own temp dir, and runs everything in --dry-run unless it is
# explicitly checking real filesystem removal.
#
#   Usage: ./test/run_tests.sh        (exit 0 = all passed, 1 = failures)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../install.sh"
[ -f "$SCRIPT" ] || { echo "cannot find install.sh at $SCRIPT" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SCRIPT"

PASS=0; FAIL=0
ok_t() { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
no_t() { printf '  FAIL - %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq()           { [ "$1" = "$2" ] && ok_t "$3" || no_t "$3 (expected [$1], got [$2])"; }
assert_contains()     { case "$1" in *"$2"*) ok_t "$3" ;; *) no_t "$3 (missing [$2])" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) no_t "$3 (unexpected [$2])" ;; *) ok_t "$3" ;; esac; }
assert_absent()       { [ ! -e "$1" ] && ok_t "$2" || no_t "$2 ($1 still exists)"; }
assert_present()      { [ -e "$1" ] && ok_t "$2" || no_t "$2 ($1 missing)"; }
# cap <fn> [args…] — run in the CURRENT shell (so global side-effects persist,
# unlike $(...)), capturing combined output into CAP.
CAP=""
cap() { local tf; tf="$(mktemp)"; "$@" >"$tf" 2>&1; CAP="$(cat "$tf")"; rm -f "$tf"; }

# isolate config + colors so output is plain and nothing real is touched
export XDG_CONFIG_HOME; XDG_CONFIG_HOME="$(mktemp -d)"
CONFIG_DIR="$XDG_CONFIG_HOME/sod-installer"; CONFIG_FILE="$CONFIG_DIR/config"
c_reset=""; c_info=""; c_warn=""; c_err=""; c_ok=""; c_blue=""; c_gray=""; c_gold=""

reset_state() {
    DRY_RUN=1; FORCE=0; ASSUME_YES=0; ACTION="install"
    SERVER=""; CLIENT=""; BUILD_METHOD=""
    PRESET_SERVER=""; PRESET_CLIENT=""; PRESET_COMPONENTS=""; PRESET_BUILD=""
    SEL_RUNE=0; SEL_WORLD=0; SEL_MAGE=0
    DOCKER_COMPOSE=""; DID_BUILD=0
}
mkrepo() { # mkrepo <dir> — a real, committed (clean) git checkout with no remote
    mkdir -p "$1"; git -C "$1" init -q
    git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

# ── tests ────────────────────────────────────────────────────────────────────
t_parse_args() {
    reset_state
    parse_args --uninstall --force --docker --components world --server /s --client /c
    assert_eq "uninstall" "$ACTION"          "parse_args: --uninstall sets ACTION"
    assert_eq "1" "$FORCE"                    "parse_args: --force sets FORCE"
    assert_eq "docker" "$PRESET_BUILD"        "parse_args: --docker sets PRESET_BUILD"
    assert_eq "world" "$PRESET_COMPONENTS"    "parse_args: --components"
    assert_eq "/s" "$PRESET_SERVER"           "parse_args: --server"
}

t_parse_yes() {
    reset_state; parse_args --yes;        assert_eq "1" "$ASSUME_YES" "parse_args: --yes sets ASSUME_YES"
    reset_state; parse_args -y;           assert_eq "1" "$ASSUME_YES" "parse_args: -y sets ASSUME_YES"
}

t_ask_yn_assume_yes() {
    reset_state; ASSUME_YES=1
    if ask_yn "q" N </dev/null; then ok_t "ask_yn: --yes overrides the No default"
    else no_t "ask_yn: --yes overrides the No default (returned non-zero)"; fi
}

t_repo_status() {
    reset_state; local d; d="$(mktemp -d)"
    assert_eq "notinstalled" "$(repo_status "$d/nope")" "repo_status: missing -> notinstalled"
    mkrepo "$d/clean"
    assert_eq "installed" "$(repo_status "$d/clean")"   "repo_status: clean, no remote -> installed"
    mkrepo "$d/dirty"; : > "$d/dirty/untracked"
    assert_eq "local" "$(repo_status "$d/dirty")"       "repo_status: dirty -> local"
    rm -rf "$d"
}

t_enus_dir() {
    reset_state; local d; d="$(mktemp -d)"
    CLIENT="$d"; mkdir -p "$d/data/enus"
    assert_eq "$d/data/enus" "$(enus_dir)" "enus_dir: lowercase data/enus"
    rm -rf "$d/data"; mkdir -p "$d/Data/enus"
    assert_eq "$d/Data/enus" "$(enus_dir)" "enus_dir: Data/enus variant"
    CLIENT="/no/such"; assert_eq "/no/such/data/enus" "$(enus_dir)" "enus_dir: fallback"
    rm -rf "$d"
}

t_addons_dir() {
    reset_state; local d; d="$(mktemp -d)"
    CLIENT="$d"; mkdir -p "$d/Interface/AddOns"
    assert_eq "$d/Interface/AddOns" "$(addons_dir)" "addons_dir: AddOns variant"
    CLIENT="/no/such"; assert_eq "/no/such/Interface/AddOns" "$(addons_dir)" "addons_dir: fallback"
    rm -rf "$d"
}

t_choose_components_dep() {
    reset_state; PRESET_COMPONENTS="mage"
    cap choose_components
    assert_eq "1" "$SEL_WORLD"                 "choose_components: mage auto-adds world (preset)"
    assert_contains "$CAP" "without SoD World" "choose_components: warns mage-without-world"
}

t_resolve_remove_deps() {
    reset_state; local d; d="$(mktemp -d)"; SERVER="$d"
    mkrepo "$d/modules/mod-sod-mage"
    SEL_WORLD=1; SEL_MAGE=0; local out
    out="$(resolve_remove_deps 2>&1)"
    assert_contains "$out" "item icons lose" "resolve_remove_deps: removing world warns mage icons"
    rm -rf "$d"
}

t_remove_repo_guard() {
    reset_state; local d out; d="$(mktemp -d)"
    mkrepo "$d/r"; : > "$d/r/dirty"          # untracked -> repo_status local
    FORCE=0
    out="$(remove_repo name "$d/r" 2>&1)"
    assert_contains "$out" "skipping"        "remove_repo: dirty repo skipped without --force"
    assert_present  "$d/r"                    "remove_repo: dirty repo left in place"
    FORCE=1
    out="$(remove_repo name "$d/r" 2>&1)"
    assert_contains "$out" "Removing"        "remove_repo: --force removes dirty (dry)"
    rm -rf "$d"
}

t_remove_repo_real() {
    reset_state; local d; d="$(mktemp -d)"
    mkrepo "$d/r"; DRY_RUN=0; FORCE=0
    remove_repo name "$d/r" >/dev/null 2>&1
    assert_absent "$d/r" "remove_repo: clean repo really removed (non-dry)"
    rm -rf "$d"
}

t_remove_patches() {
    reset_state; local d out; d="$(mktemp -d)"
    CLIENT="$d"; mkdir -p "$d/data/enus"
    : > "$d/data/enus/patch-enus-y.mpq"; : > "$d/data/enus/patch-enus-z.mpq"
    SEL_WORLD=1; SEL_MAGE=0
    out="$(remove_patches 2>&1)"
    assert_contains     "$out" "patch-enus-y" "remove_patches: world patch targeted"
    assert_not_contains "$out" "patch-enus-z" "remove_patches: mage patch untouched"
    rm -rf "$d"
}

t_rebuild_cmd() {
    reset_state; SERVER="/srv"
    BUILD_METHOD="docker"; assert_contains "$(print_rebuild_cmd)" "docker compose build" "print_rebuild_cmd: docker"
    BUILD_METHOD="source"; assert_contains "$(print_rebuild_cmd)" "cmake"                "print_rebuild_cmd: source"
}

t_next_steps_docker_built() {
    reset_state; BUILD_METHOD="docker"; DID_BUILD=1
    assert_contains "$(print_next_steps)" "rebuilt and restarted above" "print_next_steps: docker+built"
}

t_docker_rebuild() {
    reset_state; BUILD_METHOD="docker"; DOCKER_COMPOSE="docker compose"; SERVER="/srv"; DRY_RUN=1
    cap docker_rebuild
    assert_contains "$CAP" "docker compose down"  "docker_rebuild: stops stack first"
    assert_contains "$CAP" "docker compose build" "docker_rebuild: rebuilds image"
    assert_contains "$CAP" "up -d"                "docker_rebuild: starts containers"
    assert_contains "$CAP" "logs -f ac-worldserver" "docker_rebuild: follows worldserver log"
    assert_eq "1" "$DID_BUILD"                    "docker_rebuild: sets DID_BUILD"
}

t_usage() {
    local out; out="$( ( usage ) 2>&1 )"
    assert_contains     "$out" "--uninstall"        "usage: lists --uninstall"
    assert_contains     "$out" "--force"            "usage: lists --force"
    assert_not_contains "$out" "set -uo pipefail"   "usage: stops at end of header block"
}

t_resolve_path_valid_preset() {
    reset_state; local d; d="$(mktemp -d)"; mkdir -p "$d/modules"
    resolve_path SERVER "$d" "title" "modules"
    assert_eq "$d" "$SERVER" "resolve_path: accepts a valid preset"
    rm -rf "$d"
}

t_do_uninstall_real() {
    reset_state
    local srv cli; srv="$(mktemp -d)"; cli="$(mktemp -d)"
    mkdir -p "$srv/modules" "$cli/Interface/AddOns" "$cli/data/enus" "$CONFIG_DIR"
    mkrepo "$srv/modules/mod-rune-engraving"
    mkrepo "$srv/modules/mod-sod-world"
    mkrepo "$srv/modules/mod-sod-mage"
    mkrepo "$cli/Interface/AddOns/RuneEngraver"
    : > "$cli/data/enus/patch-enus-y.mpq"; : > "$cli/data/enus/patch-enus-z.mpq"
    printf 'server=%s\nclient=%s\nbuild=source\n' "$srv" "$cli" > "$CONFIG_FILE"

    DRY_RUN=0; SERVER="$srv"; CLIENT="$cli"; BUILD_METHOD="source"; PRESET_COMPONENTS="all"
    ask_yn() { return 0; }                # auto-confirm the destructive prompt
    do_uninstall >/dev/null 2>&1
    unset -f ask_yn

    assert_absent "$srv/modules/mod-rune-engraving"        "do_uninstall: rune repo removed"
    assert_absent "$srv/modules/mod-sod-world"             "do_uninstall: world repo removed"
    assert_absent "$srv/modules/mod-sod-mage"              "do_uninstall: mage repo removed"
    assert_absent "$cli/Interface/AddOns/RuneEngraver"     "do_uninstall: addon removed"
    assert_absent "$cli/data/enus/patch-enus-y.mpq"        "do_uninstall: world patch removed"
    assert_absent "$cli/data/enus/patch-enus-z.mpq"        "do_uninstall: mage patch removed"
    assert_absent "$CONFIG_FILE"                           "do_uninstall: config removed (full clean)"
    rm -rf "$srv" "$cli"
}

t_blackbox_help() {
    local out; out="$(bash "$SCRIPT" --help 2>&1)"
    assert_contains "$out" "--uninstall" "blackbox: --help lists --uninstall"
}

t_blackbox_unknown_arg() {
    local rc; bash "$SCRIPT" --bogus >/dev/null 2>&1; rc=$?
    assert_eq "1" "$rc" "blackbox: unknown arg exits non-zero"
}

# ── run ──────────────────────────────────────────────────────────────────────
for t in \
    t_parse_args t_parse_yes t_ask_yn_assume_yes \
    t_repo_status t_enus_dir t_addons_dir t_choose_components_dep \
    t_resolve_remove_deps t_remove_repo_guard t_remove_repo_real t_remove_patches \
    t_rebuild_cmd t_next_steps_docker_built t_docker_rebuild t_usage \
    t_resolve_path_valid_preset t_do_uninstall_real t_blackbox_help t_blackbox_unknown_arg
do
    printf '%s\n' "$t"
    "$t"
done

echo
echo "──────────────────────────────────────────"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
