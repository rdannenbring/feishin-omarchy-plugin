import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "io.github.nag3sy.feishin"

  // Feishin (via mpris-service) registers as org.mpris.MediaPlayer2.Feishin
  // with identity "Feishin". Match on identity only (case-insensitive, for
  // future casing changes) — not on a dbus-name substring, which any local
  // MPRIS player could satisfy just by including "feishin" somewhere in a
  // self-chosen bus name. This is still a self-reported string, not a
  // cryptographic identity, so it's a courtesy filter rather than a real
  // trust boundary — see the Security model section in the README.
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var player: findPlayer()

  function findPlayer() {
    for (var i = 0; i < mprisPlayers.length; i++) {
      var p = mprisPlayers[i]
      if (!p) continue
      var identity = String(p.identity || "").toLowerCase()
      if (identity === "feishin") return p
    }
    return null
  }

  readonly property bool hasMedia: player !== null && (player.trackTitle || player.trackArtist)
  readonly property string playIcon: player && player.isPlaying ? "󰏤" : "󰐊"
  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property bool canAdjustVolume: player && player.volumeSupported && player.canControl

  property bool popupOpen: false

  function close() { popupOpen = false }

  // --- Library search -------------------------------------------------
  // Feishin has no external API to command playback of an arbitrary track
  // (confirmed: MPRIS OpenUri, the feishin:// scheme, and Feishin's own
  // remote-control server are all transport-only — see upstream issue
  // jeffvli/feishin#1221). So search here can't start playback directly.
  // Instead it queries the same Subsonic-compatible server Feishin itself
  // uses (auth reused from the token already embedded in its cover-art
  // URLs, so no extra login is needed) and clicking a result raises the
  // Feishin window and copies the track name so it's one paste away.

  property string authOrigin: ""
  property string authUser: ""
  property string authToken: ""
  property string authSalt: ""
  property string authVersion: "1.16.1"
  readonly property bool canSearch: authOrigin !== "" && authUser !== "" && authToken !== "" && authSalt !== ""

  property var searchResults: []
  property bool searching: false

  function captureAuthFromArtUrl(url) {
    if (!url) return
    if (url.indexOf("http://") !== 0 && url.indexOf("https://") !== 0) return
    var restIndex = url.indexOf("/rest/")
    var queryIndex = url.indexOf("?")
    if (restIndex < 0 || queryIndex < 0) return
    var origin = url.substring(0, restIndex)
    var params = {}
    var parts = url.substring(queryIndex + 1).split("&")
    for (var i = 0; i < parts.length; i++) {
      var kv = parts[i].split("=")
      if (kv.length < 2) continue
      params[decodeURIComponent(kv[0])] = decodeURIComponent(kv[1])
    }
    if (origin && params.u && params.t && params.s) {
      authOrigin = origin
      authUser = params.u
      authToken = params.t
      authSalt = params.s
      if (params.v) authVersion = params.v
    }
  }

  onPlayerChanged: if (player && player.trackArtUrl) captureAuthFromArtUrl(player.trackArtUrl)
  Component.onCompleted: if (player && player.trackArtUrl) captureAuthFromArtUrl(player.trackArtUrl)

  Connections {
    target: root.player
    function onTrackArtUrlChanged() {
      if (root.player && root.player.trackArtUrl) root.captureAuthFromArtUrl(root.player.trackArtUrl)
    }
  }

  function performSearch(query) {
    if (!canSearch || query.trim() === "") {
      searchResults = []
      searching = false
      return
    }
    searching = true
    var url = authOrigin + "/rest/search3.view"
      + "?u=" + encodeURIComponent(authUser)
      + "&t=" + encodeURIComponent(authToken)
      + "&s=" + encodeURIComponent(authSalt)
      + "&v=" + encodeURIComponent(authVersion)
      + "&c=Feishin&f=json"
      + "&query=" + encodeURIComponent(query)
      + "&songCount=8&albumCount=0&artistCount=0"

    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      searching = false
      try {
        if (xhr.status !== 200) { searchResults = []; return }
        // Guard against a malicious or misconfigured server returning an
        // enormous body — cap what we're willing to hand to JSON.parse.
        if (xhr.responseText.length > 1000000) { searchResults = []; return }
        var data = JSON.parse(xhr.responseText)
        var resp = data["subsonic-response"]
        if (!resp || resp.status !== "ok") { searchResults = []; return }
        searchResults = (resp.searchResult3 && resp.searchResult3.song) || []
      } catch (e) {
        searchResults = []
      }
    }
    xhr.ontimeout = function() { searching = false; searchResults = [] }
    xhr.open("GET", url)
    xhr.timeout = 8000
    xhr.send()
  }

  function songArtUrl(song) {
    if (!song || !song.coverArt) return ""
    return authOrigin + "/rest/getCoverArt.view?id=" + encodeURIComponent(song.coverArt)
      + "&u=" + encodeURIComponent(authUser) + "&t=" + encodeURIComponent(authToken)
      + "&s=" + encodeURIComponent(authSalt) + "&v=" + encodeURIComponent(authVersion)
      + "&c=Feishin&size=64"
  }

  // Raising Feishin's window is silent and its own art/title clicks look
  // like a no-op without this — surface what actually happened via the
  // shared OSD so it's clear the window came forward for a paste, not a
  // jump to that exact page.
  function notifyCopied(label) {
    if (!label || !bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "media",
      message: "Copied “" + label + "” — paste (Ctrl+V) into Feishin's search",
      duration: 2600
    }))
  }

  // Can't start playback of an arbitrary track from outside Feishin (no
  // API exists for it — see comment above). Best available bridge: bring
  // Feishin forward and hand it the track name via clipboard.
  function openInFeishin(song) {
    if (player && player.canRaise) player.raise()
    var label = (song.title || "") + (song.artist ? " - " + song.artist : "")
    if (label) {
      Quickshell.execDetached(["wl-copy", label])
      notifyCopied(label)
    }
  }

  // Same bridge, applied to whatever's currently playing rather than a
  // search result — clicking the art/title in the popup header.
  function openNowPlaying(kind) {
    if (!player) return
    if (player.canRaise) player.raise()
    var label = ""
    if (kind === "album" && player.trackAlbum) {
      var albumArtist = player.trackAlbumArtist || player.trackArtist || ""
      label = player.trackAlbum + (albumArtist ? " - " + albumArtist : "")
    } else {
      label = (player.trackTitle || "") + (player.trackArtist ? " - " + player.trackArtist : "")
    }
    if (label) {
      Quickshell.execDetached(["wl-copy", label])
      notifyCopied(label)
    }
  }

  function playPause() {
    if (!player) return
    if (player.isPlaying && player.canPause) player.pause()
    else if (!player.isPlaying && player.canPlay) player.play()
    else if (player.canTogglePlaying) player.togglePlaying()
  }

  visible: hasMedia
  implicitWidth: hasMedia ? row.implicitWidth + Style.space(14) : 0
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    // Play/pause hit target. Padded a little past the glyph itself so it's
    // not a single-pixel-wide click target.
    Item {
      id: glyphHit
      implicitWidth: glyph.implicitWidth + Style.space(8)
      implicitHeight: glyph.implicitHeight
      anchors.verticalCenter: parent.verticalCenter

      Text {
        id: glyph
        anchors.centerIn: parent
        text: root.playIcon
        color: root.player && root.player.isPlaying ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.player ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.playPause()
        onEntered: if (root.bar) root.bar.showTooltip(root, root.player && root.player.isPlaying ? "Pause" : "Play")
        onExited: if (root.bar) root.bar.hideTooltip(root)
      }
    }

    // Art + track name. Click opens the controls popup. Wrapped in a plain
    // Item (not a Row) because Row forbids fill/centerIn anchors on its
    // direct children, which the MouseArea below needs.
    Item {
      id: infoWrap
      implicitWidth: infoRow.implicitWidth
      implicitHeight: infoRow.implicitHeight
      anchors.verticalCenter: parent.verticalCenter

      Row {
        id: infoRow
        spacing: Style.space(6)

        // Always takes its slot (even with no art yet) so the bar never
        // shifts width for it — only the label's own clip below scrolls.
        BorderSurface {
          id: miniArt
          visible: !root.bar.vertical && root.player !== null
          width: Style.space(16)
          height: Style.space(16)
          radius: Style.space(3)
          anchors.verticalCenter: parent.verticalCenter
          color: Style.normalFillFor(root.bar.barForeground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar.barForeground, Color.accent)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(1)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.player && root.player.trackArtUrl ? root.player.trackArtUrl : ""
            visible: source !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: !root.player || !root.player.trackArtUrl
            text: "󰝚"
            color: root.bar.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Fixed-width clip so the bar's width never changes with track
        // length — long titles scroll inside it instead of resizing the bar.
        Item {
          id: labelClip
          visible: !root.bar.vertical && root.title !== ""
          width: Style.space(150)
          height: labelText.implicitHeight
          clip: true
          anchors.verticalCenter: parent.verticalCenter

          Text {
            id: labelText
            anchors.verticalCenter: parent.verticalCenter
            text: root.title + (root.artist ? "  ·  " + root.artist : "")
            color: root.bar.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body

            readonly property real scrollDistance: Math.max(0, implicitWidth - labelClip.width)
            readonly property bool needsScroll: scrollDistance > 0

            onTextChanged: { x = 0; scrollAnim.restart() }

            SequentialAnimation {
              id: scrollAnim
              running: labelText.needsScroll && !root.bar.vertical
              loops: Animation.Infinite

              PauseAnimation { duration: 1400 }
              NumberAnimation {
                target: labelText
                property: "x"
                to: -labelText.scrollDistance
                duration: Math.max(2500, labelText.scrollDistance * 35)
                easing.type: Easing.Linear
              }
              PauseAnimation { duration: 1200 }
              NumberAnimation {
                target: labelText
                property: "x"
                to: 0
                duration: 400
                easing.type: Easing.InOutQuad
              }
            }
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.player ? Qt.PointingHandCursor : Qt.ArrowCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        onClicked: function(mouse) {
          if (!root.player) return
          if (mouse.button === Qt.MiddleButton) root.playPause()
          else root.popupOpen = !root.popupOpen
        }
        onWheel: function(wheel) {
          if (!root.player) return
          if (wheel.angleDelta.y > 0 && root.player.canGoPrevious) root.player.previous()
          else if (wheel.angleDelta.y < 0 && root.player.canGoNext) root.player.next()
        }
        onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia ? (root.title + (root.artist ? " — " + root.artist : "")) : "")
        onExited: if (root.bar) root.bar.hideTooltip(root)
      }
    }
  }

  // KeyboardPanel (not PopupCard) — PopupCard is an xdg-popup and never
  // receives compositor keyboard focus, so a TextField inside one can't be
  // typed into. KeyboardPanel does the Wayland keyboard-focus handshake
  // that the search field below needs; the audio/network/weather panels
  // use it for the same reason.
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        spacing: Style.space(10)
        width: parent.width

        BorderSurface {
          width: Style.space(64)
          height: Style.space(64)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.player && root.player.trackArtUrl ? root.player.trackArtUrl : ""
            visible: source !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: !root.player || !root.player.trackArtUrl
            text: "󰝚"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }

          HoverHandler { id: nowArtHover }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: root.player ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.openNowPlaying("album")
          }

          PanelToolTip {
            visible: root.player !== null && nowArtHover.hovered
            text: "Open Feishin to this album"
            fontFamily: root.bar.fontFamily
          }
        }

        // Plain Item (not a Column) so the MouseArea below can use
        // anchors.fill — Row/Column forbid fill/centerIn on direct children.
        Item {
          id: titleWrap
          width: parent.width - Style.space(74)
          implicitHeight: titleColumn.implicitHeight

          Column {
            id: titleColumn
            anchors.fill: parent
            spacing: Style.space(4)

            Text {
              text: root.title || "Feishin — nothing playing"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.artist
              color: Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
              visible: text !== ""
            }

            Text {
              text: root.player && root.player.trackAlbum ? root.player.trackAlbum : ""
              color: Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
              visible: text !== ""
            }
          }

          HoverHandler { id: titleHover }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: root.player ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.openNowPlaying("song")
          }

          PanelToolTip {
            visible: root.player !== null && titleHover.hovered
            text: "Open Feishin to this song"
            fontFamily: root.bar.fontFamily
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Button {
          iconText: "󰒮"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.player && root.player.canGoPrevious
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.player) root.player.previous()
        }

        Button {
          iconText: root.playIcon
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: root.player && (root.player.canTogglePlaying || root.player.canPlay || root.player.canPause)
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.playPause()
        }

        Button {
          iconText: "󰒭"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.player && root.player.canGoNext
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.player) root.player.next()
        }
      }

      PanelSeparator {
        visible: root.player !== null
        foreground: root.bar.foreground
      }

      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.player !== null

        Item {
          width: parent.width
          height: Math.max(volumeLabel.implicitHeight, volumePercent.implicitHeight)

          Text {
            id: volumeLabel
            text: "VOLUME"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: volumePercent
            text: root.player ? Math.round((volumeSlider.dragging ? volumeSlider.liveValue : root.player.volume) * 100) + "%" : ""
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSlider {
          id: volumeSlider
          bar: root.bar
          width: parent.width
          minimum: 0
          maximum: 1
          step: 0.05
          value: root.player ? root.player.volume : 0
          enabled: root.canAdjustVolume
          opacity: enabled ? 1.0 : 0.4
          onMoved: function(v) { if (root.player) root.player.volume = v }
        }
      }

      PanelSeparator {
        visible: root.player !== null
        foreground: root.bar.foreground
      }

      Text {
        visible: root.player !== null && !root.canSearch
        text: "Play something once to enable library search"
        color: Qt.darker(root.bar.foreground, 1.6)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }

      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.canSearch

        Text {
          text: "SEARCH LIBRARY"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        TextField {
          id: searchField
          width: parent.width
          placeholderText: "Search songs…"
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall

          onTextChanged: searchDebounce.restart()

          Timer {
            id: searchDebounce
            interval: 350
            repeat: false
            onTriggered: root.performSearch(searchField.text)
          }
        }

        Text {
          visible: root.searching
          text: "Searching…"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          visible: !root.searching && searchField.text !== "" && root.searchResults.length === 0
          text: "No matches"
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.searchResults.length > 0

          Repeater {
            model: root.searchResults

            BorderSurface {
              id: resultRow
              required property var modelData
              width: parent.width
              height: resultInner.implicitHeight + Style.space(8)
              radius: Style.spacing.labelGap
              color: resultHover.hovered ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
              borderSpec: Border.none()

              Row {
                id: resultInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                BorderSurface {
                  width: Style.space(28)
                  height: Style.space(28)
                  radius: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  color: Style.normalFillFor(root.bar.foreground, Color.accent)
                  borderSpec: Border.none()

                  Image {
                    anchors.fill: parent
                    anchors.margins: Style.space(1)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: root.songArtUrl(resultRow.modelData)
                  }
                }

                Column {
                  width: parent.width - Style.space(36)
                  spacing: Style.space(1)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    text: resultRow.modelData.title || ""
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    text: [resultRow.modelData.artist, resultRow.modelData.album].filter(function(v) { return !!v }).join("  ·  ")
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }
              }

              HoverHandler { id: resultHover }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openInFeishin(resultRow.modelData)

                PanelToolTip {
                  visible: resultHover.hovered
                  text: "Open Feishin and paste to jump to this track"
                  fontFamily: root.bar.fontFamily
                }
              }
            }
          }
        }
      }
    }
  }
}
