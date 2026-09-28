import {useCallback, useEffect, useState} from "react"
import {useDashboardApi} from "./react.js"

function matchesAction(action, {scope, pluginId} = {}) {
  if (scope && action?.scope && action.scope !== scope) return false
  if (pluginId && action?.plugin_id && action.plugin_id !== pluginId) return false
  return true
}

export function useDashboardActions({scope, pluginId} = {}) {
  const api = useDashboardApi()
  const actionsApi = api?.actions
  const [actions, setActions] = useState([])
  const [invocations, setInvocations] = useState({})
  const allowed = typeof actionsApi?.allowed === "function" ? actionsApi.allowed({scope, pluginId}) !== false : false

  useEffect(() => {
    let cancelled = false
    if (!allowed || typeof actionsApi?.list !== "function") {
      setActions([])
      return undefined
    }
    Promise.resolve(actionsApi.list({scope, pluginId}))
      .then((entries) => {
        const listed = Array.isArray(entries) ? entries : []
        if (!cancelled) setActions(listed.filter((entry) => matchesAction(entry, {scope, pluginId})))
      })
      .catch(() => {
        if (!cancelled) setActions([])
      })
    return () => {
      cancelled = true
    }
  }, [actionsApi, allowed, pluginId, scope])

  const invoke = useCallback(
    (request) => {
      if (typeof actionsApi?.invoke !== "function") return Promise.reject(new Error("dashboard actions are unavailable"))
      return actionsApi.invoke(request, {
        onProgress(progress) {
          if (!progress?.invocation_id) return
          setInvocations((previous) => ({...previous, [progress.invocation_id]: progress}))
        },
      })
    },
    [actionsApi],
  )

  return {allowed, actions, invoke, invocations}
}

export function useDashboardEvents(filter, onEvents, {enabled = true} = {}) {
  const api = useDashboardApi()
  const eventsApi = api?.events
  const allowed = typeof eventsApi?.allowed === "function" ? eventsApi.allowed(filter) !== false : false
  const [error, setError] = useState(null)

  useEffect(() => {
    if (!enabled || !allowed || typeof eventsApi?.subscribe !== "function") return undefined
    try {
      setError(null)
      return eventsApi.subscribe(filter, onEvents)
    } catch (subscriptionError) {
      setError(subscriptionError)
      return undefined
    }
  }, [allowed, enabled, eventsApi, filter, onEvents])

  return {allowed, error}
}

export function useFrameRefresh() {
  const api = useDashboardApi()
  return useCallback(() => {
    if (typeof api?.refreshFrames === "function") return api.refreshFrames()
    return Promise.resolve({refreshed: false})
  }, [api])
}

export {useDashboardActions as useActions, useDashboardEvents as useEvents}
