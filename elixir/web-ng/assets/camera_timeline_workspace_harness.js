import CameraTimelinePlayer from "./js/hooks/CameraTimelinePlayer"
import CameraVerticalTimeline from "./js/hooks/CameraVerticalTimeline"

// Mount shipped timeline hooks onto the rendered production HEEx component and
// record pushed LiveView events + delegated phx-click dispatches for verification.
const pushedEvents = []
const phxClicks = []

window.__timelinePushedEvents = pushedEvents
window.__timelinePhxClicks = phxClicks

const verticalEl = document.querySelector("[phx-hook='CameraVerticalTimeline']")
if (verticalEl) {
  const verticalHook = {
    ...CameraVerticalTimeline,
    el: verticalEl,
    pushEvent: (event, payload) => pushedEvents.push({hook: "CameraVerticalTimeline", event, payload}),
  }
  verticalHook.mounted()
  window.verticalTimelineHook = verticalHook
}

const playerEl = document.querySelector("[phx-hook='CameraTimelinePlayer']")
if (playerEl) {
  const playerHook = {
    ...CameraTimelinePlayer,
    el: playerEl,
    pushEvent: (event, payload) => pushedEvents.push({hook: "CameraTimelinePlayer", event, payload}),
  }
  playerHook.mounted()
  window.timelinePlayerHook = playerHook
}

// Mirror LiveView's delegated phx-click dispatch and drive drawer toggle DOM state.
document.addEventListener("click", event => {
  const target = event.target?.closest?.("[phx-click]")
  if (!target) return

  const action = target.getAttribute("phx-click")
  const values = {}
  for (const attr of target.attributes) {
    if (attr.name.startsWith("phx-value-")) {
      values[attr.name.slice("phx-value-".length)] = attr.value
    }
  }
  phxClicks.push({action, id: target.id || null, values})

  const drawer = document.getElementById("camera-timeline-manage-drawer")
  if (drawer) {
    if (action === "toggle_manage_drawer") {
      const opening = drawer.classList.contains("hidden")
      drawer.classList.toggle("hidden", !opening)
      drawer.setAttribute("aria-hidden", String(!opening))
    } else if (action === "close_manage_drawer") {
      drawer.classList.add("hidden")
      drawer.setAttribute("aria-hidden", "true")
    }
  }
})
