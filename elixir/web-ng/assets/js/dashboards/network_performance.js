import {mountNetworkPerformance as mountBlueprintNetworkPerformance} from "../../component/src/NetworkPerformanceDashboard.jsx"

export function mountNetworkPerformance(element, host, api) {
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

  return mountBlueprintNetworkPerformance(element, resolvedHost, api)
}

export default mountNetworkPerformance
