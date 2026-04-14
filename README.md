# WROS — Offstyle World Records for SourceMod

A [SourceMod](https://www.sourcemod.net/) plugin that integrates with the [Offstyle](https://offstyles.net/) API to display and browse World Records directly on your server. Players can view ranked record lists, inspect detailed run info, and watch downloaded replays, all from an in-game menu. Based on [WRSJ](https://github.com/rtldg/wrsj).

---
> **Note:** Replay downloading is currently broken. Proper support is planned and will be implemented once available.
---

## Features

- **Offstyle WR browser** — Browse world records for the current map or any other map by passing a map name after the command (e.g. `!wros [mapname]`). Supports partial map names using the server's map list as reference (from `[shavit] MapChooser` when loaded, otherwise from `mapcycle.txt`)
- **Top Left HUD integration** — Optionally shows the Offstyle WR time in the Top Left HUD
- **Replay system** — Download and watch Offstyle replays in-game via replay bots
- **Per-player settings** — Each player can configure HUD visibility and display behavior to their preference
- **Style mapping** — Maps Offstyle DB style IDs to your server's local shavit style indices via `wros.cfg`
- **Developer API** — Exposes natives, forwards, and a stock utility function for use in other plugins

---

## Requirements

- [SourceMod](https://www.sourcemod.net/) 1.12+
- [sm-ripext](https://github.com/ErikMinekus/sm-ripext) — HTTP extension for API requests and replay downloading
- [SteamWorks](https://forums.alliedmods.net/showthread.php?t=229556) *(optional)* — Alternative HTTP extension for API requests, recommended on Windows [(sm-ripext issue)](https://github.com/ErikMinekus/sm-ripext/issues/63)
- [shavit-bhoptimer](https://github.com/shavitush/bhoptimer) *(optional)* — For HUD and replay playback integration

---

## Installation

1. Copy `wros.smx` to `addons/sourcemod/plugins/`
2. Copy `wros.phrases.txt` to `addons/sourcemod/translations/`
3. Copy `wros.cfg` to `addons/sourcemod/configs/` and configure it for your server (see [Configuration](#configuration))
4. Restart the server or reload the map
5. A `cfg/sourcemod/wros.cfg` containing all ConVars will be auto-generated on first load

---

## Configuration

Edit `addons/sourcemod/configs/wros.cfg` to map Offstyle DB style IDs to your server's style indices.
The order of entries can be changed freely and will be reflected in the style selection menu.

```
"root"
{
    // Offstyle DB style ID
    "190"
    {
        // Display name shown in the style selection menu and WR list/info title
        "style_name"    "Normal"

		// Maps the offstyle DB style (190) to the server style (0) from shavit-styles.cfg for the Top Left HUD display
		// Used by Top Left HUD to automatically show offstyle records when playing this server style
		// Also used by the re-cache feature to detect when a new record should trigger a cache refresh
		// Remove or set to -1 to disable the Top Left HUD and re-cache for this style (Can still display the default style when enabled)
        "style_server"  "0"

		// Maps the offstyle DB style (190) to the server style (0) from shavit-styles.cfg for the correct replay style
		// Ensures replay bots play with the correct server style
		// You may use a different server style (E.g. the index for Normal) if you do not have a matching style on your server
		// Remove or set to -1 to disable the replay option for this style
        "style_replay"  "0"
    }*
}
```

---

## Commands

| Command | Alias | Description |
|---------|-------|-------------|
| `!wros [map]` | `!oswr` | Opens the Offstyle WR browser. Without an argument, shows records for the current map. Accepts a partial map name to search. |
| `!wrosr [map]` | — | Opens directly into replay selection. Records without a replay are greyed out and unselectable. Clicking a record immediately starts the replay. In the style selection menu, each style shows `(replay count / WR count)`. |
| `!wrossettings` | `!wross` | Opens the players settings menu for WROS. Also accessible through SourceMod's `!settings` menu. |

Replay access requires the `sm_wros_getreplay` permission (Ban flag, `d`). This can be overridden in `addons/sourcemod/configs/admin_overrides.cfg`:
```
"sm_wros_getreplay" ""   // Allow everyone
"sm_wros_getreplay" "m"  // Requires "Changing the map" permission
```
See [Overriding Command Access](https://wiki.alliedmods.net/Overriding_Command_Access_(Sourcemod)) for more info.

---

## Contributing

If you find a bug or have a suggestion, feel free to [open an issue](https://github.com/mariokeks/wros/issues).

## License

[GPL-3.0](LICENSE)
