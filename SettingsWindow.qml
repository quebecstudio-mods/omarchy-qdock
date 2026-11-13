import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "WeatherModel.js" as WeatherModel

// qDock's settings, in a window of their own: Omarchy has no settings panel
// for plugins (it does not draw a manifest's settingsForm), so the dock brings
// its own, drawn with Omarchy's controls, in Omarchy's own style. A
// list of sections on the left (Appearance, Behavior, Tiles, Weather, About), the
// section's settings on the right. Esc or a click outside closes it.
Item {
  id: root
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var dock: null
  property bool opened: false
  property string section: "appearance"

  readonly property var sections: [
    { id: "appearance", label: strings.t("settings.appearance"), glyph: "\u{f03d8}" },
    { id: "behavior", label: strings.t("settings.behavior"), glyph: "\u{f0493}" },
    { id: "tiles", label: strings.t("settings.tiles"), glyph: "\u{f0570}" },
    { id: "weather", label: strings.t("settings.weatherSection"), glyph: "\u{f0599}" },
    { id: "about", label: strings.t("settings.aboutSection"), glyph: "\u{f02fd}" }
  ]

  // The card keeps Omarchy's corners whatever the dock's style: its controls
  // are Omarchy's, so the styles stay on the dock. An opaque pane, so the
  // settings read well over any window.
  readonly property string styleName: dock ? dock.style : "omarchy"
  readonly property int cardRadius: Style.cornerRadius

  readonly property color foreground: Commons.Color.popups.text
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property var manifest: dock && dock.manifest ? dock.manifest : ({})

  // Opens on the named section, or else always on the first one.
  function open(name) {
    root.section = name && sections.some(function(s) { return s.id === name }) ? name : sections[0].id
    root.opened = true
  }
  function close() { root.opened = false }

  // The weather place search: Open-Meteo's geocoder, asked once typing stops,
  // in the settings' language. Nothing is asked until something is typed.
  property var placeResults: []
  onOpenedChanged: if (!opened) { placeField.text = ""; placeProc.query = ""; root.placeResults = [] }
  function pickPlace(place) {
    root.dock.setWeatherPlace(place)
    placeField.text = ""
    root.placeResults = []
  }
  Timer {
    id: placeSearch
    interval: 350
    onTriggered: {
      var name = placeField.text.trim()
      if (name.length < 2) { root.placeResults = []; return }
      // A search still running is stopped; the new one starts once it has
      // exited.
      if (placeProc.running) placeProc.running = false
      else root.searchPlace()
    }
  }
  // Searches for what the field holds, unless that is what was just searched.
  function searchPlace() {
    var name = placeField.text.trim()
    if (name.length < 2 || placeProc.running || name === placeProc.query) return
    placeProc.query = name
    placeProc.command = ["curl", "-fsS", "--max-time", "6", WeatherModel.geocodingUrl(name, Qt.locale().name)]
    placeProc.running = true
  }
  Process {
    id: placeProc
    property string query: ""
    stdout: StdioCollector {
      onStreamFinished: if (placeProc.query === placeField.text.trim()) root.placeResults = WeatherModel.parseGeocoding(text)
    }
    onExited: Qt.callLater(root.searchPlace)
  }
  function toggle(name) {
    if (root.opened && (!name || name === root.section)) root.close()
    else root.open(name)
  }

  // The preferred player's choices: automatic, then the players publishing
  // now, then the saved one if it is not among them.
  readonly property var playerOptions: {
    var out = [{ value: "", label: strings.t("settings.musicPlayerAuto") }]
    var seen = {}
    var players = Mpris.players ? Mpris.players.values : []
    for (var i = 0; i < players.length; i++) {
      var name = String(players[i].identity || "").trim()
      if (!name || seen[name.toLowerCase()]) continue
      seen[name.toLowerCase()] = true
      out.push({ value: name, label: name })
    }
    var saved = dock ? dock.musicPreferred : ""
    if (saved && !seen[saved.toLowerCase()]) out.push({ value: saved, label: saved })
    return out
  }

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "qdock-settings"

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.close()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      BorderSurface {
        id: card
        anchors.centerIn: parent
        width: Math.min(Style.space(720), keyCatcher.width - Style.space(32))
        height: Math.min(Style.space(520), keyCatcher.height - Style.space(32))
        radius: root.cardRadius
        color: Util.alpha(Commons.Color.popups.background, 1)
        borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Style.normalBorderWidth)
        padding: Style.spacing.md

        // Swallow clicks so only the scrim outside the card closes it.
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

        // The sections.
        Column {
          id: sidebar
          x: card.contentLeftInset
          y: card.contentTopInset
          width: Style.space(180)
          height: card.height - card.contentTopInset - card.contentBottomInset
          spacing: Style.spacing.xs

          Row {
            spacing: Style.spacing.sm
            leftPadding: Style.spacing.controlPaddingX
            bottomPadding: Style.spacing.md
            topPadding: Style.spacing.xs

            Image {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(28)
              height: width
              source: Qt.resolvedUrl("assets/logo.png")
              sourceSize: Qt.size(width * 2, height * 2)
              fillMode: Image.PreserveAspectFit
              smooth: true
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.manifest.name || "qDock"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }
          }

          Repeater {
            model: root.sections
            delegate: Rectangle {
              id: navRow
              required property var modelData
              readonly property bool current: root.section === modelData.id

              width: sidebar.width
              height: Style.spacing.popupRowHeight
              radius: Math.min(height / 2, root.cardRadius)
              color: current ? Commons.Color.menu.selectedBackground : (navMouse.containsMouse ? Style.hoverFill : "transparent")

              Text {
                id: navGlyph
                anchors.verticalCenter: parent.verticalCenter
                x: Style.spacing.controlPaddingX
                width: Style.space(20)
                textFormat: Text.PlainText
                text: navRow.modelData.glyph
                color: navRow.current ? Commons.Color.accent : root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: navGlyph.right
                anchors.leftMargin: Style.spacing.sm
                textFormat: Text.PlainText
                text: navRow.modelData.label
                color: navRow.current ? Commons.Color.menu.selectedText : root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: navRow.current
              }

              MouseArea {
                id: navMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.section = navRow.modelData.id
              }
            }
          }
        }

        // The settings the window leaves out (groups, badges, the Files app)
        // are in shell.json: a quiet link to it in the bottom left corner, on
        // every page, for those who look.
        Item {
          anchors.left: sidebar.left
          anchors.leftMargin: Style.spacing.controlPaddingX
          anchors.bottom: parent.bottom
          anchors.bottomMargin: card.contentBottomInset + Style.spacing.xs
          width: editRow.implicitWidth
          height: editRow.implicitHeight

          readonly property color tint: editMouse.containsMouse ? root.foreground : Util.alpha(root.foreground, 0.4)

          Row {
            id: editRow
            spacing: Style.spacing.xs

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "shell.json"
              color: editRow.parent.tint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.underline: editMouse.containsMouse
            }

            // It opens elsewhere, in the text editor.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "\u{f03cc}"
              color: editRow.parent.tint
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: editMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.close(); if (root.dock) root.dock.editSettings() }
          }
        }

        // The project's page, in the bottom right corner of the About section,
        // at the bottom of the card.
        Button {
          visible: root.section === "about" && !!root.manifest.homepage
          anchors.right: parent.right
          anchors.rightMargin: card.contentRightInset
          anchors.bottom: parent.bottom
          anchors.bottomMargin: card.contentBottomInset
          text: strings.t("about.homepage")
          iconText: "\u{f02a4}"
          bordered: true
          foreground: root.foreground
          onClicked: { root.close(); Util.execArgv(["xdg-open", root.manifest.homepage]) }
        }

        Rectangle {
          id: divider
          x: sidebar.x + sidebar.width + Style.spacing.md
          y: card.contentTopInset
          width: 1
          height: sidebar.height
          color: Util.alpha(root.foreground, 0.12)
        }

        Flickable {
          id: pane
          x: divider.x + divider.width + Style.spacing.lg
          y: card.contentTopInset
          width: card.width - x - card.contentRightInset - Style.spacing.sm
          height: sidebar.height
          contentWidth: width
          contentHeight: page.implicitHeight
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds
          clip: true

          Connections {
            target: root
            function onSectionChanged() { pane.contentY = 0 }
          }

          Column {
            id: page
            width: pane.width
            spacing: Style.spacing.xl
            topPadding: Style.spacing.xs
            bottomPadding: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              text: {
                for (var i = 0; i < root.sections.length; i++)
                  if (root.sections[i].id === root.section) return root.sections[i].label
                return ""
              }
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            // ---- Appearance ----
            Setting {
              visible: root.section === "appearance"
              label: strings.t("settings.position")
              ButtonGroup {
                options: [
                  { value: "bottom", label: strings.t("dock.positionBottom") },
                  { value: "left", label: strings.t("dock.positionLeft") },
                  { value: "right", label: strings.t("dock.positionRight") },
                  { value: "top", label: strings.t("dock.positionTop") }
                ]
                value: root.dock ? root.dock.position : ""
                foreground: root.foreground
                onChanged: v => Util.execArgv(["omarchy-dock", "position", v])
              }
            }

            Setting {
              visible: root.section === "appearance"
              label: strings.t("settings.style")
              description: strings.t("settings.styleHelp")
              ButtonGroup {
                options: [
                  { value: "omarchy", label: strings.t("settings.styleOmarchy") },
                  { value: "cupertino", label: strings.t("settings.styleCupertino") },
                  { value: "redmond", label: strings.t("settings.styleRedmond") },
                  { value: "plasma", label: strings.t("settings.stylePlasma") }
                ]
                value: root.styleName
                foreground: root.foreground
                onChanged: v => root.dock.setSetting("style", v, "omarchy")
              }
            }

            Setting {
              visible: root.section === "appearance"
              label: strings.t("settings.labels")
              description: strings.t("settings.labelsHelp")
              ButtonGroup {
                options: [
                  { value: "auto", label: strings.t("settings.attentionAuto") },
                  { value: "theme", label: strings.t("settings.labelsTheme") },
                  { value: "pill", label: strings.t("settings.labelsPill") },
                  { value: "box", label: strings.t("settings.labelsBox") }
                ]
                value: root.dock ? root.dock.labelStyle : ""
                foreground: root.foreground
                onChanged: v => root.dock.setSetting("labels", v, "auto")
              }
            }

            Setting {
              visible: root.section === "appearance"
              label: strings.t("settings.launcher")
              description: strings.t("settings.launcherHelp")
              ButtonGroup {
                options: [
                  { value: "omarchy", label: strings.t("settings.styleOmarchy") },
                  { value: "cupertino", label: strings.t("settings.styleCupertino") }
                ]
                value: root.dock ? root.dock.launcherStyle : ""
                foreground: root.foreground
                onChanged: v => root.dock.setSetting("launcher", v, "omarchy")
              }
            }

            Setting {
              visible: root.section === "appearance"
              label: strings.t("settings.icons")
              description: strings.t("settings.iconsHelp")
              ButtonGroup {
                options: [
                  { value: "omarchy", label: strings.t("settings.styleOmarchy") },
                  { value: "glass", label: strings.t("settings.iconsGlass") },
                  { value: "system", label: strings.t("settings.iconsSystem") }
                ]
                value: root.dock ? root.dock.iconStyle : ""
                foreground: root.foreground
                onChanged: v => root.dock.setSetting("iconStyle", v, "omarchy")
              }
            }

            Setting {
              visible: root.section === "appearance"
              label: strings.t("settings.size")
              ButtonGroup {
                options: [
                  { value: "small", label: strings.t("settings.sizeSmall") },
                  { value: "medium", label: strings.t("settings.sizeMedium") },
                  { value: "large", label: strings.t("settings.sizeLarge") }
                ]
                value: root.dock ? root.dock.iconSizeName : ""
                foreground: root.foreground
                onChanged: v => root.dock.setSetting("iconSize", v, "medium")
              }
            }

            // ---- Behavior ----
            Toggle {
              visible: root.section === "behavior"
              width: page.width
              label: strings.t("dock.autoHide")
              description: strings.t("settings.autoHideHelp")
              foreground: root.foreground
              checked: !!root.dock && root.dock.autohide
              onClicked: Util.execArgv(["omarchy-dock", "autohide", root.dock.autohide ? "off" : "on"])
            }

            Toggle {
              visible: root.section === "behavior"
              width: page.width
              label: strings.t("settings.reserveSpace")
              description: strings.t("settings.reserveSpaceHelp")
              foreground: root.foreground
              checked: !!root.dock && root.dock.reserveSpace
              onClicked: root.dock.setSetting("reserveSpace", !root.dock.reserveSpace, false)
            }

            Setting {
              visible: root.section === "behavior"
              label: strings.t("settings.attention")
              description: strings.t("settings.attentionHelp")
              ButtonGroup {
                options: [
                  { value: "auto", label: strings.t("settings.attentionAuto") },
                  { value: "bounce", label: strings.t("settings.attentionBounce") },
                  { value: "flash", label: strings.t("settings.attentionFlash") },
                  { value: "highlight", label: strings.t("settings.attentionHighlight") }
                ]
                value: root.dock ? root.dock.attention : ""
                foreground: root.foreground
                onChanged: v => root.dock.setSetting("attention", v, "auto")
              }
            }

            Toggle {
              visible: root.section === "behavior"
              width: page.width
              label: strings.t("settings.bounce")
              description: strings.t("settings.bounceHelp")
              foreground: root.foreground
              checked: !!root.dock && root.dock.bounce
              onClicked: root.dock.setSetting("bounce", !root.dock.bounce, true)
            }

            // ---- Tiles ----
            Toggle {
              visible: root.section === "tiles"
              width: page.width
              label: strings.t("settings.stack")
              description: strings.t("settings.stackHelp")
              foreground: root.foreground
              checked: !!root.dock && root.dock.showStack
              onClicked: root.dock.setSetting("stack", !root.dock.showStack, true)
            }

            Setting {
              visible: root.section === "tiles" && !!root.dock && root.dock.showStack
              label: strings.t("settings.stackCount")
              NumberField {
                from: 5
                to: 30
                value: root.dock ? root.dock.stackLimit : 15
                foreground: root.foreground
                onModified: v => root.dock.setSetting("stackCount", v, 15)
              }
            }

            Setting {
              visible: root.section === "tiles"
              label: strings.t("settings.music")
              description: strings.t("settings.musicHelp")
              ButtonGroup {
                options: [
                  { value: "hidden", label: strings.t("settings.musicHidden") },
                  { value: "mini", label: strings.t("settings.musicMini") },
                  { value: "normal", label: strings.t("settings.musicNormal") },
                  { value: "large", label: strings.t("settings.musicLarge") }
                ]
                value: root.dock ? root.dock.musicSize : ""
                foreground: root.foreground
                onChanged: v => root.dock.setSetting("music", v, "hidden")
              }
            }

            Setting {
              visible: root.section === "tiles" && !!root.dock && root.dock.showMusic
              label: strings.t("settings.musicPlayer")
              description: strings.t("settings.musicPlayerHelp")
              Dropdown {
                width: Style.spacing.dropdownWidth
                showLabel: false
                options: root.playerOptions
                value: root.dock ? root.dock.musicPreferred : ""
                onChanged: v => root.dock.setSetting("musicPlayer", v, "")
              }
            }

            // ---- Weather ----
            Toggle {
              visible: root.section === "weather"
              width: page.width
              label: strings.t("settings.weather")
              description: strings.t("settings.weatherHelp")
              foreground: root.foreground
              checked: !!root.dock && root.dock.showWeather
              onClicked: root.dock.setSetting("weather", !root.dock.showWeather, false)
            }

            // The place: qDock's own, else Omarchy's weather panel's. A search
            // lists matching places (Open-Meteo's geocoder), a click picks one.
            Setting {
              visible: root.section === "weather" && !!root.dock && root.dock.showWeather
              label: strings.t("settings.weatherPlace")
              description: !root.dock ? ""
                : root.dock.weatherOwnSet ? strings.t("settings.weatherPlaceOwn").arg(root.dock.weatherOwnPlace.name)
                : root.dock.weatherHasPlace ? strings.t("settings.weatherPlaceOmarchy").arg(root.dock.weatherPlaceName)
                : strings.t("settings.weatherPlaceNone")

              Column {
                width: parent.width
                spacing: Style.spacing.xs

                Row {
                  spacing: Style.spacing.sm

                  TextField {
                    id: placeField
                    width: Style.space(280)
                    foreground: root.foreground
                    placeholderText: strings.t("settings.weatherSearch")
                    onTextChanged: placeSearch.restart()
                    onAccepted: if (root.placeResults.length > 0) root.pickPlace(root.placeResults[0])
                  }

                  Button {
                    visible: !!root.dock && root.dock.weatherOwnSet
                    anchors.verticalCenter: parent.verticalCenter
                    text: strings.t("settings.weatherUseOmarchy")
                    foreground: root.foreground
                    onClicked: root.dock.setWeatherPlace(null)
                  }
                }

                Repeater {
                  model: root.placeResults

                  Rectangle {
                    id: placeRow
                    required property var modelData
                    width: Style.space(280)
                    height: placeRowText.implicitHeight + Style.spacing.xs * 2
                    radius: Math.min(height / 2, root.cardRadius)
                    color: placeMouse.containsMouse ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"

                    Text {
                      id: placeRowText
                      x: Style.spacing.sm
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - Style.spacing.sm * 2
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: placeRow.modelData.region ? placeRow.modelData.name + " — " + placeRow.modelData.region : placeRow.modelData.name
                      color: root.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                    }
                    MouseArea {
                      id: placeMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.pickPlace(placeRow.modelData)
                    }
                  }
                }
              }
            }

            Setting {
              visible: root.section === "weather" && !!root.dock && root.dock.showWeather
              label: strings.t("settings.weatherUnit")
              description: strings.t("settings.weatherUnitHelp")
              ButtonGroup {
                options: [
                  { value: "auto", label: strings.t("settings.weatherUnitAuto") },
                  { value: "metric", label: "°C" },
                  { value: "imperial", label: "°F" }
                ]
                value: root.dock ? root.dock.weatherUnit : ""
                foreground: root.foreground
                onChanged: v => root.dock.setSetting("weatherUnit", v, "auto")
              }
            }

            // ---- About ----
            // The owl beside the name and version, then the description and
            // the project's page, left-aligned on the whole width.
            Row {
              visible: root.section === "about"
              width: page.width
              spacing: Style.spacing.lg

              Image {
                id: aboutLogo
                width: Style.space(80)
                height: width
                source: Qt.resolvedUrl("assets/logo.png")
                sourceSize: Qt.size(width * 2, height * 2)
                fillMode: Image.PreserveAspectFit
                smooth: true
              }

              Column {
                anchors.verticalCenter: aboutLogo.verticalCenter
                width: page.width - aboutLogo.width - Style.spacing.lg
                spacing: Style.spacing.xs

                Text {
                  textFormat: Text.PlainText
                  text: root.manifest.name || "qDock"
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Math.round(Style.font.heading * 1.3)
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: strings.t("about.version").arg(root.manifest.version || "")
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  textFormat: Text.PlainText
                  text: strings.t("about.credits").arg(root.manifest.author || "").arg(root.manifest.license || "")
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Text {
              visible: root.section === "about"
              width: page.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: strings.t("about.description")
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

          }
        }
      }
    }
  }

  // A setting's name and an optional line of help over its control.
  component Setting: Column {
    id: setting
    property string label: ""
    property string description: ""
    default property alias control: holder.data

    width: parent ? parent.width : 0
    height: visible ? implicitHeight : 0
    spacing: Style.spacing.xs

    Text {
      textFormat: Text.PlainText
      font.bold: true
      text: setting.label
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
    }

    Text {
      visible: setting.description !== ""
      width: setting.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: setting.description
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Item { width: 1; height: Style.spacing.xs }

    Item {
      id: holder
      width: setting.width
      height: childrenRect.height
    }
  }
}
