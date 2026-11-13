# Changelog

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
