pragma ComponentBehavior: Bound

import QtQuick

// Two surfaces keep the previous frame painted until the next JPEG is ready.
// A single Image visibly blinks each time its source changes.
Item {
  id: root

  property string frameUrl: ""
  property bool frontIsA: true
  readonly property bool hasFrame: imageA.status === Image.Ready || imageB.status === Image.Ready
  readonly property real sourceAspect: {
    var candidate = frontIsA ? imageA : imageB
    if (candidate.sourceSize.width <= 0 || candidate.sourceSize.height <= 0) return 4 / 3
    return candidate.sourceSize.width / candidate.sourceSize.height
  }

  onFrameUrlChanged: {
    if (frameUrl === "") return
    if (frontIsA) imageB.source = frameUrl
    else imageA.source = frameUrl
  }

  Image {
    id: imageA
    anchors.fill: parent
    asynchronous: true
    cache: false
    fillMode: Image.PreserveAspectCrop
    opacity: root.frontIsA ? 1 : 0
    onStatusChanged: if (status === Image.Ready && !root.frontIsA) root.frontIsA = true
  }

  Image {
    id: imageB
    anchors.fill: parent
    asynchronous: true
    cache: false
    fillMode: Image.PreserveAspectCrop
    opacity: root.frontIsA ? 0 : 1
    onStatusChanged: if (status === Image.Ready && root.frontIsA) root.frontIsA = false
  }
}
