import React, {useCallback, useEffect, useMemo, useRef, useState} from "react"

import {
  buildDesktopFocusFrame,
  buildDesktopKeyFrame,
  buildDesktopPointerFrame,
  buildDesktopResizeFrame,
  sendDesktopControlFrame,
} from "../../js/lib/remote_desktop/control_frame.js"
import {createDesktopRenderQueue, desktopPolicyStatusItems, normalizeDesktopPolicySnapshot} from "../../js/lib/remote_desktop/renderer_state.js"
import {drainDesktopRenderQueue} from "../../js/lib/remote_desktop/renderer_runtime.js"
import {RemoteDesktopWebRTCClient} from "../../js/lib/remote_desktop/webrtc_client.js"

const DEFAULT_QUEUE_MAX_FRAMES = 12
const DEFAULT_RENDER_DRAIN_FRAMES = 4

function createRemoteDesktopWebRTCClient(options) {
  return new RemoteDesktopWebRTCClient(options)
}

function sessionValue(session, key, fallback = "") {
  const value = session?.[key]
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback
}

function sessionStatus(session) {
  return sessionValue(session, "status", "unknown").replaceAll("_", " ")
}

function webrtcReady(session) {
  return session?.desktop_webrtc_enabled === true && Boolean(session?.desktop_webrtc_signaling_path)
}

export function Component({
  session = null,
  title = "RDP remote access",
  queueMaxFrames = DEFAULT_QUEUE_MAX_FRAMES,
  autoConnect = false,
  clientFactory = createRemoteDesktopWebRTCClient,
}) {
  const policySnapshot = session?.desktop_policy_snapshot || {}
  const policy = useMemo(() => normalizeDesktopPolicySnapshot(policySnapshot), [policySnapshot])
  const statusItems = useMemo(() => desktopPolicyStatusItems(policySnapshot), [policySnapshot])
  const sessionIdentity = sessionValue(session, "id", sessionValue(session, "session_id", ""))
  const renderQueueRef = useRef(createDesktopRenderQueue({maxFrames: queueMaxFrames}))
  const canvasRef = useRef(null)
  const clientRef = useRef(null)
  const [connectionStatus, setConnectionStatus] = useState(autoConnect ? "pending" : "idle")
  const [viewerSessionId, setViewerSessionId] = useState("")
  const [frameCount, setFrameCount] = useState(0)
  const [droppedFrameCount, setDroppedFrameCount] = useState(0)
  const [rendererStats, setRendererStats] = useState({framesApplied: 0, tilesApplied: 0, lastSequence: null})
  const [controlFrameCount, setControlFrameCount] = useState(0)
  const [lastError, setLastError] = useState("")

  const closeClient = useCallback((reason = "desktop viewer closed") => {
    clientRef.current?.close(reason)
    clientRef.current = null
    setViewerSessionId("")
  }, [])

  const connect = useCallback(async () => {
    if (!session || !webrtcReady(session) || clientRef.current) {
      return
    }

    setLastError("")
    setConnectionStatus("connecting")
    setViewerSessionId("")
    setFrameCount(0)
    setDroppedFrameCount(0)
    setRendererStats({framesApplied: 0, tilesApplied: 0, lastSequence: null})
    setControlFrameCount(0)
    renderQueueRef.current.clear()

    const client = clientFactory({
      signalingPath: session.desktop_webrtc_signaling_path,
      iceServers: session.desktop_webrtc_ice_servers || [],
      mediaQueueState: () => renderQueueRef.current.state(),
      onStatus: setConnectionStatus,
      onFrame(frame) {
        const result = renderQueueRef.current.push(frame)
        const droppedCount = result.accepted ? result.dropped.length : result.dropped.length + 1

        if (result.accepted) {
          setFrameCount((count) => count + 1)
        }
        if (droppedCount > 0) {
          setDroppedFrameCount((count) => count + droppedCount)
        }
      },
      onFrameDropped() {
        setDroppedFrameCount((count) => count + 1)
      },
      onClose(label) {
        setConnectionStatus(`closed:${label}`)
      },
      onError(error) {
        setLastError(error?.message || "Desktop media connection failed")
      },
    })

    clientRef.current = client

    try {
      const viewer = await client.connect()
      setViewerSessionId(viewer.viewerSessionId || "")
      setConnectionStatus("connected")
    } catch (error) {
      client.close?.("desktop viewer connect failed")
      clientRef.current = null
      setLastError(error?.message || "Unable to start desktop media session")
      setConnectionStatus("error")
    }
  }, [clientFactory, session])

  const disconnect = useCallback(() => {
    closeClient("operator closed desktop viewer")
    setConnectionStatus("closed")
  }, [closeClient])

  useEffect(() => {
    closeClient("desktop session changed")
    renderQueueRef.current.clear()
    setViewerSessionId("")
    setFrameCount(0)
    setDroppedFrameCount(0)
    setRendererStats({framesApplied: 0, tilesApplied: 0, lastSequence: null})
    setControlFrameCount(0)
    setLastError("")
    setConnectionStatus(autoConnect ? "pending" : "idle")
  }, [autoConnect, closeClient, sessionIdentity])

  const sendControlFrame = useCallback((frame) => {
    if (sendDesktopControlFrame(clientRef.current, frame)) {
      setControlFrameCount((count) => count + 1)
      return true
    }

    return false
  }, [])

  const handleCanvasFocus = useCallback(() => {
    sendControlFrame(buildDesktopFocusFrame(session, true))
  }, [sendControlFrame, session])

  const handleCanvasBlur = useCallback(() => {
    sendControlFrame(buildDesktopFocusFrame(session, false))
  }, [sendControlFrame, session])

  const handleCanvasKey = useCallback((event, down) => {
    if (sendControlFrame(buildDesktopKeyFrame(session, {key: event.key, down}))) {
      event.preventDefault()
    }
  }, [sendControlFrame, session])

  const handlePointer = useCallback((event, down) => {
    if (down) {
      canvasRef.current?.focus?.()
    }

    if (sendControlFrame(buildDesktopPointerFrame(session, event, canvasRef.current, {down}))) {
      event.preventDefault()
    }
  }, [sendControlFrame, session])

  const sendResizeFrame = useCallback(() => {
    const canvas = canvasRef.current
    sendControlFrame(buildDesktopResizeFrame(session, {width: canvas?.width, height: canvas?.height}))
  }, [sendControlFrame, session])

  useEffect(() => {
    if (autoConnect && webrtcReady(session) && !clientRef.current) {
      void connect()
    }
  }, [autoConnect, connect, session])

  useEffect(() => () => closeClient("desktop viewer unmounted"), [closeClient])

  useEffect(() => {
    if (!session) {
      return undefined
    }

    const scheduleFrame = (callback) => (
      typeof globalThis.requestAnimationFrame === "function"
        ? globalThis.requestAnimationFrame(callback)
        : globalThis.setTimeout(callback, 16)
    )
    const cancelFrame = (handle) => {
      if (typeof globalThis.cancelAnimationFrame === "function") {
        globalThis.cancelAnimationFrame(handle)
      } else {
        globalThis.clearTimeout(handle)
      }
    }
    let frameHandle = null
    let stopped = false

    const tick = () => {
      if (stopped) {
        return
      }

      const context = canvasRef.current?.getContext?.("2d", {alpha: false})
      const result = drainDesktopRenderQueue(renderQueueRef.current, {
        context,
        maxFrames: DEFAULT_RENDER_DRAIN_FRAMES,
      })

      if (result.frames > 0) {
        if (result.resized) {
          sendResizeFrame()
        }

        setRendererStats((stats) => ({
          framesApplied: stats.framesApplied + result.frames,
          tilesApplied: stats.tilesApplied + result.uploads,
          lastSequence: result.lastSequence ?? stats.lastSequence,
        }))
      }

      frameHandle = scheduleFrame(tick)
    }

    frameHandle = scheduleFrame(tick)

    return () => {
      stopped = true
      if (frameHandle !== null) {
        cancelFrame(frameHandle)
      }
    }
  }, [sendResizeFrame, session])

  if (!session) {
    return (
      <section className="flex h-full min-h-[420px] items-center justify-center bg-base-100 p-6 text-sm text-base-content/60">
        No RDP session selected.
      </section>
    )
  }

  return (
    <section className="grid h-full min-h-[560px] bg-neutral text-neutral-content lg:grid-cols-[minmax(0,1fr)_22rem]">
      <div className="flex min-h-0 flex-col">
        <header className="flex min-h-14 items-center gap-3 border-b border-white/10 px-4">
          <div className="min-w-0 flex-1">
            <h2 className="truncate text-sm font-semibold">{title}</h2>
            <p className="truncate text-xs text-neutral-content/60">{policy.target.label}</p>
          </div>
          <div className="badge badge-outline border-white/20 text-neutral-content">{sessionStatus(session)}</div>
        </header>

        <div className="flex min-h-0 flex-1 items-center justify-center bg-black">
          <div className="relative flex aspect-video w-full max-w-6xl items-center justify-center overflow-hidden border border-white/10 bg-neutral-950 text-center">
            <canvas
              aria-label="Remote desktop display"
              className="h-full w-full object-contain"
              onBlur={handleCanvasBlur}
              onFocus={handleCanvasFocus}
              onKeyDown={(event) => handleCanvasKey(event, true)}
              onKeyUp={(event) => handleCanvasKey(event, false)}
              onPointerDown={(event) => handlePointer(event, true)}
              onPointerMove={(event) => handlePointer(event, false)}
              onPointerUp={(event) => handlePointer(event, false)}
              ref={canvasRef}
              tabIndex={0}
            />
            {rendererStats.framesApplied === 0 ? (
              <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
                <div className="space-y-2 px-4">
                  <div className="text-sm font-medium">No video yet</div>
                  <div className="text-xs text-neutral-content/60">
                    {webrtcReady(session) ? "Waiting for frames." : "Media unavailable."}
                  </div>
                </div>
              </div>
            ) : null}
            <div className="absolute bottom-3 left-3 rounded bg-black/70 px-2 py-1 text-xs text-white/70">
              {rendererStats.tilesApplied} tile updates
            </div>
            <div className="sr-only" aria-live="polite">
              {rendererStats.framesApplied} rendered frames
              {rendererStats.lastSequence === null ? "" : ` through sequence ${rendererStats.lastSequence}`}
            </div>
          </div>
        </div>
      </div>

      <aside className="flex min-h-0 flex-col border-t border-white/10 bg-base-200 text-base-content lg:border-l lg:border-t-0">
        <div className="border-b border-base-300 p-4">
          <div className="text-sm font-semibold">Session posture</div>
          <div className="mt-1 truncate text-xs text-base-content/60">{policy.route.label}</div>
        </div>

        <dl className="grid grid-cols-1 gap-3 border-b border-base-300 p-4 text-sm">
          {statusItems.map((item) => (
            <div className="grid grid-cols-[7rem_minmax(0,1fr)] gap-2" key={item.key}>
              <dt className="text-xs uppercase tracking-wide text-base-content/50">{item.label}</dt>
              <dd className="truncate font-medium" title={item.value}>{item.value}</dd>
            </div>
          ))}
        </dl>

        <div className="space-y-3 border-b border-base-300 p-4 text-sm">
          <div className="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
            <span className="text-xs uppercase tracking-wide text-base-content/50">Transport</span>
            <span className="truncate font-medium">{connectionStatus}</span>
          </div>
          <div className="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
            <span className="text-xs uppercase tracking-wide text-base-content/50">Viewer</span>
            <span className="truncate font-medium">{viewerSessionId || "Not attached"}</span>
          </div>
          <div className="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
            <span className="text-xs uppercase tracking-wide text-base-content/50">Frames</span>
            <span className="font-medium">{frameCount} accepted / {droppedFrameCount} dropped</span>
          </div>
          <div className="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
            <span className="text-xs uppercase tracking-wide text-base-content/50">Input</span>
            <span className="font-medium">{controlFrameCount} control frames</span>
          </div>
        </div>

        {lastError ? (
          <div className="m-4 rounded border border-error/30 bg-error/10 px-3 py-2 text-sm text-error">{lastError}</div>
        ) : null}

        <div className="mt-auto flex gap-2 p-4">
          <button className="btn btn-primary btn-sm flex-1" type="button" disabled={!webrtcReady(session) || Boolean(clientRef.current)} onClick={connect}>
            {connectionStatus === "connecting" ? "Connecting" : "Connect"}
          </button>
          <button className="btn btn-outline btn-sm flex-1" type="button" disabled={!clientRef.current} onClick={disconnect}>
            Disconnect
          </button>
        </div>
      </aside>
    </section>
  )
}

export default Component
