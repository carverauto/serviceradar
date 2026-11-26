import React, { useMemo, useState } from "react"
import {
  mountReactDashboard,
  useDashboardCapability,
  useDashboardSettings,
  useDashboardTheme,
  useFrameRows,
} from "@carverauto/serviceradar-dashboard-sdk/react"
import { CameraGrid } from "@carverauto/serviceradar-dashboard-sdk/camera"
import { useDashboardEvents, useFrameRefresh } from "@carverauto/serviceradar-dashboard-sdk/live"

export const MODULE_VERSION = "dashboard-browser-module-v1"

const SYNTHETIC_REFERENCE_PLATES = ["SR-0100", "TEST-742"]

function isSafeThumbnailUrl(url) {
  if (typeof url !== "string") return false
  const trimmed = url.trim()
  if (!trimmed) return false
  return /^https?:\/\//i.test(trimmed) || (trimmed.startsWith("/") && !trimmed.startsWith("//"))
}

function formatConfidence(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return "-"
  return `${Math.round(value * 100)}%`
}

function formatTimestamp(timelineTsUs) {
  if (typeof timelineTsUs !== "number" || !Number.isFinite(timelineTsUs) || timelineTsUs <= 0) {
    return "-"
  }
  try {
    return new Date(Math.floor(timelineTsUs / 1000)).toISOString()
  } catch {
    return "-"
  }
}

function normalizeRow(row) {
  const attrs = row?.attributes && typeof row.attributes === "object" ? row.attributes : {}
  const plateText = String(attrs.plate_text || row?.label || "").trim() || "-"
  const region = String(attrs.region || "").trim() || "-"
  const vehicle = [attrs.vehicle_color, attrs.vehicle_type].filter(Boolean).join(" ") || "-"
  const thumbnailUrl = isSafeThumbnailUrl(row?.thumbnail_url) ? row.thumbnail_url.trim() : null

  return {
    key: String(row?.observation_key || row?.id || `${plateText}-${row?.timeline_ts_us || 0}`),
    plateText,
    region,
    vehicle,
    confidence: typeof row?.confidence === "number" ? row.confidence : attrs.confidence,
    cameraSourceId: row?.camera_source_id ? String(row.camera_source_id) : "",
    streamProfileId: row?.stream_profile_id ? String(row.stream_profile_id) : "",
    cameraLabel: String(row?.camera_name || row?.camera_label || "").trim(),
    timelineTsUs: row?.timeline_ts_us ?? null,
    timeBasis: String(row?.time_basis || "received"),
    hasCrop: Boolean(row?.crop_jpeg || row?.crop_jpeg_b64 || thumbnailUrl),
    thumbnailUrl,
  }
}

export function AlprConsole() {
  const theme = useDashboardTheme()
  const settings = useDashboardSettings()
  const rows = useFrameRows("recent_plate_reads")
  const refreshFrames = useFrameRefresh()
  const cameraAllowed = useDashboardCapability("camera.stream.view")
  const eventsAllowed = useDashboardCapability("events.subscribe")
  const [liveCount, setLiveCount] = useState(0)
  const [plateFilter, setPlateFilter] = useState("")
  const [selectedCameraKey, setSelectedCameraKey] = useState(null)

  const minConfidence =
    typeof settings?.min_confidence === "number" && Number.isFinite(settings.min_confidence)
      ? settings.min_confidence
      : 0

  const scopedCameraId =
    typeof settings?.camera_source_id === "string" && settings.camera_source_id.trim() !== ""
      ? settings.camera_source_id.trim()
      : null

  const eventFilter = useMemo(() => {
    const filter = {
      class_uid: 1008,
      metadata: {
        service_radar: {
          signal_schema: { schema_id: "alpr_plate_read" },
        },
      },
    }
    if (scopedCameraId) {
      filter.camera_source_id = scopedCameraId
    }
    return filter
  }, [scopedCameraId])

  const eventsState = useDashboardEvents(
    eventFilter,
    (events) => {
      const count = Array.isArray(events) ? events.length : 1
      if (count > 0) {
        setLiveCount((prev) => prev + count)
        void refreshFrames()
      }
    },
    { enabled: eventsAllowed },
  )

  const normalizedRows = useMemo(() => {
    const needle = plateFilter.trim().toUpperCase()
    return (Array.isArray(rows) ? rows : [])
      .map(normalizeRow)
      .filter((item) => {
        if (scopedCameraId && item.cameraSourceId !== scopedCameraId) return false
        if (typeof item.confidence === "number" && item.confidence < minConfidence) return false
        if (needle && !item.plateText.toUpperCase().includes(needle)) return false
        return true
      })
  }, [rows, scopedCameraId, minConfidence, plateFilter])

  const cameras = useMemo(() => {
    const seen = new Map()
    for (const row of normalizedRows) {
      if (!row.cameraSourceId || !row.streamProfileId) continue
      const key = `${row.cameraSourceId}:${row.streamProfileId}`
      if (!seen.has(key)) {
        seen.set(key, {
          camera_source_id: row.cameraSourceId,
          stream_profile_id: row.streamProfileId,
          label: row.cameraLabel || `Camera ${row.cameraSourceId.slice(0, 8)}`,
        })
      }
    }
    return Array.from(seen.values())
  }, [normalizedRows])

  const dark = theme === "dark"
  const palette = dark
    ? {
        bg: "#0f172a",
        panel: "#1e293b",
        border: "#334155",
        text: "#f8fafc",
        muted: "#94a3b8",
        accent: "#38bdf8",
      }
    : {
        bg: "#f8fafc",
        panel: "#ffffff",
        border: "#cbd5e1",
        text: "#0f172a",
        muted: "#475569",
        accent: "#0284c7",
      }

  return (
    <div
      data-vantage-alpr-console="true"
      style={{
        background: palette.bg,
        color: palette.text,
        padding: "16px",
        borderRadius: "8px",
        fontFamily: "system-ui, -apple-system, sans-serif",
        display: "grid",
        gap: "16px",
      }}
    >
      <div
        style={{
          display: "flex",
          flexWrap: "wrap",
          justifyContent: "space-between",
          alignItems: "center",
          gap: "12px",
          padding: "12px 16px",
          background: palette.panel,
          border: `1px solid ${palette.border}`,
          borderRadius: "8px",
        }}
      >
        <div>
          <div style={{ fontSize: "16px", fontWeight: 700 }}>Vantage ALPR Synthetic Console</div>
          <div style={{ fontSize: "12px", color: palette.muted }}>
            Live plate reads from Gate West 01 (192.0.2.10) | Live OCSF 1008 updates: {liveCount}
          </div>
        </div>
        <div style={{ display: "flex", gap: "8px", alignItems: "center" }}>
          <input
            type="search"
            value={plateFilter}
            onChange={(event) => setPlateFilter(event.target.value)}
            placeholder={`Filter plate (e.g. ${SYNTHETIC_REFERENCE_PLATES[0]})`}
            aria-label="Filter plate reads"
            style={{
              padding: "6px 10px",
              borderRadius: "6px",
              border: `1px solid ${palette.border}`,
              background: palette.bg,
              color: palette.text,
              fontSize: "13px",
            }}
          />
          <button
            type="button"
            onClick={() => void refreshFrames()}
            style={{
              padding: "6px 12px",
              borderRadius: "6px",
              border: `1px solid ${palette.accent}`,
              background: palette.accent,
              color: "#ffffff",
              fontSize: "13px",
              fontWeight: 600,
              cursor: "pointer",
            }}
          >
            Refresh
          </button>
        </div>
      </div>

      {eventsState.error ? (
        <div
          style={{
            padding: "8px 12px",
            borderRadius: "6px",
            border: `1px solid ${palette.border}`,
            background: palette.panel,
            color: palette.muted,
            fontSize: "12px",
          }}
        >
          Event subscription notice: {eventsState.error.message}
        </div>
      ) : null}

      {cameraAllowed && cameras.length > 0 ? (
        <div
          style={{
            padding: "12px",
            background: palette.panel,
            border: `1px solid ${palette.border}`,
            borderRadius: "8px",
          }}
        >
          <div style={{ fontSize: "13px", fontWeight: 600, marginBottom: "8px" }}>
            Active ALPR Camera Streams ({cameras.length})
          </div>
          <CameraGrid
            cameras={cameras}
            columns={Math.min(2, cameras.length)}
            maxTiles={4}
            enabled={cameraAllowed}
            selectedKey={selectedCameraKey}
            onSelect={(cam) =>
              setSelectedCameraKey(`${cam.camera_source_id}:${cam.stream_profile_id}`)
            }
          />
        </div>
      ) : null}

      <div
        style={{
          background: palette.panel,
          border: `1px solid ${palette.border}`,
          borderRadius: "8px",
          overflowX: "auto",
        }}
      >
        <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "13px" }}>
          <thead>
            <tr style={{ borderBottom: `1px solid ${palette.border}`, textAlign: "left" }}>
              <th style={{ padding: "10px 12px" }}>Plate</th>
              <th style={{ padding: "10px 12px" }}>Region</th>
              <th style={{ padding: "10px 12px" }}>Vehicle</th>
              <th style={{ padding: "10px 12px" }}>Confidence</th>
              <th style={{ padding: "10px 12px" }}>Time Basis</th>
              <th style={{ padding: "10px 12px" }}>Timestamp</th>
              <th style={{ padding: "10px 12px" }}>Crop</th>
            </tr>
          </thead>
          <tbody>
            {normalizedRows.length === 0 ? (
              <tr>
                <td colSpan={7} style={{ padding: "16px 12px", color: palette.muted }}>
                  No ALPR observations yet. Synthetic verification plates:{" "}
                  {SYNTHETIC_REFERENCE_PLATES.join(", ")} (Gate West 01).
                </td>
              </tr>
            ) : (
              normalizedRows.map((item) => (
                <tr key={item.key} style={{ borderTop: `1px solid ${palette.border}` }}>
                  <td style={{ padding: "8px 12px", fontWeight: 700 }}>{item.plateText}</td>
                  <td style={{ padding: "8px 12px" }}>{item.region}</td>
                  <td style={{ padding: "8px 12px" }}>{item.vehicle}</td>
                  <td style={{ padding: "8px 12px" }}>{formatConfidence(item.confidence)}</td>
                  <td style={{ padding: "8px 12px" }}>{item.timeBasis}</td>
                  <td style={{ padding: "8px 12px", fontFamily: "monospace", fontSize: "12px" }}>
                    {formatTimestamp(item.timelineTsUs)}
                  </td>
                  <td style={{ padding: "8px 12px" }}>
                    {item.hasCrop ? "Available" : "None"}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}

export const mountDashboard = mountReactDashboard(AlprConsole)
export default mountDashboard
