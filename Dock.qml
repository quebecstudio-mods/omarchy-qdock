import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "DockModel.js" as DockModel

// An app dock that shows on floating workspaces. A floating workspace has no
// tiles to hand the apps out, so the dock gives back a place to find them:
// pinned apps, running apps, and a grid of every app.
Item {
  id: root
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var shell: null
  property var manifest: null

  // The shell hands its app library only to menu plugins, so the dock loads
  // its own copy of Omarchy's for the app grid: same hidden entries, icons,
  // launch feedback and removal.
  readonly property var appLibrary: shell && shell.appLibrary ? shell.appLibrary : ownAppLibrary.item
  Loader {
    id: ownAppLibrary
    active: !(root.shell && root.shell.appLibrary)
    source: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell/services/AppLibrary.qml"
  }
  // A third-party service plugin is not handed the shell's config, so the
  // "dock" sections of the user's and the default shell.json are read from the
  // files themselves (see the plugin settings below).
  property var fileDockConfig: ({})
  property var fileDefaultDockConfig: ({})
  readonly property var dockConfig: shell && shell.shellConfig && shell.shellConfig.dock ? shell.shellConfig.dock : root.fileDockConfig
  readonly property var defaultDockConfig: shell && shell.defaultsConfig && shell.defaultsConfig.dock ? shell.defaultsConfig.dock : root.fileDefaultDockConfig

  FileView {
    path: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/config/omarchy/shell.json"
    printErrors: false
    onLoaded: {
      try {
        var dock = JSON.parse(text()).dock
        root.fileDefaultDockConfig = dock && typeof dock === "object" ? dock : {}
      } catch (e) {}
    }
  }
  readonly property string position: DockModel.normalizePosition(dockConfig.position)
  readonly property bool vertical: DockModel.isVertical(position)
  readonly property bool autohide: dockConfig.autohide === true

  // The dock's order for the session, as desktop ids, set when the user moves
  // an app: a drag moves it, and keeping it in the dock puts it at the end. An
  // app the order does not know yet goes at the end. Pins are saved in this
  // order.
  property var order: []

  // A reorder shows at once rather than when the saved config comes back.
  property var pendingPins: null
  onDockConfigChanged: pendingPins = null

  // Entries that can claim a terminal app's window: those run in a terminal,
  // and those that hand the terminal an app id of their own.
  readonly property var terminalEntries: {
    var values = DesktopEntries.applications.values
    var out = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry.runInTerminal || String(entry.execString || "").indexOf("--app-id=") >= 0)
        out.push({ id: entry.id, execString: entry.execString, command: entry.command, runInTerminal: entry.runInTerminal })
    }
    return out
  }

  function entryForAppId(appId) {
    var entry = DesktopEntries.heuristicLookup(appId)
    if (entry) return entry
    var id = DockModel.claimingEntryId(appId, root.terminalEntries)
    return id ? DesktopEntries.byId(id) : null
  }

  // The file manager (setting filesApp, a desktop id) is always in the dock,
  // first, and cannot be taken out of it.
  readonly property string filesKey: DockModel.normalizeId(root.settings.filesApp) || "org.gnome.Nautilus"

  // Files has its own slot before the apps button: it is built like the other
  // items, with its windows, but kept out of the list of apps.
  readonly property var items: root.allItems.filter(function(item) { return item.key !== root.filesKey })
  readonly property var filesItem: {
    for (var i = 0; i < root.allItems.length; i++) if (root.allItems[i].key === root.filesKey) return root.allItems[i]
    return null
  }

  // A pinned app that is not installed has nothing to launch, so it is left
  // out until it is. Windows are matched to the desktop entry that claims them.
  readonly property var allItems: {
    var appsRevision = DesktopEntries.applications.values.length
    var pinned = (root.pendingPins || DockModel.pinnedIds(dockConfig, defaultDockConfig)).filter(function(id) {
      return !!DesktopEntries.byId(id)
    })
    if (pinned.indexOf(root.filesKey) < 0 && DesktopEntries.byId(root.filesKey)) pinned = [root.filesKey].concat(pinned)

    var windows = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i].wayland
      if (!toplevel || !toplevel.appId || toplevel.parent) continue
      var entry = root.entryForAppId(toplevel.appId)
      var workspace = toplevels[i].workspace
      windows.push({
        key: entry ? entry.id : toplevel.appId,
        hasEntry: !!entry && !entry.noDisplay,
        workspaceId: workspace ? workspace.id : -1,
        minimized: !!workspace && DockModel.isMinimizedWorkspace(workspace.name),
        address: toplevels[i].address,
        toplevel: toplevel
      })
    }

    return root.grouped(DockModel.orderItems(DockModel.buildItems(pinned, windows), root.order))
  }

  // Plugin settings. Omarchy keeps them in the plugin's entry under "plugins"
  // in shell.json but only hands them to bar widgets, so the dock reads its
  // entry itself.
  property var settings: ({})
  readonly property string userShellJson: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/shell.json"
  // The ids in shell.json's plugins[]: the plugins enabled besides the
  // built-in ones.
  property var pluginIds: []

  FileView {
    path: root.userShellJson
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var id = root.manifest && root.manifest.id ? root.manifest.id : "quebecstudio.qdock"
      var found = {}
      try {
        var config = JSON.parse(text())
        root.fileDockConfig = config.dock && typeof config.dock === "object" ? config.dock : {}
        var list = config.plugins || []
        root.pluginIds = list.map(function(entry) { return entry && typeof entry === "object" ? String(entry.id || "") : String(entry) })
        for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === id) { found = list[i]; break }
      } catch (e) {}
      root.settings = found
    }
  }

  // App groups (setting groups). A group gathers the apps whose desktop id or
  // window class matches one of its regular expressions. Groups follow the
  // setting's order, and ungrouped apps come after them. For example:
  //   "groups": [{ "name": "work", "color": "#2dd4bf", "match": ["^chrome-.*-Profile_1$"] }]
  readonly property var groups: {
    var list = Array.isArray(root.settings.groups) ? root.settings.groups : []
    var out = []
    for (var i = 0; i < list.length && i < 20; i++) {
      var g = list[i]
      if (!g || typeof g.name !== "string" || g.name === "") continue
      out.push({ name: g.name, color: typeof g.color === "string" ? g.color : "",
                 match: DockModel.compilePatterns(g.match) })
    }
    return out
  }

  function groupIndex(key) {
    var k = String(key || "")
    for (var i = 0; i < root.groups.length; i++)
      if (DockModel.matchesAny(root.groups[i].match, k)) return i
    return -1
  }

  function groupOf(key) {
    var i = root.groupIndex(key)
    return i >= 0 ? root.groups[i].name : ""
  }

  function groupColor(key) {
    var i = root.groupIndex(key)
    return i >= 0 ? root.groups[i].color : ""
  }

  // Files first, then each group in turn, then the ungrouped apps.
  function groupRank(key) {
    if (key === root.filesKey) return -1
    var i = root.groupIndex(key)
    return i >= 0 ? i : root.groups.length
  }

  // A stable sort, so the dock's own order holds within each group.
  function grouped(list) {
    var decorated = list.map(function(item, i) { return { item: item, i: i, g: root.groupRank(item.key) } })
    decorated.sort(function(a, b) { return a.g - b.g || a.i - b.i })
    return decorated.map(function(d) { return d.item })
  }

  readonly property var itemsByKey: {
    var byKey = {}
    for (var i = 0; i < root.allItems.length; i++) byKey[root.allItems[i].key] = root.allItems[i]
    return byKey
  }

  function itemFor(key) {
    return root.itemsByKey[key] || null
  }

  // The dock's slots follow this model rather than the items list itself, so
  // a slot survives a window opening or closing instead of being rebuilt
  // under the pointer, and a reorder moves slots rather than replacing them.
  property alias itemModel: itemModel

  ListModel { id: itemModel }

  onItemsChanged: syncItemModel()

  function shownKeys() {
    return root.items.map(function(item) { return item.key })
  }

  // An app that leaves the dock stays in the model for its leave animation
  // (the icon shrinks, then its slot closes), or its slot would vanish at
  // once. It is marked in leavingKeys, and its slot calls finishLeaving when
  // the animation ends.
  property var leavingKeys: ({})

  function syncItemModel() {
    var keys = root.shownKeys()
    var wanted = {}
    for (var w = 0; w < keys.length; w++) wanted[keys[w]] = true
    var leaving = {}
    if (!Style.reduceMotion) {
      for (var m = 0; m < itemModel.count; m++) {
        var gone = itemModel.get(m).key
        if (wanted[gone]) continue
        leaving[gone] = true
        // Right after the slot before it that stays.
        var pos = 0
        for (var p = m - 1; p >= 0; p--) {
          var at = keys.indexOf(itemModel.get(p).key)
          if (at >= 0) { pos = at + 1; break }
        }
        keys.splice(pos, 0, gone)
      }
    }
    for (var i = 0; i < keys.length; i++) {
      if (i < itemModel.count && itemModel.get(i).key === keys[i]) continue
      var found = -1
      for (var j = i + 1; j < itemModel.count; j++) {
        if (itemModel.get(j).key === keys[i]) { found = j; break }
      }
      if (found >= 0) itemModel.move(found, i, 1)
      else itemModel.insert(i, { key: keys[i] })
    }
    if (itemModel.count > keys.length) itemModel.remove(keys.length, itemModel.count - keys.length)
    if (JSON.stringify(leaving) !== JSON.stringify(root.leavingKeys)) root.leavingKeys = leaving
    root.settleLaunches()
  }

  function finishLeaving(key) {
    if (!root.leavingKeys[key]) return
    var next = {}
    for (var k in root.leavingKeys) if (k !== key) next[k] = true
    root.leavingKeys = next
    for (var i = 0; i < itemModel.count; i++) {
      if (itemModel.get(i).key === key) { itemModel.remove(i, 1); break }
    }
  }

  // An app launched from the dock pulses its dot until a new window of it
  // shows up, or for ten seconds if none does.
  property var launches: ({})
  readonly property int launchTimeout: 10000

  function isLaunching(key) {
    return root.launches[key] !== undefined
  }

  function settleLaunches() {
    var next = {}
    var changed = false
    var now = Date.now()
    for (var key in root.launches) {
      var launch = root.launches[key]
      var item = root.itemsByKey[key]
      var windows = item ? item.windows.length : 0
      if (windows > launch.windows || now - launch.at > root.launchTimeout) changed = true
      else next[key] = launch
    }
    if (changed) root.launches = next
  }

  Timer {
    interval: 1000
    repeat: true
    running: Object.keys(root.launches).length > 0
    onTriggered: root.settleLaunches()
  }

  function entryFor(item) {
    return item ? DesktopEntries.byId(item.key) : null
  }

  // Surface style (setting style): "mac", the default, a frosted pane with
  // round corners; "omarchy", opaque surfaces with the theme's corners and
  // popup border, like the shell's own menus.
  readonly property string style: root.settings.style === "omarchy" ? "omarchy" : "mac"

  // Icon size (setting iconSize): "small", "medium" (the default), "large",
  // or a number of pixels. The dock still shrinks icons that would not fit.
  readonly property var iconSizes: ({ small: 36, medium: 45, large: 56 })
  readonly property string iconSizeName: typeof root.settings.iconSize === "number" ? ""
    : (root.iconSizes[root.settings.iconSize] ? root.settings.iconSize : "medium")
  readonly property int iconSize: typeof root.settings.iconSize === "number"
    ? Math.max(24, Math.min(96, Math.round(root.settings.iconSize)))
    : root.iconSizes[root.iconSizeName]

  // Keep the dock's space (setting reserveSpace, off by default): on floating
  // workspaces, a maximized window stops at the dock instead of covering it,
  // like a zoomed window on a Mac. Fullscreen still covers everything.
  readonly property bool reserveSpace: root.settings.reserveSpace === true

  // "Show All Windows" hands an app's windows to the Exposé plugin, so it is
  // offered only while that plugin is enabled in shell.json.
  readonly property string exposeId: "quebecstudio.qexpose"
  readonly property bool exposeAvailable: root.pluginIds.indexOf(root.exposeId) >= 0

  // Apps asking for attention bounce (setting bounce, on by default) before
  // their halo glows.
  readonly property bool bounce: root.settings.bounce !== false

  // Writes a setting into the plugin's entry in shell.json; the default value
  // removes it, so the entry only holds what differs.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  function setSetting(key, value, defaultValue) {
    var json = value === defaultValue ? "null" : JSON.stringify(value)
    Util.execArgv([root.pluginDir + "bin/qdock-config", key, json])
  }

  function editSettings() {
    Util.execArgv(["omarchy-launch-config-editor", root.userShellJson])
  }

  // Icon style (setting iconStyle): "mono", the default, draws Files, the
  // stack and the trash as glyphs in the theme's accent on a tile of its
  // background; "glass" uses the plugin's own icons.
  readonly property string iconStyle: root.settings.iconStyle === "glass" ? "glass" : "mono"

  // Files icon (setting filesIcon): "mono", "glass", "theme" (the icon
  // theme's) or an image path such as "~/Pictures/files.png". Defaults to the
  // icon style.
  readonly property string filesIcon: typeof root.settings.filesIcon === "string" && root.settings.filesIcon !== "" ? root.settings.filesIcon : root.iconStyle

  // The Nerd Font glyph of a slot drawn in mono style, or "". Files is an owl,
  // like the project's logo.
  function monoGlyphFor(key) {
    return key === root.filesKey && root.filesIcon === "mono" ? "\u{f03d2}" : ""
  }

  function iconFor(item) {
    if (item && item.key === root.filesKey && root.filesIcon === "mono") return ""
    if (item && item.key === root.filesKey && root.filesIcon !== "theme") {
      if (root.filesIcon === "glass") return Qt.resolvedUrl("icons/files.png")
      var path = root.filesIcon.replace(/^~(?=\/)/, Quickshell.env("HOME"))
      return path.charAt(0) === "/" ? root.fileUri(path) : ""
    }
    var entry = entryFor(item)
    var icon = entry && entry.icon ? entry.icon : (item ? item.key : "")
    return root.appLibrary ? root.appLibrary.iconSource(icon) : Quickshell.iconPath(icon, true)
  }

  function launch(item) {
    var entry = entryFor(item)
    if (!entry) return
    var next = Object.assign({}, root.launches)
    next[item.key] = { at: Date.now(), windows: item.windows.length }
    root.launches = next
    root.launchEntry(entry)
  }

  // Omarchy's app library launches with its feedback; without it, the entry
  // still launches itself.
  function launchEntry(entry) {
    if (!entry) return
    if (root.appLibrary) root.appLibrary.launch(entry.id, entry.name)
    else entry.execute()
  }

  function activate(item) {
    if (!item) return
    if (item.windows.length === 0) {
      // Files with no window open opens the home folder.
      if (item.key === root.filesKey) root.openPlace(root.home)
      else root.launch(item)
      return
    }
    root.cycle(item, 1)
  }

  // Brings forward the app's next window (1) or previous one (-1), for a
  // repeated click or the wheel over its icon.
  function cycle(item, step) {
    if (!item || item.windows.length === 0) return
    var monitor = Hyprland.focusedMonitor
    var workspaceId = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
    var index = DockModel.stepWindow(item.windows.map(function(window) {
      return { workspaceId: window.workspaceId, minimized: window.minimized, activated: window.toplevel.activated }
    }), workspaceId, step)
    if (index >= 0) root.bringForward(item.windows[index])
  }

  // A window the dock brings forward lands on top of the others, focused; a
  // minimized one first comes back to the workspace in front of the user.
  function bringForward(window) {
    var address = String(window.address || "")
    if (!address) {
      window.toplevel.activate()
      return
    }
    if (address.indexOf("0x") !== 0) address = "0x" + address
    var target = "window = \"address:" + address + "\""
    var steps = []
    var after = []
    if (window.minimized) {
      var monitor = Hyprland.focusedMonitor
      var workspace = monitor && monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
      if (!(workspace >= 1)) return
      // A restored window is simply there again, without animating in.
      steps.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", " + target + " })")
      steps.push("hl.dsp.window.move({ workspace = \"" + workspace + "\", " + target + " })")
      after.push("hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", " + target + " })")
    }
    steps.push("hl.dsp.focus({ " + target + " })")
    steps.push("hl.dsp.window.alter_zorder({ mode = \"top\", " + target + " })")
    var dispatch = function(step) { return "hyprctl dispatch " + Util.shellQuote(step) }
    // The pointer stays on the dock: warping to the focused window is turned
    // off while focusing, then set back to what it was.
    var noWarps = function(value) { return "hyprctl eval \"hl.config({ cursor = { no_warps = " + value + " } })\" >/dev/null" }
    var command = "was=$(hyprctl getoption cursor:no_warps -j | jq -r '.bool // (.int == 1)'); [ \"$was\" = true ] || was=false; "
      + noWarps("true") + "; " + steps.map(dispatch).join(" && ") + "; " + noWarps("$was")
    if (after.length > 0) command += "; sleep 0.4; " + after.map(dispatch).join("; ")
    Util.execDetached(command)
  }

  function quit(item) {
    if (!item) return
    var windows = item.windows.slice()
    for (var i = 0; i < windows.length; i++) windows[i].toplevel.close()
  }

  function openApps() {
    appGrid.open()
  }

  readonly property var pinnedKeys: root.pendingPins || DockModel.pinnedIds(root.dockConfig, root.defaultDockConfig)

  function isPinned(key) {
    return root.pinnedKeys.indexOf(key) >= 0
  }

  // Moves an app to a slot in the dock's order, pinning it there; the pins are
  // saved in the new order. The index counts the slots once the app has left
  // its own.
  function placeAt(key, index) {
    if (!key) return
    root.order = DockModel.orderWithKeyAt(root.shownKeys(), key, index)
    var pinned = {}
    root.pinnedKeys.forEach(function(other) { pinned[other] = true })
    pinned[key] = true
    root.savePins(DockModel.pinsInOrder(root.order, pinned, root.pinnedKeys))
  }

  // A reorder shows at once; the saved config catches up after.
  function savePins(pins) {
    root.pendingPins = pins
    Util.execDetached("omarchy-dock pinned " + pins.map(function(id) { return Util.shellQuote(id) }).join(" "))
  }

  // Moves an app to where a drag dropped it. toIndex counts the dock's slots,
  // leaving apps included (they keep a slot while they shrink away), once the
  // app has left its own; placeAt counts only the apps that stay.
  function moveItem(key, toIndex) {
    if (!key || root.leavingKeys[key]) return
    var index = 0
    var seen = 0
    for (var i = 0; i < itemModel.count && seen < toIndex; i++) {
      var other = itemModel.get(i).key
      if (other === key) continue
      seen++
      if (!root.leavingKeys[other]) index++
    }
    if (root.shownKeys().indexOf(key) !== index) root.placeAt(key, index)
  }

  // An app dropped before the slot at index, counted as the slots stand.
  function pinAt(key, index) {
    var from = root.shownKeys().indexOf(key)
    root.placeAt(key, from >= 0 && from < index ? index - 1 : index)
  }

  // Keeping an app in the dock puts it at the end; taking one out leaves it in
  // its slot while it still runs.
  function setPinned(key, pinned) {
    if (!key) return
    if (pinned) {
      root.placeAt(key, root.shownKeys().length)
    } else {
      root.pendingPins = root.pinnedKeys.filter(function(other) { return other !== key })
      Util.execDetached("omarchy-dock unpin " + Util.shellQuote(key))
    }
  }

  // Each workspace's layout is read once and cached. It only changes through
  // the layout commands, which ask the dock to refresh, or a config reload.
  property var modes: ({})
  property var pendingModes: []
  property int modeGeneration: 0
  property int modeProcWorkspace: -1
  property int modeProcGeneration: 0

  function isFloating(workspaceId) {
    return root.modes[workspaceId] === "floating"
  }

  function readMode(workspaceId) {
    if (!(workspaceId >= 1) || root.modes[workspaceId] !== undefined) return
    if (root.pendingModes.indexOf(workspaceId) === -1) root.pendingModes.push(workspaceId)
    root.readNextMode()
  }

  function readNextMode() {
    if (modeProc.running || root.pendingModes.length === 0) return
    root.modeProcWorkspace = root.pendingModes.shift()
    root.modeProcGeneration = root.modeGeneration
    modeProc.command = ["omarchy-hyprland-workspace-layout-current", String(root.modeProcWorkspace)]
    modeProc.running = true
  }

  function refresh() {
    root.modes = ({})
    root.pendingModes = []
    root.modeGeneration++
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i].activeWorkspace) root.readMode(monitors[i].activeWorkspace.id)
    }
    // Read the rest ahead of time, so the dock shows or hides the moment the
    // user switches to one.
    var workspaces = Hyprland.workspaces.values
    for (var j = 0; j < workspaces.length; j++) root.readMode(workspaces[j].id)
  }

  Component.onCompleted: {
    refresh()
    syncItemModel()
  }

  Process {
    id: modeProc
    stdout: StdioCollector {
      onStreamFinished: {
        var mode = text.trim()
        // A read that started before a refresh may predate the change.
        if (!mode || root.modeProcGeneration !== root.modeGeneration) return
        var next = Object.assign({}, root.modes)
        next[root.modeProcWorkspace] = mode
        root.modes = next
      }
    }
    // Deferred: the process still reports running while it signals exit.
    onExited: Qt.callLater(root.readNextMode)
  }

  // Apps asking for attention. Hyprland reports "urgent" for a window that
  // wants focus without getting it (misc:focus_on_activate = false). Its icon
  // bounces, then glows until the window is focused or closed.
  property var urgentAddresses: ({})

  function normalAddress(address) {
    var a = String(address || "")
    return a.indexOf("0x") === 0 ? a.slice(2) : a
  }

  function setUrgent(address, on) {
    var key = root.normalAddress(address)
    if (!key || !!root.urgentAddresses[key] === on) return
    var next = Object.assign({}, root.urgentAddresses)
    if (on) next[key] = true
    else delete next[key]
    root.urgentAddresses = next
  }

  function isUrgent(item) {
    var list = item ? item.windows : []
    for (var i = 0; i < list.length; i++) {
      if (root.urgentAddresses[root.normalAddress(list[i].address)]) return true
    }
    return false
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      var data = event ? String(event.data || "") : ""
      if (name === "urgent") {
        var active = Hyprland.activeToplevel
        if (!active || root.normalAddress(active.address) !== root.normalAddress(data)) root.setUrgent(data, true)
      }
      else if (name === "activewindowv2" || name === "closewindow") root.setUrgent(data.split(",")[0], false)
      else if (name === "configreloaded") root.refresh()
      // Hyprland's window and workspace lists do not follow fullscreen on
      // their own.
      else if (name === "fullscreen") {
        Hyprland.refreshWorkspaces()
        Hyprland.refreshToplevels()
      }
    }
  }

  ShellIpc {
    target: "omarchy.dock"

    // The layout commands call this after changing a workspace's mode.
    function refresh(): void { root.refresh() }
    function apps(): void { appGrid.toggle() }
    // Toggle the stack or the settings menu of the focused screen's dock, or,
    // with On, of the named screen's.
    function stack(): void { root.dockForScreen("").toggleStackHere() }
    function stackOn(screen: string): void { root.dockForScreen(screen).toggleStackHere() }
    function settings(): void { root.dockForScreen("").toggleSettingsHere() }
    function settingsOn(screen: string): void { root.dockForScreen(screen).toggleSettingsHere() }
  }

  // The dock on the named screen, or on the focused one; a stand-in that does
  // nothing when there is none.
  function dockForScreen(screen) {
    var name = screen || (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) if (windows[i].screen.name === name) return windows[i]
    return { toggleStackHere: function() {}, toggleSettingsHere: function() {} }
  }

  // An app dragged out of the app grid: the grid holds the pointer and
  // reports where it is, and the dock on that screen shows where it would land.
  function dockOn(screen) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].screen === screen) return windows[i]
    }
    return null
  }

  function moveExternalDrag(screen, x, y) {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].screen === screen) windows[i].moveExternalDrag(x, y)
      else windows[i].endExternalDrag()
    }
  }

  function dropExternalDrag(screen, x, y, key) {
    var target = root.dockOn(screen)
    if (target) target.dropExternalDrag(x, y, key)
    root.endExternalDrag()
  }

  function endExternalDrag() {
    var windows = docks.instances
    for (var i = 0; i < windows.length; i++) windows[i].endExternalDrag()
  }

  // The stack shows a folder's newest files, Downloads by default. The chosen
  // folder is kept in a small state file. Settings: stack (shown, true by
  // default), stackCount (files shown, 5 to 30, 15 by default) and
  // stackFolders (folders offered besides the usual ones, such as
  // "~/Pictures/Screenshots").
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/qdock"
  readonly property bool showStack: root.settings.stack !== false
  readonly property int stackLimit: typeof root.settings.stackCount === "number"
    ? Math.max(5, Math.min(30, Math.round(root.settings.stackCount))) : 15
  onStackLimitChanged: root.refreshStack()
  // The folders on offer, as { path, label }: the usual ones from
  // xdg-user-dir, then the user's own.
  property var xdgStackFolders: []
  readonly property var stackFolders: {
    var out = root.xdgStackFolders.slice()
    var extra = Array.isArray(root.settings.stackFolders) ? root.settings.stackFolders : []
    extra.forEach(function(folder) {
      if (typeof folder !== "string") return
      var path = folder.replace(/^~(?=\/|$)/, root.home).replace(/\/+$/, "")
      if (path.indexOf("/") !== 0 || out.some(function(f) { return f.path === path })) return
      out.push({ path: path, label: path.split("/").pop() })
    })
    return out
  }
  property string savedStackFolder: ""
  readonly property string stackFolder: savedStackFolder !== "" ? savedStackFolder
    : (stackFolders.length > 0 ? stackFolders[0].path : home + "/Downloads")
  onStackFolderChanged: root.refreshStack()
  // Stack folder labels are kept as i18n keys (places.*), so they follow the
  // language.
  function placeLabel(label) {
    return String(label).indexOf("places.") === 0 ? strings.t(label) : label
  }

  readonly property string stackFolderLabel: {
    for (var i = 0; i < stackFolders.length; i++)
      if (stackFolders[i].path === stackFolder) return root.placeLabel(stackFolders[i].label)
    return stackFolder.split("/").pop()
  }
  // Newest first: { path, name, dir, mime, time }.
  property var stackFiles: []
  property bool trashFull: false

  function fileUri(path) {
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
  }

  function iconForFile(file) {
    if (!file) return ""
    if (file.dir) return Quickshell.iconPath("folder", true)
    var mime = String(file.mime || "")
    var names = [mime.replace("/", "-"), mime.split("/")[0] + "-x-generic", "text-x-generic"]
    for (var i = 0; i < names.length; i++) {
      var path = Quickshell.iconPath(names[i], true)
      if (path) return path
    }
    return ""
  }

  function isImage(file) {
    return !!file && !file.dir && /^image\/(png|jpeg|gif|webp|bmp|svg\+xml)$/.test(String(file.mime || ""))
  }

  // A read keeps the folder it lists, so its files always get that folder's
  // paths; a refresh asked for meanwhile reads again once it is done.
  property string stackProcFolder: ""
  property bool stackRefreshPending: false
  function refreshStack() {
    if (stackProc.running) {
      root.stackRefreshPending = true
      return
    }
    root.stackRefreshPending = false
    root.stackProcFolder = root.stackFolder
    stackProc.command = ["bash", "-c",
      "cd -- \"$1\" 2>/dev/null || exit 0\n" +
      // One line per file: a name may hold tabs (the name is the last field
      // and is split off by hand), but not a newline, which would cut its line.
      "find . -mindepth 1 -maxdepth 1 ! -name '.*' ! -name '*.crdownload' ! -name '*.part' ! -name $'*\\n*' -printf '%T@\\t%y\\t%f\\n' 2>/dev/null" +
      " | sort -rn | head -n \"$2\" | while IFS= read -r line; do" +
      " t=${line%%$'\\t'*}; rest=${line#*$'\\t'}; y=${rest%%$'\\t'*}; f=${rest#*$'\\t'};" +
      " printf '%s\\t%s\\t%s\\t%s\\n' \"$t\" \"$y\" \"$(file -b --mime-type -- \"$f\" 2>/dev/null)\" \"$f\"; done",
      "stack", root.stackProcFolder, String(root.stackLimit)]
    stackProc.running = true
  }

  function setStackFolder(path) {
    root.savedStackFolder = path
    root.stackFiles = []
    Util.execDetached("mkdir -p " + Util.shellQuote(root.stateDir) + " && printf '%s' " +
      Util.shellQuote(JSON.stringify({ folder: path })) + " > " + Util.shellQuote(root.stateDir + "/stack.json"))
    root.refreshStack()
  }

  function openPath(path) { Util.execDetached("xdg-open " + Util.shellQuote(path)) }
  // Shows the file in the default file manager, through the freedesktop
  // FileManager1 interface that Nautilus, Dolphin, Thunar and others offer.
  function revealPath(path) {
    Quickshell.execDetached(["gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1",
      "--object-path", "/org/freedesktop/FileManager1", "--method", "org.freedesktop.FileManager1.ShowItems",
      "['" + root.fileUri(path).replace(/'/g, "%27") + "']", ""])
  }
  function openStackFolder() { root.openPlace(root.stackFolder) }

  function copyPaths(paths) {
    var uris = paths.map(root.fileUri).join("\n")
    Util.execDetached("printf '%s\\n' " + Util.shellQuote(uris) + " | wl-copy -t text/uri-list")
  }

  // Takes paths or file:// URIs.
  // The stack and the trash icon are refreshed once gio is done.
  function trashFiles(targets) {
    if (!targets || targets.length === 0) return
    var proc = trashCommand.createObject(root, { command: ["gio", "trash", "--"].concat(targets.map(String)) })
    proc.running = true
  }
  Component {
    id: trashCommand
    Process {
      onExited: { trashTimer.restart(); root.refreshStack(); destroy() }
    }
  }

  // A click on the trash brings back its window when one is open, rather than
  // opening another. File managers title it with the trash's display name
  // ("Trash", "Corbeille"), alone or before the app's name.
  property string trashName: "Trash"
  Process {
    running: true
    command: ["gio", "info", "-a", "standard::display-name", "trash:///"]
    stdout: StdioCollector {
      onStreamFinished: {
        var match = /standard::display-name:\s*(.+)/.exec(text)
        if (match) root.trashName = match[1].trim()
      }
    }
  }

  function trashWindow() {
    var windows = root.filesItem ? root.filesItem.windows : []
    for (var i = 0; i < windows.length; i++) {
      var title = String(windows[i].toplevel && windows[i].toplevel.title || "")
      if (title === root.trashName || title.indexOf(root.trashName + " ") === 0) return windows[i]
    }
    return null
  }

  function openTrash() {
    var open = root.trashWindow()
    if (open) root.bringForward(open)
    else root.openPlace("trash:///")
  }

  // The places in the Files menu: the standard XDG folders, then the GTK
  // bookmarks shown in the file manager's sidebar.
  property var xdgDirs: ({})
  property var bookmarks: []

  FileView {
    path: root.home + "/.config/user-dirs.dirs"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var dirs = {}
      var lines = text().split("\n")
      for (var i = 0; i < lines.length; i++) {
        var m = /^XDG_([A-Z]+)_DIR="(.*)"\s*$/.exec(lines[i])
        if (!m) continue
        var path = m[2].replace(/^\$HOME/, root.home).replace(/\/+$/, "")
        if (path && path !== root.home) dirs[m[1]] = path
      }
      root.xdgDirs = dirs
    }
  }

  FileView {
    path: root.home + "/.config/gtk-3.0/bookmarks"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var out = []
      var lines = text().split("\n")
      for (var i = 0; i < lines.length && out.length < 15; i++) {
        var m = /^file:\/\/(\S+)(?:\s+(.*))?$/.exec(lines[i].trim())
        if (!m) continue
        var path = ""
        try { path = decodeURIComponent(m[1]) } catch (e) { continue }
        out.push({ path: path, label: m[2] || path.split("/").pop() || path })
      }
      root.bookmarks = out
    }
  }

  readonly property var places: {
    var labels = [["DOCUMENTS", strings.t("places.documents")], ["DOWNLOAD", strings.t("places.downloads")],
                  ["PICTURES", strings.t("places.pictures")], ["MUSIC", strings.t("places.music")],
                  ["VIDEOS", strings.t("places.videos")], ["DESKTOP", strings.t("places.desktop")]]
    var out = [{ label: strings.t("places.home"), path: root.home }]
    var seen = {}
    seen[root.home] = true
    for (var i = 0; i < labels.length; i++) {
      var path = root.xdgDirs[labels[i][0]]
      if (!path || seen[path]) continue
      seen[path] = true
      out.push({ label: labels[i][1], path: path })
    }
    var marks = []
    for (var j = 0; j < root.bookmarks.length; j++) {
      var b = root.bookmarks[j]
      if (seen[b.path]) continue
      seen[b.path] = true
      marks.push(b)
    }
    return { standard: out, bookmarks: marks }
  }

  // Opens path in a new file manager window. It runs the entry's own command
  // (its Exec, such as "nautilus --new-window %U") rather than gtk-launch or
  // gio open: a D-Bus activated file manager such as Nautilus would only raise
  // the window it already has.
  function openPlace(path) {
    if (!path) return
    var entry = DesktopEntries.byId(root.filesKey)
    var command = entry && entry.command ? Array.prototype.slice.call(entry.command).filter(function(word) {
      return !/^%[a-zA-Z]$/.test(String(word))
    }) : []
    if (command.length > 0) Quickshell.execDetached(["uwsm-app", "--"].concat(command, [path]))
    else Quickshell.execDetached(["gio", "open", path])
  }

  function emptyTrash() {
    Util.execDetached("gio trash --empty")
    root.trashFull = false
  }

  FileView {
    path: root.stateDir + "/stack.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var folder = JSON.parse(text()).folder
        if (typeof folder === "string" && folder.indexOf("/") === 0) root.savedStackFolder = folder
      } catch (e) {}
    }
  }

  Process {
    running: true
    command: ["bash", "-c", "for d in DOWNLOAD DOCUMENTS DESKTOP PICTURES; do printf '%s\\t%s\\n' \"$d\" \"$(xdg-user-dir $d)\"; done"]
    stdout: StdioCollector {
      onStreamFinished: {
        var labels = { DOWNLOAD: "places.downloads", DOCUMENTS: "places.documents",
                       DESKTOP: "places.desktop", PICTURES: "places.pictures" }
        var out = []
        text.split("\n").forEach(function(line) {
          var parts = line.split("\t")
          var path = parts.slice(1).join("\t")
          if (!path || path === root.home || !labels[parts[0]]) return
          out.push({ path: path, label: labels[parts[0]] })
        })
        root.xdgStackFolders = out
      }
    }
  }

  Process {
    id: stackProc
    onExited: if (root.stackRefreshPending) Qt.callLater(root.refreshStack)
    stdout: StdioCollector {
      onStreamFinished: {
        var folder = root.stackProcFolder
        if (folder !== root.stackFolder) return
        var files = []
        text.split("\n").forEach(function(line) {
          var parts = line.split("\t")
          var name = parts.slice(3).join("\t")
          if (parts.length < 4 || !name) return
          files.push({ path: folder + "/" + name, name: name, dir: parts[1] === "d", mime: parts[2], time: Number(parts[0]) })
        })
        root.stackFiles = files
      }
    }
  }

  // The trash icon shows whether it is full, checked every few seconds.
  Timer {
    id: trashTimer
    interval: 4000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (!trashProc.running) trashProc.running = true
  }

  Process {
    id: trashProc
    command: ["sh", "-c", "find \"${XDG_DATA_HOME:-$HOME/.local/share}/Trash/files\" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null"]
    stdout: StdioCollector {
      onStreamFinished: root.trashFull = text.trim() !== ""
    }
  }

  Variants {
    id: docks
    model: Quickshell.screens

    delegate: Component {
      DockWindow {
        required property var modelData

        screen: modelData
        dock: root
      }
    }
  }

  AppGrid {
    id: appGrid
    appLibrary: root.appLibrary
    dock: root
  }
}
