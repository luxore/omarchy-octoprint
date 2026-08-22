pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Attention.js" as Attention

Panel {
  id: root

  readonly property string pluginId: "io.github.luxore.octoprint"
  readonly property url logoUrl: Qt.resolvedUrl("assets/octoprint.svg")
  // Nerd Fonts Material Design printer-3d-nozzle (U+F0E5B).
  readonly property string barIcon: "󰹛"
  readonly property string helperPath:
    Qt.resolvedUrl("bin/octoprint-companion").toString().replace(/^file:\/\//, "")

  moduleName: pluginId
  ipcTarget: pluginId
  manageIpc: false

  property var printer: ({
    configured: false,
    connected: false,
    state: "unknown",
    stateText: "Waiting for OctoPrint",
    faulted: false,
    errorMessage: "",
    job: { name: "", path: "" },
    progress: { completion: null, printTime: null, printTimeLeft: null, etaAt: null },
    temperature: {
      tool0: { actual: null, target: null },
      bed: { actual: null, target: null }
    },
    fetchedAt: 0
  })
  property string lastError: ""
  property string cameraError: ""
  property string commandError: ""
  property string frameUrl: ""
  property bool initialized: false
  property bool refreshing: false
  property bool authorizing: false
  property bool commanding: false
  property bool confirmCancel: false
  property bool abandoningAuthorization: false
  property bool abandoningManualAuthorization: false
  property bool abandoningSnapshot: false
  property bool abandoningStream: false
  property var previousObservation: ({ state: "", faulted: false })
  property bool cancelPending: false
  property int frameSerial: 0
  property real nowMs: Date.now()
  property string currentTab: setupComplete ? "monitor" : "setup"
  property string settingsMessage: ""
  property bool settingsMessageIsError: false
  property string pendingSettingsAction: ""
  property string pendingSettingsUrl: ""
  property string runningSettingsUrl: ""

  function boolSetting(key, fallback) {
    var value = settings ? settings[key] : undefined
    if (value === undefined || value === null) return fallback
    if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
    return value !== false
  }

  readonly property string instanceUrl: String(setting("instanceUrl", "http://octopi.local")).trim()
  readonly property string snapshotPath: String(setting("snapshotPath", "/webcam/?action=snapshot")).trim()
  readonly property string streamPath: String(setting("streamPath", "/webcam/?action=stream")).trim()
  readonly property bool setupComplete: boolSetting("setupComplete", false)
  readonly property string savedCameraMode: String(setting("cameraMode", "")).trim()
  readonly property string cameraMode: ["stream", "snapshots", "off"].indexOf(savedCameraMode) >= 0
    ? savedCameraMode : (boolSetting("cameraEnabled", true) ? "snapshots" : "off")
  readonly property bool cameraVisible: cameraMode !== "off"
  readonly property bool showProgress: boolSetting("showProgress", true)
  readonly property bool notifyFinished: boolSetting("notifyFinished", true)
  readonly property bool notifyPaused: boolSetting("notifyPaused", true)
  readonly property bool notifyError: boolSetting("notifyError", true)
  readonly property int activePollMs: 5000
  readonly property int idlePollMs: 60000
  readonly property int cameraIntervalMs: 1500
  readonly property bool jobInProgress: printer.state === "printing" || printer.state === "paused" || printer.state === "cancelling"
  readonly property bool activePrint: printer.state === "printing" || printer.state === "paused"
  readonly property string pauseAction: Attention.pauseAction(printer)
  readonly property bool barProgressVisible: showProgress && jobInProgress
  readonly property bool barAlarm: Attention.barAlarm(printer, barProgressVisible)
  readonly property bool needsAttention: barAlarm || dataIsStale
  readonly property bool dataIsStale: printer.fetchedAt > 0 && nowMs - printer.fetchedAt > Math.max(idlePollMs * 2.5, 120000)
  readonly property int completion: printer.progress.completion === null || printer.progress.completion === undefined
    ? 0 : Math.max(0, Math.min(100, Math.round(printer.progress.completion)))
  readonly property color detailColor:
    Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.72)
  readonly property bool statusOwner: Attention.ownsStatus(root, statusInstances())
  readonly property bool anyPanelOpened: {
    var items = statusInstances()
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i].opened === true) return true
    }
    return false
  }

  function statusInstances() {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(pluginId) : []
    return items && items.length > 0 ? items : [root]
  }

  function statusOwnerInstance() {
    var items = statusInstances()
    return items.length > 0 ? items[0] : root
  }

  function setCancelPending(value) {
    var items = statusInstances()
    for (var i = 0; i < items.length; i++) {
      if (items[i]) items[i].cancelPending = value
    }
  }

  function formatDuration(seconds) {
    if (seconds === null || seconds === undefined || !isFinite(seconds) || seconds < 0) return "--"
    var totalMinutes = Math.max(1, Math.round(seconds / 60))
    var hours = Math.floor(totalMinutes / 60)
    var minutes = totalMinutes % 60
    return hours > 0 ? hours + "h " + (minutes < 10 ? "0" : "") + minutes + "m" : minutes + "m"
  }

  function formatClock(epochMs) {
    if (!epochMs) return "--"
    return new Date(epochMs).toLocaleTimeString(Qt.locale(), "h:mm ap")
  }

  function formatTemp(node) {
    if (!node || node.actual === null || node.actual === undefined) return "--"
    var actual = Math.round(node.actual) + "°"
    if (node.target && node.target > 0) return actual + " / " + Math.round(node.target) + "°"
    return actual
  }

  function formatAgo(epochMs) {
    if (!epochMs) return "never"
    var seconds = Math.max(0, Math.round((nowMs - epochMs) / 1000))
    if (seconds < 60) return "just now"
    if (seconds < 3600) return Math.round(seconds / 60) + "m ago"
    return Math.round(seconds / 3600) + "h ago"
  }

  function refresh() {
    var owner = statusOwnerInstance()
    if (owner !== root) {
      refreshing = true
      owner.refresh()
      return
    }
    if (statusProcess.running || instanceUrl === "") return
    var items = statusInstances()
    for (var i = 0; i < items.length; i++) {
      if (items[i]) items[i].refreshing = true
    }
    statusProcess.command = [helperPath, "--url", instanceUrl, "status"]
    statusProcess.running = true
  }

  function refreshCamera() {
    if (!opened || cameraMode !== "snapshots" || snapshotProcess.running || instanceUrl === "" || lastError !== "") return
    snapshotProcess.command = [helperPath, "--url", instanceUrl, "snapshot", "--path", snapshotPath]
    snapshotProcess.running = true
  }

  function startStream() {
    if (!opened || cameraMode !== "stream" || streamProcess.running || instanceUrl === "" || lastError !== "") return
    cameraError = ""
    streamProcess.command = [helperPath, "--url", instanceUrl, "stream", "--path", streamPath]
    streamProcess.running = true
  }

  function acceptCameraOutput(output) {
    try {
      var parsed = JSON.parse(String(output || ""))
      if (parsed.error) {
        cameraError = String(parsed.error)
        frameUrl = ""
      } else if (parsed.path) {
        cameraError = ""
        frameSerial += 1
        frameUrl = String(parsed.path) + "?frame=" + frameSerial
      }
    } catch (error) {
      cameraError = "Camera returned unreadable data"
      frameUrl = ""
    }
  }

  function stopCamera() {
    if (snapshotProcess.running) {
      abandoningSnapshot = true
      snapshotProcess.running = false
    }
    if (streamProcess.running) {
      abandoningStream = true
      streamProcess.running = false
    }
    streamRetry.stop()
  }

  function runCommand(action) {
    if (commandProcess.running) return
    commandError = ""
    commanding = true
    commandProcess.action = action
    if (action === "cancel") setCancelPending(true)
    commandProcess.command = [helperPath, "--url", instanceUrl, "command", action]
    commandProcess.running = true
  }

  function askCancel() {
    if (confirmCancel) {
      confirmCancel = false
      cancelReset.stop()
      runCommand("cancel")
    } else {
      confirmCancel = true
      cancelReset.restart()
    }
  }

  function applyStatus(output) {
    var parsed
    try {
      parsed = JSON.parse(String(output || ""))
    } catch (error) {
      lastError = "The OctoPrint helper returned unreadable data"
      return
    }
    if (parsed.error) {
      applyStatusFailure(String(parsed.error))
      return
    }
    publishStatus(parsed, "")
  }

  function applyStatusFailure(message) {
    var detail = message || "OctoPrint status failed"
    publishStatus(Attention.unavailable(detail), detail)
  }

  function publishStatus(observation, errorMessage) {
    var items = statusInstances()
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (!item) continue
      item.acceptStatus(observation, errorMessage, item === root)
    }
  }

  function acceptStatus(observation, errorMessage, announce) {
    initialized = true
    refreshing = false
    lastError = errorMessage || ""
    if (lastError !== "") frameUrl = ""
    printer = observation
    if (announce) {
      evaluateTransition(observation)
      return
    }
    previousObservation = {
      state: String(observation.state || ""),
      faulted: observation.faulted === true
    }
    if (observation.state === "idle" || observation.state === "offline"
        || observation.state === "error" || observation.state === "unreachable")
      cancelPending = false
  }

  function evaluateTransition(observation) {
    var event = Attention.notification(previousObservation, observation, cancelPending)
    previousObservation = {
      state: String(observation.state || ""),
      faulted: observation.faulted === true
    }

    if (observation.state === "idle" || observation.state === "offline"
        || observation.state === "error" || observation.state === "unreachable")
      cancelPending = false

    if (event === "finished" && notifyFinished)
      notify("Print finished", printer.job.name || "OctoPrint is ready")
    else if (event === "paused" && notifyPaused)
      notify("Print paused", printer.job.name || "The printer needs attention", "critical")
    else if (event === "error" && notifyError)
      notify("Printer error", observation.errorMessage || observation.stateText || "Open OctoPrint for details", "critical")
  }

  function notify(title, body, urgency) {
    notifyProcess.command = Attention.notificationCommand(title, body, urgency)
    notifyProcess.running = true
  }

  function authorize(server) {
    var target = String(server || instanceUrl)
    if (authorizeProcess.running || target === "") return
    authorizing = true
    commandError = ""
    authorizeProcess.command = [helperPath, "--url", target, "authorize"]
    authorizeProcess.running = true
  }

  function saveConnection(url, nextAction, apiKey) {
    settingsMessage = ""
    settingsMessageIsError = false
    pendingSettingsAction = nextAction
    pendingSettingsUrl = String(url)
    if (nextAction === "key") manualAuthorizeProcess.secret = String(apiKey)
    if (settingsProcess.running) return
    runningSettingsUrl = pendingSettingsUrl
    settingsProcess.command = [
      helperPath, "--url", runningSettingsUrl, "configure"
    ]
    settingsProcess.running = true
  }

  function savePreference(key, value) {
    if (preferenceProcess.running) return
    settingsMessage = ""
    settingsMessageIsError = false
    preferenceProcess.command = [helperPath, "--url", instanceUrl, "setting", String(key), String(value)]
    preferenceProcess.running = true
  }

  function forgetKey(url) {
    if (forgetProcess.running) return
    settingsMessage = ""
    settingsMessageIsError = false
    forgetProcess.command = [helperPath, "--url", String(url), "forget"]
    forgetProcess.running = true
  }

  function showPreferences() {
    settingsPane.load()
    currentTab = "preferences"
    Qt.callLater(settingsPane.forceActiveFocus)
  }

  function showSetup() {
    settingsPane.load()
    currentTab = "setup"
    Qt.callLater(settingsPane.forceActiveFocus)
  }

  function openOctoPrint() {
    openExternal(instanceUrl)
  }

  function openExternal(url) {
    openProcess.command = [helperPath, "--url", String(url), "open"]
    openProcess.running = true
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(statusStdout.text)
      else {
        root.applyStatusFailure(String(statusStderr.text || "OctoPrint status failed").trim())
      }
    }
  }

  Process {
    id: snapshotProcess
    running: false
    command: []
    stdout: StdioCollector { id: snapshotStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (root.abandoningSnapshot) {
        root.abandoningSnapshot = false
        return
      }
      root.acceptCameraOutput(snapshotStdout.text)
    }
  }

  Process {
    id: streamProcess
    running: false
    command: []
    stdout: SplitParser { onRead: function(line) { root.acceptCameraOutput(line) } }
    onExited: function(_exitCode) {
      if (root.abandoningStream) {
        root.abandoningStream = false
        return
      }
      if (root.opened && root.cameraMode === "stream") {
        if (root.cameraError === "") root.cameraError = "Camera stream stopped"
        root.frameUrl = ""
        streamRetry.restart()
      }
    }
  }

  Process {
    id: commandProcess
    property string action: ""
    running: false
    command: []
    stdout: StdioCollector { id: commandStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.commanding = false
      if (exitCode !== 0) {
        if (action === "cancel") root.setCancelPending(false)
        try {
          var parsed = JSON.parse(String(commandStdout.text || ""))
          root.commandError = parsed.error || "The printer rejected the command"
        } catch (error) {
          root.commandError = "The printer rejected the command"
        }
      }
      action = ""
      settleRefresh.restart()
    }
  }

  Process {
    id: authorizeProcess
    running: false
    command: []
    stdout: StdioCollector { id: authorizeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.authorizing = false
      if (root.abandoningAuthorization) {
        root.abandoningAuthorization = false
        return
      }
      if (exitCode !== 0) {
        try {
          var parsed = JSON.parse(String(authorizeStdout.text || ""))
          root.commandError = parsed.error || "Authorization failed"
        } catch (error) {
          root.commandError = "Authorization failed"
        }
      } else {
        root.settingsMessage = "Connected"
        root.settingsMessageIsError = false
        root.currentTab = "monitor"
        root.refresh()
      }
    }
  }

  Process {
    id: settingsProcess
    running: false
    command: []
    stdout: StdioCollector { id: settingsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = ({})
      try { parsed = JSON.parse(String(settingsStdout.text || "")) }
      catch (error) { parsed = ({ error: "Settings returned unreadable data" }) }
      if (exitCode !== 0 || parsed.error) {
        root.settingsMessage = String(parsed.error || "Could not save settings")
        root.settingsMessageIsError = true
        manualAuthorizeProcess.secret = ""
        root.pendingSettingsAction = ""
        return
      }
      var savedUrl = String(parsed.url || root.runningSettingsUrl)
      if (root.pendingSettingsUrl !== root.runningSettingsUrl) {
        root.runningSettingsUrl = root.pendingSettingsUrl
        command = [root.helperPath, "--url", root.runningSettingsUrl, "configure"]
        running = true
        return
      }
      var nextAction = root.pendingSettingsAction
      root.pendingSettingsAction = ""
      root.settingsMessage = ""
      settingsPane.acceptSavedUrl(savedUrl)
      if (nextAction === "browser") {
        root.authorize(savedUrl)
      } else if (nextAction === "key") {
        manualAuthorizeProcess.command = [
          root.helperPath, "--url", savedUrl, "authorize", "--stdin"
        ]
        manualAuthorizeProcess.running = true
      } else {
        root.refresh()
      }
    }
  }

  Process {
    id: preferenceProcess
    running: false
    command: []
    stdout: StdioCollector { id: preferenceStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = ({})
      try { parsed = JSON.parse(String(preferenceStdout.text || "")) }
      catch (error) { parsed = ({ error: "Preference returned unreadable data" }) }
      if (exitCode !== 0 || parsed.error) {
        root.settingsMessage = String(parsed.error || "Could not save preference")
        root.settingsMessageIsError = true
        settingsPane.load()
      }
    }
  }

  Process {
    id: forgetProcess
    running: false
    command: []
    stdout: StdioCollector { id: forgetStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = ({})
      try { parsed = JSON.parse(String(forgetStdout.text || "")) }
      catch (error) { parsed = ({ error: "Key removal returned unreadable data" }) }
      if (exitCode !== 0 || parsed.error) {
        root.settingsMessage = String(parsed.error || "Could not remove the saved key")
        root.settingsMessageIsError = true
        return
      }
      root.settingsMessage = "Saved key removed"
      root.settingsMessageIsError = false
      root.refresh()
    }
  }

  Process {
    id: manualAuthorizeProcess
    property string secret: ""
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector { id: manualAuthorizeStdout; waitForEnd: true }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      if (root.abandoningManualAuthorization) {
        root.abandoningManualAuthorization = false
        return
      }
      var parsed = ({})
      try { parsed = JSON.parse(String(manualAuthorizeStdout.text || "")) }
      catch (error) { parsed = ({ error: "Authorization returned unreadable data" }) }
      if (exitCode !== 0 || parsed.error) {
        root.settingsMessage = String(parsed.error || "OctoPrint rejected the API key")
        root.settingsMessageIsError = true
        return
      }
      root.settingsMessage = "Connected"
      root.settingsMessageIsError = false
      root.currentTab = "monitor"
      root.refresh()
    }
  }

  Process { id: notifyProcess; running: false; command: [] }
  Process { id: openProcess; running: false; command: [] }

  Timer {
    interval: root.jobInProgress || root.anyPanelOpened ? root.activePollMs : root.idlePollMs
    running: root.statusOwner
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.cameraIntervalMs
    running: root.opened && root.cameraMode === "snapshots"
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshCamera()
  }

  Timer {
    id: streamRetry
    interval: 2000
    repeat: false
    onTriggered: root.startStream()
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: cancelReset
    interval: 5000
    repeat: false
    onTriggered: root.confirmCancel = false
  }

  Timer {
    id: settleRefresh
    interval: 800
    repeat: false
    onTriggered: root.refresh()
  }

  onOpenedChanged: {
    if (opened) {
      if (!setupComplete) showSetup()
      refresh()
      if (cameraMode === "stream") startStream()
      else refreshCamera()
    } else {
      confirmCancel = false
      cancelReset.stop()
      stopCamera()
      if (authorizeProcess.running) {
        abandoningAuthorization = true
        authorizing = false
        authorizeProcess.running = false
      }
      if (manualAuthorizeProcess.running) {
        abandoningManualAuthorization = true
        manualAuthorizeProcess.running = false
      }
    }
  }

  onInstanceUrlChanged: {
    stopCamera()
    previousObservation = ({ state: "", faulted: false })
    cancelPending = false
    lastError = ""
    cameraError = ""
    frameUrl = ""
    initialized = false
    Qt.callLater(root.refresh)
    if (opened && cameraMode === "stream") streamRetry.restart()
    else if (opened && cameraMode === "snapshots") Qt.callLater(root.refreshCamera)
  }

  onSnapshotPathChanged: {
    cameraError = ""
    frameUrl = ""
    if (opened) Qt.callLater(root.refreshCamera)
  }

  onStreamPathChanged: {
    cameraError = ""
    frameUrl = ""
    if (streamProcess.running) {
      abandoningStream = true
      streamProcess.running = false
    }
    if (opened && cameraMode === "stream") streamRetry.restart()
  }

  onCameraModeChanged: {
    stopCamera()
    cameraError = ""
    frameUrl = ""
    if (opened) {
      if (cameraMode === "stream") streamRetry.restart()
      else if (cameraMode === "snapshots") Qt.callLater(root.refreshCamera)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    fixedWidth: root.bar && root.bar.vertical
      ? root.bar.barSize
      : (root.barProgressVisible || root.barAlarm
          ? horizontalBarContent.implicitWidth + Style.space(12)
          : Style.bar.statusSlot)
    fixedHeight: root.bar && root.bar.vertical
      ? (root.barProgressVisible || root.barAlarm
          ? verticalBarContent.implicitHeight + Style.space(8)
          : Style.bar.statusSlot)
      : (root.bar ? root.bar.barSize : Style.bar.sizeHorizontal)
    active: root.needsAttention
    dimmed: Attention.barDimmed(root.printer, root.initialized)
    tooltipText: root.lastError !== ""
      ? "OctoPrint unavailable"
      : (root.jobInProgress
          ? root.completion + "% · " + root.formatDuration(root.printer.progress.printTimeLeft)
              + " remaining · ETA " + root.formatClock(root.printer.progress.etaAt)
          : ((root.printer.state === "error" || root.printer.faulted === true)
              ? "Printer error"
              : (root.printer.connected ? "Printer ready" : "Printer disconnected")))
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    Row {
      id: horizontalBarContent
      anchors.centerIn: parent
      spacing: Style.space(4)
      visible: !root.bar || !root.bar.vertical

      OpticalGlyph {
        width: Style.bar.iconCanvas
        height: width
        text: root.barIcon
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        fontSize: Style.bar.iconFont
        color: root.barAlarm ? Color.urgent : root.barForeground
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        visible: root.barProgressVisible
        spacing: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: horizontalEta
          text: root.completion + "% · ETA " + root.formatClock(root.printer.progress.etaAt)
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Rectangle {
          width: horizontalEta.implicitWidth
          height: Math.max(2, Style.space(2))
          radius: height / 2
          color: Style.normalFill

          Rectangle {
            width: parent.width * root.completion / 100
            height: parent.height
            radius: height / 2
            color: root.printer.state === "paused" ? Color.urgent : Color.accent
          }
        }
      }

      Text {
        visible: root.barAlarm
        text: "Error"
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Column {
      id: verticalBarContent
      anchors.centerIn: parent
      spacing: Style.space(2)
      visible: root.bar && root.bar.vertical

      OpticalGlyph {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.bar.iconCanvas
        height: width
        text: root.barIcon
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        fontSize: Style.bar.iconFont
        color: root.barAlarm ? Color.urgent : root.barForeground
      }

      Text {
        visible: root.barProgressVisible
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.completion + "%"
        color: root.barForeground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        visible: root.barAlarm
        anchors.horizontalCenter: parent.horizontalCenter
        text: "Error"
        color: Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Rectangle {
        visible: root.barProgressVisible
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.max(2, Style.space(2))
        height: Style.space(24)
        radius: width / 2
        color: Style.normalFill

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: parent.height * root.completion / 100
          radius: width / 2
          color: root.printer.state === "paused" ? Color.urgent : Color.accent
        }
      }
    }

    Rectangle {
      visible: root.dataIsStale
      width: Style.space(5)
      height: width
      radius: width / 2
      color: Color.urgent
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(2)
      anchors.topMargin: Style.space(2)
    }
  }

  KeyboardPanel {
    id: printerPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.currentTab === "monitor" ? keyCatcher : settingsPane
    contentWidth: printerPanel.fittedContentWidth(Style.space(420))
    contentHeight: printerPanel.fittedContentHeight(content.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.currentTab !== "monitor"
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      property string heldKey: ""
      Keys.onReleased: function(event) {
        if (!event.isAutoRepeat) keyCatcher.heldKey = ""
      }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (heldKey === key) return
        heldKey = key
        if (key === "r") root.refresh()
        else if (key === "o") root.openOctoPrint()
        else if (key === "p" && root.pauseAction !== "" && !root.commanding)
          root.runCommand(root.pauseAction)
        else if (key === "c" && root.activePrint && !root.commanding)
          root.askCancel()
        else if (key === "s") root.showPreferences()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Row {
          width: parent.width
          spacing: Style.space(6)

          Image {
            width: Style.space(18)
            height: width
            source: root.logoUrl
            fillMode: Image.PreserveAspectFit
            smooth: true
            sourceSize: Qt.size(width * 2, height * 2)
            anchors.verticalCenter: parent.verticalCenter
          }

          PanelSectionHeader {
            text: "PRINT COMPANION"
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        ButtonGroup {
          options: [
            { value: "monitor", label: "Monitor" },
            { value: "preferences", label: "Preferences" },
            { value: "setup", label: "Setup" }
          ]
          value: root.currentTab
          focusable: false
          onChanged: function(value) {
            if (value === "preferences") root.showPreferences()
            else if (value === "setup") root.showSetup()
            else root.currentTab = "monitor"
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.currentTab === "monitor"

        Rectangle {
          width: parent.width
          height: Math.round(width / Math.max(1.25, Math.min(1.9, cameraFrame.sourceAspect)))
          visible: root.cameraVisible
          radius: Style.cornerRadius
          color: Color.background
          clip: true

          CameraFrame {
            id: cameraFrame
            anchors.fill: parent
            frameUrl: root.frameUrl
          }

          Rectangle {
            anchors.fill: parent
            visible: root.frameUrl === ""
            color: Color.background

            Column {
              anchors.centerIn: parent
              spacing: Style.space(4)

              Image {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(28)
                height: width
                source: root.logoUrl
                fillMode: Image.PreserveAspectFit
                opacity: 0.7
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.cameraError !== "" ? root.cameraError : "Waiting for camera"
                textFormat: Text.PlainText
                color: root.cameraError !== "" ? Color.urgent : root.detailColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: cameraState.implicitHeight + Style.space(8)
            color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.82)

            Text {
              id: cameraState
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.printer.stateText
              textFormat: Text.PlainText
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              visible: root.jobInProgress
              text: root.completion + "%"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.openOctoPrint()
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.lastError === ""

          Text {
            width: parent.width
            elide: Text.ElideRight
            text: root.printer.job.name
              || ((root.printer.connected && root.printer.faulted !== true && root.printer.state !== "error")
                  ? "Printer ready"
                  : (root.printer.stateText || "Printer disconnected"))
            textFormat: Text.PlainText
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            width: parent.width
            visible: root.printer.errorMessage !== ""
            wrapMode: Text.WordWrap
            text: root.printer.errorMessage
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            visible: root.jobInProgress
            text: root.formatDuration(root.printer.progress.printTimeLeft) + " left · done "
              + root.formatClock(root.printer.progress.etaAt)
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Item {
          width: parent.width
          height: Style.space(5)
          visible: root.jobInProgress

          Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Style.normalFill
          }

          Rectangle {
            width: parent.width * root.completion / 100
            height: parent.height
            radius: height / 2
            color: root.printer.state === "paused" ? Color.urgent : Color.accent
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(18)
          visible: root.lastError === ""

          Column {
            spacing: Style.space(2)
            Text {
              text: "NOZZLE"
              color: root.detailColor
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              text: root.formatTemp(root.printer.temperature.tool0)
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          Column {
            spacing: Style.space(2)
            Text {
              text: "BED"
              color: root.detailColor
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              text: root.formatTemp(root.printer.temperature.bed)
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.lastError !== ""

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.lastError
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Button {
            visible: root.lastError.indexOf("Authorize") >= 0 || root.lastError.indexOf("authorization") >= 0
            text: "Open setup"
            bordered: true
            fontSize: Style.font.caption
            onClicked: root.showSetup()
          }
        }

        Text {
          width: parent.width
          visible: root.commandError !== ""
          wrapMode: Text.WordWrap
          text: root.commandError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Row {
          spacing: Style.space(6)
          visible: root.activePrint && root.lastError === ""

          Button {
            text: Attention.pauseLabel(root.printer)
            bordered: true
            enabled: root.pauseAction !== "" && !root.commanding
            fontSize: Style.font.caption
            onClicked: root.runCommand(root.pauseAction)
          }

          Button {
            text: root.confirmCancel ? "Confirm cancel" : "Cancel"
            bordered: true
            enabled: !root.commanding
            fontSize: Style.font.caption
            onClicked: root.askCancel()
          }
        }

        Row {
          width: parent.width

          Text {
            width: parent.width - openButton.implicitWidth
            anchors.verticalCenter: parent.verticalCenter
            text: root.refreshing
              ? "Refreshing…"
              : (root.dataIsStale ? "Status is stale" : "Updated " + root.formatAgo(root.printer.fetchedAt))
            color: root.dataIsStale ? Color.urgent : root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            id: openButton
            text: "Open OctoPrint"
            fontSize: Style.font.caption
            onClicked: root.openOctoPrint()
          }
        }

        Text {
          width: parent.width
          text: root.activePrint
            ? "P pause/resume · C C cancel · R refresh · O open · S preferences"
            : "R refresh · O open · S preferences"
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        }

        SettingsPane {
          id: settingsPane
          width: parent.width
          visible: root.currentTab !== "monitor"
          page: root.currentTab
          configuredUrl: root.instanceUrl
          configuredCameraMode: root.cameraMode
          configuredShowProgress: root.showProgress
          configuredNotifyFinished: root.notifyFinished
          configuredNotifyPaused: root.notifyPaused
          configuredNotifyError: root.notifyError
          savingConnection: settingsProcess.running
          savingPreference: preferenceProcess.running
          authorizing: authorizeProcess.running || manualAuthorizeProcess.running
          message: root.settingsMessage
          messageIsError: root.settingsMessageIsError
          onConnectionRequested: function(url, nextAction, apiKey) {
            root.saveConnection(url, nextAction, apiKey)
          }
          onPreferenceRequested: function(key, value) { root.savePreference(key, value) }
          onForgetRequested: function(url) { root.forgetKey(url) }
          onExternalLinkRequested: function(url) { root.openExternal(url) }
          onMonitorRequested: root.currentTab = "monitor"
        }
      }
    }
  }
}
