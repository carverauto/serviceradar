import ELK from "elkjs/lib/elk.bundled.js"

const elk = new ELK()

export const POSTURE_EVALUATORS = [
  {
    id: "storage.entitlement_utilization",
    label: "Storage Entitlement Utilization (#6760)",
    description: "Monitors billable_bytes / plan_bytes utilization and hard_cap_active state.",
  },
  {
    id: "storage.hold_pin_pressure",
    label: "Storage Hold Pin Pressure (#6760)",
    description: "Warns when PD5 RecordingHold pins starve normal archive object retention.",
  },
  {
    id: "storage.archive_credential_and_usage_health",
    label: "Archive Credential & Usage Health (#6760)",
    description: "Verifies uploader/reader/retention archive credentials and daily usage report freshness.",
  },
  {
    id: "camera.continuous_recording_silence",
    label: "Camera Continuous Recording Silence (#6760)",
    description: "Detects enabled continuous NVR recording policies sealing 0 blocks across window.",
  },
]

export const NODE_PALETTE_CATEGORIES = [
  {
    id: "core_signals",
    title: "Core Signals",
    items: [
      {
        kind: "srql_query",
        label: "SRQL Query",
        icon: "search-template",
        description: "Bounded read-only SRQL query via AshAdapter (<= 1,000 rows).",
      },
      {
        kind: "platform_posture",
        label: "Platform Posture",
        icon: "shield",
        description: "First-party Core posture evaluator (#6760 storage & NVR health).",
      },
      {
        kind: "vantage_point",
        label: "Vantage Point",
        icon: "satellite",
        description: "Agent reachability observation for composite multi-vantage checks.",
      },
      {
        kind: "device_metadata",
        label: "Device Metadata",
        icon: "database",
        description: "Device inventory fact selector for composite checks.",
      },
    ],
  },
  {
    id: "edge_signals",
    title: "Edge Signals",
    items: [
      {
        kind: "http_request",
        label: "HTTP Request",
        icon: "globe-network",
        description: "Single synthetic HTTP/HTTPS request with SecretBroker auth.",
      },
      {
        kind: "http_journey",
        label: "HTTP Journey",
        icon: "route",
        description: "Multi-step synthetic HTTP workflow with httptrace phase waterfalls.",
      },
      {
        kind: "tcp_connect",
        label: "TCP Connect",
        icon: "exchange",
        description: "TCP socket reachability and handshake latency probe.",
      },
      {
        kind: "tls_handshake",
        label: "TLS Handshake",
        icon: "lock",
        description: "TLS certificate chain validation and leaf_days_remaining check.",
      },
      {
        kind: "dns_lookup",
        label: "DNS Lookup",
        icon: "globe",
        description: "DNS record resolution and response latency probe.",
      },
    ],
  },
  {
    id: "transforms_logic",
    title: "Transforms & Logic",
    items: [
      {
        kind: "extract_field",
        label: "Extract Field",
        icon: "filter-keep",
        description: "Extract value via safe JSONPath, header, linear regex, or SRQL column.",
      },
      {
        kind: "threshold_assert",
        label: "Threshold Assert",
        icon: "sliders-horizontal",
        description: "Compare numeric, string, or boolean signal against warn/crit rules.",
      },
      {
        kind: "decision_table",
        label: "Decision Table",
        icon: "th",
        description: "Ordered multi-signal verdict matrix with max_age_seconds staleness.",
      },
    ],
  },
  {
    id: "output",
    title: "Output",
    items: [
      {
        kind: "alert_output",
        label: "Alert Output",
        icon: "notifications",
        description: "Project verdict to ServiceState, OCSF JetStream event, and StatefulAlertRule.",
      },
    ],
  },
]

export const CORE_SIGNAL_KINDS = new Set([
  "srql_query",
  "platform_posture",
  "vantage_point",
  "device_metadata",
])

export const EDGE_SIGNAL_KINDS = new Set([
  "http_request",
  "http_journey",
  "tcp_connect",
  "tls_handshake",
  "dns_lookup",
])

export const ALLOWED_NODE_KINDS = new Set([
  ...CORE_SIGNAL_KINDS,
  ...EDGE_SIGNAL_KINDS,
  "extract_field",
  "threshold_assert",
  "decision_table",
  "alert_output",
])

export const ALLOWED_COMPARATORS = ["==", "!=", ">", ">=", "<", "<=", "in", "contains", "matches"]
export const ALLOWED_STATUSES = ["healthy", "degraded", "down", "unknown"]

const FORBIDDEN_SECRET_KEYS = new Set([
  "password",
  "encrypted_password",
  "secret",
  "client_secret",
  "secret_key",
  "secret_payload",
  "encrypted_secret_payload",
  "token",
  "api_token",
  "access_token",
  "refresh_token",
  "bearer_token",
  "auth_token",
  "api_key",
  "private_key",
  "ssh_private_key",
  "access_key",
  "access_key_id",
  "secret_access_key",
  "session_token",
  "credential_secret_id",
  "credential_rule_id",
  "credentials_encrypted",
])

const FORBIDDEN_AUTH_HEADERS = new Set([
  "authorization",
  "proxy-authorization",
  "x-api-key",
  "api-key",
  "x-auth-token",
])

const ALLOWED_TOP_KEYS = new Set([
  "schema_version",
  "slug",
  "name",
  "description",
  "state",
  "pack_id",
  "pack_version",
  "managed",
  "template_fingerprint",
  "parameter_overrides",
  "schedule",
  "target_binding",
  "inputs",
  "credential_slots",
  "nodes",
  "edges",
  "alert_policy",
  "ui_layout",
])

const SEMANTIC_TEMPLATE_KEYS = [
  "schema_version",
  "slug",
  "schedule",
  "target_binding",
  "inputs",
  "credential_slots",
  "nodes",
  "edges",
  "alert_policy",
]

export const STARTER_TEMPLATES = {
  "HTTP JSON API Check": () => ({
    schema_version: 1,
    slug: "http-json-api-check",
    name: "HTTP JSON API Check",
    description: "Probes an HTTPS JSON health endpoint, extracts status, and asserts healthy response.",
    state: "draft",
    managed: false,
    parameter_overrides: {},
    schedule: {
      interval_seconds: 60,
      timeout_seconds: 15,
      jitter_seconds: 5,
    },
    target_binding: {
      mode: "singleton",
    },
    inputs: [
      {
        key: "expected_status",
        type: "string",
        default: "ok",
        description: "Expected JSON $.status field value",
      },
    ],
    credential_slots: [
      {
        slot: "api_auth",
        provider: "http_bearer",
        role: "reader",
        purpose: "synthetic_http",
        required: false,
      },
    ],
    nodes: [
      {
        id: "http_1",
        kind: "http_request",
        label: "GET API Health",
        config: {
          url: "https://api.example.com/v1/health",
          method: "GET",
          expected_statuses: [200],
          timeout_ms: 5000,
          credential_slot: "api_auth",
        },
      },
      {
        id: "extract_status",
        kind: "extract_field",
        label: "Extract $.status",
        config: {
          source_type: "jsonpath",
          expression: "$.status",
          output_key: "service_status",
        },
      },
      {
        id: "assert_status",
        kind: "threshold_assert",
        label: "Assert Status OK",
        config: {
          field: "service_status",
          crit: {op: "!=", value: "{{inputs.expected_status}}"},
        },
      },
      {
        id: "out_1",
        kind: "alert_output",
        label: "API Health Verdict",
        config: {
          verdict_map: {
            healthy: "api_healthy",
            degraded: "api_degraded",
            down: "api_unhealthy",
            unknown: "api_unknown",
          },
        },
      },
    ],
    edges: [
      {
        id: "e1",
        source: "http_1",
        source_handle: "signal",
        target: "extract_status",
        target_handle: "in",
      },
      {
        id: "e2",
        source: "extract_status",
        source_handle: "value",
        target: "assert_status",
        target_handle: "in",
      },
      {
        id: "e3",
        source: "assert_status",
        source_handle: "verdict",
        target: "out_1",
        target_handle: "in",
      },
    ],
    alert_policy: {
      emit_ocsf_transition: true,
      open_on_statuses: ["down"],
      priority: 2,
      threshold: 1,
      window_seconds: 300,
      cooldown_seconds: 300,
      renotify_seconds: 21600,
    },
    ui_layout: {
      nodes: {
        http_1: {x: 60, y: 120},
        extract_status: {x: 340, y: 120},
        assert_status: {x: 620, y: 120},
        out_1: {x: 900, y: 120},
      },
    },
  }),

  "SRQL Posture Check": () => ({
    schema_version: 1,
    slug: "srql-posture-check",
    name: "SRQL Posture Check",
    description: "Evaluates fleet posture via read-only SRQL count and threshold assertions.",
    state: "draft",
    managed: false,
    parameter_overrides: {},
    schedule: {
      interval_seconds: 300,
      timeout_seconds: 30,
      jitter_seconds: 15,
    },
    target_binding: {
      mode: "singleton",
    },
    inputs: [
      {
        key: "warn_count",
        type: "integer",
        default: 1,
        min: 0,
        max: 1000,
        description: "Warning threshold for unavailable devices",
      },
      {
        key: "crit_count",
        type: "integer",
        default: 5,
        min: 1,
        max: 1000,
        description: "Critical threshold for unavailable devices",
      },
    ],
    credential_slots: [],
    nodes: [
      {
        id: "srql_1",
        kind: "srql_query",
        label: "Unavailable Core Routers",
        config: {
          query: "in:devices is_available:false",
          limit: 100,
          timeout_ms: 5000,
          result_mode: "count",
        },
      },
      {
        id: "assert_posture",
        kind: "threshold_assert",
        label: "Unavailable Count Threshold",
        config: {
          field: "count",
          warn: {op: ">=", value: "{{inputs.warn_count}}"},
          crit: {op: ">=", value: "{{inputs.crit_count}}"},
        },
      },
      {
        id: "out_1",
        kind: "alert_output",
        label: "Fleet Posture Verdict",
        config: {
          verdict_map: {
            healthy: "posture_compliant",
            degraded: "posture_warning",
            down: "posture_violated",
            unknown: "posture_unknown",
          },
        },
      },
    ],
    edges: [
      {
        id: "e1",
        source: "srql_1",
        source_handle: "signal",
        target: "assert_posture",
        target_handle: "in",
      },
      {
        id: "e2",
        source: "assert_posture",
        source_handle: "verdict",
        target: "out_1",
        target_handle: "in",
      },
    ],
    alert_policy: {
      emit_ocsf_transition: true,
      open_on_statuses: ["down"],
      priority: 3,
      threshold: 1,
      window_seconds: 300,
      cooldown_seconds: 300,
      renotify_seconds: 21600,
    },
    ui_layout: {
      nodes: {
        srql_1: {x: 80, y: 120},
        assert_posture: {x: 400, y: 120},
        out_1: {x: 720, y: 120},
      },
    },
  }),

  "Multi-Step Synthetic Journey": () => ({
    schema_version: 1,
    slug: "multi-step-synthetic-journey",
    name: "Multi-Step Synthetic Journey",
    description: "Executes a multi-step synthetic HTTP workflow with httptrace phase timing assertions.",
    state: "draft",
    managed: false,
    parameter_overrides: {},
    schedule: {
      interval_seconds: 120,
      timeout_seconds: 30,
      jitter_seconds: 10,
    },
    target_binding: {
      mode: "singleton",
    },
    inputs: [
      {
        key: "warn_total_ms",
        type: "integer",
        default: 1500,
        min: 50,
        max: 30000,
        description: "Warning journey total duration in milliseconds",
      },
      {
        key: "crit_total_ms",
        type: "integer",
        default: 4000,
        min: 100,
        max: 30000,
        description: "Critical journey total duration in milliseconds",
      },
    ],
    credential_slots: [
      {
        slot: "journey_auth",
        provider: "http_bearer",
        role: "reader",
        purpose: "synthetic_http",
        required: true,
      },
    ],
    nodes: [
      {
        id: "journey_1",
        kind: "http_journey",
        label: "Checkout Synthetic Journey",
        config: {
          timeout_ms: 10000,
          credential_slot: "journey_auth",
          steps: [
            {
              id: "step_session",
              name: "Fetch Session Ready",
              method: "GET",
              url: "https://api.example.com/v1/session",
              expected_statuses: [200],
            },
            {
              id: "step_catalog",
              name: "Verify Catalog Feed",
              method: "GET",
              url: "https://api.example.com/v1/catalog",
              expected_statuses: [200],
            },
          ],
        },
      },
      {
        id: "assert_latency",
        kind: "threshold_assert",
        label: "Journey Latency Budget",
        config: {
          field: "total_ms",
          warn: {op: ">=", value: "{{inputs.warn_total_ms}}"},
          crit: {op: ">=", value: "{{inputs.crit_total_ms}}"},
          fail_closed_field: "journey_failed",
        },
      },
      {
        id: "out_1",
        kind: "alert_output",
        label: "Synthetic Journey Verdict",
        config: {
          verdict_map: {
            healthy: "journey_ok",
            degraded: "journey_slow",
            down: "journey_failed",
            unknown: "journey_unknown",
          },
        },
      },
    ],
    edges: [
      {
        id: "e1",
        source: "journey_1",
        source_handle: "signal",
        target: "assert_latency",
        target_handle: "in",
      },
      {
        id: "e2",
        source: "assert_latency",
        source_handle: "verdict",
        target: "out_1",
        target_handle: "in",
      },
    ],
    alert_policy: {
      emit_ocsf_transition: true,
      open_on_statuses: ["down"],
      priority: 2,
      threshold: 1,
      window_seconds: 300,
      cooldown_seconds: 300,
      renotify_seconds: 21600,
    },
    ui_layout: {
      nodes: {
        journey_1: {x: 80, y: 120},
        assert_latency: {x: 410, y: 120},
        out_1: {x: 740, y: 120},
      },
    },
  }),

  "Multi-Vantage Composite Check": () => ({
    schema_version: 1,
    slug: "multi-vantage-composite-check",
    name: "Multi-Vantage Composite Check",
    description: "Combines primary and witness agent vantage observations via an ordered decision table.",
    state: "draft",
    managed: false,
    parameter_overrides: {},
    schedule: {
      interval_seconds: 180,
      timeout_seconds: 30,
      jitter_seconds: 15,
    },
    target_binding: {
      mode: "srql_devices",
      scope_query: "in:devices",
    },
    inputs: [],
    credential_slots: [],
    nodes: [
      {
        id: "vp_primary",
        kind: "vantage_point",
        label: "Primary Vantage Agent",
        config: {
          agent_id: "agent-primary",
          max_age_seconds: 300,
        },
      },
      {
        id: "vp_witness",
        kind: "vantage_point",
        label: "Witness Vantage Agent",
        config: {
          agent_id: "agent-witness",
          max_age_seconds: 300,
        },
      },
      {
        id: "decision_1",
        kind: "decision_table",
        label: "Multi-Vantage Matrix",
        config: {
          inputs: [
            {key: "primary", source_node_id: "vp_primary", max_age_seconds: 300, label: "Primary"},
            {key: "witness", source_node_id: "vp_witness", max_age_seconds: 300, label: "Witness"},
          ],
          rules: [
            {
              match: {primary: "healthy", witness: "healthy"},
              status: "healthy",
              verdict: "reachable_all_vantages",
            },
            {
              match: {primary: "down", witness: "healthy"},
              status: "degraded",
              verdict: "primary_path_impaired",
            },
            {
              match: {primary: "down", witness: "down"},
              status: "down",
              verdict: "unreachable_confirmed",
            },
            {
              match: {primary: "*", witness: "*"},
              status: "unknown",
              verdict: "inconclusive",
            },
          ],
        },
      },
      {
        id: "out_1",
        kind: "alert_output",
        label: "Composite Verdict",
        config: {
          verdict_map: {
            healthy: "reachable_all_vantages",
            degraded: "primary_path_impaired",
            down: "unreachable_confirmed",
            unknown: "inconclusive",
          },
        },
      },
    ],
    edges: [
      {
        id: "e_primary",
        source: "vp_primary",
        source_handle: "signal",
        target: "decision_1",
        target_handle: "primary",
      },
      {
        id: "e_witness",
        source: "vp_witness",
        source_handle: "signal",
        target: "decision_1",
        target_handle: "witness",
      },
      {
        id: "e_out",
        source: "decision_1",
        source_handle: "verdict",
        target: "out_1",
        target_handle: "in",
      },
    ],
    alert_policy: {
      emit_ocsf_transition: true,
      open_on_statuses: ["down"],
      priority: 2,
      threshold: 1,
      window_seconds: 300,
      cooldown_seconds: 300,
      renotify_seconds: 21600,
    },
    ui_layout: {
      nodes: {
        vp_primary: {x: 80, y: 60},
        vp_witness: {x: 80, y: 220},
        decision_1: {x: 420, y: 140},
        out_1: {x: 760, y: 140},
      },
    },
  }),
}

export function defaultSourceHandleForKind(kind) {
  if (kind === "threshold_assert" || kind === "decision_table") return "verdict"
  if (kind === "extract_field") return "value"
  if (kind === "alert_output") return null
  return "signal"
}

export function sourcePortType(kind, handle) {
  const h = handle || defaultSourceHandleForKind(kind)
  if (CORE_SIGNAL_KINDS.has(kind) || EDGE_SIGNAL_KINDS.has(kind)) {
    return h === "signal" ? "signal" : null
  }
  if (kind === "extract_field") {
    return ["value", "signal", "out"].includes(h) ? "value" : null
  }
  if (kind === "threshold_assert" || kind === "decision_table") {
    return h === "verdict" ? "verdict" : null
  }
  return null
}

export function targetAcceptedPortTypes(node, handle) {
  if (!node) return null
  const kind = node.kind
  const h = handle || "in"
  if (CORE_SIGNAL_KINDS.has(kind) || EDGE_SIGNAL_KINDS.has(kind)) return null
  if (kind === "extract_field" || kind === "threshold_assert") {
    return h === "in" ? ["signal", "value"] : null
  }
  if (kind === "alert_output") {
    return h === "in" ? ["verdict"] : null
  }
  if (kind === "decision_table") {
    const declaredKeys = Array.isArray(node.config?.inputs)
      ? node.config.inputs.map(item => item?.key).filter(Boolean)
      : []
    const normalized = String(h).replace(/^in:/, "")
    if (h === "in" || declaredKeys.includes(normalized)) {
      return ["signal", "value", "verdict"]
    }
    return null
  }
  return null
}

export function wouldCreateCycle(nodes, edges, sourceId, targetId) {
  if (!sourceId || !targetId) return false
  if (sourceId === targetId) return true

  const adj = new Map()
  for (const node of nodes || []) {
    adj.set(node.id, [])
  }
  for (const edge of edges || []) {
    if (adj.has(edge.source)) {
      adj.get(edge.source).push(edge.target)
    }
  }

  // Adding sourceId -> targetId creates a cycle iff sourceId is reachable from targetId.
  const visited = new Set()
  const stack = [targetId]
  while (stack.length > 0) {
    const curr = stack.pop()
    if (curr === sourceId) return true
    if (visited.has(curr)) continue
    visited.add(curr)
    const nexts = adj.get(curr) || []
    for (const next of nexts) {
      if (!visited.has(next)) stack.push(next)
    }
  }
  return false
}

export function validateEdgeConnection(nodes, edges, connection) {
  const sourceId = connection?.source
  const targetId = connection?.target
  if (!sourceId || !targetId) {
    return {ok: false, code: "missing_endpoints", message: "Edge requires both source and target nodes."}
  }
  if (sourceId === targetId) {
    return {ok: false, code: "self_loop", message: `Self-loop on node '${sourceId}' is forbidden.`}
  }

  const byId = new Map((nodes || []).map(n => [n.id, n]))
  const srcNode = byId.get(sourceId)
  const dstNode = byId.get(targetId)
  if (!srcNode || !dstNode) {
    return {ok: false, code: "unknown_node", message: "Edge references an unknown node."}
  }

  const srcHandle = connection.sourceHandle || connection.source_handle || defaultSourceHandleForKind(srcNode.kind)
  const dstHandle = connection.targetHandle || connection.target_handle || "in"

  const srcType = sourcePortType(srcNode.kind, srcHandle)
  if (!srcType) {
    return {
      ok: false,
      code: "incompatible_handle",
      message: `Node '${srcNode.id}' (${srcNode.kind}) does not expose output handle '${srcHandle}'.`,
    }
  }

  const accepted = targetAcceptedPortTypes(dstNode, dstHandle)
  if (!accepted) {
    return {
      ok: false,
      code: "incompatible_handle",
      message: `Node '${dstNode.id}' (${dstNode.kind}) does not accept input handle '${dstHandle}'.`,
    }
  }

  if (!accepted.includes(srcType)) {
    return {
      ok: false,
      code: "incompatible_handle_types",
      message: `Cannot connect ${srcNode.kind} (${srcType}) into ${dstNode.kind} (accepts ${accepted.join(" | ")}).`,
    }
  }

  if (wouldCreateCycle(nodes, edges, sourceId, targetId)) {
    return {
      ok: false,
      code: "cyclic_graph",
      message: `Connecting '${sourceId}' -> '${targetId}' would introduce a cycle; declarative checks must be acyclic.`,
    }
  }

  return {
    ok: true,
    source_handle: srcHandle,
    target_handle: dstHandle,
  }
}

export function defaultNodeConfig(kind) {
  switch (kind) {
    case "platform_posture":
      return {
        evaluator: "storage.entitlement_utilization",
        consumer: "recordings",
      }
    case "srql_query":
      return {
        query: "in:devices limit:25",
        limit: 25,
        timeout_ms: 5000,
        result_mode: "rows",
      }
    case "vantage_point":
      return {
        agent_id: "agent-default",
        max_age_seconds: 300,
      }
    case "device_metadata":
      return {
        path: "os.name",
        max_age_seconds: 3600,
      }
    case "http_request":
      return {
        url: "https://api.example.com/v1/health",
        method: "GET",
        expected_statuses: [200],
        timeout_ms: 5000,
      }
    case "http_journey":
      return {
        timeout_ms: 10000,
        steps: [
          {
            id: "step_1",
            name: "GET Health",
            method: "GET",
            url: "https://api.example.com/v1/health",
            expected_statuses: [200],
          },
        ],
      }
    case "tcp_connect":
      return {
        host: "example.com",
        port: 443,
        timeout_ms: 5000,
      }
    case "tls_handshake":
      return {
        host: "example.com",
        port: 443,
        min_days_remaining: 14,
        timeout_ms: 5000,
      }
    case "dns_lookup":
      return {
        hostname: "example.com",
        record_type: "A",
        timeout_ms: 5000,
      }
    case "extract_field":
      return {
        source_type: "jsonpath",
        expression: "$.status",
        output_key: "extracted_value",
      }
    case "threshold_assert":
      return {
        field: "value",
        warn: {op: ">=", value: 80},
        crit: {op: ">=", value: 95},
      }
    case "decision_table":
      return {
        inputs: [{key: "sig_a", max_age_seconds: 300, label: "Signal A"}],
        rules: [
          {match: {sig_a: "healthy"}, status: "healthy", verdict: "ok"},
          {match: {sig_a: "*"}, status: "unknown", verdict: "inconclusive"},
        ],
      }
    case "alert_output":
      return {
        verdict_map: {
          healthy: "healthy",
          degraded: "degraded",
          down: "down",
          unknown: "unknown",
        },
      }
    default:
      return {}
  }
}

export function sortObjectKeysDeep(value) {
  if (Array.isArray(value)) {
    return value.map(sortObjectKeysDeep)
  }
  if (value && typeof value === "object") {
    const sorted = {}
    for (const key of Object.keys(value).sort()) {
      if (value[key] !== undefined) {
        sorted[key] = sortObjectKeysDeep(value[key])
      }
    }
    return sorted
  }
  return value
}

export function toCanonicalExportObject(rawDoc) {
  const doc = rawDoc || {}
  const schedule = {
    interval_seconds: 300,
    timeout_seconds: 30,
    jitter_seconds: 15,
    ...(doc.schedule || {}),
  }
  const targetBinding =
    doc.target_binding && Object.keys(doc.target_binding).length > 0
      ? doc.target_binding
      : {mode: "singleton"}
  const alertPolicy = {
    emit_ocsf_transition: true,
    open_on_statuses: ["down"],
    priority: 3,
    threshold: 1,
    window_seconds: 300,
    cooldown_seconds: 300,
    renotify_seconds: 21600,
    ...(doc.alert_policy || {}),
  }

  const out = {
    schema_version: 1,
    slug: String(doc.slug ?? ""),
    name: String(doc.name ?? ""),
    description: doc.description ?? null,
    state: String(doc.state || "draft"),
    pack_id: doc.pack_id ?? null,
    pack_version: doc.pack_version ?? null,
    managed: Boolean(doc.managed),
    parameter_overrides: doc.parameter_overrides || {},
    schedule,
    target_binding: targetBinding,
    inputs: Array.isArray(doc.inputs) ? doc.inputs : [],
    credential_slots: Array.isArray(doc.credential_slots) ? doc.credential_slots : [],
    nodes: Array.isArray(doc.nodes) ? doc.nodes : [],
    edges: Array.isArray(doc.edges) ? doc.edges : [],
    alert_policy: alertPolicy,
  }

  if (typeof doc.template_fingerprint === "string" && /^[0-9a-f]{64}$/.test(doc.template_fingerprint)) {
    out.template_fingerprint = doc.template_fingerprint
  }

  if (doc.ui_layout && typeof doc.ui_layout === "object" && Object.keys(doc.ui_layout).length > 0) {
    out.ui_layout = doc.ui_layout
  }

  return sortObjectKeysDeep(out)
}

export function formatCanonicalCheckJson(doc) {
  return JSON.stringify(toCanonicalExportObject(doc), null, 2) + "\n"
}

export function structuralSignature(doc) {
  const canonical = toCanonicalExportObject(doc)
  const semantic = {}
  for (const key of SEMANTIC_TEMPLATE_KEYS) {
    semantic[key] = canonical[key]
  }
  return JSON.stringify(sortObjectKeysDeep(semantic))
}

function scanSecrets(value, path = "$", inHeaders = false) {
  const issues = []
  if (Array.isArray(value)) {
    value.forEach((item, idx) => {
      issues.push(...scanSecrets(item, `${path}[${idx}]`, inHeaders))
    })
    return issues
  }
  if (value && typeof value === "object") {
    for (const [key, child] of Object.entries(value)) {
      const norm = key.trim().toLowerCase()
      const childPath = `${path}.${key}`
      if (FORBIDDEN_SECRET_KEYS.has(norm)) {
        issues.push({
          path: childPath,
          code: "secret_forbidden",
          message: `Secret or local credential reference '${key}' is forbidden in check JSON; use credential_slots.`,
        })
      } else if (
        inHeaders &&
        FORBIDDEN_AUTH_HEADERS.has(norm) &&
        typeof child === "string" &&
        child.trim() !== ""
      ) {
        issues.push({
          path: childPath,
          code: "secret_forbidden",
          message: `Literal authentication header '${key}' is forbidden; bind a credential_slot instead.`,
        })
      }
      issues.push(...scanSecrets(child, childPath, norm === "headers"))
    }
    return issues
  }
  if (typeof value === "string") {
    if (/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/.test(value)) {
      issues.push({
        path,
        code: "secret_forbidden",
        message: "PEM private key material is forbidden in declarative check JSON.",
      })
    } else if (/\bauthorization\s*:\s*(bearer|basic|token|apikey|digest)\s+\S+/i.test(value)) {
      issues.push({
        path,
        code: "secret_forbidden",
        message: "Literal Authorization credential header is forbidden; use credential_slots.",
      })
    } else if (inHeaders && /^\s*(bearer|basic|token|apikey|digest)\s+\S+/i.test(value)) {
      issues.push({
        path,
        code: "secret_forbidden",
        message: "Literal authorization token scheme is forbidden in headers; use credential_slots.",
      })
    }
  }
  return issues
}

export function validateDeclarativeCheckDocument(doc) {
  if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
    return {
      ok: false,
      errors: [{path: "$", code: "invalid_type", message: "Check document must be a JSON object."}],
    }
  }

  const errors = [...scanSecrets(doc)]

  for (const key of Object.keys(doc)) {
    if (!ALLOWED_TOP_KEYS.has(key)) {
      errors.push({
        path: `$.${key}`,
        code: "unknown_field",
        message: `Unknown top-level field '${key}' is not permitted.`,
      })
    }
  }

  if ((doc.schema_version ?? 1) !== 1) {
    errors.push({
      path: "$.schema_version",
      code: "invalid_schema_version",
      message: "schema_version must equal 1.",
    })
  }

  if (typeof doc.slug !== "string" || !/^[a-z0-9][a-z0-9._-]{0,126}$/.test(doc.slug.trim())) {
    errors.push({
      path: "$.slug",
      code: "invalid_slug",
      message: "slug must match [a-z0-9][a-z0-9._-]{0,126}.",
    })
  }

  if (typeof doc.name !== "string" || doc.name.trim() === "") {
    errors.push({
      path: "$.name",
      code: "required",
      message: "name is required.",
    })
  }

  const nodes = Array.isArray(doc.nodes) ? doc.nodes : null
  const edges = Array.isArray(doc.edges) ? doc.edges : []

  if (!nodes || nodes.length === 0) {
    errors.push({
      path: "$.nodes",
      code: "empty_nodes",
      message: "nodes must be a non-empty array.",
    })
    return {ok: false, errors}
  }

  const nodesById = new Map()
  let hasAlertOutput = false
  nodes.forEach((node, idx) => {
    const p = `$.nodes[${idx}]`
    if (!node || typeof node !== "object") {
      errors.push({path: p, code: "invalid_type", message: "Node must be an object."})
      return
    }
    if (typeof node.id !== "string" || !node.id.trim()) {
      errors.push({path: `${p}.id`, code: "invalid_node_id", message: "Node id is required."})
    } else if (nodesById.has(node.id)) {
      errors.push({path: `${p}.id`, code: "duplicate_node_id", message: `Duplicate node id '${node.id}'.`})
    } else {
      nodesById.set(node.id, node)
    }

    if (!ALLOWED_NODE_KINDS.has(node.kind)) {
      errors.push({
        path: `${p}.kind`,
        code: "invalid_node_kind",
        message: `Unsupported node kind '${String(node.kind)}'.`,
      })
    }
    if (node.kind === "alert_output") hasAlertOutput = true
  })

  if (!hasAlertOutput) {
    errors.push({
      path: "$.nodes",
      code: "missing_alert_output",
      message: "Graph must terminate in at least one alert_output node.",
    })
  }

  // Validate edges + cycle check
  const partialEdges = []
  edges.forEach((edge, idx) => {
    const p = `$.edges[${idx}]`
    if (!edge || typeof edge !== "object") {
      errors.push({path: p, code: "invalid_type", message: "Edge must be an object."})
      return
    }
    const check = validateEdgeConnection(nodes, partialEdges, {
      source: edge.source,
      target: edge.target,
      sourceHandle: edge.source_handle,
      targetHandle: edge.target_handle,
    })
    if (!check.ok) {
      errors.push({path: p, code: check.code, message: check.message})
    } else {
      partialEdges.push(edge)
    }
  })

  return {ok: errors.length === 0, errors}
}

export async function layoutGraphWithElk(doc, {onlyMissing = false} = {}) {
  const nodes = Array.isArray(doc?.nodes) ? doc.nodes : []
  const edges = Array.isArray(doc?.edges) ? doc.edges : []
  const existingCoords = doc?.ui_layout?.nodes || {}

  if (nodes.length === 0) return doc

  if (onlyMissing && nodes.every(n => existingCoords[n.id] && Number.isFinite(Number(existingCoords[n.id].x)))) {
    return doc
  }

  const elkGraph = {
    id: "root",
    layoutOptions: {
      "elk.algorithm": "layered",
      "elk.direction": "RIGHT",
      "elk.layered.spacing.nodeNodeBetweenLayers": "96",
      "elk.spacing.nodeNode": "56",
      "elk.padding": "[top=40,left=40,bottom=40,right=40]",
    },
    children: nodes.map(node => ({
      id: node.id,
      width: 220,
      height: 88,
    })),
    edges: edges
      .filter(e => e.source && e.target && e.source !== e.target)
      .map((edge, index) => ({
        id: edge.id || `elk_e_${index}`,
        sources: [edge.source],
        targets: [edge.target],
      })),
  }

  try {
    const laidOut = await elk.layout(elkGraph)
    const nextNodesLayout = {...existingCoords}
    for (const child of laidOut.children || []) {
      const hasExisting =
        existingCoords[child.id] &&
        Number.isFinite(Number(existingCoords[child.id].x)) &&
        Number.isFinite(Number(existingCoords[child.id].y))

      if (!onlyMissing || !hasExisting) {
        nextNodesLayout[child.id] = {
          x: Math.round(child.x ?? 80),
          y: Math.round(child.y ?? 80),
        }
      }
    }
    return {
      ...doc,
      ui_layout: {
        ...(doc.ui_layout || {}),
        nodes: nextNodesLayout,
      },
    }
  } catch (_err) {
    const fallback = {...existingCoords}
    nodes.forEach((node, idx) => {
      if (!onlyMissing || !fallback[node.id]) {
        fallback[node.id] = {x: 80 + idx * 280, y: 120}
      }
    })
    return {
      ...doc,
      ui_layout: {
        ...(doc.ui_layout || {}),
        nodes: fallback,
      },
    }
  }
}

export function scrubTraceSecrets(value) {
  if (Array.isArray(value)) return value.map(scrubTraceSecrets)
  if (value && typeof value === "object") {
    const out = {}
    for (const [k, v] of Object.entries(value)) {
      const lower = k.toLowerCase()
      if (
        FORBIDDEN_SECRET_KEYS.has(lower) ||
        FORBIDDEN_AUTH_HEADERS.has(lower) ||
        lower === "credential_slot" ||
        lower === "auth_header"
      ) {
        out[k] = "[REDACTED]"
      } else {
        out[k] = scrubTraceSecrets(v)
      }
    }
    return out
  }
  if (typeof value === "string" && /\b(bearer|basic|apikey)\s+\S+/i.test(value)) {
    return "[REDACTED]"
  }
  return value
}
