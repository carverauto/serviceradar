import React, {useCallback, useEffect, useMemo, useRef, useState} from "react"

import {
  buildDesktopFocusFrame,
  buildDesktopKeyFrame,
  buildDesktopPointerFrame,
  buildDesktopResizeFrame,
  sendDesktopControlFrame,
} from "../../js/lib/remote_desktop/control_frame.js"
import {createDesktopRenderQueue, desktopPolicyStatusItems, normalizeDesktopPolicySnapshot} from "../../js/lib/remote_desktop/renderer_state.js"
import {createBrowserDesktopRenderTarget, drainDesktopRenderQueue} from "../../js/lib/remote_desktop/renderer_runtime.js"
import {RemoteDesktopWebRTCClient} from "../../js/lib/remote_desktop/webrtc_client.js"

const DEFAULT_QUEUE_MAX_FRAMES = 12
const DEFAULT_RENDER_DRAIN_FRAMES = 4
const DEFAULT_RDP_LAUNCH_TIMEOUT_MS = 30_000
const DEFAULT_RDP_ACTIVITY_INTERVAL_MS = 30_000
const EMPTY_RENDERER_STATS = {framesApplied: 0, tilesApplied: 0, lastSequence: null}

function csrfToken() {
  return document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
}

function websocketUrl(path) {
  const url = new URL(path, window.location.origin)
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:"
  return url.toString()
}

function apiError(payload, fallback) {
  const error = new Error(payload?.message || payload?.error || fallback)
  error.code = payload?.error || ""
  return error
}

function normalizedString(value) {
  return typeof value === "string" ? value.trim() : ""
}

export function buildRdpSessionRequest(desktopTargetId, deviceUid, approvalId = "") {
  const request = {
    protocol: "rdp",
    adapter: "rdp",
    desktop_target_id: normalizedString(desktopTargetId),
    device_uid: normalizedString(deviceUid),
  }
  const normalizedApprovalId = normalizedString(approvalId)

  if (normalizedApprovalId) {
    request.approval_id = normalizedApprovalId
  }

  return request
}

export function buildRdpAttachMessage(session, credential) {
  return {
    type: "attach",
    ticket: session?.ticket,
    session_id: session?.id,
    credential: {
      username: normalizedString(credential?.username),
      password: credential?.password || "",
    },
  }
}

export function readyForSession(message, sessionId) {
  return message?.type === "ready" && message?.session_id === sessionId
}

export function rdpLaunchInProgress(status) {
  return status === "opening" || status === "attaching" || status === "awaiting_ready"
}

function validCreatedSession(session) {
  return Boolean(
    normalizedString(session?.id) &&
      normalizedString(session?.ticket) &&
      normalizedString(session?.websocket_path),
  )
}

function sessionClosePath(createPath, sessionId) {
  return `${createPath.replace(/\/+$/u, "")}/${encodeURIComponent(sessionId)}/close`
}

export function createRdpLauncherRuntime({
  desktopTargetId,
  deviceUid,
  approvalId = "",
  createPath = "/api/remote-access/sessions",
  fetchImpl = (...args) => globalThis.fetch(...args),
  socketFactory = (path) => new WebSocket(websocketUrl(path)),
  csrfTokenProvider = csrfToken,
  launchTimeoutMs = DEFAULT_RDP_LAUNCH_TIMEOUT_MS,
  setTimeoutImpl = (...args) => globalThis.setTimeout(...args),
  clearTimeoutImpl = (handle) => globalThis.clearTimeout(handle),
  abortControllerFactory = () => (
    typeof globalThis.AbortController === "function" ? new globalThis.AbortController() : null
  ),
  onStatus = () => {},
  onReady = () => {},
  onError = () => {},
  onCredentialCleared = () => {},
  onClosed = () => {},
}) {
  let session = null
  let socket = null
  let credential = null
  let closing = false
  let ready = false
  let closeRequested = false
  let launchDeadline = null
  let abortController = null
  let lastActivityAtMs = 0

  function clearCredential() {
    if (!credential) {
      return
    }

    credential.password = ""
    credential = null
    onCredentialCleared()
  }

  function clearLaunchDeadline() {
    if (launchDeadline !== null) {
      clearTimeoutImpl(launchDeadline)
      launchDeadline = null
    }
    abortController = null
  }

  function abortLaunchRequest() {
    try {
      abortController?.abort?.()
    } catch (_error) {
      // Timeout/close is authoritative even when an AbortController shim fails.
    }
    abortController = null
  }

  async function requestSessionClose(reason) {
    if (!session?.id || closeRequested) {
      return
    }

    closeRequested = true

    try {
      await fetchImpl(sessionClosePath(createPath, session.id), {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfTokenProvider(),
        },
        body: JSON.stringify({reason}),
        keepalive: true,
      })
    } catch (_error) {
      // The server also expires abandoned sessions; never surface cleanup details.
    }
  }

  function closeSocket(reason) {
    if (socket && (socket.readyState === 0 || socket.readyState === 1)) {
      socket.close(1000, reason.slice(0, 120))
    }
    socket = null
  }

  function recordActivity() {
    const nowMs = Date.now()

    if (
      closing ||
      !ready ||
      !socket ||
      socket.readyState !== 1 ||
      nowMs - lastActivityAtMs < DEFAULT_RDP_ACTIVITY_INTERVAL_MS
    ) {
      return false
    }

    try {
      socket.send(JSON.stringify({type: "activity", session_id: session.id}))
      lastActivityAtMs = nowMs
      return true
    } catch (_error) {
      fail("Unable to refresh the RDP session activity lease.")
      return false
    }
  }

  function close(reason = "RDP launcher closed") {
    if (closing) {
      return
    }

    closing = true
    abortLaunchRequest()
    clearLaunchDeadline()
    clearCredential()
    closeSocket(reason)
    void requestSessionClose(reason)
    onClosed()
  }

  function fail(message) {
    if (closing) {
      return
    }

    onStatus("failed")
    onError(message)
    close("RDP session failed")
  }

  function attachSocket() {
    try {
      socket = socketFactory(session.websocket_path)
    } catch (_error) {
      fail("Unable to open the RDP control channel.")
      return
    }

    socket.addEventListener("open", () => {
      if (closing || !credential) {
        return
      }

      onStatus("attaching")
      try {
        socket.send(JSON.stringify(buildRdpAttachMessage(session, credential)))
      } catch (_error) {
        fail("Unable to authorize the RDP control channel.")
        return
      }

      clearCredential()
      onStatus("awaiting_ready")
    })

    socket.addEventListener("message", (event) => {
      if (closing) {
        return
      }

      let message
      try {
        message = JSON.parse(event.data)
      } catch (_error) {
        fail("The RDP control channel returned an invalid response.")
        return
      }

      if (readyForSession(message, session.id)) {
        ready = true
        clearLaunchDeadline()
        clearCredential()
        onStatus("ready")
        onReady(session)
        return
      }

      if (message?.type === "error") {
        fail(message.message || "The RDP control channel rejected the session.")
      }
    })

    socket.addEventListener("error", () => {
      fail("The RDP control channel failed.")
    })

    socket.addEventListener("close", () => {
      socket = null
      if (!closing) {
        fail(ready ? "The RDP control channel closed." : "The RDP session closed before it was ready.")
      }
    })
  }

  async function open({username, password}) {
    if (closing || session) {
      return
    }

    const normalizedTargetId = normalizedString(desktopTargetId)
    const normalizedDeviceUid = normalizedString(deviceUid)
    const normalizedUsername = normalizedString(username)

    if (!normalizedTargetId) {
      onError("The authorized RDP target is missing.")
      return
    }

    if (!normalizedDeviceUid) {
      onError("The RDP launch device is missing.")
      return
    }

    if (!normalizedUsername || !password) {
      onError("Windows username and password are required.")
      return
    }

    credential = {username: normalizedUsername, password}
    onStatus("opening")
    abortController = abortControllerFactory()
    launchDeadline = setTimeoutImpl(() => {
      abortLaunchRequest()
      fail("The RDP session did not become ready before the launch deadline.")
    }, launchTimeoutMs)

    try {
      const response = await fetchImpl(createPath, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrfTokenProvider(),
        },
        body: JSON.stringify(buildRdpSessionRequest(normalizedTargetId, normalizedDeviceUid, approvalId)),
        ...(abortController?.signal ? {signal: abortController.signal} : {}),
      })

      const payload = await response.json()

      if (closing) {
        if (response.ok && normalizedString(payload?.data?.id)) {
          session = payload.data
          await requestSessionClose("RDP launcher closed during session creation")
        }
        return
      }

      if (!response.ok) {
        throw apiError(payload, "Unable to open the RDP session.")
      }

      if (!validCreatedSession(payload?.data)) {
        throw new Error("The RDP session response was incomplete.")
      }

      session = payload.data
      attachSocket()
    } catch (error) {
      fail(error?.message || "Unable to open the RDP session.")
    }
  }

  return {open, close, recordActivity}
}

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

function queueState(queue) {
  return queue?.state?.() || {decodeQueueSize: 0, maxDecodeQueueSize: 0}
}

function queueDepthLabel(queueStats) {
  return `${queueStats.decodeQueueSize}/${queueStats.maxDecodeQueueSize} queued`
}

function sequenceLabel(sequence) {
  return sequence === null || sequence === undefined ? "No frames" : String(sequence)
}

function closeRenderTarget(renderTargetRef) {
  renderTargetRef.current.target?.close?.()
  renderTargetRef.current = {canvas: null, target: null}
}

export function Component({
  session = null,
  title = "RDP remote access",
  queueMaxFrames = DEFAULT_QUEUE_MAX_FRAMES,
  autoConnect = false,
  clientFactory = createRemoteDesktopWebRTCClient,
  onDisconnect = null,
  onConnectionFailure = null,
  onActivity = null,
}) {
  const policySnapshot = session?.desktop_policy_snapshot || {}
  const policy = useMemo(() => normalizeDesktopPolicySnapshot(policySnapshot), [policySnapshot])
  const statusItems = useMemo(() => desktopPolicyStatusItems(policySnapshot), [policySnapshot])
  const sessionIdentity = sessionValue(session, "id", sessionValue(session, "session_id", ""))
  const renderQueueRef = useRef(createDesktopRenderQueue({maxFrames: queueMaxFrames}))
  const renderTargetRef = useRef({canvas: null, target: null})
  const canvasRef = useRef(null)
  const videoRef = useRef(null)
  const clientRef = useRef(null)
  const failureReportedRef = useRef(false)
  const mountedRef = useRef(true)
  const [connectionStatus, setConnectionStatus] = useState(autoConnect ? "pending" : "idle")
  const [viewerSessionId, setViewerSessionId] = useState("")
  const [frameCount, setFrameCount] = useState(0)
  const [droppedFrameCount, setDroppedFrameCount] = useState(0)
  const [rendererStats, setRendererStats] = useState(EMPTY_RENDERER_STATS)
  const [queueStats, setQueueStats] = useState(() => queueState(renderQueueRef.current))
  const [controlFrameCount, setControlFrameCount] = useState(0)
  const [lastError, setLastError] = useState("")
  const [mediaStream, setMediaStream] = useState(null)

  const closeClient = useCallback((reason = "desktop viewer closed") => {
    clientRef.current?.close(reason)
    clientRef.current = null
    if (mountedRef.current) {
      setViewerSessionId("")
      setMediaStream(null)
    }
  }, [])

  const connect = useCallback(async () => {
    if (!session || !webrtcReady(session) || clientRef.current) {
      return
    }

    setLastError("")
    setConnectionStatus("connecting")
    failureReportedRef.current = false
    setViewerSessionId("")
    setFrameCount(0)
    setDroppedFrameCount(0)
    setRendererStats(EMPTY_RENDERER_STATS)
    setControlFrameCount(0)
    renderQueueRef.current.clear()
    setQueueStats(queueState(renderQueueRef.current))

    const client = clientFactory({
      signalingPath: session.desktop_webrtc_signaling_path,
      iceServers: session.desktop_webrtc_ice_servers || [],
      mediaQueueState: () => renderQueueRef.current.state(),
      onStatus(nextStatus) {
        if (mountedRef.current) {
          setConnectionStatus(nextStatus)
        }
      },
      onFrame(frame) {
        if (!mountedRef.current) {
          return
        }

        onActivity?.()
        const result = renderQueueRef.current.push(frame)
        const droppedCount = result.accepted ? result.dropped.length : result.dropped.length + 1

        if (result.accepted) {
          setFrameCount((count) => count + 1)
        }
        if (droppedCount > 0) {
          setDroppedFrameCount((count) => count + droppedCount)
        }
        setQueueStats(queueState(renderQueueRef.current))
      },
      onFrameDropped() {
        if (!mountedRef.current) {
          return
        }

        onActivity?.()
        setDroppedFrameCount((count) => count + 1)
        setQueueStats(queueState(renderQueueRef.current))
      },
      onClose(label) {
        if (!mountedRef.current) {
          return
        }

        if (!failureReportedRef.current) {
          failureReportedRef.current = true
          const message = `Desktop media connection closed: ${label}`
          setConnectionStatus(`closed:${label}`)
          setLastError(message)
          onConnectionFailure?.(message)
        }
      },
      onError(error) {
        if (!mountedRef.current) {
          return
        }

        if (!failureReportedRef.current) {
          failureReportedRef.current = true
          const message = error?.message || "Desktop media connection failed"
          setLastError(message)
          onConnectionFailure?.(message)
        }
      },
      onMediaStream(stream) {
        if (mountedRef.current) {
          setMediaStream(stream)
        }
      },
    })

    clientRef.current = client

    try {
      const viewer = await client.connect()
      if (!mountedRef.current) {
        client.close?.("desktop viewer unmounted")
        return
      }

      setViewerSessionId(viewer.viewerSessionId || "")
      setConnectionStatus("connected")
    } catch (error) {
      client.close?.("desktop viewer connect failed")
      clientRef.current = null
      if (!mountedRef.current) {
        return
      }

      const message = error?.message || "Unable to start desktop media session"
      setLastError(message)
      setConnectionStatus("error")
      if (!failureReportedRef.current) {
        failureReportedRef.current = true
        onConnectionFailure?.(message)
      }
    }
  }, [clientFactory, onActivity, onConnectionFailure, session])

  const disconnect = useCallback(() => {
    closeClient("operator closed desktop viewer")
    setConnectionStatus("closed")
    onDisconnect?.()
  }, [closeClient, onDisconnect])

  useEffect(() => {
    mountedRef.current = true

    return () => {
      mountedRef.current = false
    }
  }, [])

  useEffect(() => {
    closeClient("desktop session changed")
    renderQueueRef.current.clear()
    closeRenderTarget(renderTargetRef)
    setViewerSessionId("")
    setFrameCount(0)
    setDroppedFrameCount(0)
    setRendererStats(EMPTY_RENDERER_STATS)
    setQueueStats(queueState(renderQueueRef.current))
    setControlFrameCount(0)
    setLastError("")
    setMediaStream(null)
    setConnectionStatus(autoConnect ? "pending" : "idle")
  }, [autoConnect, closeClient, sessionIdentity])

  const sendControlFrame = useCallback((frame) => {
    if (sendDesktopControlFrame(clientRef.current, frame)) {
      setControlFrameCount((count) => count + 1)
      onActivity?.()
      return true
    }

    return false
  }, [onActivity])

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

  const canvasRenderTarget = useCallback(() => {
    const canvas = canvasRef.current
    if (!canvas) {
      return null
    }

    if (renderTargetRef.current.canvas !== canvas) {
      renderTargetRef.current.target?.close?.()
      renderTargetRef.current = {
        canvas,
        target: createBrowserDesktopRenderTarget(canvas),
      }
    }

    return renderTargetRef.current.target
  }, [])

  useEffect(() => {
    if (autoConnect && webrtcReady(session) && !clientRef.current) {
      void connect()
    }
  }, [autoConnect, connect, session])

  useEffect(() => () => {
    closeClient("desktop viewer unmounted")
    closeRenderTarget(renderTargetRef)
  }, [closeClient])

  useEffect(() => {
    const video = videoRef.current

    if (!video) {
      return undefined
    }

    if (video.srcObject !== mediaStream) {
      video.srcObject = mediaStream
    }

    if (mediaStream) {
      void video.play?.().catch(() => {})
    }

    return () => {
      if (video.srcObject === mediaStream) {
        video.srcObject = null
      }
    }
  }, [mediaStream])

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

      const result = drainDesktopRenderQueue(renderQueueRef.current, {
        maxFrames: DEFAULT_RENDER_DRAIN_FRAMES,
        onFrameError(error) {
          const message = error?.message || "Unable to render desktop frame"
          setLastError(message)
          closeClient("desktop renderer rejected frame")
          if (!failureReportedRef.current) {
            failureReportedRef.current = true
            onConnectionFailure?.(message)
          }
        },
        renderTarget: canvasRenderTarget(),
      })

      if (result.frames > 0) {
        const renderErrors = result.errors || 0
        const appliedFrames = Math.max(0, result.frames - renderErrors)

        if (result.errors > 0) {
          setDroppedFrameCount((count) => count + renderErrors)
        }

        if (result.resized) {
          sendResizeFrame()
        }

        setRendererStats((stats) => ({
          framesApplied: stats.framesApplied + appliedFrames,
          tilesApplied: stats.tilesApplied + result.uploads,
          lastSequence: result.lastSequence ?? stats.lastSequence,
        }))
        setQueueStats(queueState(renderQueueRef.current))
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
  }, [canvasRenderTarget, closeClient, onConnectionFailure, sendResizeFrame, session])

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
              className={`h-full w-full object-contain ${mediaStream ? "opacity-0" : ""}`}
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
            <video
              aria-label="Remote desktop video track"
              autoPlay
              className={`pointer-events-none absolute inset-0 h-full w-full object-contain ${mediaStream ? "" : "hidden"}`}
              muted
              onTimeUpdate={() => onActivity?.()}
              playsInline
              ref={videoRef}
            />
            {rendererStats.framesApplied === 0 && !mediaStream ? (
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
            <span className="text-xs uppercase tracking-wide text-base-content/50">Backpressure</span>
            <span className="font-medium">{queueDepthLabel(queueStats)}</span>
          </div>
          <div className="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
            <span className="text-xs uppercase tracking-wide text-base-content/50">Sequence</span>
            <span className="font-medium">{sequenceLabel(rendererStats.lastSequence)}</span>
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

export function Launcher({
  desktopTargetId = "",
  deviceUid = "",
  approvalId = "",
  createPath = "/api/remote-access/sessions",
  title = "RDP remote access",
  fetchImpl = (...args) => globalThis.fetch(...args),
  socketFactory = (path) => new WebSocket(websocketUrl(path)),
  csrfTokenProvider = csrfToken,
  clientFactory = createRemoteDesktopWebRTCClient,
}) {
  const usernameRef = useRef(null)
  const passwordRef = useRef(null)
  const runtimeRef = useRef(null)
  const mountedRef = useRef(true)
  const [session, setSession] = useState(null)
  const [status, setStatus] = useState("idle")
  const [error, setError] = useState("")

  const clearPasswordInput = useCallback(() => {
    if (passwordRef.current) {
      passwordRef.current.value = ""
    }
  }, [])

  const closeActiveSession = useCallback((reason, nextStatus = "closed") => {
    runtimeRef.current?.close(reason)
    runtimeRef.current = null
    clearPasswordInput()
    setSession(null)
    setStatus(nextStatus)
  }, [clearPasswordInput])

  useEffect(() => {
    mountedRef.current = true

    return () => {
      mountedRef.current = false
      clearPasswordInput()
      runtimeRef.current?.close("RDP launcher unmounted")
      runtimeRef.current = null
    }
  }, [clearPasswordInput])

  const handleSubmit = useCallback((event) => {
    event.preventDefault()
    setError("")

    const username = usernameRef.current?.value || ""
    const password = passwordRef.current?.value || ""
    let runtime

    runtime = createRdpLauncherRuntime({
      desktopTargetId,
      deviceUid,
      approvalId,
      createPath,
      fetchImpl,
      socketFactory,
      csrfTokenProvider,
      onStatus(nextStatus) {
        if (mountedRef.current) {
          setStatus(nextStatus)
        }
      },
      onReady(nextSession) {
        if (mountedRef.current) {
          setError("")
          setSession(nextSession)
        }
      },
      onError(message) {
        if (mountedRef.current) {
          setError(message)
        }
      },
      onCredentialCleared: clearPasswordInput,
      onClosed() {
        if (runtimeRef.current === runtime) {
          runtimeRef.current = null
        }
        if (mountedRef.current) {
          setSession(null)
        }
      },
    })

    runtimeRef.current?.close("RDP launcher restarted")
    runtimeRef.current = runtime
    void runtime.open({username, password})
  }, [approvalId, clearPasswordInput, createPath, csrfTokenProvider, desktopTargetId, deviceUid, fetchImpl, socketFactory])

  const handleConnectionFailure = useCallback((message) => {
    if (mountedRef.current) {
      setError(message)
      closeActiveSession("RDP media connection failed", "failed")
    }
  }, [closeActiveSession])

  if (session) {
    return (
      <Component
        autoConnect
        clientFactory={clientFactory}
        onActivity={() => runtimeRef.current?.recordActivity()}
        onConnectionFailure={handleConnectionFailure}
        onDisconnect={() => closeActiveSession("Operator closed RDP session")}
        session={session}
        title={title}
      />
    )
  }

  const opening = rdpLaunchInProgress(status)

  return (
    <section className="flex h-full min-h-[560px] items-center justify-center bg-base-200 p-4 sm:p-8">
      <div className="card card-border w-full max-w-lg bg-base-100">
        <div className="card-body gap-5">
          <div>
            <h2 className="card-title">{title}</h2>
            <p className="mt-2 text-sm text-base-content/70">
              Enter credentials for the Windows account on this device. ServiceRadar sends them once to the authorized edge route and does not retain them.
            </p>
          </div>

          {error ? (
            <div id="rdp-launch-error" className="alert alert-error" role="alert">
              <span>{error}</span>
            </div>
          ) : null}

          {opening ? (
            <div id="rdp-launch-status" className="alert alert-info" role="status">
              <span className="loading loading-spinner loading-sm" aria-hidden="true"></span>
              <span>
                {status === "awaiting_ready"
                  ? "Waiting for the RDP route to become ready…"
                  : status === "attaching"
                    ? "Authorizing the RDP connection…"
                    : "Opening the RDP session…"}
              </span>
            </div>
          ) : null}

          <form id="rdp-credential-form" className="space-y-4" onSubmit={handleSubmit}>
            <fieldset className="fieldset">
              <legend className="fieldset-legend">Windows username</legend>
              <input
                id="rdp-windows-username"
                className="input w-full"
                autoComplete="username"
                disabled={opening}
                name="username"
                ref={usernameRef}
                required
                type="text"
              />
              <p className="label">Use the local or domain-qualified account allowed by the target policy.</p>
            </fieldset>

            <fieldset className="fieldset">
              <legend className="fieldset-legend">Password</legend>
              <input
                id="rdp-windows-password"
                className="input w-full"
                autoComplete="current-password"
                disabled={opening}
                name="password"
                ref={passwordRef}
                required
                type="password"
              />
              <p className="label">The password is cleared immediately after the one-time attach message is sent.</p>
            </fieldset>

            <div className="card-actions justify-end">
              <button id="rdp-connect-button" className="btn btn-primary" disabled={opening} type="submit">
                {opening ? "Connecting…" : "Connect with RDP"}
              </button>
            </div>
          </form>
        </div>
      </div>
    </section>
  )
}

export default function RemoteAccessDesktopSession(props) {
  return normalizedString(props?.desktopTargetId) ? <Launcher {...props} /> : <Component {...props} />
}
