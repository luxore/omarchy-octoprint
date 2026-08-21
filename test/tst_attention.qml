import QtQuick
import QtTest
import "../Attention.js" as Attention

TestCase {
  name: "AttentionTransitions"

  function observation(state, faulted) {
    return { state: state, faulted: faulted === true }
  }

  function test_firstObservationIsQuiet() {
    compare(Attention.notification(observation("", false), observation("error", true), false), "")
  }

  function test_oneInstanceOwnsStatusAndNotifications() {
    var first = ({ name: "first" })
    var second = ({ name: "second" })
    verify(Attention.ownsStatus(first, [first, second]))
    verify(!Attention.ownsStatus(second, [first, second]))
    verify(Attention.ownsStatus(first, []))
  }

  function test_pauseControlMatchesOctoprintTransitions() {
    compare(Attention.pauseAction({ state: "printing", stateText: "Printing" }), "pause")
    compare(Attention.pauseAction({ state: "paused", stateText: "Paused" }), "resume")
    compare(Attention.pauseAction({ state: "paused", stateText: "Pausing" }), "resume")
    compare(Attention.pauseAction({ state: "printing", stateText: "Resuming" }), "pause")
    compare(Attention.pauseAction({ state: "printing", stateText: "Starting" }), "pause")
    compare(Attention.pauseAction({ state: "printing", stateText: "Finishing" }), "")
    compare(Attention.pauseLabel({ state: "printing", stateText: "Finishing" }), "Finishing…")
  }

  function test_completedPrintNotifies() {
    compare(Attention.notification(observation("printing", false), observation("idle", false), false), "finished")
  }

  function test_localCancelSuppressesMissedWireState() {
    compare(Attention.notification(observation("printing", false), observation("idle", false), true), "")
  }

  function test_observedCancelDoesNotFinish() {
    compare(Attention.notification(observation("cancelling", false), observation("idle", false), false), "")
  }

  function test_pauseNotifiesOnce() {
    compare(Attention.notification(observation("printing", false), observation("paused", false), false), "paused")
    compare(Attention.notification(observation("paused", false), observation("paused", false), false), "")
  }

  function test_activePrintLostToCleanOfflineIsError() {
    compare(Attention.notification(observation("printing", false), observation("offline", false), false), "error")
  }

  function test_activePrintLostToTransportIsError() {
    compare(Attention.notification(observation("printing", false), observation("unreachable", true), false), "error")
  }

  function test_transportFailureClearsLiveMeasurements() {
    var unavailable = Attention.unavailable("Network down")
    compare(unavailable.state, "unreachable")
    compare(unavailable.connected, false)
    compare(unavailable.faulted, true)
    compare(unavailable.errorMessage, "Network down")
    compare(unavailable.job.name, "")
    compare(unavailable.progress.completion, null)
    compare(unavailable.progress.etaAt, null)
    compare(unavailable.temperature.tool0.actual, null)
    compare(unavailable.fetchedAt, 0)
  }

  function test_errorThenFaultedOfflineDoesNotRepeat() {
    compare(Attention.notification(observation("error", true), observation("offline", true), false), "")
  }

  function test_cleanOfflineBecomingFaultedIsError() {
    compare(Attention.notification(observation("offline", false), observation("offline", true), false), "error")
  }
}
