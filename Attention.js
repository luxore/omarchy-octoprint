.pragma library

function isActive(observation) {
  if (!observation) return false
  return observation.state === "printing"
    || observation.state === "paused"
    || observation.state === "cancelling"
}

function isFault(observation) {
  if (!observation) return false
  return observation.faulted === true
    || observation.state === "error"
    || observation.state === "unreachable"
}

function ownsStatus(instance, instances) {
  return !instances || instances.length === 0 || instances[0] === instance
}

function barAlarm(observation, progressVisible) {
  return observation
    && observation.connected === true
    && progressVisible !== true
    && (observation.state === "error" || observation.faulted === true)
}

function barDimmed(observation, initialized) {
  return initialized !== true || !observation || observation.connected !== true
}

function pauseAction(observation) {
  if (!observation) return ""
  var state = String(observation.state || "")
  var text = String(observation.stateText || "").toLowerCase()

  // OctoPrint deliberately permits reversing Starting, Pausing, and Resuming.
  // Finishing is the one printing state in which it rejects pause.
  if (text === "finishing") return ""
  if (state === "paused") return "resume"
  if (state === "printing") return "pause"
  return ""
}

function pauseLabel(observation) {
  var action = pauseAction(observation)
  if (action === "pause") return "Pause"
  if (action === "resume") return "Resume"
  return String(observation && observation.stateText || "").toLowerCase() === "finishing"
    ? "Finishing…" : "Working…"
}

function notificationCommand(title, body, urgency) {
  var escapedBody = String(body || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
  if (escapedBody.charAt(0) === "-") escapedBody = "&#45;" + escapedBody.slice(1)
  return [
    "omarchy-notification-send", "--app-name", "OctoPrint",
    "-u", urgency || "normal", String(title), escapedBody
  ]
}

function failureKind(message) {
  var text = String(message || "").toLowerCase()
  if (text.indexOf("authorize") >= 0 || text.indexOf("authorization") >= 0) return "auth"
  if (text.indexOf("helper is missing") >= 0) return "helper"
  return "transport"
}

function unavailable(message) {
  var detail = message || "OctoPrint status failed"
  var kind = failureKind(detail)
  return {
    configured: true,
    connected: false,
    state: "unreachable",
    stateText: kind === "auth"
      ? "Authorization required"
      : (kind === "helper" ? "Helper unavailable" : "OctoPrint unreachable"),
    faulted: true,
    errorMessage: detail,
    job: { name: "", path: "" },
    progress: { completion: null, printTime: null, printTimeLeft: null, etaAt: null },
    temperature: {
      tool0: { actual: null, target: null },
      bed: { actual: null, target: null }
    },
    fetchedAt: 0
  }
}

function notification(previous, current, cancelPending) {
  if (!previous || !previous.state || !current || !current.state) return ""

  if (current.state === "idle" && previous.state === "printing" && !cancelPending)
    return "finished"

  if (current.state === "paused" && previous.state !== "paused")
    return "paused"

  if (isFault(current) && !isFault(previous))
    return "error"

  if (current.state === "offline" && isActive(previous))
    return "error"

  return ""
}
