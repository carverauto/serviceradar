import {mountWebRum as mountBlueprintWebRum} from "../../component/src/WebRumDashboard.jsx"

export function mountWebRum(element, host, api) {
  const domTimezone =
    element?.dataset?.timezone ||
    (typeof element?.closest === "function" ? element.closest("[data-timezone]")?.dataset?.timezone : null)

  const resolvedHost =
    domTimezone && !host?.instance?.timezone
      ? {
          ...(host || {}),
          instance: {
            ...(host?.instance || {}),
            timezone: domTimezone,
          },
        }
      : host

  return mountBlueprintWebRum(element, resolvedHost, api)
}

export default mountWebRum
