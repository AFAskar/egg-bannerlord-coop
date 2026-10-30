# Bannerlord Coop: Pelican egg and server image

Pelican egg and Docker image for a **Mount & Blade II: Bannerlord** co-op
campaign server, running the Windows dedicated build under Wine.

No game files are baked in. On boot the container reads the release
[`manifest.json`](https://github.com/Bannerlord-Coop-Team/BannerlordCoop/releases/latest/download/manifest.json)
from the [Bannerlord Coop GitHub releases](https://github.com/Bannerlord-Coop-Team/BannerlordCoop/releases),
verifies the Windows dedicated server archive against its SHA-256 and extracts
it into the server volume. The server itself needs no Steam account.

Optional Steam Workshop mods are the one exception: Bannerlord refuses Workshop
downloads for anonymous and non-owning accounts, so `WORKSHOP_MODS` requires a
`STEAM_USERNAME` for an account that owns Bannerlord. Manual modules in
`data/mods` need no account.

## What is in here

| File | What it is |
| --- | --- |
| [`egg-bannerlord-coop.json`](egg-bannerlord-coop.json) | The egg. Import this in the panel. |
| [`Dockerfile`](Dockerfile) | The yolk, built on the official Pelican wine yolk. |
| [`start.sh`](start.sh) | Boot script: release download, modules, Wine prefix, server config, launch. |
| [`compose.yaml`](compose.yaml) | Runs the same image with no panel. |

Published image `ghcr.io/afaskar/bannerlord-coop:latest`, also tagged per
commit sha. amd64 only.

## Requirements

- No Steam account is needed for the server itself. The Coop team publishes the
  Windows dedicated server package on GitHub releases. Players still need their
  own Bannerlord install to join.
- Automatic Workshop mods need a Steam account that owns Bannerlord (app
  `261550`). Steam refuses anonymous and non-owning accounts. Manual modules do
  not need an account.
- Two consecutive UDP allocations. Clients join on the first, the mod also uses
  the second.
- Disk: about 12 GB free on first boot (the ~4.2 GB archive, its extracted
  files, and a 1.6 GB Wine prefix). Allow up to ~14 GB during an update, when
  the old and new game directories coexist.

## Install on Pelican

1. Admin, Eggs, Import Egg: upload `egg-bannerlord-coop.json`.
2. Create a server on it with two consecutive UDP allocations.
3. Leave **Coop release** at `latest`, or pin a tag such as `v0.1.6`.
4. Optional: for automatic Workshop mods, set **Workshop mods** and **Steam
   username**. The account must own Bannerlord. Manual modules in `data/mods`
   need no account.
5. Start it. The first start downloads about 4.2 GB from the GitHub release and
   creates the Wine prefix.
6. Later starts read the release manifest and only download when the SHA-256
   changes. Set **Auto update** to `0` to skip GitHub and Workshop updates.

## Run without a panel

```sh
cp .env.example .env   # optionally pin COOP_VERSION
docker compose up
```

`.env` is all you need, compose loads it and wires every variable. For automatic
Workshop mods also set `WORKSHOP_MODS` and `STEAM_USERNAME` there.

`compose.yaml` also sets `STARTUP`, which a panel would send itself. For other
host ports, change the left side of both `ports:` entries.

## Variables

| Variable | Default | What it does |
| --- | --- | --- |
| `COOP_VERSION` | `latest` | GitHub release tag to install, for example `v0.1.6`. `latest` follows the newest stable release. |
| `AUTO_UPDATE` | `1` | Check GitHub and Steam Workshop for updates on every start. `0` boots what is already there. |
| `WORKSHOP_MODS` | | Optional Workshop item ids to download and load, `X,Y,Z`. Requires `STEAM_USERNAME`. |
| `STEAM_USERNAME` | | Account that owns Bannerlord. Only used with `WORKSHOP_MODS`. |
| `STEAM_PASSWORD` | | Optional. Only used with `WORKSHOP_MODS`; prompted in the console if empty. |
| `SAVE_NAME` | `saveauto1` | World to host. A missing save is created from `default_new_game.sav`. |
| `SERVER_PASSWORD` | | Password players are prompted for. Empty means open. |
| `AUTOSAVE_MINUTES` | `5` | Minutes between autosaves. `0` disables them. |

`DATA_DIR`, `GAME_DIR`, `MODS_DIR`, `STEAM_DIR` and `WINEPREFIX` are internal and
stay hidden in the panel. `MODS_DIR` defaults to `data/mods`; `STEAM_DIR`
defaults to `.steamcmd` and is only used with `WORKSHOP_MODS`. `ENGINE_PORT`
(`7210`) and `REGION` (`EU`) set the engine's internal custom-server arguments
and are not the port players join on.

## Mods

There are two ways to add modules. Both load after Coop, and the engine module
list is built from manual modules first and Workshop modules second.

### Manual modules (no Steam account)

Put each module folder in `data/mods` (the panel's file manager can upload it; in
the compose layout that is `server-data/mods`), then restart. The folder must be
the one that contains `SubModule.xml`; some archives nest it one level down,
which `start.sh` also finds.

Manual modules load in folder-name order. Prefix folders (`10-Foo`, `20-Bar`)
when order matters. Because `data/mods` is in the data directory, modules
survive a game update.

### Steam Workshop modules (owning account required)

Set `WORKSHOP_MODS` to the Workshop item ids and `STEAM_USERNAME` to an account
that owns Bannerlord:

```sh
WORKSHOP_MODS=3010984416,3794802607
STEAM_USERNAME=your-account
```

Steam refuses Bannerlord Workshop downloads for anonymous accounts and for
accounts that do not own app `261550`. Login succeeds, but every Bannerlord item
fails with `ERROR! Download item ... failed (Failure)`. The account must own the
game.

`STEAM_PASSWORD` is optional: leave it empty and steamcmd prompts for it in the
console. The first login may also ask for a Steam Guard code. steamcmd caches a
token in `STEAM_DIR` afterwards, so later starts are unattended.

Workshop items are downloaded into `STEAM_DIR` and linked after the manual
modules, in the order listed. `AUTO_UPDATE=0` skips both the game update and the
Workshop update. Removing an id unlinks that module on the next start; delete its
folder under `STEAM_DIR` to reclaim the disk space.

Each module is linked into the server's `engine/Modules` under the id its
`SubModule.xml` declares, and the module list handed to the engine becomes:

```
_MODULES_*Native*SandBoxCore*Sandbox*Coop*<manual mods>*<workshop mods>*DedicatedServer.Windows*_MODULES_
```

The Coop id is read from the Coop module, so it is `Coop` on stable builds and
`CoopNightly` on nightlies.

Three rules decide whether a mod works here:

- **It must ship `bin/Win64_Shipping_Server`.** The dedicated server loads module
  code from there, never from `Win64_Shipping_Client`. A client-only mod is
  listed and its XML applies, but none of its code runs.
- **Mods needing `Bannerlord.Harmony` do not work yet.** Coop bundles its own
  MonoMod; giving Harmony a server build makes Coop's `GameInterface.dll` fail to
  load, in either load order. [ModderLords](https://github.com/PlueRyvius/ModderLords)
  solves this with an assembly-resolution hook, which this egg does not carry.
- **Every player needs the identical set, at identical versions.** The server
  compares module lists on join and refuses a client that has one the server
  lacks, or the other way round.

Use a mod release built for the same game version as the dedicated server
package; an older server build is refused or crashes.

## Ports

Clients join on `port` in `server-config.json`, set from the primary allocation
on every start. The mod uses that port and the one above it.

`ENGINE_PORT` is not the join port. It is the engine's internal custom-server
port, default 7210, so pointing it at your allocation gives a server that boots
and never connects.

## Console and stopping

Commands are read from stdin, so they work in the panel console: `status`,
`players`, `save`, `say`, `kick`, `stop`, `help`, plus the game's `campaign.*`
and `coop.*` commands. The server prints its own list as an
`@DS@{"ev":"commands"}` line on boot.

`start.sh` still has the tty translate carriage returns, so the console also
works from a real terminal, which submits a line on CR.

`stop` writes a shutdown save and exits cleanly, and is what the egg sends. After
a kill instead, the last autosave is the recovery point and two dated backups
are kept.

Everything persistent lives in the server volume:

| Path | Contents |
| --- | --- |
| `data/Game Saves` | Worlds and dated backups. |
| `data/logs` | `Coop_server.log`, written by the mod. Console output also goes to the panel. |
| `data/server-config.json` | Port, save name, password, autosave. Re-applied from the panel on every start. |
| `data/mod-config.json` | Mod settings, written by the mod on first boot. |
| `data/mods` | Manual modules, linked into `engine/Modules` on every start. |
| `.steamcmd` | steamcmd and downloaded Workshop mods, only when `WORKSHOP_MODS` is set. |
| `game` | The extracted dedicated server release. Replaced on update. |

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `could not fetch the release manifest from ...` | GitHub is unreachable, or `COOP_VERSION` names a release without `manifest.json`. Use `latest` or `v0.1.6` or newer, and check the container's network. |
| `SHA-256 mismatch for ...` | The download was truncated or corrupted. It is deleted; the next start downloads it again. Check free disk space and the network. |
| `7z is not installed - rebuild the image` | The image predates the GitHub-release downloader. Pull `:latest` or rebuild. |
| `no game files found and the GitHub release could not be installed` | First boot could not download. Check `COOP_VERSION`, the network and free disk, or point `GAME_DIR` at an existing copy with `AUTO_UPDATE=0`. |
| `module folder X has no SubModule.xml` | `data/mods/X` is not a module root. Put the folder that contains `SubModule.xml` there. |
| `WORKSHOP_MODS is set but STEAM_USERNAME is empty` | Automatic Workshop mods need an owning account. Set `STEAM_USERNAME` or remove `WORKSHOP_MODS` and use `data/mods`. |
| `ERROR! Download item N failed (Failure)` | The account does not own Bannerlord, the item is private or deleted, or steamcmd's cache is stale. Use an owning account or place the module in `data/mods`. |
| `workshop item N is not downloaded - not loaded` | The download failed. Check the steamcmd error above it in the console. |
| `steamcmd failed - using installed Workshop mods` | Login, Steam Guard or network failed. The server starts with whatever Workshop content is already in `STEAM_DIR`. |
| A mod is listed on boot but does nothing | It ships no `bin/Win64_Shipping_Server`, so none of its code loads. See [Mods](#mods). |
| `Cannot load: GameInterface.dll` | A mod is supplying its own Harmony or MonoMod. Remove it from `data/mods` or `WORKSHOP_MODS`. |
| Players are refused with `Server does not support module 'X'` | Their module list differs from the server's. Line up `data/mods` and `WORKSHOP_MODS` with what they have. |
| Typed commands do nothing | The container has no tty. wings always allocates one, compose needs `tty: true`. |
| `SERVER_PORT=0 is not in 1-65534` | The server has no primary allocation. Give it two consecutive free UDP ports. |
| `server-config.json port=0 is not a port in 1-65534` | The stored config holds `"port": 0`. Assign a primary allocation, the next start rewrites it. |

## How it boots

```
tini -g --                          from the yolk: reaps orphans, signals the group
/entrypoint.sh                      from the yolk: Xvfb on :0, stty 250, evals $STARTUP
/usr/local/bin/start.sh             GitHub release, optional Workshop mods, modules, Wine prefix
exec wine engine/dotnet/dotnet.exe TaleWorlds.Starter.DotNetCore.dll \
          "_MODULES_*...*_MODULES_" /dedicatedcustomserver 7210 EU 0
```

`start.sh` reads `manifest.json` from the release, downloads the archive it
names, checks the SHA-256, extracts it to a staging directory and swaps it in.
A failed download or extraction leaves the previous game files in place. When
`WORKSHOP_MODS` is set, it updates those items through steamcmd before linking
modules; a Workshop failure leaves the server running with what is already there.

The image adds no `ENTRYPOINT` and no `CMD`, it keeps the yolk's. wings passes
the panel's Startup Command as `$STARTUP` and the yolk entrypoint is what
evaluates it, so that panel field stays live. `exec` keeps the game one hop from
wings' stdin, which is how console commands reach it.

`BannerlordCoopServer.exe` is shipped in the release archive but not used: it
hardcodes its module list to the five it ships with, so extra mods can only be
loaded by starting the engine the same way it does. What it also did, `start.sh`
now does: seeding `server-config.json`, checking the port, and creating the
first world from `default_new_game.sav`. The mod still verifies its own
assemblies against the release pins at boot, and `data/Game Saves` keeps the same
backup generations.

## Development

```sh
docker build -t bannerlord-coop:latest .
sh start.sh --self-test
```

The egg's `~bannerlord-coop:latest` image entry tells wings to use a local build
without pulling. CI runs `shellcheck start.sh` and the self-test on every push,
then builds and pushes `:latest` plus the sha tag.
