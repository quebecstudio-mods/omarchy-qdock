<p align="center">
  <img src="assets/logo.png" width="128" alt="qDock owl">
</p>

<h1 align="center">qDock</h1>

<p align="center">A Mac-style dock for <a href="https://omarchy.org">Omarchy</a>, in your theme's colors.</p>

<p align="center"><a href="README.fr.md">Version française</a></p>

![qDock on Tokyo Night](docs/dock.png)

**Coming from macOS?** qDock is the Dock: Finder at its head, Launchpad, Stacks and the Trash.
Add [qExposé](https://github.com/quebecstudio-mods/omarchy-qexpose) for Exposé and Mission Control, and [qCenter](https://github.com/quebecstudio-mods/omarchy-qcenter) for the
Notification Center.

qDock replaces Omarchy's dock on floating workspaces. It keeps what the built-in
dock does (pinned apps, running windows, auto-hide, the app grid, its Launchpad) and adds:

- **Files, as an owl**, where Finder sits on a Mac. A click opens your file manager; a right click lists
  your folders, your bookmarks and the trash.
- **Window lists.** Right-click an app to see its windows, bring one forward,
  open a new one, or quit.
- **A stack**, like the Mac's Downloads stack, of your newest downloads (or another folder), with files you can
  open, reveal, copy or drag into another app.
- **A trash**, at the end as on a Mac, that shows when it is full, takes files dropped on it, and can be
  emptied from its menu.
- **Badges, bounces and groups.** Apps asking for attention bounce, then glow;
  web apps can show an unread count; apps can be grouped by color.
- **Two styles.** Mac (frosted glass, round corners) or Omarchy (opaque, with
  your theme's corners and borders).
- **Icons that fit.** Three sizes, and icons shrink when many apps are open.
- **Keeps its space**, if you want: maximized windows stop at the dock.
- **English and French**, following Omarchy's language.

| Settings menu | Stack | Omarchy style |
| --- | --- | --- |
| ![Settings](docs/settings.png) | ![Stack](docs/stack.png) | ![Omarchy style](docs/omarchy-style.png) |

It follows your theme as you switch: here with Tokyo Night, Catppuccin Latte and
Gruvbox.

![qDock with three themes](docs/themes.png)

## Install

```bash
omarchy plugin add https://github.com/quebecstudio-mods/omarchy-qdock --enable
```

Omarchy first shows a security notice and asks you to confirm (*Clone and add
this plugin?*); add `--yes` to skip the question in a script.

The dock shows on **floating** workspaces only, like Omarchy's. A fresh Omarchy
is tiled, so nothing appears until you make a workspace floating with
`omarchy hyprland workspace layout toggle`, or make it the default with
`omarchy hyprland workspace layout default floating`.

qDock takes the place of Omarchy's dock: enabling it turns the built-in one
off, and disabling it brings it back.

There is nothing to uninstall first. Another dock, though, would show next to
qDock: turn off any other Omarchy plugin that replaces the dock (`omarchy plugin
disable <id>`) and any standalone dock you started yourself, such as
`nwg-dock-hyprland`.

### Frosted glass

The Mac style is translucent. For the blur behind it, add this rule to
`~/.config/hypr/hyprland.lua`:

```lua
hl.layer_rule({ match = { namespace = "^(omarchy-dock|omarchy-dock-apps)$" }, blur = true, ignore_alpha = 0.2 })
```

## Use

| | Click | Right click |
| --- | --- | --- |
| **Owl** | Its windows, or your home folder | Folders, bookmarks, trash, new window |
| **Apps button** | Grid of every app | The dock's settings |
| **App** | Open it, or bring it forward | Its windows, new window, keep in or remove from the dock, quit |
| **Stack** | The folder's newest files | The same |
| **Trash** | Open it (or bring it back) | Empty the trash |

Drag apps to reorder them, or from the grid into the dock to pin them.
Middle-click an app to open a new window, or the stack to open its folder.

## Settings

The quick ones are in the dock's menu: right-click the apps button. The rest go
in qDock's entry under `plugins` in `~/.config/omarchy/shell.json` (the menu's
**Edit settings…** opens it):

```json
{
  "id": "quebecstudio.qdock",
  "style": "omarchy",
  "iconSize": "large",
  "stackFolders": ["~/Pictures/Screenshots"],
  "groups": [{ "name": "work", "color": "#2dd4bf", "match": ["^chrome-.*-Profile_1$"] }]
}
```

| Setting | Values | Default |
| --- | --- | --- |
| `style` | `"mac"`, `"omarchy"` | `"mac"` |
| `iconStyle` | `"mono"` (Files, stack and trash drawn in your theme's accent), `"glass"` | `"mono"` |
| `iconSize` | `"small"`, `"medium"`, `"large"`, or pixels (24 to 96) | `"medium"` |
| `bounce` | Apps asking for attention bounce | `true` |
| `reserveSpace` | Maximized windows stop at the dock | `false` |
| `stack` | Show the stack | `true` |
| `stackCount` | Files in the stack, 5 to 30 | `15` |
| `stackFolders` | Folders offered besides Downloads, Documents, Desktop and Pictures | `[]` |
| `filesApp` | Desktop id of your file manager | `"org.gnome.Nautilus"` |
| `filesIcon` | `"mono"`, `"glass"`, `"theme"`, or an image path (absolute or starting with `~/`) | `iconStyle` |
| `groups` | Color groups, in order: `name`, `color`, and `match`, regexes on the desktop id (the window class for an app without one) | `[]` |
| `badges` | Unread counts for web apps (see below) | — |

Position, auto-hide and pinned apps stay in Omarchy's own `dock` settings,
set with `omarchy dock`.

### Badges

A badge shows a number read from a JSON file on an app's icon, and follows the
file as it changes. Each entry gives the apps (`match`, regexes on the desktop
id, or the window class for an app without one), the file, and the `path` to the number: one `/` per level,
and a `key=value` segment picks an element of an array.

```json
"badges": [{ "match": ["^Mail$"], "file": "~/.local/state/mail.json", "path": "accounts/name=work/unread" }]
```

## Works with qExposé

[qExposé](https://github.com/quebecstudio-mods/omarchy-qexpose) adds a Mac-style
Exposé and an Alt+Tab switcher with previews. When it is enabled, an app's menu
in the dock offers **Show All Windows**: every window of that app, across
workspaces, minimized ones included.

## Commands

qDock answers to the same commands as Omarchy's dock, plus a few:

```bash
omarchy-shell -q omarchy.dock apps       # toggle the app grid
omarchy-shell -q omarchy.dock stack      # toggle the stack on the focused screen
omarchy-shell -q omarchy.dock settings   # toggle the settings menu on the focused screen
omarchy-shell -q omarchy.dock stackOn DP-1      # the same, on a named screen
omarchy-shell -q omarchy.dock settingsOn DP-1
```

## License

MIT © Québec Studio

macOS, Finder, Launchpad, Mission Control and Exposé are trademarks of Apple Inc. This project is not affiliated with or endorsed by Apple.
