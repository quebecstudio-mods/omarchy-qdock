import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DockModel.js" as DockModel
import "WeatherModel.js" as WeatherModel

// One screen's dock. It stays mapped and only hides its contents, so switching
// to a floating workspace does not wait on a fresh layer surface. While hidden the
// mask is empty and clicks fall through to the windows below.
PanelWindow {
  id: window
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  // Right-to-left languages read this window mirrored.
  Binding { target: window.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
  Binding { target: window.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

  property var dock: null

  // Badges (setting badges): a number read from a JSON file, shown on the apps
  // whose id matches. "path" walks down the JSON one "/" segment at a time, and
  // a "key=value" segment picks an array element. For example:
  //   "badges": [{ "match": ["^Mail$"], "file": "~/.local/state/mail.json", "path": "accounts/name=work/unread" }]
  readonly property var badgeRules: {
    var list = window.dock && Array.isArray(window.dock.settings.badges) ? window.dock.settings.badges : []
    var out = []
    for (var i = 0; i < list.length && i < 20; i++) {
      var b = list[i]
      if (!b || typeof b.file !== "string" || typeof b.path !== "string") continue
      out.push({ match: DockModel.compilePatterns(b.match),
                 file: b.file.replace(/^~(?=\/)/, Quickshell.env("HOME")), path: b.path })
    }
    return out
  }
  readonly property var badgeFiles: {
    var seen = []
    for (var i = 0; i < badgeRules.length; i++) if (seen.indexOf(badgeRules[i].file) < 0) seen.push(badgeRules[i].file)
    return seen
  }
  // Each file's parsed contents, by path.
  property var badgeData: ({})

  Instantiator {
    model: window.badgeFiles
    delegate: FileView {
      required property string modelData
      path: modelData
      watchChanges: true
      printErrors: false
      onFileChanged: reload()
      onLoaded: {
        var data = null
        try { data = JSON.parse(text()) } catch (e) {}
        var next = Object.assign({}, window.badgeData)
        next[modelData] = data
        window.badgeData = next
      }
    }
  }

  function badgeCount(key) {
    var k = String(key || "")
    for (var i = 0; i < badgeRules.length; i++) {
      var rule = badgeRules[i]
      if (!DockModel.matchesAny(rule.match, k)) continue
      var n = Number(DockModel.jsonAt(window.badgeData[rule.file], rule.path))
      return isFinite(n) && n > 0 ? Math.floor(n) : 0
    }
    return 0
  }

  function badgeLabel(key) {
    var n = badgeCount(key)
    if (n <= 0) return ""
    return n > 999 ? "999+" : String(n)
  }

  readonly property string position: dock ? dock.position : "bottom"
  readonly property bool vertical: dock ? dock.vertical : false
  readonly property var monitor: Hyprland.monitorFor(screen)
  readonly property var workspace: monitor ? monitor.activeWorkspace : null
  readonly property int workspaceId: workspace ? workspace.id : -1
  // The most fullscreen window on the workspace, as Hyprland counts it: 1 is
  // maximized, and 2 or 3 fullscreen.
  readonly property int fullscreenMode: {
    var mode = 0
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      if (!toplevel.workspace || toplevel.workspace.id !== workspaceId) continue
      var ipc = toplevel.lastIpcObject
      mode = Math.max(mode, ipc && ipc.fullscreen ? ipc.fullscreen : 0)
    }
    return mode
  }
  readonly property bool shown: !!dock && dock.isFloating(workspaceId) && fullscreenMode < 2
  // With reserveSpace on, the dock keeps its strip of the screen while shown,
  // unless it hides itself.
  readonly property bool reserving: shown && dock.reserveSpace && !dock.autohide
  // With auto-hide on, the dock waits off screen until the pointer reaches its
  // edge, and stays while the pointer, a menu, or a drag still needs it. A
  // maximized window hides the dock the same way, so it can still be called up,
  // unless the dock keeps its space and the window stops short of it.
  readonly property bool autohide: !!dock && (dock.autohide || (fullscreenMode === 1 && !reserving))
  property bool revealed: false
  readonly property bool menuOpen: menuItem !== null || settingsMenu || trashMenu || musicMenu || weatherMenu || stackOpen
  readonly property bool tucked: autohide && !(revealed || menuOpen || musicPopupShown || weatherPopupShown || dragging || insertIndex >= 0)
  readonly property bool contentShown: shown && !tucked

  readonly property int gap: Style.spacing.xs
  // Surface styles (setting style). Omarchy, the default, follows the theme:
  // opaque surfaces with its corners and borders. The others keep their own
  // corners whatever the windows have, over a translucent pane a blur rule
  // can frost: Cupertino, round, with dots under running apps and icons that
  // grow on hover, as on a Mac; Redmond, slightly rounded, with a short line
  // under running apps, longer for the focused one, and a lit square on
  // hover, as on Windows; Plasma, nearly opaque and unoutlined, with a faint
  // veil behind each running app, tinted with the accent for the focused one,
  // and an accent frame on hover, as in KDE's task manager.
  readonly property string styleName: dock ? dock.style : "omarchy"
  readonly property bool cupertinoStyle: styleName === "cupertino"
  readonly property bool redmondStyle: styleName === "redmond"
  readonly property bool plasmaStyle: styleName === "plasma"
  readonly property bool themedStyle: styleName === "omarchy"
  readonly property int dockRadius: cupertinoStyle ? Math.max(Style.cornerRadius, Style.space(16))
    : redmondStyle ? Style.space(8) : plasmaStyle ? Style.space(6) : Style.cornerRadius
  readonly property int popupRadius: cupertinoStyle ? Math.max(Style.cornerRadius, Style.space(12))
    : redmondStyle ? Style.space(8) : plasmaStyle ? Style.space(5) : Style.cornerRadius
  // The pane's opacity, for the dock and its popups.
  readonly property real paneOpacity: cupertinoStyle ? 0.5 : redmondStyle ? 0.72 : plasmaStyle ? 0.92 : 1
  readonly property real popupOpacity: cupertinoStyle ? 0.85 : redmondStyle ? 0.9 : plasmaStyle ? 0.94 : 1
  // Icons grow on hover in the Omarchy and Cupertino styles; in the others a
  // square lights up behind them.
  readonly property bool hoverPop: themedStyle || cupertinoStyle
  // The tiles the dock draws itself (mono glyphs, the apps button).
  readonly property int tileRadius: tileRadiusFor(iconSize)

  function tileRadiusFor(size) {
    return cupertinoStyle ? Math.round(size * 0.24) : redmondStyle ? Math.round(size * 0.2)
      : plasmaStyle ? Math.round(size * 0.14) : Style.cornerRadius
  }

  // What a hovered control or slot looks like, on text of the given color:
  // the theme's hover tokens in the Omarchy style, as Omarchy's buttons; an
  // accent fill in a thin accent frame in the Plasma style, as Breeze; a
  // light fill otherwise.
  function hoverFill(foreground) {
    return themedStyle ? Style.hoverFillFor(foreground, Commons.Color.accent)
      : plasmaStyle ? Util.alpha(Commons.Color.accent, 0.18)
      : Util.alpha(foreground, cupertinoStyle ? 0.14 : 0.1)
  }
  function hoverFrameWidth(foreground) {
    return themedStyle ? Border.top(Border.controlSpec("hover-cursor", foreground, Commons.Color.accent))
      : plasmaStyle ? 1 : 0
  }
  function hoverFrameColor(foreground) {
    return plasmaStyle ? Util.alpha(Commons.Color.accent, 0.6)
      : Border.controlSpec("hover-cursor", foreground, Commons.Color.accent).color
  }

  // A small control (a chip, a button), full height: a pill or a circle in
  // the Cupertino style, the theme's corners in Omarchy's.
  function controlRadius(height) {
    return cupertinoStyle ? height / 2 : redmondStyle ? Style.space(4)
      : plasmaStyle ? Style.space(3) : Math.min(height / 2, Style.cornerRadius)
  }
  // Icons shrink, like on a Mac, when the slots no longer fit along the edge:
  // Files, the apps button, the apps, the music, the stack and the trash.
  readonly property int baseIconSize: Math.round((dock ? dock.iconSize : 45) * Style.fontScale)
  readonly property int minIconSize: Math.round(24 * Style.fontScale)
  readonly property real slotCount: appRepeater.count + 2
    + (dock && dock.filesItem ? 1 : 0) + (dock && dock.showStack ? 1 : 0) + (dock && dock.musicPlayer ? musicSpan : 0) + (dock && dock.showWeather ? 1 : 0)
  readonly property real slotRoom: ((vertical ? height : width) - gap * 2) / slotCount
  readonly property int iconSize: Math.max(minIconSize, Math.min(baseIconSize, Math.floor(slotRoom) - iconInset * 2))
  // Each app has a square slot with its icon in the middle, and the slots run
  // straight to the edge of the dock.
  readonly property int iconInset: Style.spacing.md
  readonly property int slotSize: iconSize + iconInset * 2
  // Slots animate in only once the dock has settled, not at startup.
  property bool settled: false
  Timer { interval: 1500; running: true; onTriggered: window.settled = true }
  // A pinned app that is not running is drawn faded.
  readonly property real idleOpacity: 0.7
  // Room inward of the dock for its menus. The tallest is an app's, which lists
  // up to maxMenuWindows windows above its actions; on a side dock, the room
  // is for the width of window titles.
  readonly property int maxMenuWindows: 12
  readonly property int menuWideWidth: Style.space(300)
  readonly property int popupRoom: vertical
    ? menuWideWidth + Style.spacing.sm * 2 + Style.normalBorderWidth * 2 + gap * 2
    : Style.spacing.popupRowHeight * (maxMenuWindows + 5) + Style.spacing.sm * 2 + Style.normalBorderWidth * 2 + gap * 2
  // The tallest a menu gets; a longer one (Files with many bookmarks) scrolls.
  readonly property real menuMaxHeight: vertical ? height - gap * 2 : popupRoom - gap * 2
  // Icons pop away from the screen edge.
  readonly property int popOrigin: position === "top" ? Item.Top
    : position === "left" ? Item.Left
    : position === "right" ? Item.Right
    : Item.Bottom

  // The app being dragged along the dock, how far the pointer has taken it,
  // and the slot it would land in.
  property int dragIndex: -1
  property int dropIndex: -1
  property real dragOffset: 0
  readonly property bool dragging: dragIndex >= 0
  // Off while a drop resets the slots: they snap to where the reorder puts
  // them rather than sliding back from where they stepped aside. Set before
  // the drag state changes, so the slots never see the reset animated.
  property bool animateShifts: true
  // After a drop the slots have moved under a pointer that has not, so what
  // they think is hovered is stale until it moves again.
  property bool hoverStale: false
  property point dropPoint
  // Where an app dragged in from the app grid would land, or -1.
  property int insertIndex: -1

  // Where this window sits on its screen, which a point from the app grid's
  // fullscreen surface is given in: against its edge, clear of the space
  // other surfaces such as the bar reserve. Hyprland lists that space as
  // left, top, right, bottom, and it includes the dock's own space when the
  // dock keeps it.
  function origin() {
    var reserved = monitor && monitor.lastIpcObject && monitor.lastIpcObject.reserved ? monitor.lastIpcObject.reserved : [0, 0, 0, 0]
    var left = reserved[0] || 0, top = reserved[1] || 0, right = reserved[2] || 0, bottom = reserved[3] || 0
    var own = window.reserving ? window.exclusiveZone : 0
    if (window.position === "left") left = Math.max(0, left - own)
    else if (window.position === "right") right = Math.max(0, right - own)
    else if (window.position === "top") top = Math.max(0, top - own)
    else bottom = Math.max(0, bottom - own)
    var x = window.position === "right" ? screen.width - right - window.width : left
    var y = window.position === "bottom" ? screen.height - bottom - window.height : top
    return Qt.point(x, y)
  }

  // An app from the app grid lands where the pointer is, once it is over the
  // dock or close to it on the inward side.
  function moveExternalDrag(screenX, screenY) {
    var at = window.origin()
    var point = Qt.point(screenX - at.x - body.x, screenY - at.y - body.y)
    var reach = window.slotSize
    var along = window.vertical ? point.y : point.x
    var across = window.vertical ? point.x : point.y
    var length = window.vertical ? body.height : body.width
    var depth = window.vertical ? body.width : body.height
    var near = along >= -window.slotSize && along <= length + window.slotSize && across >= -reach && across <= depth + reach
    if (window.shown && window.autohide && near) window.revealed = true
    window.insertIndex = window.shown && near ? window.slotIndexAt(point) : -1
  }

  function dropExternalDrag(screenX, screenY, key) {
    window.moveExternalDrag(screenX, screenY)
    window.settleShifts()
    if (window.insertIndex >= 0 && key && window.dock) window.dock.pinAt(key, window.insertIndex)
    window.endExternalDrag()
  }

  function endExternalDrag() {
    window.insertIndex = -1
    if (window.autohide) hideTimer.restart()
  }

  // The slot a point along the dock falls before, counting from the first app.
  function slotIndexAt(point) {
    var along = window.vertical ? point.y : point.x
    // Files, when there is a file manager, and the apps button come before
    // the first app.
    var first = window.slotSize * ((window.dock && window.dock.filesItem ? 1 : 0) + 1)
    var count = window.dock ? window.dock.itemModel.count : 0
    return Math.max(0, Math.min(count, Math.round((along - first) / window.slotSize)))
  }
  // The app whose menu is open, looked up by key so the menu follows its
  // windows; it closes if the app leaves the dock.
  property string menuKey: ""
  readonly property var menuItem: menuKey !== "" && dock ? dock.itemFor(menuKey) : null
  property Item menuSlot: null
  // The apps button's menu: where the dock sits and whether it hides.
  property bool settingsMenu: false
  // The trash menu, the open stack, and the trash waiting for a second click
  // to empty.
  property bool trashMenu: false
  // The music controls: shown while the music tile or the controls are
  // hovered, or kept open by a right click on the tile (musicMenu).
  property bool musicMenu: false
  property bool musicHover: false
  readonly property bool musicPopupShown: !!dock && !!dock.musicPlayer && (musicMenu || (musicHover && !menuOpen))
  // The weather's details, the same way (weatherMenu: kept open by a click).
  property bool weatherMenu: false
  property bool weatherHover: false
  readonly property bool weatherPopupShown: !!dock && dock.showWeather && dock.weatherHasPlace && (weatherMenu || (weatherHover && !menuOpen))
  property bool stackOpen: false
  property bool trashConfirm: false

  onWorkspaceIdChanged: if (dock) dock.readMode(workspaceId)
  // Moving to another edge remaps the window and Hyprland drops the focus
  // grab, so an open menu would no longer close on a click outside: close it.
  onPositionChanged: closeMenu()
  onShownChanged: {
    if (shown) return
    closeMenu()
    window.revealed = false
  }
  Component.onCompleted: if (dock) dock.readMode(workspaceId)

  function openMenu(item, slot) {
    window.settingsMenu = false
    window.trashMenu = false
    window.musicMenu = false
    window.weatherMenu = false
    window.stackOpen = false
    window.menuKey = item ? item.key : ""
    window.menuSlot = slot
  }

  function openSettingsMenu(slot) {
    window.menuKey = ""
    window.trashMenu = false
    window.musicMenu = false
    window.weatherMenu = false
    window.stackOpen = false
    window.settingsMenu = true
    window.menuSlot = slot
  }

  function settleShifts() {
    window.animateShifts = false
    Qt.callLater(function() { window.animateShifts = true })
  }

  function endDrag() {
    window.settleShifts()
    window.hoverStale = true
    window.dragIndex = -1
    window.dropIndex = -1
    window.dragOffset = 0
  }

  function openTrashMenu(slot) {
    window.menuKey = ""
    window.settingsMenu = false
    window.stackOpen = false
    window.trashConfirm = false
    window.trashMenu = true
    window.menuSlot = slot
  }

  function openMusicMenu(slot) {
    window.menuKey = ""
    window.settingsMenu = false
    window.trashMenu = false
    window.stackOpen = false
    window.weatherMenu = false
    window.musicMenu = true
    window.menuSlot = slot
  }

  function openWeatherMenu(slot) {
    window.menuKey = ""
    window.settingsMenu = false
    window.trashMenu = false
    window.musicMenu = false
    window.stackOpen = false
    window.weatherMenu = true
    window.menuSlot = slot
  }

  function toggleStack(slot) {
    if (window.stackOpen) {
      window.closeMenu()
      return
    }
    window.menuKey = ""
    window.settingsMenu = false
    window.trashMenu = false
    window.musicMenu = false
    window.weatherMenu = false
    if (window.dock) window.dock.refreshStack()
    window.stackOpen = true
    window.menuSlot = slot
  }

  function toggleStackHere() {
    if (window.shown && window.dock && window.dock.showStack) window.toggleStack(stackSlotItem)
  }

  function toggleWeatherHere() {
    if (!window.shown || !window.dock || !window.dock.showWeather || !window.dock.weatherHasPlace) return
    if (window.weatherMenu) window.closeMenu()
    else window.openWeatherMenu(weatherSlotItem)
  }

  function toggleSettingsHere() {
    if (!window.shown) return
    if (window.settingsMenu) window.closeMenu()
    else window.openSettingsMenu(appsSlotItem)
  }

  function closeMenu() {
    window.menuKey = ""
    window.settingsMenu = false
    window.trashMenu = false
    window.musicMenu = false
    window.weatherMenu = false
    window.stackOpen = false
    window.trashConfirm = false
    window.menuSlot = null
    if (window.autohide) hideTimer.restart()
  }

  // Places the menu inward of the dock, centered on a slot. mapToItem is not
  // tracked by bindings: reading the slot's and the dock's geometry first
  // keeps a popup bound to it (music, weather) over its slot as apps come and
  // go and the tile moves.
  function popupX(slot, popup) {
    if (!slot) return 0
    void (slot.x + slot.width + body.x + body.width + slots.width)
    var center = slot.mapToItem(window.contentItem, slot.width / 2, 0).x
    if (window.position === "left") return body.x + body.width + window.gap
    if (window.position === "right") return body.x - window.gap - popup.width
    return Math.max(window.gap, Math.min(window.width - popup.width - window.gap, center - popup.width / 2))
  }

  function popupY(slot, popup) {
    if (!slot) return 0
    void (slot.y + slot.height + body.y + body.height + slots.height)
    var center = slot.mapToItem(window.contentItem, 0, slot.height / 2).y
    if (window.position === "top") return body.y + body.height + window.gap
    if (window.position === "bottom") return body.y - window.gap - popup.height
    return Math.max(window.gap, Math.min(window.height - popup.height - window.gap, center - popup.height / 2))
  }

  visible: !remapGuard.remapping
  color: "transparent"
  WlrLayershell.namespace: "omarchy-dock"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  // Kept clear of the bar's reserved edge. It reserves its own only with
  // reserveSpace on, and floating windows can still be put over it.
  exclusionMode: ExclusionMode.Normal
  exclusiveZone: reserving ? gap + slotSize : 0

  anchors {
    top: window.position !== "bottom"
    bottom: window.position !== "top"
    left: window.position !== "right"
    right: window.position !== "left"
  }

  implicitWidth: window.vertical ? window.gap + window.slotSize + window.popupRoom : 0
  implicitHeight: window.vertical ? 0 : window.gap + window.slotSize + window.popupRoom

  mask: Region {
    item: window.contentShown ? body : null

    Region { item: window.shown && window.autohide ? edgeTrigger : null }
    Region { item: menu.visible ? menu : null }
    Region { item: stackPopup.visible ? stackPopup : null }
    Region { item: musicPopup.visible ? musicPopup : null }
    Region { item: weatherPopup.visible ? weatherPopup : null }
  }

  onAutohideChanged: window.revealed = false

  // A player that goes away takes its kept-open controls with it.
  Connections {
    target: window.dock
    function onMusicPlayerChanged() { if (!window.dock.musicPlayer) { window.musicMenu = false; window.musicHover = false } }
  }

  Timer {
    id: hideTimer
    // Long enough to cross a gap between the edge and the icons, no longer.
    interval: 150
    onTriggered: {
      if (!bodyHover.hovered && !edgeHover.hovered && !window.menuOpen && !window.musicPopupShown && !window.weatherPopupShown && !window.dragging) window.revealed = false
    }
  }

  // The strip along the screen edge that brings an auto-hidden dock back.
  Item {
    id: edgeTrigger

    readonly property int depth: window.gap + Style.spacing.xxs

    x: window.position === "left" ? 0 : window.position === "right" ? window.width - depth : body.x
    y: window.position === "top" ? 0 : window.position === "bottom" ? window.height - depth : body.y
    width: window.vertical ? depth : body.width
    height: window.vertical ? body.height : depth

    HoverHandler {
      id: edgeHover
      onHoveredChanged: {
        if (hovered) window.revealed = true
        else hideTimer.restart()
      }
    }
  }

  ScreenMoveRemap {
    id: remapGuard
    window: window
  }

  HyprlandFocusGrab {
    active: window.menuOpen
    windows: [window]
    onCleared: window.closeMenu()
  }

  Item {
    id: body

    // The strip keeps its order in every language, like the bar: drags and
    // drops reckon slots along x from the first app. Only the menu mirrors.
    LayoutMirroring.enabled: false
    LayoutMirroring.childrenInherit: true

    width: slots.implicitWidth
    height: slots.implicitHeight
    // How far the dock is tucked past its edge. Auto-hide slides it, but only
    // while the dock is on screen: arriving on a floating workspace shows it
    // where it belongs at once.
    property real tuck: window.tucked ? window.slotSize + window.gap : 0

    // Tucking away is quicker than coming back. A gentler curve than
    // Style.easeOut, which crosses the short slide in a frame or two.
    Behavior on tuck {
      id: tuckMotion
      enabled: window.shown
      NumberAnimation {
        duration: Style.duration(tuckMotion.targetValue > 0 ? 120 : 180)
        easing.type: Easing.OutCubic
      }
    }

    x: window.position === "left" ? window.gap - tuck
      : window.position === "right" ? window.width - width - window.gap + tuck
      : Math.round((window.width - width) / 2)
    y: window.position === "top" ? window.gap - tuck
      : window.position === "bottom" ? window.height - height - window.gap + tuck
      : Math.round((window.height - height) / 2)
    // Switching between tiled and floating workspaces shows and hides the dock
    // at once, with nothing to watch in between. Hidden by opacity rather than
    // visibility, so the icons keep their textures and are drawn on the first
    // frame back instead of being uploaded again.
    opacity: window.shown ? 1 : 0

    HoverHandler {
      id: bodyHover
      onHoveredChanged: if (!hovered && window.autohide) hideTimer.restart()
      // Only a real move clears it: the release itself reports the pointer too.
      onPointChanged: {
        if (!window.hoverStale || window.dragging) return
        var at = point.position
        if (Math.hypot(at.x - window.dropPoint.x, at.y - window.dropPoint.y) > Style.space(4)) window.hoverStale = false
      }
    }

    // The Cupertino, Redmond and Plasma styles: the theme's background,
    // translucent, so a blur rule on the omarchy-dock layer can frost what is
    // behind it.
    Rectangle {
      anchors.fill: parent
      z: -1
      visible: !window.themedStyle
      radius: window.dockRadius
      color: Util.alpha(Commons.Color.popups.background, window.paneOpacity)
      // Plasma's panel has no outline.
      border.width: window.plasmaStyle ? 0 : Style.normalBorderWidth
      border.color: window.redmondStyle ? Util.alpha("white", 0.1) : Util.alpha(Commons.Color.bar.text, 0.18)

      // A faint sheen along the top, like a pane of glass (Cupertino).
      Rectangle {
        visible: window.cupertinoStyle
        anchors.fill: parent
        anchors.margins: parent.border.width
        radius: Math.max(0, parent.radius - parent.border.width)
        gradient: Gradient {
          GradientStop { position: 0; color: Util.alpha("white", 0.08) }
          GradientStop { position: 0.5; color: "transparent" }
        }
      }
    }

    // Omarchy style: an opaque surface, like the shell's menus.
    BorderSurface {
      anchors.fill: parent
      z: -1
      visible: window.themedStyle
      radius: window.dockRadius
      color: Commons.Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    }

    Grid {
      id: slots
      anchors.centerIn: parent
      // Files, the apps button, the apps, the music, the weather, the stack
      // and the trash.
      columns: window.vertical ? 1 : appRepeater.count + 6

      // Files, then the apps button, then the apps. Files sits outside the
      // apps' indices, so drags never count it.
      AppSlot {
        index: -100
        key: window.dock ? window.dock.filesKey : ""
        fixed: true
        visible: !!window.dock && !!window.dock.filesItem
      }

      AppsSlot { id: appsSlotItem }

      Repeater {
        id: appRepeater
        model: window.dock ? window.dock.itemModel : null
        // An app that joins or leaves mid-drag shifts the slots' indexes:
        // the drag ends rather than move another app.
        onCountChanged: if (window.dragging) window.endDrag()

        delegate: AppSlot {}
      }

      // The music, the stack and the trash at the end, after a separator.
      MusicSlot { id: musicSlotItem }

      WeatherSlot { id: weatherSlotItem }

      StackSlot { id: stackSlotItem; visible: !!window.dock && window.dock.showStack }

      TrashSlot {}
    }
  }

  component Slot: Item {
    id: slot

    // Only the dragged icon is lifted while a drag is on; none of the others
    // pop as it passes over them.
    property bool hovered: mouse.containsMouse && !window.hoverStale && !window.dragging
    property alias mouse: mouse
    // The hover label's text, for slots that are not apps.
    property string label: ""
    // In the styles where icons do not grow on hover, a square lights up
    // behind the hovered one (styleHover). In Plasma, as in KDE's task
    // manager, every running app has a faint veil (running), tinted with the
    // accent for the focused one (lit).
    property bool styleHover: true
    property bool running: false
    property bool lit: false
    readonly property bool framed: slot.hovered || (window.plasmaStyle && (slot.lit || slot.running))
    readonly property bool accented: window.plasmaStyle && (slot.hovered || slot.lit)

    width: window.slotSize
    height: window.slotSize

    Rectangle {
      z: -1
      anchors.centerIn: parent
      width: Math.min(parent.width, window.iconSize + window.iconInset)
      height: Math.min(parent.height, window.iconSize + window.iconInset)
      radius: window.controlRadius(height)
      // Plasma: a faint veil behind a running app, an accent one with a soft
      // edge for the focused app, a clearer accent frame on hover.
      color: !window.plasmaStyle ? window.hoverFill(Commons.Color.bar.text)
        : slot.hovered ? Util.alpha(Commons.Color.accent, 0.22)
        : slot.lit ? Util.alpha(Commons.Color.accent, 0.12)
        : Util.alpha(Commons.Color.bar.text, 0.05)
      border.width: window.plasmaStyle && !slot.accented ? 0 : window.hoverFrameWidth(Commons.Color.bar.text)
      border.color: window.plasmaStyle && !slot.hovered ? Util.alpha(Commons.Color.accent, 0.3)
        : window.hoverFrameColor(Commons.Color.bar.text)
      opacity: window.hoverPop || !slot.styleHover || !slot.framed ? 0 : 1
      visible: opacity > 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }
      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    }

    onHoveredChanged: {
      if (hovered) window.hoverSlot = slot
      else if (window.hoverSlot === slot) window.hoverSlot = null
    }
    Component.onDestruction: if (window.hoverSlot === slot) window.hoverSlot = null

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    }
  }

  component AppsSlot: Slot {
    id: appsSlot
    label: strings.t("apps")

    property real displayedShift: window.insertIndex >= 0 ? -window.slotSize / 2 : 0

    Behavior on displayedShift {
      enabled: window.animateShifts
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }

    transform: Translate {
      x: window.vertical ? 0 : appsSlot.displayedShift
      y: window.vertical ? appsSlot.displayedShift : 0
    }

    mouse.onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        window.openSettingsMenu(appsSlot)
        return
      }
      window.closeMenu()
      if (window.dock) window.dock.toggleApps()
    }

    // A grid of app squares reads as "all apps" in any icon theme. Drawn
    // rather than taken from a font, so its edges stay crisp on the
    // transparent dock and it fills its slot like the app icons beside it.
    Item {
      x: window.iconInset
      y: window.iconInset
      width: window.iconSize
      height: window.iconSize
      scale: appsSlot.hovered && window.hoverPop ? 1.15 : 1
      transformOrigin: window.popOrigin

      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

      // A rounded tile under the nine squares: light with colored squares in
      // glass style, the theme's background with accent squares in mono.
      readonly property bool mono: !window.dock || window.dock.iconStyle === "omarchy"
      Rectangle {
        anchors.fill: parent
        anchors.margins: Math.round(window.iconSize * 0.04)
        radius: window.tileRadius
        gradient: parent.mono ? null : glassTile
        color: Commons.Color.background
        border.width: parent.mono ? Math.max(1, Style.space(1.5)) : 1
        border.color: parent.mono ? Util.alpha(Commons.Color.accent, 0.45) : Util.alpha("#012533", 0.2)
        Gradient {
          id: glassTile
          GradientStop { position: 0; color: "#f6f8f8" }
          GradientStop { position: 1; color: "#cfdde0" }
        }
      }

      Grid {
        // As large as an app icon, which keeps a margin inside its square: the
        // grid takes about 70% of the tile.
        readonly property int square: Math.round(window.iconSize * 0.17)
        readonly property bool mono: parent.mono

        anchors.centerIn: parent
        columns: 3
        spacing: Math.round(window.iconSize * 0.07)

        Repeater {
          model: parent.mono
            ? [1, 0.55, 1, 0.55, 1, 0.55, 1, 0.55, 1]
            : ["#fac40b", "#156570", "#e8705f", "#8cc79a", "#5fa8d3", "#c39bd3", "#f59e3b", "#589199", "#012533"]

          delegate: Rectangle {
            required property var modelData
            width: parent.square
            height: parent.square
            radius: window.themedStyle ? Math.min(Style.cornerRadius, Math.round(parent.square * 0.25)) : Math.max(1, Math.round(parent.square * 0.25))
            color: typeof modelData === "number" ? Util.alpha(Commons.Color.accent, modelData) : modelData
          }
        }
      }
    }
  }

  component AppSlot: Slot {
    id: appSlot

    required property int index
    required property string key
    // A fixed slot (Files) cannot be dragged.
    property bool fixed: false
    readonly property var modelData: window.dock ? window.dock.itemFor(key) : null
    readonly property bool launching: !!window.dock && window.dock.isLaunching(key)
    readonly property bool lifted: window.dragIndex === index
    property point pressPoint
    property bool dragged: false
    readonly property int windowCount: modelData ? modelData.windows.length : 0
    readonly property bool active: {
      var list = modelData ? modelData.windows : []
      for (var i = 0; i < list.length; i++) if (list[i].toplevel && list[i].toplevel.activated) return true
      return false
    }
    property real pulse: 1
    // Asking for attention: three bounces, then a glowing halo.
    readonly property bool urgent: !!window.dock && !!modelData && window.dock.isUrgent(modelData)
    property real bounce: 0
    property real glow: 0
    onUrgentChanged: {
      if (urgent) {
        if (Style.reduceMotion || !window.dock.bounce) return
        if (window.attention === "bounce") bounceAnim.restart()
        else if (window.attention === "flash") flashAnim.restart()
      } else {
        flashAnim.stop()
        bounceAnim.stop()
        appSlot.bounce = 0
      }
    }
    // An app joining the dock fades in and grows while its slot opens and
    // pushes its neighbours aside (presence). Leaving is the reverse: the icon
    // shrinks away, then the slot closes. At shell startup the slots are just
    // there.
    readonly property bool animated: !Style.reduceMotion && window.settled && !fixed
    property real appear: animated ? 0 : 1
    property real presence: animated ? 0 : 1
    NumberAnimation on appear { running: appSlot.animated; from: 0; to: 1; duration: Style.duration(260); easing.type: Easing.OutBack }
    NumberAnimation on presence { running: appSlot.animated; from: 0; to: 1; duration: Style.duration(220); easing.type: Easing.OutCubic }
    readonly property bool leaving: !!window.dock && !!window.dock.leavingKeys[key]
    onLeavingChanged: {
      if (leaving) leaveAnim.restart()
      else if (leaveAnim.running || presence < 1) { leaveAnim.stop(); comeBackAnim.restart() }
    }
    SequentialAnimation {
      id: leaveAnim
      NumberAnimation { target: appSlot; property: "appear"; to: 0; duration: Style.duration(180); easing.type: Easing.InCubic }
      NumberAnimation { target: appSlot; property: "presence"; to: 0; duration: Style.duration(200); easing.type: Easing.InOutCubic }
      ScriptAction { script: if (window.dock) window.dock.finishLeaving(appSlot.key) }
    }
    ParallelAnimation {
      id: comeBackAnim
      NumberAnimation { target: appSlot; property: "presence"; to: 1; duration: Style.duration(200); easing.type: Easing.OutCubic }
      NumberAnimation { target: appSlot; property: "appear"; to: 1; duration: Style.duration(220); easing.type: Easing.OutBack }
    }
    readonly property string monoGlyph: window.dock ? window.dock.monoGlyphFor(key) : ""
    // A leaving app has no item anymore, so the icon keeps the last one it had.
    property url lastIcon: ""
    readonly property url iconUrl: {
      var url = window.dock && appSlot.modelData ? window.dock.iconFor(appSlot.modelData) : ""
      return url !== "" ? url : lastIcon
    }
    onIconUrlChanged: if (iconUrl !== "") lastIcon = iconUrl
    width: window.vertical ? window.slotSize : window.slotSize * presence
    height: window.vertical ? window.slotSize * presence : window.slotSize
    // Wheel: one notch (120) per window, whether from a mouse or a touchpad.
    property real wheelAccum: 0

    // App groups (setting groups): a separator between groups, and the group's
    // color on the app's stripe and dots.
    readonly property string group: window.dock ? window.dock.groupOf(key) : ""
    readonly property string groupColor: window.dock ? window.dock.groupColor(key) : ""
    readonly property bool groupStart: {
      if (!window.dock || index <= 0) return false
      var model = window.dock.itemModel
      return index - 1 < model.count && window.dock.groupOf(model.get(index - 1).key) !== group
    }

    Separator {
      trailing: false
      visible: appSlot.groupStart && !window.dragging && window.insertIndex < 0
    }

    // A grouped app that is not running: a faint stripe in the group's color.
    Rectangle {
      visible: appSlot.groupColor !== "" && !appSlot.lifted && appSlot.windowCount === 0
      readonly property real thickness: Math.max(2, Style.space(3))
      readonly property real length: window.iconSize * 0.45
      readonly property real edge: window.iconInset / 2 - thickness / 2
      x: window.vertical ? (window.position === "left" ? edge : window.slotSize - edge - thickness)
                         : (window.slotSize - length) / 2 + appSlot.displayedShift
      y: window.vertical ? (window.slotSize - length) / 2 + appSlot.displayedShift
                         : (window.position === "top" ? edge : window.slotSize - edge - thickness)
      width: window.vertical ? thickness : length
      height: window.vertical ? length : thickness
      radius: thickness / 2
      color: appSlot.groupColor
      opacity: 0.5
    }

    running: windowCount > 0
    lit: active

    // A running app: one dot per window, three at most (Omarchy and Cupertino
    // styles).
    Grid {
      id: dots
      readonly property real size: Math.max(3, Style.space(4))
      readonly property real edge: window.iconInset / 2 - size / 2
      visible: window.hoverPop && appSlot.windowCount > 0 && !appSlot.lifted
      columns: window.vertical ? 1 : 3
      spacing: size * 0.8
      x: window.vertical ? (window.position === "left" ? edge : window.slotSize - edge - size)
                         : (window.slotSize - implicitWidth) / 2 + appSlot.displayedShift
      y: window.vertical ? (window.slotSize - implicitHeight) / 2 + appSlot.displayedShift
                         : (window.position === "top" ? edge : window.slotSize - edge - size)

      Repeater {
        model: DockModel.dotCount(appSlot.windowCount)

        delegate: Rectangle {
          width: dots.size
          height: dots.size
          radius: dots.size / 2
          color: appSlot.groupColor !== "" ? appSlot.groupColor : Commons.Color.bar.text
          opacity: appSlot.active ? 1 : 0.75
        }
      }
    }

    // A running app in the Redmond style: a short line under the icon, longer
    // and in the accent when the app has the focus.
    Rectangle {
      readonly property real thickness: Math.max(3, Style.space(3))
      readonly property real length: appSlot.active ? window.iconSize * 0.38 : window.iconSize * 0.16
      readonly property real edge: window.iconInset / 2 - thickness / 2
      visible: window.redmondStyle && appSlot.windowCount > 0 && !appSlot.lifted
      x: window.vertical ? (window.position === "left" ? edge : window.slotSize - edge - thickness)
                         : (window.slotSize - width) / 2 + appSlot.displayedShift
      y: window.vertical ? (window.slotSize - height) / 2 + appSlot.displayedShift
                         : (window.position === "top" ? edge : window.slotSize - edge - thickness)
      width: window.vertical ? thickness : length
      height: window.vertical ? length : thickness
      radius: thickness / 2
      color: appSlot.groupColor !== "" ? appSlot.groupColor
        : appSlot.active ? Commons.Color.accent : Util.alpha(Commons.Color.bar.text, 0.6)
      Behavior on width { enabled: !window.vertical; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
      Behavior on height { enabled: window.vertical; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    }

    // Slots between where the dragged app was and where it would land step
    // aside to make room; the dragged one follows the pointer.
    readonly property real shift: window.insertIndex >= 0 ? (index >= window.insertIndex ? 1 : -1) * window.slotSize / 2
      : !window.dragging ? 0
      : lifted ? window.dragOffset
      : (window.dragIndex < index && index <= window.dropIndex) ? -window.slotSize
      : (window.dropIndex <= index && index < window.dragIndex) ? window.slotSize
      : 0
    property real displayedShift: shift

    // Only while dragging: once the drop reorders the slots, they are already
    // where they were shown.
    Behavior on displayedShift {
      enabled: window.animateShifts && ((window.dragging && !appSlot.lifted) || window.insertIndex >= 0)
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }

    z: lifted ? 1 : 0

    // The slot, and the pointer handling in it, stays where it is; only the
    // icon moves. Reading the pointer through a slot that moves with it would
    // feed each move back into the next.
    function bodyPoint(event) {
      return appSlot.mapToItem(body, event.x, event.y)
    }

    mouse.onPressed: function(event) {
      appSlot.dragged = false
      if (event.button === Qt.LeftButton) appSlot.pressPoint = appSlot.bodyPoint(event)
    }

    mouse.onPositionChanged: function(event) {
      if (appSlot.fixed || appSlot.leaving) return
      if (!(appSlot.mouse.pressedButtons & Qt.LeftButton)) return
      var point = appSlot.bodyPoint(event)
      var delta = window.vertical ? point.y - appSlot.pressPoint.y : point.x - appSlot.pressPoint.x
      // A press that wanders is a drag in the making, not a click.
      if (Math.hypot(point.x - appSlot.pressPoint.x, point.y - appSlot.pressPoint.y) > Style.space(4)) appSlot.dragged = true
      if (!window.dragging) {
        if (Math.abs(delta) < Style.space(6)) return
        window.closeMenu()
        // The landing slot first: with the dragged slot set and no landing
        // slot yet, every slot before it would count as in between and step
        // aside for a moment.
        window.dropIndex = appSlot.index
        window.dragIndex = appSlot.index
      }
      if (!appSlot.lifted) return
      window.dragOffset = delta
      window.dropIndex = DockModel.dropIndex(appSlot.index, delta, window.slotSize, appRepeater.count)
    }

    mouse.onReleased: function(event) {
      if (!appSlot.lifted) return
      window.dropPoint = appSlot.mapToItem(body, event.x, event.y)
      var to = window.dropIndex
      appSlot.dragged = true
      window.endDrag()
      window.dock.moveItem(appSlot.key, to)
    }

    mouse.onCanceled: if (appSlot.lifted) window.endDrag()

    mouse.onClicked: function(event) {
      // A drag ends in a release over the app, which is not a click on it.
      if (appSlot.dragged) {
        appSlot.dragged = false
        return
      }
      if (event.button === Qt.RightButton) {
        window.openMenu(appSlot.modelData, appSlot)
        return
      }
      window.closeMenu()
      if (event.button === Qt.MiddleButton) window.dock.launch(appSlot.modelData)
      else window.dock.activate(appSlot.modelData)
    }

    // Wheel down for the next window, up for the previous one.
    mouse.onWheel: function(event) {
      if (!appSlot.modelData || appSlot.windowCount === 0) return
      var delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
      appSlot.wheelAccum += delta
      // One step at a time: focus has to follow before the next step.
      if (Math.abs(appSlot.wheelAccum) < 120) return
      var step = appSlot.wheelAccum < 0 ? 1 : -1
      appSlot.wheelAccum = 0
      window.dock.cycle(appSlot.modelData, step)
    }

    // Running apps are drawn in full, pinned ones that are not running faded,
    // and one that is starting pulses between the two.
    Image {
      // Centered in the slot, even while it opens or closes.
      x: window.iconInset + (appSlot.width - window.slotSize) / 2
      y: window.iconInset + (appSlot.height - window.slotSize) / 2
      width: window.iconSize
      height: window.iconSize
      sourceSize: Qt.size(window.iconSize * 2, window.iconSize * 2)
      source: appSlot.monoGlyph !== "" ? "" : appSlot.iconUrl
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      mipmap: true
      opacity: Math.min(1, appSlot.appear) * (appSlot.launching ? appSlot.pulse : (appSlot.windowCount > 0 ? 1 : window.idleOpacity))
      // The bounce goes away from the screen edge.
      transform: Translate {
        x: window.vertical ? (window.position === "left" ? appSlot.bounce : -appSlot.bounce) : appSlot.displayedShift
        y: window.vertical ? appSlot.displayedShift : (window.position === "top" ? appSlot.bounce : -appSlot.bounce)
      }
      scale: (appSlot.lifted || (appSlot.hovered && window.hoverPop) ? 1.15 : 1) * (0.5 + 0.5 * appSlot.appear)
      transformOrigin: window.popOrigin

      Behavior on scale { enabled: appSlot.appear >= 1; NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

      MonoTile { visible: appSlot.monoGlyph !== ""; glyph: appSlot.monoGlyph }

      // The badge from the badges setting, in the style's manner: the theme's
      // urgent color and corners in Omarchy's; a red pill on the Mac; a small
      // accent badge at the bottom corner on Windows; an accent pill in Plasma.
      Rectangle {
        readonly property string count: appSlot.modelData ? window.badgeLabel(appSlot.modelData.key) : ""
        readonly property bool accented: window.redmondStyle || window.plasmaStyle
        visible: count !== ""
        height: Math.round(parent.height * (window.redmondStyle ? 0.36 : 0.42))
        width: Math.max(height, badgeText.implicitWidth + height * 0.5)
        radius: window.themedStyle ? Math.min(height / 2, Style.cornerRadius) : height / 2
        x: parent.width - width * 0.75
        y: window.redmondStyle ? parent.height - height * 0.8 : -height * 0.25
        color: window.cupertinoStyle ? "#ff3b30" : accented ? Commons.Color.accent : Commons.Color.urgent
        border.width: window.cupertinoStyle ? 0 : Math.max(1, Style.space(1.5))
        border.color: Commons.Color.background

        Text {
          id: badgeText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: parent.count
          color: parent.accented ? Commons.Color.background : "white"
          font.family: Style.font.family
          font.pixelSize: Math.round(parent.height * 0.62)
          font.bold: true
        }
      }
    }

    SequentialAnimation {
      id: bounceAnim
      loops: 3
      NumberAnimation { target: appSlot; property: "bounce"; from: 0; to: window.slotSize * 0.45; duration: Style.duration(260); easing.type: Easing.OutQuad }
      NumberAnimation { target: appSlot; property: "bounce"; to: 0; duration: Style.duration(420); easing.type: Easing.OutBounce }
    }

    // Behind the icon while the app waits: a glowing accent halo, an orange
    // button that flashes then holds, or a framed accent square.
    Rectangle {
      x: window.iconInset - Style.spacing.xs
      y: window.iconInset - Style.spacing.xs
      width: window.iconSize + Style.spacing.xs * 2
      height: width
      radius: window.attention === "bounce" ? window.popupRadius : window.controlRadius(height)
      color: window.attentionColor
      border.width: window.attention === "highlight" ? Math.max(1, Style.space(1.5)) : 0
      border.color: Util.alpha(Commons.Color.accent, 0.8)
      opacity: !appSlot.urgent ? 0
        : window.attention === "flash" ? 0.12 + 0.5 * appSlot.flash
        : window.attention === "highlight" ? 0.3
        : 0.18 + 0.22 * appSlot.glow
      visible: opacity > 0
      z: -1
      transform: Translate {
        x: window.vertical ? 0 : appSlot.displayedShift
        y: window.vertical ? appSlot.displayedShift : 0
      }
      Behavior on opacity { enabled: !appSlot.urgent; NumberAnimation { duration: Style.duration(200) } }
    }

    // Windows' flash: a few blinks, then it stays lit (at once without
    // motion).
    property real flash: 1
    SequentialAnimation {
      id: flashAnim
      onStopped: appSlot.flash = 1
      SequentialAnimation {
        loops: 4
        NumberAnimation { target: appSlot; property: "flash"; to: 0; duration: Style.duration(380); easing.type: Easing.InOutSine }
        NumberAnimation { target: appSlot; property: "flash"; to: 1; duration: Style.duration(380); easing.type: Easing.InOutSine }
      }
    }

    SequentialAnimation {
      running: appSlot.urgent && !Style.reduceMotion && window.attention === "bounce"
      loops: Animation.Infinite
      onRunningChanged: if (!running) appSlot.glow = 0
      NumberAnimation { target: appSlot; property: "glow"; from: 0; to: 1; duration: Style.duration(900); easing.type: Easing.InOutSine }
      NumberAnimation { target: appSlot; property: "glow"; to: 0; duration: Style.duration(900); easing.type: Easing.InOutSine }
    }

    // With animations off it holds still rather than spinning through
    // zero-length steps.
    SequentialAnimation {
      running: appSlot.launching && !Style.reduceMotion
      loops: Animation.Infinite
      onRunningChanged: if (!running) appSlot.pulse = 1

      NumberAnimation { target: appSlot; property: "pulse"; from: 1; to: window.idleOpacity; duration: Style.duration(500); easing.type: Easing.InOutSine }
      NumberAnimation { target: appSlot; property: "pulse"; to: 1; duration: Style.duration(500); easing.type: Easing.InOutSine }
    }
  }

  // The tile of a mono glyph: the theme's background, with the border and the
  // glyph in its accent, so the dock follows any theme.
  component MonoTile: Rectangle {
    property string glyph: ""
    // A full trash: a dome rises above the lid, as if it overflowed.
    property bool bulge: false
    // The tile's own size, for one drawn larger than the dock's icons.
    property real size: window.iconSize
    anchors.fill: parent
    anchors.margins: Math.round(size * 0.04)
    radius: window.tileRadiusFor(size)
    color: Commons.Color.background
    border.width: Math.max(1, Style.space(1.5))
    border.color: Util.alpha(Commons.Color.accent, 0.45)
    Text {
      id: glyphText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.glyph
      color: Commons.Color.accent
      font.family: Style.fontFamily
      font.pixelSize: Math.round(parent.size * 0.58)
    }

    Item {
      visible: parent.bulge
      readonly property real g: glyphText.font.pixelSize
      width: g * 0.56
      height: g * 0.22
      x: (parent.width - width) / 2
      y: parent.height / 2 - g * 0.37 - height
      clip: true
      Rectangle {
        width: parent.width
        height: parent.height * 2
        radius: height / 2
        color: Commons.Color.accent
        // A border in the theme's background sets the dome apart from the lid.
        border.width: Math.max(1.5, parent.g * 0.06)
        border.color: Commons.Color.background
      }
    }
  }

  // A slot that is not an app: an icon that grows on hover and steps aside
  // like the apps button when an app comes in from the app grid.
  component IconSlot: Slot {
    id: iconSlot

    // In mono style, the glyph replaces the image.
    property string glyph: ""
    property bool bulge: false
    readonly property bool mono: !!window.dock && window.dock.iconStyle === "omarchy" && glyph !== ""
    property string iconSource: ""
    property real insertShift: 0
    property bool highlight: false
    property real displayedShift: window.insertIndex >= 0 ? insertShift : 0

    Behavior on displayedShift {
      enabled: window.animateShifts
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }

    transform: Translate {
      x: window.vertical ? 0 : iconSlot.displayedShift
      y: window.vertical ? iconSlot.displayedShift : 0
    }

    // A highlight behind the icon while something is dropped on it or its
    // popup is open.
    Rectangle {
      anchors.fill: parent
      anchors.margins: Style.spacing.xxs
      radius: window.popupRadius
      color: Util.alpha(Commons.Color.bar.text, 0.16)
      opacity: iconSlot.highlight ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }
    }

    Image {
      x: window.iconInset
      y: window.iconInset
      width: window.iconSize
      height: window.iconSize
      sourceSize: Qt.size(window.iconSize * 2, window.iconSize * 2)
      source: iconSlot.mono ? "" : iconSlot.iconSource
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      mipmap: true
      MonoTile { visible: iconSlot.mono; glyph: iconSlot.glyph; bulge: iconSlot.bulge }
      scale: (iconSlot.hovered && window.hoverPop) || iconSlot.highlight ? 1.15 : 1
      transformOrigin: window.popOrigin
      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
    }
  }

  // Now playing (setting music): the track's cover with the start of its title
  // and artist beside it, or the cover alone when mini or on a side dock, where
  // the dock is one icon wide. A click plays or pauses; hovering, or a right
  // click to keep it open, brings up the controls above it. The tile opens and
  // closes like an app as a player comes and goes.
  // The tile opening (0 to 1) as a player comes, closing as it goes; the
  // separators beside it wait until it is fully gone.
  property real musicPresence: dock && dock.musicPlayer ? 1 : 0
  Behavior on musicPresence {
    enabled: window.settled && !Style.reduceMotion
    NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic }
  }
  readonly property real musicSpan: !dock || vertical || dock.musicSize === "mini" ? 1
    : (dock.musicSize === "large" ? 3.6 : 2.6)

  component MusicSlot: Slot {
    id: musicSlot
    // It lights up as a whole tile, below.
    styleHover: false

    readonly property var player: window.dock ? window.dock.musicPlayer : null
    readonly property bool playing: !!player && player.isPlaying
    readonly property string art: window.dock ? window.dock.musicArt : ""
    readonly property real progress: player && player.lengthSupported && player.positionSupported
      ? DockModel.trackProgress(player.position, player.length) : 0

    readonly property real presence: window.musicPresence
    visible: presence > 0
    width: window.vertical ? window.slotSize : Math.round(window.slotSize * window.musicSpan * presence)
    height: window.vertical ? window.slotSize * presence : window.slotSize

    onHoveredChanged: {
      if (hovered) { musicHoverTimer.stop(); window.musicHover = true }
      else musicHoverTimer.restart()
    }

    property real displayedShift: window.insertIndex >= 0 ? window.slotSize / 2 : 0
    Behavior on displayedShift {
      enabled: window.animateShifts
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }
    transform: Translate {
      x: window.vertical ? 0 : musicSlot.displayedShift
      y: window.vertical ? musicSlot.displayedShift : 0
    }

    Separator { trailing: false; visible: !window.dragging && window.insertIndex < 0 }

    Rectangle {
      anchors.fill: parent
      anchors.margins: Style.spacing.xxs
      radius: window.popupRadius
      color: window.hoverFill(Commons.Color.bar.text)
      border.width: window.hoverFrameWidth(Commons.Color.bar.text)
      border.color: window.hoverFrameColor(Commons.Color.bar.text)
      opacity: musicSlot.hovered || window.musicPopupShown ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }
    }

    mouse.onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        window.openMusicMenu(musicSlot)
        return
      }
      if (!window.dock) return
      if (event.button === Qt.MiddleButton) { window.closeMenu(); window.dock.musicOpen() }
      else window.dock.musicToggle()
    }

    Row {
      x: window.iconInset
      y: window.iconInset
      spacing: Style.spacing.sm
      opacity: musicSlot.presence

      MusicCover {
        width: window.iconSize
        height: window.iconSize
        art: musicSlot.art
        playing: musicSlot.playing
        progress: musicSlot.progress
      }

      Column {
        visible: window.musicSpan > 1
        anchors.verticalCenter: parent.verticalCenter
        width: musicSlot.width - window.iconInset * 2 - window.iconSize - Style.spacing.sm
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: window.dock ? window.dock.musicTitle : ""
          elide: Text.ElideRight
          color: Commons.Color.bar.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: window.dock ? window.dock.musicArtist : ""
          visible: text !== ""
          elide: Text.ElideRight
          color: Util.alpha(Commons.Color.bar.text, 0.65)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Weather (setting weather): the condition's glyph over the temperature, on
  // a tile like the mono icons, or a sky in the glass style. Hovering brings up
  // the details, a click keeps them open, a middle click fetches again and a
  // right click opens its settings. With no place known, a click opens them.
  component WeatherSlot: Slot {
    id: weatherSlot
    readonly property var dock: window.dock
    readonly property bool placed: !!dock && dock.weatherHasPlace
    readonly property var now: dock && dock.weather ? dock.weather.now : null
    label: placed ? "" : strings.t("weather.choosePlace")
    visible: !!dock && dock.showWeather

    property real displayedShift: window.insertIndex >= 0 ? window.slotSize / 2 : 0
    Behavior on displayedShift {
      enabled: window.animateShifts
      NumberAnimation { duration: Style.duration(150); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    }
    transform: Translate {
      x: window.vertical ? 0 : weatherSlot.displayedShift
      y: window.vertical ? weatherSlot.displayedShift : 0
    }

    // The music's separator stands for both when the music is shown.
    Separator { trailing: false; visible: window.musicPresence <= 0 && !window.dragging && window.insertIndex < 0 }

    onHoveredChanged: {
      if (hovered && placed) { weatherHoverTimer.stop(); window.weatherHover = true }
      else weatherHoverTimer.restart()
    }

    mouse.onClicked: function(event) {
      if (!weatherSlot.dock) return
      if (event.button === Qt.RightButton || !weatherSlot.placed) {
        window.closeMenu()
        window.weatherHover = false
        weatherSlot.dock.openSettings("weather")
      } else if (event.button === Qt.MiddleButton) weatherSlot.dock.refreshWeather()
      else if (window.weatherMenu) window.closeMenu()
      else window.openWeatherMenu(weatherSlot)
    }

    // Inset like the mono tiles (MonoTile), so it lines up with them at
    // every icon size.
    Item {
      x: window.iconInset
      y: window.iconInset
      width: window.iconSize
      height: window.iconSize
      scale: window.hoverPop && (weatherSlot.hovered || window.weatherPopupShown) ? 1.15 : 1
      transformOrigin: window.popOrigin
      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

      WeatherTile {
        anchors.fill: parent
        anchors.margins: Math.round(window.iconSize * 0.04)
        size: window.iconSize
        code: weatherSlot.now ? weatherSlot.now.code : 2
        night: !!weatherSlot.now && weatherSlot.now.night
        temperature: !weatherSlot.placed ? "" : weatherSlot.now ? weatherSlot.dock.weatherTemp(weatherSlot.now.temp) : "…"
        faded: !weatherSlot.now
      }
    }
  }

  // The weather's square: in mono, the theme's background in an accent frame
  // with the glyph in the accent; in glass, a sky of the hour and the weather
  // with white text. Without a temperature, the glyph alone, larger.
  component WeatherTile: Rectangle {
    id: tile
    property real size: window.iconSize
    property int code: 0
    property bool night: false
    property string temperature: ""
    property bool faded: false
    readonly property bool mono: !window.dock || window.dock.iconStyle === "omarchy"
    readonly property string kind: {
      var k = WeatherModel.conditionKey(code)
      return k === "clear" || k === "mainlyClear" || k === "partlyCloudy" ? "clear" : k === "overcast" || k === "fog" ? "grey" : "wet"
    }
    readonly property var sky: night ? ["#33447a", "#121a3d"]
      : kind === "clear" ? ["#5cb4f5", "#1f6fd0"] : kind === "grey" ? ["#9aabbe", "#5b6d82"] : ["#6f86a3", "#34475f"]
    readonly property color ink: mono ? Commons.Color.accent : "#ffffff"

    radius: window.tileRadiusFor(size)
    color: mono ? Commons.Color.background : sky[1]
    gradient: mono ? null : skyGradient
    border.width: mono ? Math.max(1, Style.space(1.5)) : 0
    border.color: Util.alpha(Commons.Color.accent, 0.45)
    Gradient {
      id: skyGradient
      GradientStop { position: 0; color: tile.sky[0] }
      GradientStop { position: 1; color: tile.sky[1] }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: tile.temperature !== "" ? -tile.size * 0.12 : 0
      textFormat: Text.PlainText
      text: WeatherModel.glyph(tile.code, tile.night)
      color: tile.ink
      opacity: tile.faded ? 0.55 : 1
      font.family: Style.fontFamily
      font.pixelSize: Math.round(tile.size * (tile.temperature !== "" ? 0.36 : 0.5))
    }
    Text {
      visible: tile.temperature !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Math.round(tile.size * 0.06)
      textFormat: Text.PlainText
      text: tile.temperature
      color: tile.mono ? Commons.Color.foreground : "#ffffff"
      font.family: Style.font.family
      font.pixelSize: Math.round(tile.size * 0.25)
      font.bold: true
      font.features: { "tnum": 1 }
    }
  }

  component MusicCoverImage: Image {
    signal ready()
    // The cover asked for, as the player named it (source may be rewritten).
    property string wanted: ""
    source: wanted
    property real reveal: 1
    anchors.fill: parent
    sourceSize: Qt.size(width * 2, height * 2)
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    smooth: true
    mipmap: true
    opacity: reveal
    visible: status === Image.Ready && reveal > 0
    onStatusChanged: if (status === Image.Ready) ready()
  }

  // A track's cover, with how far the track has gone along its bottom edge; a
  // note on the dock's tile when there is none. Two images take turns: the
  // next cover loads behind the shown one, then fades in over it. A cover
  // that comes during a fade ends it at once, so a quick skip never brings an
  // older cover back.
  component MusicCover: Item {
    id: musicCover
    property string art: ""
    property bool playing: false
    property real progress: 0
    property bool firstFront: true
    readonly property Image front: firstFront ? coverFirst : coverSecond
    readonly property Image back: firstFront ? coverSecond : coverFirst
    readonly property bool hasCover: front.status === Image.Ready || back.status === Image.Ready
    // The cover and the note share one corner, which eases from the note
    // tile's to the cover's (barely rounded) as one gives way to the other.
    readonly property real tileRadius: window.tileRadiusFor(width)
    property real cornerRadius: hasCover ? Math.max(2, Math.round(width * 0.06)) : tileRadius
    Behavior on cornerRadius {
      enabled: !Style.reduceMotion
      NumberAnimation { duration: Style.duration(260); easing.type: Easing.InOutQuad }
    }
    property real coverShown: hasCover ? 1 : 0
    Behavior on coverShown {
      enabled: !Style.reduceMotion
      NumberAnimation { duration: Style.duration(260); easing.type: Easing.InOutQuad }
    }

    onArtChanged: loadCover()
    Component.onCompleted: loadCover()

    function loadCover() {
      if (coverFade.running) { coverFade.stop(); swapCover() }
      if (art === "") { coverFirst.wanted = ""; coverSecond.wanted = ""; return }
      if (front.wanted === art && front.status !== Image.Error) { back.wanted = ""; return }
      back.reveal = 0
      back.wanted = art
    }

    function coverReady(image) {
      if (image !== back || image.wanted !== art) return
      image.z = 1
      front.z = 0
      if (front.status !== Image.Ready || Style.reduceMotion) { image.reveal = 1; swapCover() }
      else coverFade.restart()
    }

    function swapCover() {
      back.reveal = 1
      firstFront = !firstFront
    }

    MonoTile {
      glyph: "\u{f075a}"
      size: musicCover.width
      radius: musicCover.cornerRadius
      opacity: 1 - musicCover.coverShown
      visible: opacity > 0
    }

    Rectangle {
      opacity: musicCover.coverShown
      visible: opacity > 0
      anchors.fill: parent
      anchors.margins: Math.round(musicCover.width * 0.04)
      anchors.topMargin: Math.round(musicCover.width * 0.04) + Math.max(1, Math.round(musicCover.width * 0.03))
      anchors.bottomMargin: Math.round(musicCover.width * 0.04) - Math.max(1, Math.round(musicCover.width * 0.03))
      radius: musicCover.cornerRadius
      color: Util.alpha("black", 0.3)
    }

    ClippingRectangle {
      anchors.fill: parent
      anchors.margins: Math.round(musicCover.width * 0.04)
      // A cover is square: barely rounded, so nothing of it is cut, with a
      // hairline edge and a soft shadow to sit on the dock like an icon.
      radius: musicCover.cornerRadius
      color: "transparent"
      border.width: 1
      border.color: Util.alpha("black", 0.25)
      opacity: musicCover.coverShown
      visible: opacity > 0

      Item {
        anchors.fill: parent
        // Paused, the cover fades like an app that is not running.
        opacity: musicCover.playing ? 1 : window.idleOpacity
        Behavior on opacity { NumberAnimation { duration: Style.duration(160) } }

        MusicCoverImage { id: coverFirst; onReady: musicCover.coverReady(coverFirst) }
        MusicCoverImage { id: coverSecond; onReady: musicCover.coverReady(coverSecond) }
      }

      NumberAnimation {
        id: coverFade
        target: musicCover.back
        property: "reveal"
        from: 0
        to: 1
        duration: Style.duration(260)
        easing.type: Easing.InOutQuad
        onFinished: musicCover.swapCover()
      }

      Rectangle {
        visible: musicCover.progress > 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.max(2, Math.round(musicCover.height * 0.07))
        color: Util.alpha("black", 0.35)
        Rectangle {
          height: parent.height
          width: parent.width * musicCover.progress
          color: Commons.Color.accent
        }
      }
    }
  }

  // The stack: a click shows a folder's newest files.
  component StackSlot: IconSlot {
    id: stackSlot
    label: window.dock ? window.dock.stackFolderLabel : ""
    // A plain folder with no symbol on it: details are lost at dock size.
    iconSource: window.dock && window.dock.iconStyle === "system" && window.dock.stackSystemIcon
      ? window.dock.stackSystemIcon : Qt.resolvedUrl("icons/stack.png")
    glyph: "\u{f024d}"
    insertShift: window.slotSize / 2
    highlight: window.stackOpen

    mouse.onClicked: function(event) {
      if (event.button === Qt.MiddleButton) {
        window.closeMenu()
        if (window.dock) window.dock.openStackFolder()
        return
      }
      window.toggleStack(stackSlot)
    }

    // The music's or the weather's separator stands for both when one is shown.
    Separator { trailing: false; visible: window.musicPresence <= 0 && !(window.dock && window.dock.showWeather) && !window.dragging && window.insertIndex < 0 }
  }

  // The trash: a click opens it, files dropped on it go in, and a right click
  // offers to empty it.
  component TrashSlot: IconSlot {
    id: trashSlot
    label: strings.t("trash")
    // The glass icons are icons/*.svg rendered with rsvg-convert -w 256.
    readonly property string glassIcon: window.dock && window.dock.trashFull
      ? Qt.resolvedUrl("icons/trash-full.png")
      : Qt.resolvedUrl("icons/trash-empty.png")
    iconSource: window.dock && window.dock.iconStyle === "system"
      ? window.dock.systemIcon(window.dock.trashFull ? "user-trash-full" : "user-trash", glassIcon) : glassIcon
    glyph: window.dock && window.dock.trashFull ? "\u{f0a79}" : "\u{f0a7a}"
    bulge: !!window.dock && window.dock.trashFull

    // The stack's separator, when there is no stack.
    Separator { trailing: false; visible: (!window.dock || !window.dock.showStack) && window.musicPresence <= 0 && !(window.dock && window.dock.showWeather) && !window.dragging && window.insertIndex < 0 }
    insertShift: window.slotSize / 2
    highlight: trashDrop.containsDrag || (window.trashMenu && window.menuSlot === trashSlot)

    mouse.onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        window.openTrashMenu(trashSlot)
        return
      }
      window.closeMenu()
      if (window.dock) window.dock.openTrash()
    }

    DropArea {
      id: trashDrop
      anchors.fill: parent
      onEntered: function(drag) {
        if (drag.hasUrls) drag.accept(Qt.MoveAction)
      }
      onDropped: function(drop) {
        if (!drop.hasUrls || !window.dock) return
        var uris = []
        for (var i = 0; i < drop.urls.length; i++) {
          var url = String(drop.urls[i])
          if (url.indexOf("file://") === 0) uris.push(url)
        }
        window.dock.trashFiles(uris)
        drop.accept(Qt.MoveAction)
      }
    }
  }

  // A line across the dock at the leading or trailing edge of a slot.
  // A line between groups of slots, in the style's manner: the theme's muted
  // color in Omarchy's; taller and clear on the Mac; a mere hint on Windows,
  // whose taskbar has none; faint in Plasma.
  readonly property real separatorLength: cupertinoStyle ? 0.7 : redmondStyle ? 0.45 : plasmaStyle ? 0.55 : 0.6
  readonly property color separatorColor: cupertinoStyle ? Util.alpha(Commons.Color.bar.text, 0.32)
    : redmondStyle ? Util.alpha(Commons.Color.bar.text, 0.12)
    : plasmaStyle ? Util.alpha(Commons.Color.bar.text, 0.2)
    : Util.alpha(Commons.Color.muted, 0.7)

  // An app asking for attention (setting attention, by default as the style
  // does): it bounces, then a halo glows (Omarchy, Cupertino, as on a Mac);
  // its button flashes orange, then stays orange (Redmond, as on Windows); its
  // square lights up in the accent, framed (Plasma, as in KDE). The bounce
  // setting turns the motion off, leaving the mark alone.
  readonly property string attention: dock && dock.attention !== "auto" ? dock.attention
    : redmondStyle ? "flash" : plasmaStyle ? "highlight" : "bounce"
  // The hovered slot's name (setting labels, by default as the style does):
  // a pill standing a little off the dock (Cupertino, as on a Mac); a small,
  // plain box (Redmond, as on Windows); the theme's tooltip otherwise.
  readonly property string labelStyle: dock && dock.labelStyle !== "auto" ? dock.labelStyle
    : cupertinoStyle ? "pill" : redmondStyle ? "box" : "theme"
  readonly property color attentionColor: attention === "flash" ? "#f59e0b" : Commons.Color.accent

  component Separator: Rectangle {
    property bool trailing: true
    visible: !window.dragging && window.insertIndex < 0
    readonly property real thickness: window.cupertinoStyle ? Math.max(1, Style.space(1)) : Math.max(1, Style.space(1.5))
    readonly property real inset: window.slotSize * (1 - window.separatorLength) / 2
    x: window.vertical ? inset : (trailing ? window.slotSize - thickness / 2 : -thickness / 2)
    y: window.vertical ? (trailing ? window.slotSize - thickness / 2 : -thickness / 2) : inset
    width: window.vertical ? window.slotSize * window.separatorLength : thickness
    height: window.vertical ? thickness : window.slotSize * window.separatorLength
    radius: thickness / 2
    color: window.separatorColor
  }

  // The open stack: the newest files in a grid. A click opens one, a right
  // click offers to show, copy or trash it, and a file can be dragged into
  // another app. At the bottom: open the folder, or pick another one.
  property var stackMenuFile: null

  BorderSurface {
    id: stackPopup

    // Three rows along a horizontal dock, wider for more files.
    readonly property int columns: window.vertical ? 3 : Math.max(5, Math.ceil((window.dock ? window.dock.stackLimit : 15) / 3))
    readonly property int cell: Style.space(96)
    readonly property var files: window.dock ? window.dock.stackFiles : []

    visible: window.contentShown && window.stackOpen
    width: columns * cell + padding * 2 + Style.spacing.sm * 2
    height: stackColumn.implicitHeight + padding * 2
    x: window.popupX(window.menuSlot, stackPopup)
    y: window.popupY(window.menuSlot, stackPopup)
    radius: window.popupRadius
    color: Util.alpha(Commons.Color.popups.background, window.popupOpacity)
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    // The stack fades in, rising from the dock.
    property real reveal: 0
    onVisibleChanged: if (visible) { reveal = Style.reduceMotion ? 1 : 0; revealAnim.restart() }
    NumberAnimation { id: revealAnim; target: stackPopup; property: "reveal"; to: 1; duration: Style.duration(180); easing.type: Easing.OutCubic }
    opacity: reveal
    transform: Translate {
      y: window.position === "bottom" ? (1 - stackPopup.reveal) * Style.space(12) : window.position === "top" ? -(1 - stackPopup.reveal) * Style.space(12) : 0
      x: window.position === "left" ? -(1 - stackPopup.reveal) * Style.space(12) : window.position === "right" ? (1 - stackPopup.reveal) * Style.space(12) : 0
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: window.stackMenuFile = null
    }

    Column {
      id: stackColumn
      x: stackPopup.contentLeftInset + Style.spacing.sm
      y: stackPopup.contentTopInset
      width: stackPopup.columns * stackPopup.cell
      spacing: Style.spacing.xs

      Text {
        width: parent.width
        height: Style.spacing.popupRowHeight
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: window.dock ? window.dock.stackFolderLabel : ""
        color: Commons.Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        visible: stackPopup.files.length === 0
        width: parent.width
        height: stackPopup.cell
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: strings.t("stack.emptyFolder")
        color: Util.alpha(Commons.Color.popups.text, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Grid {
        visible: stackPopup.files.length > 0
        columns: stackPopup.columns

        Repeater {
          model: stackPopup.files.slice(0, window.dock ? window.dock.stackLimit : 15)

          delegate: Item {
            id: fileCell
            required property var modelData
            required property int index
            readonly property string iconUrl: window.dock ? window.dock.iconForFile(modelData) : ""
            width: stackPopup.cell
            height: stackPopup.cell

            // The files come in one after another.
            opacity: 0
            scale: 0.85
            Component.onCompleted: appearAnim.start()
            SequentialAnimation {
              id: appearAnim
              PauseAnimation { duration: Style.reduceMotion ? 0 : Style.duration(18 * fileCell.index) }
              ParallelAnimation {
                NumberAnimation { target: fileCell; property: "opacity"; to: 1; duration: Style.duration(160); easing.type: Easing.OutCubic }
                NumberAnimation { target: fileCell; property: "scale"; to: 1; duration: Style.duration(200); easing.type: Easing.OutBack }
              }
            }

            Rectangle {
              anchors.fill: parent
              anchors.margins: Style.spacing.xxs
              radius: window.popupRadius
              color: fileMouse.containsMouse || window.stackMenuFile === fileCell.modelData ? Style.hoverFill : "transparent"
            }

            // Images show their contents, other files their type's icon.
            Image {
              id: fileIcon
              anchors.horizontalCenter: parent.horizontalCenter
              y: Style.spacing.sm
              width: Math.round(stackPopup.cell * 0.5)
              height: width
              sourceSize: Qt.size(width * 2, height * 2)
              source: window.dock && window.dock.isImage(fileCell.modelData) ? window.dock.fileUri(fileCell.modelData.path) : fileCell.iconUrl
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              mipmap: true
              onStatusChanged: if (status === Image.Error && source !== fileCell.iconUrl) source = fileCell.iconUrl
            }

            Text {
              anchors.top: fileIcon.bottom
              anchors.topMargin: Style.spacing.xs
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width - Style.spacing.sm * 2
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: fileCell.modelData.name
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.body * 0.85)
              wrapMode: Text.WrapAnywhere
              maximumLineCount: 2
              elide: Text.ElideMiddle
            }

            // What a drag into another app carries: the file itself.
            Item {
              id: dragProxy
              width: fileIcon.width
              height: fileIcon.height
              Drag.dragType: Drag.Automatic
              Drag.supportedActions: Qt.CopyAction
              Drag.mimeData: ({ "text/uri-list": window.dock ? window.dock.fileUri(fileCell.modelData.path) + "\r\n" : "" })
              Drag.imageSource: fileIcon.source
              Drag.active: fileMouse.drag.active
              Drag.onDragFinished: function(action) { window.closeMenu() }
            }

            MouseArea {
              id: fileMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              drag.target: dragProxy
              drag.threshold: Style.space(6)
              onReleased: { dragProxy.x = 0; dragProxy.y = 0 }
              onClicked: function(event) {
                if (event.button === Qt.RightButton) {
                  window.stackMenuFile = window.stackMenuFile === fileCell.modelData ? null : fileCell.modelData
                  return
                }
                var path = fileCell.modelData.path
                window.closeMenu()
                if (window.dock) window.dock.openPath(path)
              }
            }
          }
        }
      }

      // Actions on the file picked with a right click.
      Column {
        visible: !!window.stackMenuFile
        width: parent.width

        StackRow {
          text: window.stackMenuFile ? strings.t("stack.file").arg(window.stackMenuFile.name) : ""
          bold: true
          interactive: false
        }
        StackRow { text: strings.t("stack.open"); onTriggered: { var p = window.stackMenuFile.path; window.closeMenu(); window.dock.openPath(p) } }
        StackRow { text: strings.t("stack.reveal"); onTriggered: { var p = window.stackMenuFile.path; window.closeMenu(); window.dock.revealPath(p) } }
        StackRow { text: strings.t("stack.copy"); onTriggered: { window.dock.copyPaths([window.stackMenuFile.path]); window.stackMenuFile = null } }
        StackRow { text: strings.t("stack.moveToTrash"); onTriggered: { window.dock.trashFiles([window.stackMenuFile.path]); window.stackMenuFile = null } }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Util.alpha(Commons.Color.muted, 0.5)
      }

      StackRow {
        text: strings.t("stack.openFolder")
        onTriggered: { window.closeMenu(); window.dock.openStackFolder() }
      }

      // The stack's folder.
      Flow {
        width: parent.width
        spacing: Style.spacing.xs

        Repeater {
          model: window.dock ? window.dock.stackFolders : []

          delegate: Chip {
            required property var modelData
            text: window.dock.placeLabel(modelData.label)
            current: !!window.dock && window.dock.stackFolder === modelData.path
            onClicked: if (!current) window.dock.setStackFolder(modelData.path)
          }
        }
      }
    }
  }

  component StackRow: Rectangle {
    id: stackRow
    property string text: ""
    property bool bold: false
    property bool interactive: true
    signal triggered()

    width: parent ? parent.width : 0
    height: Style.spacing.popupRowHeight
    radius: window.popupRadius
    color: interactive && stackRowMouse.containsMouse ? Style.hoverFill : "transparent"

    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.rightMargin: Style.spacing.controlPaddingX
      elide: Text.ElideMiddle
      textFormat: Text.PlainText
      text: stackRow.text
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: stackRow.bold
    }

    MouseArea {
      id: stackRowMouse
      anchors.fill: parent
      enabled: stackRow.interactive
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: stackRow.triggered()
    }
  }

  // The music controls, above the music tile (beside it on a side dock): the
  // cover and the track, how far it has gone (a click moves there), then the
  // previous track, play or pause, the next track and mute. Long enough to
  // cross from the tile, they stay while the pointer is on either.
  Timer {
    id: musicHoverTimer
    interval: 250
    onTriggered: if (!musicPopupHover.hovered && !musicSlotItem.hovered) window.musicHover = false
  }

  BorderSurface {
    id: musicPopup

    readonly property var player: window.dock ? window.dock.musicPlayer : null
    readonly property bool playing: !!player && player.isPlaying
    readonly property real length: player && player.lengthSupported ? player.length : 0
    readonly property real position: player && player.positionSupported ? player.position : 0
    // A player that gave a track length keeps its progress bar between two
    // tracks, empty and inactive, so the box keeps its height.
    property var lengthPlayer: null
    onLengthChanged: if (length > 0) lengthPlayer = player
    readonly property bool showProgress: length > 0 || (!!player && player === lengthPlayer)
    readonly property bool canMute: !!window.dock && window.dock.musicCanMute

    function time(seconds) {
      var s = Math.max(0, Math.floor(Number(seconds) || 0))
      var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
      var rr = r < 10 ? "0" + r : String(r)
      return h > 0 ? h + ":" + (m < 10 ? "0" + m : m) + ":" + rr : m + ":" + rr
    }

    readonly property bool wanted: window.contentShown && window.musicPopupShown && !window.dragging && window.insertIndex < 0
    visible: wanted || reveal > 0
    width: Style.space(300) + padding * 2
    height: musicColumn.implicitHeight + contentTopInset + contentBottomInset
    x: window.popupX(musicSlotItem, musicPopup)
    y: window.popupY(musicSlotItem, musicPopup)
    radius: window.popupRadius
    color: Util.alpha(Commons.Color.popups.background, window.popupOpacity)
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    // It fades in, rising from the dock like the stack, and fades back out,
    // a little faster, sinking toward it.
    property real reveal: 0
    onWantedChanged: {
      musicRevealAnim.stop()
      if (wanted && player) player.positionChanged()
      if (Style.reduceMotion) { reveal = wanted ? 1 : 0; return }
      musicRevealAnim.to = wanted ? 1 : 0
      musicRevealAnim.duration = Style.duration(wanted ? 160 : 120)
      musicRevealAnim.easing.type = wanted ? Easing.OutCubic : Easing.InCubic
      musicRevealAnim.start()
    }
    NumberAnimation { id: musicRevealAnim; target: musicPopup; property: "reveal" }
    opacity: reveal
    transform: Translate {
      y: window.position === "bottom" ? (1 - musicPopup.reveal) * Style.space(8) : window.position === "top" ? -(1 - musicPopup.reveal) * Style.space(8) : 0
      x: window.position === "left" ? -(1 - musicPopup.reveal) * Style.space(8) : window.position === "right" ? (1 - musicPopup.reveal) * Style.space(8) : 0
    }

    HoverHandler {
      id: musicPopupHover
      onHoveredChanged: {
        if (hovered) { musicHoverTimer.stop(); window.musicHover = true }
        else musicHoverTimer.restart()
      }
    }

    Column {
      id: musicColumn
      x: musicPopup.contentLeftInset
      y: musicPopup.contentTopInset
      width: musicPopup.width - musicPopup.contentLeftInset - musicPopup.contentRightInset
      spacing: Style.spacing.sm

      Row {
        width: parent.width
        spacing: Style.spacing.sm

        MusicCover {
          width: Style.space(56)
          height: width
          art: window.dock ? window.dock.musicArt : ""
          playing: true
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(56) - parent.spacing
          spacing: Style.space(2)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: window.dock ? window.dock.musicTitle : ""
            elide: Text.ElideRight
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: window.dock ? window.dock.musicArtist : ""
            visible: text !== ""
            elide: Text.ElideRight
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: musicPopup.player && musicPopup.player.identity ? musicPopup.player.identity : ""
            visible: text !== ""
            elide: Text.ElideRight
            color: Util.alpha(Commons.Color.popups.text, 0.55)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // How far the track has gone; a click moves there when the player can.
      Item {
        visible: musicPopup.showProgress
        width: parent.width
        height: Style.space(14)

        Rectangle {
          id: musicTrack
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: Math.max(3, Style.space(4))
          // Square with a square theme, as Omarchy's own sliders.
          radius: !window.themedStyle || Style.cornerRadius > 0 ? height / 2 : 0
          color: Util.alpha(Commons.Color.popups.text, 0.18)
          Rectangle {
            height: parent.height
            radius: parent.radius
            width: parent.width * DockModel.trackProgress(musicPopup.position, musicPopup.length)
            color: Commons.Color.accent
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: !!musicPopup.player && musicPopup.player.canSeek && musicPopup.length > 0
          cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: function(event) {
            musicPopup.player.position = Math.max(0, Math.min(musicPopup.length, musicPopup.length * event.x / width))
          }
        }
      }

      Item {
        visible: musicPopup.showProgress
        opacity: musicPopup.length > 0 ? 1 : 0.4
        width: parent.width
        height: musicElapsed.implicitHeight
        Text {
          id: musicElapsed
          textFormat: Text.PlainText
          text: musicPopup.time(musicPopup.position)
          color: Util.alpha(Commons.Color.popups.text, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.features: { "tnum": 1 }
        }
        Text {
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: musicPopup.time(musicPopup.length)
          color: Util.alpha(Commons.Color.popups.text, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.features: { "tnum": 1 }
        }
      }

      // The controls on the left, the player's app on the right, under the
      // elapsed and total times.
      Item {
        width: parent.width
        height: musicControls.height

        Row {
          id: musicControls
          spacing: Style.spacing.sm

          MusicButton {
            glyph: "\u{f04ae}"
            tip: strings.t("music.previous")
            enabled: !!musicPopup.player && musicPopup.player.canGoPrevious
            onTriggered: window.dock.musicPrevious()
          }
          MusicButton {
            glyph: musicPopup.playing ? "\u{f03e4}" : "\u{f040a}"
            tip: musicPopup.playing ? strings.t("music.pause") : strings.t("music.play")
            accent: true
            onTriggered: window.dock.musicToggle()
          }
          MusicButton {
            glyph: "\u{f04ad}"
            tip: strings.t("music.next")
            enabled: !!musicPopup.player && musicPopup.player.canGoNext
            onTriggered: window.dock.musicNext()
          }
          MusicButton {
            visible: musicPopup.canMute
            glyph: window.dock && window.dock.musicMuted ? "\u{f075f}" : "\u{f057e}"
            tip: window.dock && window.dock.musicMuted ? strings.t("music.unmute") : strings.t("music.mute")
            onTriggered: window.dock.musicToggleMute()
          }
        }

        MusicButton {
          anchors.right: parent.right
          glyph: "\u{f03cc}"
          iconSource: window.dock ? window.dock.musicIcon : ""
          tip: musicPopup.player && musicPopup.player.identity ? strings.t("music.open").arg(musicPopup.player.identity) : strings.t("music.openPlayer")
          onTriggered: { window.closeMenu(); window.musicHover = false; window.dock.musicOpen() }
        }
      }
    }
  }

  // The weather's details, above its tile (beside it on a side dock): the
  // place and the condition, the temperature, how it feels, the wind and the
  // humidity, then the next three days, and a button for more.
  Timer {
    id: weatherHoverTimer
    interval: 250
    onTriggered: if (!weatherPopupHover.hovered && !weatherSlotItem.hovered) window.weatherHover = false
  }

  BorderSurface {
    id: weatherPopup

    readonly property var dock: window.dock
    readonly property var now: dock && dock.weather ? dock.weather.now : null
    readonly property var days: dock && dock.weather ? dock.weather.days : []
    readonly property color dim: Util.alpha(Commons.Color.popups.text, 0.6)

    readonly property bool wanted: window.contentShown && window.weatherPopupShown && !window.dragging && window.insertIndex < 0
    visible: wanted || reveal > 0
    width: Style.space(300) + padding * 2
    height: weatherColumn.implicitHeight + contentTopInset + contentBottomInset
    x: window.popupX(weatherSlotItem, weatherPopup)
    y: window.popupY(weatherSlotItem, weatherPopup)
    radius: window.popupRadius
    color: Util.alpha(Commons.Color.popups.background, window.popupOpacity)
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    // It comes and goes like the music's.
    property real reveal: 0
    onWantedChanged: {
      weatherRevealAnim.stop()
      if (Style.reduceMotion) { reveal = wanted ? 1 : 0; return }
      weatherRevealAnim.to = wanted ? 1 : 0
      weatherRevealAnim.duration = Style.duration(wanted ? 160 : 120)
      weatherRevealAnim.easing.type = wanted ? Easing.OutCubic : Easing.InCubic
      weatherRevealAnim.start()
    }
    NumberAnimation { id: weatherRevealAnim; target: weatherPopup; property: "reveal" }
    opacity: reveal
    transform: Translate {
      y: window.position === "bottom" ? (1 - weatherPopup.reveal) * Style.space(8) : window.position === "top" ? -(1 - weatherPopup.reveal) * Style.space(8) : 0
      x: window.position === "left" ? -(1 - weatherPopup.reveal) * Style.space(8) : window.position === "right" ? (1 - weatherPopup.reveal) * Style.space(8) : 0
    }

    HoverHandler {
      id: weatherPopupHover
      onHoveredChanged: {
        if (hovered) { weatherHoverTimer.stop(); window.weatherHover = true }
        else weatherHoverTimer.restart()
      }
    }

    Column {
      id: weatherColumn
      x: weatherPopup.contentLeftInset
      y: weatherPopup.contentTopInset
      width: weatherPopup.width - weatherPopup.contentLeftInset - weatherPopup.contentRightInset
      spacing: Style.spacing.sm

      // The glyph, the place and the condition, the temperature on the right.
      Item {
        width: parent.width
        height: Style.space(48)

        Text {
          id: weatherBig
          width: Style.space(48)
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: WeatherModel.glyph(weatherPopup.now ? weatherPopup.now.code : 2, !!weatherPopup.now && weatherPopup.now.night)
          color: Commons.Color.accent
          opacity: weatherPopup.now ? 1 : 0.55
          font.family: Style.fontFamily
          font.pixelSize: Style.space(36)
        }

        Column {
          anchors.left: weatherBig.right
          anchors.leftMargin: Style.spacing.sm
          anchors.right: weatherNowTemp.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: weatherPopup.dock ? weatherPopup.dock.weatherPlaceName : ""
            elide: Text.ElideRight
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: weatherPopup.now ? weatherPopup.dock.weatherCondition(weatherPopup.now.code) : strings.t("weather.loading")
            elide: Text.ElideRight
            color: weatherPopup.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          id: weatherNowTemp
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: weatherPopup.now ? weatherPopup.dock.weatherTemp(weatherPopup.now.temp) : ""
          color: Commons.Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
          font.features: { "tnum": 1 }
        }
      }

      Text {
        visible: !!weatherPopup.now
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: !weatherPopup.now ? "" : [
          strings.t("weather.feels").arg(weatherPopup.dock.weatherTemp(weatherPopup.now.feels)),
          strings.t("weather.wind").arg(Number(weatherPopup.now.wind).toLocaleString(Qt.locale(), "f", 0) + (weatherPopup.dock.weatherImperial ? " mph" : " km/h")),
          strings.t("weather.humidity").arg(Number(weatherPopup.now.humidity).toLocaleString(Qt.locale(), "f", 0))
        ].join("  ·  ")
        color: weatherPopup.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        visible: weatherPopup.days.length > 0
        width: parent.width
        height: Math.max(1, Style.normalBorderWidth)
        color: Util.alpha(Commons.Color.popups.text, 0.12)
      }

      // The next three days.
      Row {
        visible: weatherPopup.days.length > 0
        width: parent.width

        Repeater {
          model: weatherPopup.days

          Column {
            required property var modelData
            width: weatherColumn.width / Math.max(1, weatherPopup.days.length)
            spacing: Style.space(2)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: Qt.locale().dayName(new Date(String(modelData.date) + "T12:00:00").getDay(), Locale.ShortFormat)
              color: weatherPopup.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: WeatherModel.glyph(modelData.code, false)
              color: Commons.Color.accent
              font.family: Style.fontFamily
              font.pixelSize: Style.font.display
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.StyledText
              text: weatherPopup.dock.weatherTemp(modelData.max) + " <font color=\"" + weatherPopup.dim + "\">"
                + weatherPopup.dock.weatherTemp(modelData.min) + "</font>"
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.features: { "tnum": 1 }
            }
          }
        }
      }

      // Where it comes from on the left, more details on the right.
      Item {
        width: parent.width
        height: weatherDetailsButton.height

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Open-Meteo"
          color: Util.alpha(Commons.Color.popups.text, 0.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          id: weatherDetailsButton
          anchors.right: parent.right
          width: weatherDetailsText.implicitWidth + Style.spacing.sm * 2
          height: Style.space(28)
          radius: window.controlRadius(height)
          readonly property bool hot: weatherDetailsMouse.containsMouse
          color: hot ? window.hoverFill(Commons.Color.popups.text) : "transparent"
          border.width: hot ? window.hoverFrameWidth(Commons.Color.popups.text) : 0
          border.color: window.hoverFrameColor(Commons.Color.popups.text)

          Text {
            id: weatherDetailsText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: strings.t("weather.details")
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            id: weatherDetailsMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { window.closeMenu(); window.weatherHover = false; window.dock.weatherDetails() }
          }
        }
      }
    }
  }

  // A button in the music controls: round in the Cupertino style, with the
  // theme's corners in Omarchy's, as its own panels' buttons.
  component MusicButton: Rectangle {
    id: musicButton
    property string glyph: ""
    // An app's icon in place of the glyph, when there is one.
    property string iconSource: ""
    property string tip: ""
    property bool accent: false
    signal triggered()
    width: Style.space(28)
    height: width
    radius: window.controlRadius(width)
    opacity: enabled ? 1 : 0.4
    // No border at rest; hovering fills it, and frames it where the style
    // frames what is hovered (Omarchy, with the theme's own tokens; Plasma).
    readonly property bool hot: buttonMouse.containsMouse
    color: accent ? Commons.Color.accent : hot ? window.hoverFill(Commons.Color.popups.text) : "transparent"
    border.width: hot ? window.hoverFrameWidth(Commons.Color.popups.text) : 0
    border.color: window.hoverFrameColor(Commons.Color.popups.text)
    Image {
      id: buttonIcon
      anchors.centerIn: parent
      width: Math.round(musicButton.width * 0.7)
      height: width
      sourceSize: Qt.size(width * 2, height * 2)
      source: musicButton.iconSource
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      visible: status === Image.Ready
    }
    Text {
      anchors.centerIn: parent
      visible: !buttonIcon.visible
      textFormat: Text.PlainText
      text: musicButton.glyph
      color: musicButton.accent ? Commons.Color.background : Commons.Color.popups.text
      font.family: Style.fontFamily
      font.pixelSize: Math.round(musicButton.width * 0.6)
    }
    MouseArea {
      id: buttonMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: musicButton.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: musicButton.triggered()
    }
  }

  // The hovered slot's name, above it (beside it on a side dock), hidden while
  // a menu or a drag is on. It is outside the input mask and takes no clicks.
  property Item hoverSlot: null

  BorderSurface {
    id: hoverLabel

    readonly property var item: window.hoverSlot ? window.hoverSlot.modelData : null
    readonly property string name: {
      if (window.hoverSlot && window.hoverSlot.label) return window.hoverSlot.label
      var entry = item && window.dock ? window.dock.entryFor(item) : null
      return entry && entry.name ? entry.name : (item ? item.key : "")
    }

    visible: window.contentShown && name !== "" && !window.menuOpen && !window.dragging && window.insertIndex < 0
    readonly property real sidePadding: window.labelStyle === "pill" ? Style.spacing.sm : Style.spacing.xs
    width: Math.ceil(Math.min(window.menuWideWidth, hoverText.implicitWidth)) + contentLeftInset + contentRightInset + sidePadding * 2
    height: hoverText.implicitHeight + padding * 2
    x: window.hoverSlot ? window.popupX(window.hoverSlot, hoverLabel) : 0
    y: window.hoverSlot ? window.popupY(window.hoverSlot, hoverLabel) : 0
    // As labelStyle says.
    readonly property real offset: window.labelStyle === "pill" ? Style.space(4) : 0
    transform: Translate {
      x: window.position === "left" ? hoverLabel.offset : window.position === "right" ? -hoverLabel.offset : 0
      y: window.position === "top" ? hoverLabel.offset : window.position === "bottom" ? -hoverLabel.offset : 0
    }
    radius: window.labelStyle === "pill" ? height / 2 : window.labelStyle === "box" ? Style.space(3) : window.popupRadius
    color: Commons.Color.tooltip.background
    borderSpec: Border.surfaceSpec("tooltip", "border", Commons.Color.tooltip.border, Style.normalBorderWidth)
    padding: Style.spacing.xs

    Text {
      id: hoverText
      x: hoverLabel.contentLeftInset + hoverLabel.sidePadding
      y: hoverLabel.contentTopInset
      width: hoverLabel.width - hoverLabel.contentLeftInset - hoverLabel.contentRightInset - hoverLabel.sidePadding * 2
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: hoverLabel.name
      color: Commons.Color.tooltip.text
      font.family: Style.font.family
      font.pixelSize: window.labelStyle === "box" ? Style.font.bodySmall : Style.font.body
    }
  }

  BorderSurface {
    id: menu

    readonly property var item: window.menuItem
    readonly property bool hasEntry: !!item && !!window.dock && !!window.dock.entryFor(item)
    readonly property bool running: !!item && item.windows.length > 0
    readonly property bool isFiles: !!item && !!window.dock && item.key === window.dock.filesKey
    readonly property string appName: {
      var entry = item && window.dock ? window.dock.entryFor(item) : null
      return entry && entry.name ? entry.name : (item ? item.key : "")
    }

    visible: window.contentShown && (!!item || window.settingsMenu || window.trashMenu)
    width: (menu.running ? window.menuWideWidth
      : window.settingsMenu ? Style.space(250)
      : Math.max(Style.space(window.trashMenu || menu.isFiles ? 190 : 140), menuColumn.implicitWidth)) + padding * 2
    height: Math.min(menuColumn.implicitHeight + contentTopInset + contentBottomInset, window.menuMaxHeight)
    x: window.popupX(window.menuSlot, menu)
    y: window.popupY(window.menuSlot, menu)
    radius: window.popupRadius
    color: Commons.Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    padding: Style.spacing.sm

    onVisibleChanged: menuScroll.contentY = 0

    Flickable {
      id: menuScroll
      x: menu.contentLeftInset
      y: menu.contentTopInset
      width: menu.width - menu.contentLeftInset - menu.contentRightInset
      height: menu.height - menu.contentTopInset - menu.contentBottomInset
      contentWidth: width
      contentHeight: menuColumn.implicitHeight
      interactive: contentHeight > height
      boundsBehavior: Flickable.StopAtBounds
      clip: true

      Column {
        id: menuColumn
        width: menuScroll.width

        // The apps button's menu: where the dock sits, two switches, and the
        // way to the settings window.
        ChipGroup {
          visible: window.settingsMenu
          label: strings.t("settings.position")
          options: [["bottom", strings.t("dock.positionBottom")], ["left", strings.t("dock.positionLeft")], ["right", strings.t("dock.positionRight")], ["top", strings.t("dock.positionTop")]]
          current: window.position
          onPicked: value => Util.execArgv(["omarchy-dock", "position", value])
        }

        MenuSeparator { visible: window.settingsMenu }

        // The app's windows; a click brings one forward. The focused one has a
        // dot, and the workspace shows on the right.
        Repeater {
          model: menu.item ? menu.item.windows.slice(0, window.maxMenuWindows) : []

          delegate: MenuRow {
            required property var modelData

            visible: !!menu.item && !window.settingsMenu
            text: (modelData.toplevel && modelData.toplevel.title) || menu.appName
            detail: modelData.minimized ? strings.t("window.minimized") : (modelData.workspaceId >= 1 ? strings.t("window.workspace").arg(modelData.workspaceId) : "")
            gutter: true
            marked: !!modelData.toplevel && modelData.toplevel.activated
            onTriggered: window.dock.bringForward(modelData)
          }
        }

        MenuSeparator { visible: menu.running && !window.settingsMenu }

        // Files: the places, then the bookmarks, then the trash.
        Repeater {
          model: menu.isFiles ? window.dock.places.standard : []
          delegate: MenuRow {
            required property var modelData
            text: modelData.label
            onTriggered: window.dock.openPlace(modelData.path)
          }
        }

        MenuSeparator { visible: menu.isFiles && window.dock.places.bookmarks.length > 0 }

        Repeater {
          model: menu.isFiles ? window.dock.places.bookmarks : []
          delegate: MenuRow {
            required property var modelData
            text: modelData.label
            onTriggered: window.dock.openPlace(modelData.path)
          }
        }

        MenuSeparator { visible: menu.isFiles }

        MenuRow {
          visible: menu.isFiles
          text: strings.t("trash")
          onTriggered: window.dock.openTrash()
        }

        MenuRow {
          visible: window.trashMenu
          text: strings.t("trash.open")
          onTriggered: window.dock.openTrash()
        }

        // Emptying takes a second click to confirm.
        MenuRow {
          visible: window.trashMenu
          enabled: !!window.dock && window.dock.trashFull
          opacity: enabled ? 1 : 0.45
          keepOpen: !window.trashConfirm
          text: window.trashConfirm ? strings.t("trash.confirm") : strings.t("trash.empty")
          onTriggered: {
            if (window.trashConfirm) window.dock.emptyTrash()
            else window.trashConfirm = true
          }
        }

        MenuRow {
          visible: window.settingsMenu
          text: strings.t("dock.autoHide")
          checked: !!window.dock && window.dock.autohide
          onTriggered: Util.execArgv(["omarchy-dock", "autohide", window.dock.autohide ? "off" : "on"])
        }

        MenuRow {
          visible: window.settingsMenu
          text: strings.t("settings.reserveSpace")
          checked: !!window.dock && window.dock.reserveSpace
          onTriggered: window.dock.setSetting("reserveSpace", !window.dock.reserveSpace, false)
        }

        MenuSeparator { visible: window.settingsMenu }

        MenuRow {
          visible: window.settingsMenu
          text: strings.t("settings.open")
          onTriggered: window.dock.openSettings("")
        }

        // Hands the app's windows to the Exposé plugin, which shows them as
        // thumbnails.
        MenuRow {
          visible: menu.running && window.dock.exposeAvailable
          text: strings.t("app.showAllWindows")
          onTriggered: {
            var addresses = menu.item.windows.map(function(w) { return String(w.address || "") })
            Util.execArgv(["omarchy-shell", "-q", window.dock.exposeId, "showWindows", JSON.stringify(addresses)])
          }
        }

        MenuRow {
          visible: menu.hasEntry && (menu.running || menu.isFiles)
          text: strings.t("app.newWindow")
          onTriggered: {
            if (menu.isFiles) window.dock.openPlace(window.dock.home)
            else window.dock.launch(menu.item)
          }
        }

        MenuRow {
          visible: menu.hasEntry && !menu.isFiles
          text: menu.item && menu.item.pinned ? strings.t("app.removeFromDock") : strings.t("app.keepInDock")
          onTriggered: window.dock.setPinned(menu.item.key, !menu.item.pinned)
        }

        MenuRow {
          visible: menu.running
          text: strings.t("app.quit")
          onTriggered: window.dock.quit(menu.item)
        }

        // Files, the dock's first slot, also leads to its settings, as the
        // apps button does.
        MenuSeparator { visible: menu.isFiles }

        MenuRow {
          visible: menu.isFiles
          text: strings.t("settings.open")
          onTriggered: window.dock.openSettings("")
        }
      }
    }
  }

  // A choice among a few, as in the stack's folders and the dock's settings.
  component Chip: Rectangle {
    id: chip

    property string text: ""
    property bool current: false
    signal clicked()

    width: chipText.implicitWidth + Style.spacing.md * 2
    height: Style.spacing.popupRowHeight
    radius: window.controlRadius(height)
    color: current ? Commons.Color.menu.selectedBackground : (chipMouse.containsMouse ? Style.hoverFill : Util.alpha(Commons.Color.popups.text, 0.06))

    Text {
      id: chipText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: chip.text
      color: chip.current ? Commons.Color.menu.selectedText : Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.body * 0.9)
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }

  // A setting's name over its choices; the current one is selected.
  component ChipGroup: Column {
    id: group

    property string label: ""
    property var options: []
    property string current: ""
    signal picked(string value)

    width: parent ? parent.width : 0
    height: visible ? implicitHeight : 0
    spacing: Style.spacing.xs
    topPadding: Style.spacing.xs
    bottomPadding: Style.spacing.xs

    Text {
      x: Style.spacing.controlPaddingX
      textFormat: Text.PlainText
      text: group.label
      color: Util.alpha(Commons.Color.popups.text, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Flow {
      x: Style.spacing.controlPaddingX
      width: group.width - Style.spacing.controlPaddingX * 2
      spacing: Style.spacing.xs

      Repeater {
        model: group.options
        delegate: Chip {
          required property var modelData
          text: modelData[1]
          current: group.current === modelData[0]
          onClicked: if (!current) group.picked(modelData[0])
        }
      }
    }
  }

  component MenuSeparator: Rectangle {
    width: parent ? parent.width : 0
    height: visible ? Style.spacing.sm * 2 + 1 : 0
    color: "transparent"
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: Style.spacing.controlPaddingX
      width: parent.width - Style.spacing.controlPaddingX * 2
      height: 1
      color: Util.alpha(Commons.Color.muted, 0.5)
    }
  }

  component MenuRow: Rectangle {
    id: row

    property string text: ""
    property bool checked: false
    // Window rows: a gutter on the left for the focused window's dot (marked),
    // and a quiet detail on the right (workspace, minimized).
    property bool gutter: false
    property bool marked: false
    property string detail: ""
    // Stays open after the click, for the first step of a confirmation.
    property bool keepOpen: false
    signal triggered()

    width: parent ? parent.width : 0
    height: visible ? Style.spacing.popupRowHeight : 0
    radius: Style.cornerRadius
    color: rowMouse.containsMouse ? Style.hoverFill : "transparent"

    Rectangle {
      visible: row.marked
      readonly property real size: Math.max(4, Style.space(5))
      anchors.verticalCenter: parent.verticalCenter
      x: Style.spacing.controlPaddingX
      width: size
      height: size
      radius: size / 2
      color: Commons.Color.accent
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.controlPaddingX + (row.gutter ? Style.space(14) : 0)
      anchors.right: rowDetail.visible ? rowDetail.left : parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: row.text
      color: Commons.Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: row.marked
    }

    Text {
      id: rowDetail
      visible: row.detail !== ""
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      textFormat: Text.PlainText
      text: row.detail
      color: Util.alpha(Commons.Color.popups.text, 0.55)
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.body * 0.85)
    }

    Text {
      visible: row.checked
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.controlPaddingX
      textFormat: Text.PlainText
      text: "✓"
      color: Commons.Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: row.enabled
      onClicked: {
        var keep = row.keepOpen
        row.triggered()
        if (!keep) window.closeMenu()
      }
    }
  }
}
