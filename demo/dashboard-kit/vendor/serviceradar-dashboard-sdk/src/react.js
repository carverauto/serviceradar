import React, {createContext, useCallback, useContext, useEffect, useMemo, useState} from "react"
import {createRoot} from "react-dom/client"

const DashboardHostContext = createContext(null)

export function mountReactDashboard(Component) {
  return (root, host, api) => {
    const reactRoot = createRoot(root)
    reactRoot.render(
      React.createElement(
        DashboardHostContext.Provider,
        {value: {host, api}},
        React.createElement(Component, {host, api}),
      ),
    )
    return {destroy: () => reactRoot.unmount()}
  }
}

export function useDashboardHost() {
  return useContext(DashboardHostContext)?.host ?? null
}

export function useDashboardApi() {
  return useContext(DashboardHostContext)?.api ?? null
}

export function useDashboardFrame(id) {
  const api = useDashboardApi()
  const [, setVersion] = useState(0)
  useEffect(() => {
    if (!api?.onFrameUpdate) return undefined
    return api.onFrameUpdate(() => setVersion((version) => version + 1))
  }, [api])
  if (!api) return null
  if (typeof api.frame === "function") return api.frame(id) ?? null
  return (typeof api.frames === "function" ? api.frames() : []).find((frame) => String(frame?.id) === String(id)) ?? null
}

export function useDashboardFrames() {
  const api = useDashboardApi()
  const [, setVersion] = useState(0)
  useEffect(() => {
    if (!api?.onFrameUpdate) return undefined
    return api.onFrameUpdate(() => setVersion((version) => version + 1))
  }, [api])
  return typeof api?.frames === "function" ? api.frames() : []
}

export function useDashboardSrql() {
  const api = useDashboardApi()
  return useMemo(() => api?.srql ?? {update: async () => undefined}, [api])
}

export function useDashboardTheme() {
  const api = useDashboardApi()
  const readTheme = useCallback(() => (typeof api?.theme === "function" ? api.theme() : "light"), [api])
  const [theme, setTheme] = useState(readTheme)
  useEffect(() => {
    setTheme(readTheme())
    if (!api?.onThemeChange) return undefined
    return api.onThemeChange((next) => setTheme(next))
  }, [api, readTheme])
  return theme
}
