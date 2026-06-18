# sod-installer

[![CI](https://github.com/bennybroseph/sod-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/bennybroseph/sod-installer/actions/workflows/ci.yml)

One-click installer for the **Season of Discovery** AzerothCore content and the
**RuneEngraver** client addon. It clones the modules into your server, builds the
client MPQ patches, and drops the addon into your WoW client — then you build the
worldserver as usual. Works on **native Linux** and **WSL**.

## Quick start

```bash
# clone and run
git clone https://github.com/bennybroseph/sod-installer.git
cd sod-installer && bash install.sh        # (or ./install.sh if it's executable)

# …or one-liner
curl -sSL https://raw.githubusercontent.com/bennybroseph/sod-installer/main/install.sh | bash
```

Running it with no flags opens a menu to choose **Install**, **Update**, or
**Uninstall**. You then point it at two folders (your AzerothCore **server root**
that contains `modules/`, and your **WoW 3.3.5a client root**) using a native
folder picker. (The `--install` / `--update` / `--uninstall` flags skip the menu.)

## What you can install

The first menu option is **Everything**. Or pick a subset:

| Component | Installs | Notes |
|-----------|----------|-------|
| **Rune Engraving** | `mod-rune-engraving` engine **+ the RuneEngraver addon** | bundled together (the addon is the engine's UI) |
| **SoD World** | `mod-sod-world` (the shared Awakened Lich encounter) | also owns the consolidated item-icon patch |
| **SoD Mage** | `mod-sod-mage` (mage spells & runes) | pulls in **SoD World** (for Mass Regeneration's Lich drop + item icons); recommends **Rune Engraving** so you can engrave the runes |

## What it does

It opens with a **colored status overview** of what you already have — each piece
shown as `Installed` (green), `Update Available` (blue), `Not Installed` (gray), or
`Local Changes` (gold) — then:

1. Auto-installs missing prerequisites (`git`, and `python3` + `pympq` if a patch
   needs building; `zenity` for the picker on Linux).
2. Clones the selected modules into `<server>/modules/`.
3. Builds the needed client patches — item patches (letter `y`) and spell patches
   (letter `z`) — written to both `<client>/Data/<locale>/` (e.g. `patch-enus-y.mpq`)
   and `<client>/Data/` (e.g. `patch-y.mpq`). **Close WoW first** — it locks those files.
4. Clones the RuneEngraver addon into `<client>/Interface/AddOns/`.
5. Prints your next steps. **You build the worldserver** (`-DMODULES=static`).

> Module config is **zero-touch**: every module defaults to enabled, and the
> worldserver build installs the `.conf.dist` files — nothing to edit.

## Staying up to date

```bash
./install.sh --update
```

Pulls the latest for whatever you already installed (modules + addon) and rebuilds
the patches. Paths are remembered from your install, so there's nothing to re-pick.

## Uninstalling

```bash
./install.sh --uninstall
```

Removes the cloned modules, the RuneEngraver addon, and the generated client
patches (the `y`/`z` letters in both `Data/<locale>/` and `Data/`) — and, on a full
uninstall, the saved config too. It
opens with the same status table, shows **exactly what will be deleted**, and asks
to confirm (default No). Pick **Everything** or a subset, just like install.

- **Your work is safe:** a repo with uncommitted or unpushed changes is **skipped**
  (re-run with `--force` to remove it anyway). Only our own generated patch MPQs are
  deleted — base client data is never touched.
- **Your database is left alone.** The modules' custom `acore_world` rows become
  inert once you rebuild the worldserver without the modules; drop them by hand only
  if you want a pristine DB. (Docker users get the same opt-in rebuild offer.)

## Options

```
--update              refresh an existing install instead of installing
--uninstall           remove the modules, addon, and generated client patches
--force               with --uninstall: also remove repos that have local changes
--yes, -y             answer yes to every prompt (for non-interactive automation)
--dry-run             print every action without changing anything (great first run)
--all                 select everything (no menu)
--components a,b,c     choose components non-interactively (rune,world,mage)
--server DIR          server root (skip the picker)
--client DIR          WoW client root (skip the picker)
--docker | --source   set the build method (otherwise asked once, then remembered)
-h, --help
```

## Safe to run anytime

It's **non-destructive**: it only `git clone`s missing repos or `git pull --ff-only`s
existing ones (which safely refuses if you have local/uncommitted changes — your work
is never reset or deleted). Dependencies install only if actually missing. Try
`--dry-run` first to preview.

## Requirements

A working AzerothCore source tree (you supply it and build it) and a WoW **3.3.5a**
client. The MPQ patch step needs Python + `pympq` (StormLib); on WSL it uses your
Windows Python, on Linux it pip-installs `pympq`. If `pympq` can't be installed the
installer still clones everything and just prints the manual patch commands.

## Continuous integration

GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs on every
push and PR: `shellcheck`, the unit suite (`test/run_tests.sh`), and a dry-run smoke
of install + uninstall. A separate non-blocking job exercises the **real**
clone → install → uninstall lifecycle against the live module/addon repos. (The MPQ
patch build isn't covered in CI — it needs the client's copyrighted DBC files — but
the installer skips it gracefully there.)

Run the unit tests locally with `bash test/run_tests.sh`.

## License

MIT — see [LICENSE](LICENSE).
