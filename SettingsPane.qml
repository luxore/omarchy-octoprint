pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui

FocusScope {
  id: root

  property string page: "preferences"
  property string configuredUrl: ""
  property string configuredCameraMode: "stream"
  property bool configuredShowProgress: true
  property bool configuredNotifyFinished: true
  property bool configuredNotifyPaused: true
  property bool configuredNotifyError: true
  property bool savingConnection: false
  property bool savingPreference: false
  property bool authorizing: false
  property string message: ""
  property bool messageIsError: false

  signal connectionRequested(string url, string nextAction, string apiKey)
  signal preferenceRequested(string key, string value)
  signal forgetRequested(string url)
  signal externalLinkRequested(string url)
  signal monitorRequested()

  property string draftCameraMode: "stream"
  property bool draftShowProgress: true
  property bool draftNotifyFinished: true
  property bool draftNotifyPaused: true
  property bool draftNotifyError: true
  property string localError: ""

  implicitWidth: Style.space(420)
  implicitHeight: Math.min(settingsColumn.implicitHeight, Style.space(570))

  function load() {
    urlField.text = configuredUrl
    apiKeyField.text = ""
    draftCameraMode = configuredCameraMode
    draftShowProgress = configuredShowProgress
    draftNotifyFinished = configuredNotifyFinished
    draftNotifyPaused = configuredNotifyPaused
    draftNotifyError = configuredNotifyError
    localError = ""
  }

  function acceptSavedUrl(url) {
    urlField.text = String(url)
    localError = ""
  }

  function saveConnection(nextAction) {
    localError = ""
    var url = urlField.text.trim()
    var key = apiKeyField.text.trim()
    if (url === "") {
      localError = "Enter the address of your OctoPrint server"
      urlField.forceActiveFocus()
      return
    }
    if (nextAction === "key" && key === "") {
      localError = "Enter an OctoPrint application or user API key"
      apiKeyField.forceActiveFocus()
      return
    }
    root.connectionRequested(url, nextAction, key)
    if (nextAction === "key") apiKeyField.text = ""
  }

  Component.onCompleted: load()

  Keys.onEscapePressed: function(event) {
    root.monitorRequested()
    event.accepted = true
  }

  Controls.ScrollView {
    anchors.fill: parent
    clip: true
    contentWidth: availableWidth
    Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

    Column {
      id: settingsColumn
      width: parent.width
      spacing: Style.space(12)

      Column {
        width: parent.width
        spacing: Style.space(12)
        visible: root.page === "preferences"

        PanelSectionHeader { text: "CAMERA" }

        ButtonGroup {
          options: [
            { value: "stream", label: "Stream" },
            { value: "snapshots", label: "Snapshots" },
            { value: "off", label: "Off" }
          ]
          value: root.draftCameraMode
          enabled: !root.savingPreference
          focusable: true
          onChanged: function(value) {
            if (value === root.draftCameraMode) return
            root.draftCameraMode = value
            root.preferenceRequested("cameraMode", value)
          }
        }

        Text {
          width: parent.width
          text: "Stream is smoothest. Snapshots are lighter. Camera traffic stops when the popup closes."
          wrapMode: Text.WordWrap
          color: Qt.darker(Color.popups.text, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { foreground: Color.popups.text }
        PanelSectionHeader { text: "BAR" }

        Toggle {
          width: parent.width
          label: "Progress and ETA"
          description: "Show completion and estimated finish time in the bar while printing"
          checked: root.draftShowProgress
          enabled: !root.savingPreference
          onClicked: {
            root.draftShowProgress = !root.draftShowProgress
            root.preferenceRequested("showProgress", root.draftShowProgress ? "true" : "false")
          }
        }

        PanelSeparator { foreground: Color.popups.text }
        PanelSectionHeader { text: "NOTIFICATIONS" }

        Toggle {
          width: parent.width
          label: "Print finished"
          checked: root.draftNotifyFinished
          enabled: !root.savingPreference
          onClicked: {
            root.draftNotifyFinished = !root.draftNotifyFinished
            root.preferenceRequested("notifyFinished", root.draftNotifyFinished ? "true" : "false")
          }
        }

        Toggle {
          width: parent.width
          label: "Print paused"
          checked: root.draftNotifyPaused
          enabled: !root.savingPreference
          onClicked: {
            root.draftNotifyPaused = !root.draftNotifyPaused
            root.preferenceRequested("notifyPaused", root.draftNotifyPaused ? "true" : "false")
          }
        }

        Toggle {
          width: parent.width
          label: "Printer error"
          checked: root.draftNotifyError
          enabled: !root.savingPreference
          onClicked: {
            root.draftNotifyError = !root.draftNotifyError
            root.preferenceRequested("notifyError", root.draftNotifyError ? "true" : "false")
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(12)
        visible: root.page === "setup"

        Column {
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader { text: "OCTOPRINT SERVER" }

          Text {
            width: parent.width
            text: "Use an IP address, DNS name, HTTPS URL, or reverse-proxy path. The address saves when you leave the field."
            wrapMode: Text.WordWrap
            color: Qt.darker(Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        TextField {
          id: urlField
          width: parent.width
          placeholderText: "octopi.local or https://printer.example"
          enabled: !root.savingConnection
          onEditingFinished: {
            if (text.trim() !== "" && text.trim() !== root.configuredUrl)
              root.saveConnection("")
          }
        }

        Text {
          width: parent.width
          visible: {
            var address = urlField.text.trim().toLowerCase()
            return address !== "" && !address.startsWith("https://")
          }
          text: "HTTP sends the API key without transport encryption. Use it only on a trusted local network."
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { foreground: Color.popups.text }

        Column {
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader { text: "AUTHORIZATION" }

          Text {
            width: parent.width
            text: "Recommended: approve a dedicated application key in OctoPrint. You can also use an existing application or user API key."
            wrapMode: Text.WordWrap
            color: Qt.darker(Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Button {
          text: root.authorizing ? "Waiting for OctoPrint…" : "Connect in browser"
          bordered: true
          focusable: true
          enabled: !root.authorizing
          onClicked: root.saveConnection("browser")
        }

        Text {
          width: parent.width
          text: "Compatible with OctoPrint. OctoPrint is a registered trademark."
          wrapMode: Text.WordWrap
          color: Qt.darker(Color.popups.text, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.externalLinkRequested("https://octoprint.org")
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          TextField {
            id: apiKeyField
            width: parent.width - keyButton.implicitWidth - parent.spacing
            password: true
            placeholderText: "Existing API key"
            enabled: !root.authorizing
          }

          Button {
            id: keyButton
            text: "Use key"
            bordered: true
            focusable: true
            enabled: !root.authorizing
            onClicked: root.saveConnection("key")
          }
        }

        Button {
          text: "Forget saved key"
          focusable: true
          enabled: !root.authorizing
          onClicked: {
            if (urlField.text.trim() !== "") root.forgetRequested(urlField.text.trim())
          }
        }

        Text {
          width: parent.width
          text: "Removes the key from this computer. Revoke it in OctoPrint to invalidate it."
          wrapMode: Text.WordWrap
          color: Qt.darker(Color.popups.text, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        width: parent.width
        visible: root.localError !== "" || root.message !== ""
        text: root.localError !== "" ? root.localError : root.message
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.localError !== "" || root.messageIsError ? Color.urgent : Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
