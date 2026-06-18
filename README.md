# sod-installer

One-click installer for the **Season of Discovery** AzerothCore content and the
**RuneEngraver** client addon. It clones the modules into your server, builds the
client MPQ patches, and drops the addon into your WoW client — then you build the
worldserver as usual. Works on **native Linux** and **WSL**.

## Quick start

```bash
# clone and run
git clone https://github.com/bennybroseph/sod-installer.git
cd sod-installer && ./install.sh

# …or one-liner
curl -sSL https://raw.githubusercontent.com/bennybroseph/sod-installer/main/install.sh | bash
```

You'll pick what to install and point it at two folders (your AzerothCore **server
root** that contains `modules/`, and your **WoW 3.3.5a client root**) using a native
folder picker.

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
3. Builds the needed client patches (`patch-enus-y.mpq` items, `patch-enus-z.mpq`
   spells) into `<client>/Data/enus/`. **Close WoW first** — it locks those files.
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

## Options

```
--update              refresh an existing install instead of installing
--dry-run             print every action without changing anything (great first run)
--all                 select everything (no menu)
--components a,b,c     choose components non-interactively (rune,world,mage)
--server DIR          server root (skip the picker)
--client DIR          WoW client root (skip the picker)
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

## License

MIT — see [LICENSE](LICENSE).
