# Changelog

## 1.2.1 - 2026-11-16

### Changed

- **The README says how to remove the plugin**, and the repository has a preview image for Omarchy's plugin directory.

## 1.2.0 - 2026-11-16

### Added

- **Search with qSpot.** With [qSpot](https://github.com/quebecstudio-mods/omarchy-qspot) enabled, a magnifier can sit after the apps button (`search`, off by default; a right click opens qSpot's settings). In the app grid, Tab hands what you typed over to qSpot to search everywhere, and so does Enter when no app matches.
- **The album** in the Now playing popover, under the title and the artist (left out for a single named like its track).

### Changed

- **Now playing:** under the pointer, the tile shows what a click does, play or pause, on the cover or in place of the note. The popover no longer names the player.
- **Spotify's ads** keep their own text as the title, with Advertisement where the artist goes.

### Fixed

- **Windows off screen.** A floating window can drift off every monitor when one goes away and comes back (a monitor going to sleep). A click on its app gave it the focus unseen; the dock now centers it on its monitor as it brings it forward.
- **Weather that never loads.** Open-Meteo turned the forecast away (403) when it came with curl's own User-Agent, and the tile stayed at "…". qDock now names itself in its requests.

## 1.1.1 - 2026-11-13

### Fixed

- **Covers in the Now playing tile.** A cover from the web (Spotify's, for one) sometimes never showed, and the tile kept its note. qDock now downloads each cover once into `~/.cache/qdock/covers` and shows that file.
- **Spotify's ads.** The tile says Advertisement, with no artist and the note, instead of the ad's slogan.

## 1.1.0 - 2026-11-12

### Added

- **Now playing.** A tile with the cover, title and artist of the music playing in any player (Spotify, mpv, a browser, a web app); hover it for the progress and the controls. Three sizes, off by default (`music`).
- **Weather.** The sky and the temperature, and the next three days on hover. Off by default (`weather`); the place is picked by searching for a city.
- **Four styles.** Omarchy (opaque, with your theme's corners and borders), Cupertino, Redmond and Plasma, each with its own running indicators, hover, badges, alerts and labels. Alerts (`attention`) and labels (`labels`) can also be picked on their own.
- **A settings window**, drawn with Omarchy's own controls: Appearance, Behavior, Tiles, Weather and About. Open it from the dock's menu or with `omarchy-shell -q quebecstudio.qdock settings`; a launcher entry (qDock Settings) comes in `assets/`, to copy as the README shows.
- **Two app grids** (`launcher`): Omarchy's card, floating alone with no veil or blur behind it, or Cupertino's full screen. Clicking the apps button again closes the grid.
- **Icons.** A System icon style that takes Files, the stack and the trash from your icon theme. Files is now drawn as an open folder.

### Changed

- **The default style is now Omarchy**, and the default app grid Omarchy's card. To keep 1.0's look, set `style` and `launcher` to `"cupertino"`.
- **Renamed values**, the old names still read: `style` `"mac"` → `"cupertino"`; `iconStyle` and `filesIcon` `"mono"` → `"omarchy"`; `filesIcon` `"theme"` → `"system"`.
- **Commands** now live under `quebecstudio.qdock`. `omarchy.dock` still answers to Omarchy's own (`apps`, `refresh`) and to 1.0's (`stack`, `stackOn`, `settings`, `settingsOn`); `settings` and `settingsOn` now open the settings window; the dock's menu is `menu` (`menuOn` for a named screen).

### Fixed

- Reordering the dock: an app lands where it was dropped even while another app is closing, and an app opening or closing mid-drag ends the drag instead of moving the wrong one.
- Menus taller than the space left scroll instead of being cut.
- File names holding a tab now show in the stack.

## 1.0.0 - 2026-11-11

First release.
