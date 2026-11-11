import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DockModel.js" as DockModel

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
  readonly property bool menuOpen: menuItem !== null || settingsMenu || trashMenu || stackOpen || aboutOpen
  readonly property bool tucked: autohide && !(revealed || menuOpen || dragging || insertIndex >= 0)
  readonly property bool contentShown: shown && !tucked

  readonly property int gap: Style.spacing.xs
  // In Mac style the dock and its menus keep rounded corners even when windows
  // have none; in Omarchy style they follow the theme.
  readonly property bool macStyle: !dock || dock.style !== "omarchy"
  readonly property int dockRadius: macStyle ? Math.max(Style.cornerRadius, Style.space(16)) : Style.cornerRadius
  readonly property int popupRadius: macStyle ? Math.max(Style.cornerRadius, Style.space(12)) : Style.cornerRadius
  // The tiles the dock draws itself (mono glyphs, the apps button).
  readonly property int tileRadius: macStyle ? Math.round(iconSize * 0.24) : Style.cornerRadius
  // Icons shrink, like on a Mac, when the slots no longer fit along the edge:
  // Files, the apps button, the apps, the stack and the trash.
  readonly property int baseIconSize: Math.round((dock ? dock.iconSize : 45) * Style.fontScale)
  readonly property int minIconSize: Math.round(24 * Style.fontScale)
  readonly property int slotCount: appRepeater.count + 2
    + (dock && dock.filesItem ? 1 : 0) + (dock && dock.showStack ? 1 : 0)
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
  property bool aboutOpen: false
  // The trash menu, the open stack, and the trash waiting for a second click
  // to empty.
  property bool trashMenu: false
  property bool stackOpen: false
  property bool trashConfirm: false

  onWorkspaceIdChanged: if (dock) dock.readMode(workspaceId)
  onShownChanged: {
    if (shown) return
    closeMenu()
    window.revealed = false
  }
  Component.onCompleted: if (dock) dock.readMode(workspaceId)

  function openMenu(item, slot) {
    window.settingsMenu = false
    window.aboutOpen = false
    window.trashMenu = false
    window.stackOpen = false
    window.menuKey = item ? item.key : ""
    window.menuSlot = slot
  }

  function openSettingsMenu(slot) {
    window.menuKey = ""
    window.trashMenu = false
    window.stackOpen = false
    window.aboutOpen = false
    window.settingsMenu = true
    window.menuSlot = slot
  }

  // About opens where the settings menu was, on the same slot.
  function openAbout() {
    window.settingsMenu = false
    window.aboutOpen = true
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
    window.aboutOpen = false
    window.trashConfirm = false
    window.trashMenu = true
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
    window.aboutOpen = false
    if (window.dock) window.dock.refreshStack()
    window.stackOpen = true
    window.menuSlot = slot
  }

  function toggleStackHere() {
    if (window.shown && window.dock && window.dock.showStack) window.toggleStack(stackSlotItem)
  }

  function toggleSettingsHere() {
    if (!window.shown) return
    if (window.settingsMenu || window.aboutOpen) window.closeMenu()
    else window.openSettingsMenu(appsSlotItem)
  }

  function closeMenu() {
    window.menuKey = ""
    window.settingsMenu = false
    window.trashMenu = false
    window.stackOpen = false
    window.trashConfirm = false
    window.aboutOpen = false
    window.menuSlot = null
    if (window.autohide) hideTimer.restart()
  }

  // Places the menu inward of the dock, centered on a slot.
  function popupX(slot, popup) {
    if (!slot) return 0
    var center = slot.mapToItem(window.contentItem, slot.width / 2, 0).x
    if (window.position === "left") return body.x + body.width + window.gap
    if (window.position === "right") return body.x - window.gap - popup.width
    return Math.max(window.gap, Math.min(window.width - popup.width - window.gap, center - popup.width / 2))
  }

  function popupY(slot, popup) {
    if (!slot) return 0
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
    Region { item: aboutPopup.visible ? aboutPopup : null }
  }

  onAutohideChanged: window.revealed = false

  Timer {
    id: hideTimer
    // Long enough to cross a gap between the edge and the icons, no longer.
    interval: 150
    onTriggered: {
      if (!bodyHover.hovered && !edgeHover.hovered && !window.menuOpen && !window.dragging) window.revealed = false
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

    // Mac style: the theme's background, translucent, so a blur rule on the
    // omarchy-dock layer can frost what is behind it.
    Rectangle {
      anchors.fill: parent
      z: -1
      visible: window.macStyle
      radius: window.dockRadius
      color: Util.alpha(Commons.Color.popups.background, 0.5)
      border.width: Style.normalBorderWidth
      border.color: Util.alpha(Commons.Color.bar.text, 0.18)

      // A faint sheen along the top, like a pane of glass.
      Rectangle {
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
      visible: !window.macStyle
      radius: window.dockRadius
      color: Commons.Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    }

    Grid {
      id: slots
      anchors.centerIn: parent
      columns: window.vertical ? 1 : appRepeater.count + 4

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

      // The stack and the trash at the end, after a separator.
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

    width: window.slotSize
    height: window.slotSize

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
      if (window.dock) window.dock.openApps()
    }

    // A grid of app squares reads as "all apps" in any icon theme. Drawn
    // rather than taken from a font, so its edges stay crisp on the
    // transparent dock and it fills its slot like the app icons beside it.
    Item {
      x: window.iconInset
      y: window.iconInset
      width: window.iconSize
      height: window.iconSize
      scale: appsSlot.hovered ? 1.15 : 1
      transformOrigin: window.popOrigin

      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

      // A rounded tile under the nine squares: light with colored squares in
      // glass style, the theme's background with accent squares in mono.
      readonly property bool mono: !window.dock || window.dock.iconStyle === "mono"
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
            radius: window.macStyle ? Math.max(1, Math.round(parent.square * 0.25)) : Math.min(Style.cornerRadius, Math.round(parent.square * 0.25))
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
        if (!Style.reduceMotion && window.dock.bounce) bounceAnim.restart()
      } else {
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

    // A running app: one dot per window, three at most.
    Grid {
      id: dots
      readonly property real size: Math.max(3, Style.space(4))
      readonly property real edge: window.iconInset / 2 - size / 2
      visible: appSlot.windowCount > 0 && !appSlot.lifted
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
      scale: (appSlot.lifted || appSlot.hovered ? 1.15 : 1) * (0.5 + 0.5 * appSlot.appear)
      transformOrigin: window.popOrigin

      Behavior on scale { enabled: appSlot.appear >= 1; NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

      MonoTile { visible: appSlot.monoGlyph !== ""; glyph: appSlot.monoGlyph }

      // The badge from the badges setting.
      Rectangle {
        readonly property string count: appSlot.modelData ? window.badgeLabel(appSlot.modelData.key) : ""
        visible: count !== ""
        height: Math.round(parent.height * 0.42)
        width: Math.max(height, badgeText.implicitWidth + height * 0.5)
        radius: height / 2
        x: parent.width - width * 0.75
        y: -height * 0.25
        color: Commons.Color.urgent
        border.width: Math.max(1, Style.space(1.5))
        border.color: Commons.Color.background

        Text {
          id: badgeText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: parent.count
          color: "white"
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

    // An accent halo behind the icon while the app waits.
    Rectangle {
      x: window.iconInset - Style.spacing.xs
      y: window.iconInset - Style.spacing.xs
      width: window.iconSize + Style.spacing.xs * 2
      height: width
      radius: window.popupRadius
      color: Commons.Color.accent
      opacity: appSlot.urgent ? 0.18 + 0.22 * appSlot.glow : 0
      visible: opacity > 0
      z: -1
      transform: Translate {
        x: window.vertical ? 0 : appSlot.displayedShift
        y: window.vertical ? appSlot.displayedShift : 0
      }
      Behavior on opacity { enabled: !appSlot.urgent; NumberAnimation { duration: Style.duration(200) } }
    }

    SequentialAnimation {
      running: appSlot.urgent && !Style.reduceMotion
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
    anchors.fill: parent
    anchors.margins: Math.round(window.iconSize * 0.04)
    radius: window.tileRadius
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
      font.pixelSize: Math.round(window.iconSize * 0.58)
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
    readonly property bool mono: !!window.dock && window.dock.iconStyle === "mono" && glyph !== ""
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
      scale: iconSlot.hovered || iconSlot.highlight ? 1.15 : 1
      transformOrigin: window.popOrigin
      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
    }
  }

  // The stack: a click shows a folder's newest files.
  component StackSlot: IconSlot {
    id: stackSlot
    label: window.dock ? window.dock.stackFolderLabel : ""
    // A plain folder with no symbol on it: details are lost at dock size.
    iconSource: Qt.resolvedUrl("icons/stack.png")
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

    Separator { trailing: false }
  }

  // The trash: a click opens it, files dropped on it go in, and a right click
  // offers to empty it.
  component TrashSlot: IconSlot {
    id: trashSlot
    label: strings.t("trash")
    // The glass icons are icons/*.svg rendered with rsvg-convert -w 256.
    iconSource: window.dock && window.dock.trashFull
      ? Qt.resolvedUrl("icons/trash-full.png")
      : Qt.resolvedUrl("icons/trash-empty.png")
    glyph: window.dock && window.dock.trashFull ? "\u{f0a79}" : "\u{f0a7a}"
    bulge: !!window.dock && window.dock.trashFull

    // The stack's separator, when there is no stack.
    Separator { trailing: false; visible: (!window.dock || !window.dock.showStack) && !window.dragging && window.insertIndex < 0 }
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
  component Separator: Rectangle {
    property bool trailing: true
    visible: !window.dragging && window.insertIndex < 0
    readonly property real thickness: Math.max(1, Style.space(1.5))
    x: window.vertical ? window.slotSize * 0.2 : (trailing ? window.slotSize - thickness / 2 : -thickness / 2)
    y: window.vertical ? (trailing ? window.slotSize - thickness / 2 : -thickness / 2) : window.slotSize * 0.2
    width: window.vertical ? window.slotSize * 0.6 : thickness
    height: window.vertical ? thickness : window.slotSize * 0.6
    radius: thickness / 2
    color: Util.alpha(Commons.Color.muted, 0.7)
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
    color: window.macStyle ? Util.alpha(Commons.Color.popups.background, 0.78) : Commons.Color.popups.background
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
    width: Math.ceil(Math.min(window.menuWideWidth, hoverText.implicitWidth)) + contentLeftInset + contentRightInset + Style.spacing.xs * 2
    height: hoverText.implicitHeight + padding * 2
    x: window.hoverSlot ? window.popupX(window.hoverSlot, hoverLabel) : 0
    y: window.hoverSlot ? window.popupY(window.hoverSlot, hoverLabel) : 0
    radius: window.popupRadius
    color: Commons.Color.tooltip.background
    borderSpec: Border.surfaceSpec("tooltip", "border", Commons.Color.tooltip.border, Style.normalBorderWidth)
    padding: Style.spacing.xs

    Text {
      id: hoverText
      x: hoverLabel.contentLeftInset + Style.spacing.xs
      y: hoverLabel.contentTopInset
      width: hoverLabel.width - hoverLabel.contentLeftInset - hoverLabel.contentRightInset - Style.spacing.xs * 2
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: hoverLabel.name
      color: Commons.Color.tooltip.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
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

        // The dock's settings: a row of choices for each, then the switches.
        ChipGroup {
          visible: window.settingsMenu
          label: strings.t("settings.position")
          options: [["bottom", strings.t("dock.positionBottom")], ["left", strings.t("dock.positionLeft")], ["right", strings.t("dock.positionRight")], ["top", strings.t("dock.positionTop")]]
          current: window.position
          onPicked: value => Util.execArgv(["omarchy-dock", "position", value])
        }

        ChipGroup {
          visible: window.settingsMenu
          label: strings.t("settings.style")
          options: [["mac", strings.t("settings.styleMac")], ["omarchy", strings.t("settings.styleOmarchy")]]
          current: window.dock ? window.dock.style : ""
          onPicked: value => window.dock.setSetting("style", value, "mac")
        }

        ChipGroup {
          visible: window.settingsMenu
          label: strings.t("settings.icons")
          options: [["mono", strings.t("settings.iconsMono")], ["glass", strings.t("settings.iconsGlass")]]
          current: window.dock ? window.dock.iconStyle : ""
          onPicked: value => window.dock.setSetting("iconStyle", value, "mono")
        }

        ChipGroup {
          visible: window.settingsMenu
          label: strings.t("settings.size")
          options: [["small", strings.t("settings.sizeSmall")], ["medium", strings.t("settings.sizeMedium")], ["large", strings.t("settings.sizeLarge")]]
          current: window.dock ? window.dock.iconSizeName : ""
          onPicked: value => window.dock.setSetting("iconSize", value, "medium")
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

        MenuRow {
          visible: window.settingsMenu
          text: strings.t("settings.bounce")
          checked: !!window.dock && window.dock.bounce
          onTriggered: window.dock.setSetting("bounce", !window.dock.bounce, true)
        }

        MenuRow {
          visible: window.settingsMenu
          text: strings.t("settings.stack")
          checked: !!window.dock && window.dock.showStack
          onTriggered: window.dock.setSetting("stack", !window.dock.showStack, true)
        }

        MenuSeparator { visible: window.settingsMenu }

        MenuRow {
          visible: window.settingsMenu
          text: strings.t("settings.edit")
          onTriggered: { window.closeMenu(); window.dock.editSettings() }
        }

        MenuRow {
          visible: window.settingsMenu
          text: strings.t("about")
          keepOpen: true
          onTriggered: window.openAbout()
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
    radius: window.macStyle ? height / 2 : Style.cornerRadius
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

  // About qDock: the owl, the version, the license and the project's page,
  // all read from the manifest.
  BorderSurface {
    id: aboutPopup

    readonly property var manifest: window.dock && window.dock.manifest ? window.dock.manifest : ({})

    visible: window.contentShown && window.aboutOpen
    width: Style.space(260)
    height: aboutColumn.implicitHeight + padding * 2
    x: window.popupX(window.menuSlot, aboutPopup)
    y: window.popupY(window.menuSlot, aboutPopup)
    radius: window.popupRadius
    color: window.macStyle ? Util.alpha(Commons.Color.popups.background, 0.78) : Commons.Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
    padding: Style.spacing.lg

    Column {
      id: aboutColumn
      x: aboutPopup.contentLeftInset
      y: aboutPopup.contentTopInset
      width: aboutPopup.width - aboutPopup.contentLeftInset - aboutPopup.contentRightInset
      spacing: Style.spacing.sm

      Image {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(72)
        height: width
        source: Qt.resolvedUrl("assets/logo.png")
        sourceSize: Qt.size(width * 2, height * 2)
        fillMode: Image.PreserveAspectFit
        smooth: true
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: aboutPopup.manifest.name || "qDock"
        color: Commons.Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: strings.t("about.version").arg(aboutPopup.manifest.version || "")
        color: Util.alpha(Commons.Color.popups.text, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: strings.t("about.description")
        color: Commons.Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: strings.t("about.credits").arg(aboutPopup.manifest.author || "").arg(aboutPopup.manifest.license || "")
        color: Util.alpha(Commons.Color.popups.text, 0.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        visible: !!aboutPopup.manifest.homepage
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: strings.t("about.homepage")
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.underline: homepageMouse.containsMouse

        MouseArea {
          id: homepageMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { window.closeMenu(); Util.execArgv(["xdg-open", aboutPopup.manifest.homepage]) }
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
