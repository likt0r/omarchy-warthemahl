import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// WartheMahl lunch menu in the Omarchy bar.
//
// One entry point: the bar slot button plus the popup it owns, following the
// same shape as the first-party panels. The menu itself comes from
// bin/warthemahl-menu, a helper that scrapes warthemahl.de and caches the
// result -- keeping the HTML parsing out of QML means it can be unit tested
// and that a site change can be fixed without touching the panel.
Panel {
  id: root
  moduleName: "likt0r.warthemahl"
  ipcTarget: "likt0r.warthemahl"
  manageIpc: false

  // Resolved next to this file rather than looked up on PATH, so the plugin
  // works from its own directory with no install step.
  readonly property string helperPath: {
    var url = Qt.resolvedUrl("bin/warthemahl-menu").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  property var menu: Model.emptyMenu()
  property bool loading: false
  // Relative timestamps and "which day is today" both need a clock that
  // actually ticks; a bare `new Date()` in a binding would freeze at load.
  property date now: new Date()
  property int dayIndex: 0
  property bool cursorActive: false

  readonly property int refreshIntervalSec: Math.max(60, Number(setting("refreshIntervalSec", 3600)) || 3600)
  readonly property int todayIndex: Model.todayIndex(root.menu.days, root.now)
  readonly property string weekNote: Model.weekNote(root.menu, root.now)
  readonly property bool hasDays: root.menu.days.length > 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  // The bar exposes foreground/urgent but no accent -- it reads the palette
  // singleton directly for that, and so do we.
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function refresh(force) {
    if (fetchProc.running) return
    root.now = new Date()
    root.loading = true
    fetchProc.command = force
      ? [root.helperPath]
      : [root.helperPath, "--max-age", String(root.refreshIntervalSec)]
    fetchProc.running = true
  }

  function applyPayload(text) {
    var parsed = Model.parsePayload(text)
    if (!parsed) return
    root.menu = parsed
    root.clampCursor()
  }

  function failWith(message) {
    // Only claim a hard failure when there is nothing on screen to trust;
    // a stale-but-parsed menu is more useful than an error box.
    if (root.hasDays) return
    var empty = Model.emptyMenu()
    empty.error = message
    root.menu = empty
  }

  function openPdf() {
    if (root.menu.pdfUrl === "") { root.openSite(); return }
    Quickshell.execDetached(["xdg-open", root.menu.pdfUrl])
  }

  function openSite() {
    var url = root.menu.sourceUrl !== "" ? root.menu.sourceUrl : "https://warthemahl.de/speisekarte/"
    Quickshell.execDetached(["xdg-open", url])
  }

  function clampCursor() {
    var count = root.menu.days.length
    if (count === 0) { root.dayIndex = 0; return }
    if (root.dayIndex >= count) root.dayIndex = count - 1
    if (root.dayIndex < 0) root.dayIndex = 0
  }

  function moveCursor(dx, dy) {
    root.cursorActive = true
    var count = root.menu.days.length
    if (count === 0 || dy === 0) return
    root.dayIndex = Math.max(0, Math.min(count - 1, root.dayIndex + dy))
    root.scrollCursorIntoView()
  }

  function setDayCursor(index) {
    root.cursorActive = true
    root.dayIndex = index
    root.scrollCursorIntoView()
  }

  function scrollCursorIntoView() {
    if (!panelFlick || root.dayIndex < 0 || root.dayIndex >= dayColumn.children.length) return
    var item = dayColumn.children[root.dayIndex]
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(8)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Opening parks the cursor on today when the published week contains it, so
  // the keyboard starts where the eye already is.
  onOpenedChanged: if (opened) {
    root.now = new Date()
    root.cursorActive = false
    root.dayIndex = root.todayIndex >= 0 ? root.todayIndex : 0
    if (panelFlick) panelFlick.contentY = 0
    root.refresh(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Component.onCompleted: root.refresh(false)

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPayload(text)
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      // The helper reports its own trouble inside the JSON payload, so a
      // non-zero exit means it never got that far -- missing interpreter,
      // lost executable bit, killed process.
      if (exitCode !== 0) root.failWith("Speisekarten-Helfer fehlgeschlagen (Code " + exitCode + ")")
      else if (!root.hasDays && root.menu.error === "") root.failWith("Keine Speisekarte empfangen")
    }
  }

  // Keeps "vor 12 Min." honest and rolls the today highlight over midnight
  // while the panel sits open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.now = new Date()
  }

  // Background top-up so the bar tooltip knows today's dishes before the
  // first click. Cache-respecting, so a tick usually costs one cheap read.
  Timer {
    interval: Math.min(6 * 3600 * 1000, root.refreshIntervalSec * 1000)
    running: true
    repeat: true
    onTriggered: root.refresh(false)
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(true); return "ok" }
    function status(): string { return Model.tooltipText(root.menu, new Date()) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰩰"
    tooltipText: Model.tooltipText(root.menu, root.now)

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.refresh(true)
      else if (mouseButton === Qt.MiddleButton) root.openPdf()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(
      column.implicitHeight + footer.implicitHeight + Style.space(10), Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: root.openPdf()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(key) {
        if (key === "r" || key === "R") root.refresh(true)
        else if (key === "p" || key === "P") root.openPdf()
        else if (key === "w" || key === "W") root.openSite()
      }

      // Status and actions are pinned to the bottom edge rather than left at
      // the end of the scroll: a full week already overruns the height cap, and
      // a reload button you have to scroll to find is a button nobody presses.
      Column {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(10)

          PanelSeparator { foreground: root.foreground }

          Item {
            width: parent.width
            implicitHeight: Math.max(statusText.implicitHeight, actions.implicitHeight)

            Text {
              id: statusText
              anchors.left: parent.left
              anchors.right: actions.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.statusLine(root.menu, root.now, root.loading)
              color: root.menu.stale || (!root.hasDays && !root.loading) ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Row {
              id: actions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Neu laden (r)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.loading
                onClicked: root.refresh(true)
              }

              PanelActionButton {
                iconText: "󰈦"
                tooltipText: "Speisekarte als PDF (p)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.menu.pdfUrl !== ""
                onClicked: root.openPdf()
              }

              PanelActionButton {
                iconText: "󰏌"
                tooltipText: "warthemahl.de öffnen (w)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.openSite()
              }
            }
          }
      }

      Flickable {
        id: panelFlick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(10)
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "WartheMahl"
            meta: root.menu.weekLabel !== "" ? root.menu.weekLabel : "Speisekarte der Woche"
            detail: root.menu.stale ? "OFFLINE" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰩰"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            visible: root.weekNote !== "" && root.hasDays
            width: parent.width
            text: "󰃭  " + root.weekNote
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            visible: root.hasDays
            foreground: root.foreground
          }

          Column {
            id: dayColumn
            visible: root.hasDays
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.menu.days

              DayCard {
                required property var modelData
                required property int index

                width: dayColumn.width
                day: modelData
                rowIndex: index
              }
            }
          }

          // Nothing parsed: either the fetch failed or the page changed shape.
          // Either way the user gets the reason and a way out to the website.
          Column {
            visible: !root.hasDays
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: root.loading ? "Speisekarte wird geladen…"
                : "󰗖  " + (root.menu.error !== "" ? root.menu.error : "Keine Speisekarte gefunden")
              color: root.loading ? root.dim : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }

  // One day of the week: the date header plus every dish the page listed for
  // it. Today's card carries the persistent `current` fill so it reads as the
  // answer to "what is there right now" without hunting.
  component DayCard: CursorSurface {
    id: card

    property var day: null
    property int rowIndex: 0
    readonly property bool isToday: root.todayIndex === card.rowIndex

    hasCursor: root.cursorActive && root.dayIndex === card.rowIndex
    current: card.isToday
    foreground: root.foreground
    accent: root.accent

    implicitHeight: cardBody.implicitHeight + Style.space(14)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setDayCursor(card.rowIndex)
      onClicked: root.openPdf()
    }

    Column {
      id: cardBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(5)

      Item {
        width: parent.width
        height: Math.max(weekdayText.implicitHeight, dateText.implicitHeight)

        Text {
          id: weekdayText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: card.day ? String(card.day.weekday || "") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          id: todayBadge
          visible: card.isToday
          anchors.right: dateText.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: "HEUTE"
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1
        }

        Text {
          id: dateText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: card.day ? String(card.day.dateLabel || "") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Repeater {
        model: card.day ? card.day.dishes : []

        // Wrapped dish text drives the row height off contentHeight rather
        // than implicitHeight: the glyph column is fixed, the text column is
        // whatever is left, and the row must be as tall as the wrap needs.
        Item {
          id: dishRow
          required property var modelData
          required property int index

          width: cardBody.width
          height: Math.max(dishGlyph.implicitHeight, dishText.contentHeight)

          Text {
            id: dishGlyph
            anchors.left: parent.left
            anchors.top: parent.top
            text: Model.dishIcon(dishRow.index, dishRow.modelData)
            color: dishRow.index === 0 ? root.foreground : root.accent
            opacity: dishRow.index === 0 ? 0.75 : 0.9
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconSmall
          }

          Text {
            id: dishText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(20)
            anchors.right: parent.right
            anchors.top: parent.top
            text: String(dishRow.modelData || "")
            color: root.foreground
            opacity: dishRow.index === 0 ? 1.0 : 0.82
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
