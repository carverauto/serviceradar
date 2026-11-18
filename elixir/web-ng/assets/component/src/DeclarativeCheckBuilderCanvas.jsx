import React, {useCallback, useEffect, useMemo, useRef, useState} from "react"
import {
  Button,
  ButtonGroup,
  Callout,
  Card,
  Drawer,
  FormGroup,
  HTMLSelect,
  Icon,
  InputGroup,
  MenuItem,
  NumericInput,
  Overlay2,
  PopoverNext,
  Switch,
  Tab,
  Tabs,
  Tag,
  TextArea,
} from "@blueprintjs/core"
import {Select} from "@blueprintjs/select"
import {
  Background,
  Controls,
  Handle,
  MiniMap,
  Position,
  ReactFlow,
  ReactFlowProvider,
} from "@xyflow/react"

import {
  ALLOWED_COMPARATORS,
  ALLOWED_STATUSES,
  CORE_SIGNAL_KINDS,
  EDGE_SIGNAL_KINDS,
  NODE_PALETTE_CATEGORIES,
  POSTURE_EVALUATORS,
  STARTER_TEMPLATES,
  defaultNodeConfig,
  defaultSourceHandleForKind,
  formatCanonicalCheckJson,
  layoutGraphWithElk,
  scrubTraceSecrets,
  structuralSignature,
  toCanonicalExportObject,
  validateDeclarativeCheckDocument,
  validateEdgeConnection,
} from "./declarativeCheckModel.js"

const DARK_THEME_NAMES = new Set([
  "dark",
  "night",
  "dracula",
  "synthwave",
  "halloween",
  "forest",
  "black",
  "luxury",
  "business",
  "coffee",
  "dim",
  "sunset",
])

export function detectServiceRadarDarkTheme(explicitTheme) {
  if (explicitTheme === "dark") return true
  if (explicitTheme === "light") return false
  if (typeof document === "undefined") return false

  const root = document.documentElement
  const attr = root?.getAttribute?.("data-theme")
  if (attr) {
    return DARK_THEME_NAMES.has(attr.toLowerCase())
  }
  if (root?.classList?.contains?.("dark")) {
    return true
  }
  if (typeof window !== "undefined" && typeof window.matchMedia === "function") {
    try {
      return Boolean(window.matchMedia("(prefers-color-scheme: dark)").matches)
    } catch (_err) {
      return false
    }
  }
  return false
}

function statusIntent(status) {
  switch (String(status || "").toLowerCase()) {
    case "healthy":
      return "success"
    case "degraded":
      return "warning"
    case "down":
      return "danger"
    default:
      return "none"
  }
}

function statusBorderColor(status) {
  switch (String(status || "").toLowerCase()) {
    case "healthy":
      return "#238551"
    case "degraded":
      return "#c87619"
    case "down":
      return "#cd4246"
    case "unknown":
      return "#738091"
    default:
      return null
  }
}

function nodeCategoryBadge(kind) {
  if (CORE_SIGNAL_KINDS.has(kind)) return {label: "Core Signal", intent: "primary"}
  if (EDGE_SIGNAL_KINDS.has(kind)) return {label: "Edge Signal", intent: "success"}
  if (kind === "alert_output") return {label: "Output", intent: "warning"}
  return {label: "Transform", intent: "none"}
}

function DeclarativeCheckNode({data, selected}) {
  const {node, trace, onSelect} = data
  const badge = nodeCategoryBadge(node.kind)
  const sourceHandle = defaultSourceHandleForKind(node.kind)
  const isSignal = CORE_SIGNAL_KINDS.has(node.kind) || EDGE_SIGNAL_KINDS.has(node.kind)
  const isDecision = node.kind === "decision_table"
  const decisionInputs = isDecision && Array.isArray(node.config?.inputs) ? node.config.inputs : []
  const traceColor = trace ? statusBorderColor(trace.status) : null

  return (
    <div
      data-testid={`canvas-node-${node.id}`}
      onClick={() => onSelect?.(node.id)}
      style={{
        minWidth: 210,
        maxWidth: 260,
        borderRadius: 6,
        padding: "8px 10px",
        border: traceColor
          ? `2px solid ${traceColor}`
          : selected
            ? "2px solid #2d72d2"
            : "1px solid rgba(95, 107, 124, 0.45)",
        background: "var(--bp-surface-background-color-default-rest, #ffffff)",
        boxShadow: selected ? "0 0 0 2px rgba(45, 114, 210, 0.25)" : "0 1px 3px rgba(0,0,0,0.12)",
        cursor: "pointer",
      }}
    >
      {!isSignal && !isDecision && (
        <Handle
          type="target"
          position={Position.Left}
          id="in"
          style={{width: 9, height: 9, background: "#2d72d2"}}
        />
      )}

      {isDecision &&
        (decisionInputs.length > 0 ? (
          decisionInputs.map((inp, idx) => {
            const topPct = Math.round(((idx + 1) / (decisionInputs.length + 1)) * 100)
            return (
              <Handle
                key={inp.key || idx}
                type="target"
                position={Position.Left}
                id={inp.key || "in"}
                title={`in: ${inp.key}`}
                style={{top: `${topPct}%`, width: 9, height: 9, background: "#2d72d2"}}
              />
            )
          })
        ) : (
          <Handle
            type="target"
            position={Position.Left}
            id="in"
            style={{width: 9, height: 9, background: "#2d72d2"}}
          />
        ))}

      <div style={{display: "flex", alignItems: "center", justifyContent: "space-between", gap: 6}}>
        <Tag minimal intent={badge.intent} style={{fontSize: 10}}>
          {node.kind}
        </Tag>
        {trace && (
          <Tag
            intent={statusIntent(trace.status)}
            minimal={false}
            data-testid={`node-trace-badge-${node.id}`}
            style={{fontSize: 10}}
          >
            {trace.status} {Number.isFinite(Number(trace.duration_ms)) ? `${trace.duration_ms}ms` : ""}
          </Tag>
        )}
      </div>

      <div style={{fontWeight: 600, fontSize: 12, marginTop: 5, wordBreak: "break-word"}}>
        {node.label || node.id}
      </div>

      <div style={{fontSize: 10, opacity: 0.72, marginTop: 2, fontFamily: "monospace"}}>
        id: {node.id}
      </div>

      {sourceHandle && (
        <Handle
          type="source"
          position={Position.Right}
          id={sourceHandle}
          title={`out: ${sourceHandle}`}
          style={{width: 9, height: 9, background: "#238551"}}
        />
      )}
    </div>
  )
}

const NODE_TYPES = {
  declarativeNode: DeclarativeCheckNode,
}

let monacoLoaderPromise = null
function loadMonacoApi() {
  if (typeof window === "undefined") return Promise.reject(new Error("no_window"))
  if (!monacoLoaderPromise) {
    monacoLoaderPromise = import("monaco-editor/esm/vs/editor/editor.api")
  }
  return monacoLoaderPromise
}

function MonacoJsonPane({
  jsonText,
  onJsonChange,
  validationErrors,
  isDark,
  readOnly,
  onFormatCanonical,
}) {
  const containerRef = useRef(null)
  const editorRef = useRef(null)
  const monacoRef = useRef(null)
  const latestOnChangeRef = useRef(onJsonChange)
  latestOnChangeRef.current = onJsonChange
  const suppressProgrammaticRef = useRef(false)
  const [monacoMounted, setMonacoMounted] = useState(false)

  const enableMonaco =
    typeof window !== "undefined" &&
    typeof navigator !== "undefined" &&
    !/HappyDOM|jsdom/i.test(navigator.userAgent || "")

  useEffect(() => {
    if (!enableMonaco || !containerRef.current) return undefined
    let cancelled = false
    let subscription = null

    loadMonacoApi()
      .then(monaco => {
        if (cancelled || !containerRef.current) return
        monacoRef.current = monaco
        const editor = monaco.editor.create(containerRef.current, {
          value: jsonText,
          language: "json",
          theme: isDark ? "vs-dark" : "vs",
          readOnly: Boolean(readOnly),
          automaticLayout: true,
          minimap: {enabled: false},
          fontSize: 12,
          tabSize: 2,
          scrollBeyondLastLine: false,
          wordWrap: "on",
        })
        editorRef.current = editor
        setMonacoMounted(true)

        subscription = editor.onDidChangeModelContent(() => {
          if (suppressProgrammaticRef.current) return
          latestOnChangeRef.current?.(editor.getValue())
        })
      })
      .catch(() => {
        setMonacoMounted(false)
      })

    return () => {
      cancelled = true
      subscription?.dispose?.()
      editorRef.current?.dispose?.()
      editorRef.current = null
      monacoRef.current = null
    }
  }, [enableMonaco])

  useEffect(() => {
    const editor = editorRef.current
    const monaco = monacoRef.current
    if (!editor || !monaco) return
    monaco.editor.setTheme(isDark ? "vs-dark" : "vs")
    editor.updateOptions({readOnly: Boolean(readOnly)})
  }, [isDark, readOnly])

  useEffect(() => {
    const editor = editorRef.current
    if (!editor) return
    if (typeof editor.hasTextFocus === "function" && editor.hasTextFocus()) return
    if (editor.getValue() !== jsonText) {
      suppressProgrammaticRef.current = true
      editor.setValue(jsonText)
      suppressProgrammaticRef.current = false
    }
  }, [jsonText])

  useEffect(() => {
    const editor = editorRef.current
    const monaco = monacoRef.current
    const model = editor?.getModel?.()
    if (!editor || !monaco || !model) return

    const markers = (validationErrors || []).map(err => ({
      startLineNumber: 1,
      startColumn: 1,
      endLineNumber: 1,
      endColumn: Math.max(2, model.getLineMaxColumn(1)),
      severity: monaco.MarkerSeverity.Error,
      message: `${err.path || "$"} [${err.code || "invalid"}]: ${err.message}`,
    }))
    monaco.editor.setModelMarkers(model, "declarative-check-v1", markers)
  }, [validationErrors])

  return (
    <div style={{display: "flex", flexDirection: "column", height: "100%", gap: 8}}>
      <div style={{display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8}}>
        <div style={{display: "flex", alignItems: "center", gap: 8}}>
          <Tag minimal intent={validationErrors.length === 0 ? "success" : "danger"}>
            {validationErrors.length === 0
              ? "schema_version: 1 valid"
              : `${validationErrors.length} validation issue(s)`}
          </Tag>
          <span style={{fontSize: 12, opacity: 0.8}}>
            Deterministic sorted-key canonical JSON (ui_layout preserved; secrets forbidden)
          </span>
        </div>
        <Button
          size="small"
          icon="clean"
          onClick={onFormatCanonical}
          disabled={Boolean(readOnly) || validationErrors.length > 0}
          data-testid="format-canonical-json-btn"
        >
          Format Canonical JSON
        </Button>
      </div>

      {validationErrors.length > 0 && (
        <Callout
          intent="danger"
          title="JSON / DAG Validation Diagnostics"
          data-testid="monaco-validation-errors"
        >
          <ul style={{margin: 0, paddingLeft: 18, fontSize: 12}}>
            {validationErrors.map((err, idx) => (
              <li key={`${err.path}-${err.code}-${idx}`}>
                <code>{err.path || "$"}</code> ({err.code}): {err.message}
              </li>
            ))}
          </ul>
        </Callout>
      )}

      {enableMonaco && (
        <div
          ref={containerRef}
          data-testid="monaco-editor-host"
          style={{
            flex: 1,
            minHeight: 420,
            border: "1px solid var(--bp-surface-border-color-default, #d3d8de)",
            borderRadius: 4,
            display: monacoMounted ? "block" : "none",
          }}
        />
      )}

      {!monacoMounted && (
        <textarea
          aria-label="Canonical Declarative Check JSON"
          data-testid="declarative-check-json-editor"
          value={jsonText}
          readOnly={Boolean(readOnly)}
          onChange={e => onJsonChange?.(e.target.value)}
          spellCheck={false}
          style={{
            flex: 1,
            minHeight: 420,
            width: "100%",
            fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
            fontSize: 12,
            lineHeight: 1.45,
            padding: 12,
            borderRadius: 4,
            border: "1px solid var(--bp-surface-border-color-default, #d3d8de)",
            background: isDark ? "#1c2127" : "#ffffff",
            color: isDark ? "#f6f7f9" : "#111418",
          }}
        />
      )}
    </div>
  )
}

export function DeclarativeCheckBuilderCanvas({
  initialDocument,
  initialBindings = [],
  credentialOptions = {secrets: [], rules: []},
  postureEvaluators = POSTURE_EVALUATORS,
  initialTestRun = null,
  isNew = false,
  canManage = true,
  canEvaluate = true,
  initialTheme,
  pushEvent,
  onDocumentChange,
  onSave,
  onTestRun,
  onExportJson,
}) {
  const defaultDoc = useMemo(() => {
    if (initialDocument && typeof initialDocument === "object" && Array.isArray(initialDocument.nodes)) {
      return toCanonicalExportObject(initialDocument)
    }
    return toCanonicalExportObject(STARTER_TEMPLATES["HTTP JSON API Check"]())
  }, [])

  const [doc, setDoc] = useState(defaultDoc)
  const [bindings, setBindings] = useState(() => (Array.isArray(initialBindings) ? initialBindings : []))
  const [activeTab, setActiveTab] = useState("canvas")
  const [inspectorTab, setInspectorTab] = useState("node")
  const [selectedNodeId, setSelectedNodeId] = useState(() => defaultDoc.nodes?.[0]?.id || null)
  const [jsonText, setJsonText] = useState(() => formatCanonicalCheckJson(defaultDoc))
  const [jsonErrors, setJsonErrors] = useState([])
  const [canvasError, setCanvasError] = useState(null)
  const [testRun, setTestRun] = useState(initialTestRun)
  const [testRunLoading, setTestRunLoading] = useState(false)
  const [traceDrawerOpen, setTraceDrawerOpen] = useState(false)
  const [confirmDetachState, setConfirmDetachState] = useState({
    confirmed: false,
    pendingNextDoc: null,
  })
  const [portalContainer, setPortalContainer] = useState(null)
  const [isDark, setIsDark] = useState(() => detectServiceRadarDarkTheme(initialTheme))

  const baselineManagedSigRef = useRef(defaultDoc.managed ? structuralSignature(defaultDoc) : null)
  const debounceTimerRef = useRef(null)

  useEffect(() => {
    if (initialTestRun !== undefined && initialTestRun !== null) {
      setTestRun(initialTestRun)
      setTestRunLoading(false)
    }
  }, [initialTestRun])

  useEffect(() => {
    setIsDark(detectServiceRadarDarkTheme(initialTheme))
    if (typeof document === "undefined" || initialTheme === "dark" || initialTheme === "light") {
      return undefined
    }

    const syncTheme = () => setIsDark(detectServiceRadarDarkTheme())
    const observer =
      typeof MutationObserver !== "undefined"
        ? new MutationObserver(syncTheme)
        : null

    observer?.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme", "class"],
    })

    const mql =
      typeof window !== "undefined" && typeof window.matchMedia === "function"
        ? window.matchMedia("(prefers-color-scheme: dark)")
        : null
    mql?.addEventListener?.("change", syncTheme)

    return () => {
      observer?.disconnect?.()
      mql?.removeEventListener?.("change", syncTheme)
    }
  }, [initialTheme])

  useEffect(() => () => {
    if (debounceTimerRef.current) clearTimeout(debounceTimerRef.current)
  }, [])

  const applyValidatedDoc = useCallback(
    (nextRawDoc, {syncJson = true, bypassManagedGuard = false} = {}) => {
      const nextCanonical = toCanonicalExportObject(nextRawDoc)

      if (
        doc.managed &&
        !confirmDetachState.confirmed &&
        !bypassManagedGuard &&
        baselineManagedSigRef.current &&
        structuralSignature(nextCanonical) !== baselineManagedSigRef.current
      ) {
        setConfirmDetachState(prev => ({...prev, pendingNextDoc: nextCanonical}))
        return false
      }

      const finalDoc =
        doc.managed &&
        confirmDetachState.confirmed &&
        baselineManagedSigRef.current &&
        structuralSignature(nextCanonical) !== baselineManagedSigRef.current
          ? {...nextCanonical, managed: false}
          : nextCanonical

      setDoc(finalDoc)
      setCanvasError(null)
      if (syncJson) {
        setJsonText(formatCanonicalCheckJson(finalDoc))
        setJsonErrors([])
      }
      onDocumentChange?.(finalDoc, bindings)
      pushEvent?.("canvas_change", {
        document: finalDoc,
        credential_bindings: bindings,
        confirm_detach: confirmDetachState.confirmed,
      })
      return true
    },
    [bindings, confirmDetachState.confirmed, doc.managed, onDocumentChange, pushEvent],
  )

  const handleConfirmDetach = useCallback(() => {
    const pending = confirmDetachState.pendingNextDoc
    const detachedDoc = pending ? {...pending, managed: false} : {...doc, managed: false}
    setConfirmDetachState({confirmed: true, pendingNextDoc: null})
    setDoc(detachedDoc)
    setJsonText(formatCanonicalCheckJson(detachedDoc))
    setJsonErrors([])
    onDocumentChange?.(detachedDoc, bindings)
    pushEvent?.("confirm_detach", {
      document: detachedDoc,
      credential_bindings: bindings,
      confirm_detach: true,
    })
  }, [bindings, confirmDetachState.pendingNextDoc, doc, onDocumentChange, pushEvent])

  const handleCancelDetach = useCallback(() => {
    setConfirmDetachState(prev => ({...prev, pendingNextDoc: null}))
    setJsonText(formatCanonicalCheckJson(doc))
    setJsonErrors([])
  }, [doc])

  const evaluatorItems = useMemo(() => {
    if (Array.isArray(postureEvaluators) && postureEvaluators.length > 0) {
      return postureEvaluators.map(item =>
        typeof item === "string"
          ? POSTURE_EVALUATORS.find(p => p.id === item) || {id: item, label: item, description: ""}
          : item,
      )
    }
    return POSTURE_EVALUATORS
  }, [postureEvaluators])

  const tracesByNodeId = useMemo(() => {
    const map = new Map()
    const list = testRun?.node_traces || testRun?.nodes || []
    for (const raw of list) {
      if (raw && raw.node_id) {
        map.set(raw.node_id, {
          ...raw,
          resolved_inputs: scrubTraceSecrets(raw.resolved_inputs || {}),
          output: scrubTraceSecrets(raw.output || {}),
        })
      }
    }
    return map
  }, [testRun])

  const selectedNode = useMemo(
    () => (doc.nodes || []).find(n => n.id === selectedNodeId) || null,
    [doc.nodes, selectedNodeId],
  )

  const selectedTrace = selectedNode ? tracesByNodeId.get(selectedNode.id) || null : null

  const rfNodes = useMemo(() => {
    const coordsMap = doc.ui_layout?.nodes || {}
    return (doc.nodes || []).map((node, index) => {
      const pos = coordsMap[node.id] || {x: 80 + index * 270, y: 120}
      return {
        id: node.id,
        type: "declarativeNode",
        position: {x: Number(pos.x) || 0, y: Number(pos.y) || 0},
        selected: node.id === selectedNodeId,
        data: {
          node,
          trace: tracesByNodeId.get(node.id) || null,
          onSelect: id => {
            setSelectedNodeId(id)
            setInspectorTab(tracesByNodeId.has(id) ? "trace" : "node")
          },
        },
      }
    })
  }, [doc.nodes, doc.ui_layout, selectedNodeId, tracesByNodeId])

  const rfEdges = useMemo(
    () =>
      (doc.edges || []).map(edge => ({
        id: edge.id,
        source: edge.source,
        sourceHandle: edge.source_handle || undefined,
        target: edge.target,
        targetHandle: edge.target_handle || "in",
        animated: Boolean(testRun),
      })),
    [doc.edges, testRun],
  )

  const handleAddPaletteNode = useCallback(
    (kind, positionOverride = null) => {
      if (!canManage) return
      const existingIds = new Set((doc.nodes || []).map(n => n.id))
      let seq = (doc.nodes || []).length + 1
      let newId = `${kind}_${seq}`
      while (existingIds.has(newId)) {
        seq += 1
        newId = `${kind}_${seq}`
      }

      const labelBase =
        NODE_PALETTE_CATEGORIES.flatMap(c => c.items).find(i => i.kind === kind)?.label || kind
      const newNode = {
        id: newId,
        kind,
        label: `${labelBase} ${seq}`,
        config: defaultNodeConfig(kind),
      }
      const pos = positionOverride || {
        x: 100 + ((seq - 1) % 3) * 280,
        y: 100 + Math.floor((seq - 1) / 3) * 140,
      }

      const nextDoc = {
        ...doc,
        nodes: [...(doc.nodes || []), newNode],
        ui_layout: {
          ...(doc.ui_layout || {}),
          nodes: {
            ...(doc.ui_layout?.nodes || {}),
            [newId]: pos,
          },
        },
      }
      if (applyValidatedDoc(nextDoc)) {
        setSelectedNodeId(newId)
        setInspectorTab("node")
      }
    },
    [applyValidatedDoc, canManage, doc],
  )

  const handleConnect = useCallback(
    connection => {
      if (!canManage) return
      const validation = validateEdgeConnection(doc.nodes, doc.edges, connection)
      if (!validation.ok) {
        setCanvasError(validation.message)
        return
      }
      const existingEdgeIds = new Set((doc.edges || []).map(e => e.id))
      let seq = (doc.edges || []).length + 1
      let edgeId = `e${seq}`
      while (existingEdgeIds.has(edgeId)) {
        seq += 1
        edgeId = `e${seq}`
      }
      const newEdge = {
        id: edgeId,
        source: connection.source,
        source_handle: validation.source_handle,
        target: connection.target,
        target_handle: validation.target_handle,
      }
      applyValidatedDoc({
        ...doc,
        edges: [...(doc.edges || []), newEdge],
      })
    },
    [applyValidatedDoc, canManage, doc],
  )

  const handleDeleteNode = useCallback(
    nodeId => {
      if (!canManage) return
      const nextNodes = (doc.nodes || []).filter(n => n.id !== nodeId)
      const nextEdges = (doc.edges || []).filter(e => e.source !== nodeId && e.target !== nodeId)
      const nextLayoutNodes = {...(doc.ui_layout?.nodes || {})}
      delete nextLayoutNodes[nodeId]

      if (
        applyValidatedDoc({
          ...doc,
          nodes: nextNodes,
          edges: nextEdges,
          ui_layout: {...(doc.ui_layout || {}), nodes: nextLayoutNodes},
        })
      ) {
        setSelectedNodeId(nextNodes[0]?.id || null)
      }
    },
    [applyValidatedDoc, canManage, doc],
  )

  const handleNodeDragStop = useCallback(
    (_event, draggedNode) => {
      if (!draggedNode?.id || !draggedNode?.position) return
      const nextDoc = {
        ...doc,
        ui_layout: {
          ...(doc.ui_layout || {}),
          nodes: {
            ...(doc.ui_layout?.nodes || {}),
            [draggedNode.id]: {
              x: Math.round(draggedNode.position.x),
              y: Math.round(draggedNode.position.y),
            },
          },
        },
      }
      // Position-only changes never alter semantic template_fingerprint!
      applyValidatedDoc(nextDoc, {bypassManagedGuard: true})
    },
    [applyValidatedDoc, doc],
  )

  const handleAutoLayout = useCallback(async () => {
    const laidOut = await layoutGraphWithElk(doc, {onlyMissing: false})
    applyValidatedDoc(laidOut, {bypassManagedGuard: true})
  }, [applyValidatedDoc, doc])

  const handleApplyStarterTemplate = useCallback(
    async templateName => {
      if (!canManage) return
      const builder = STARTER_TEMPLATES[templateName]
      if (!builder) return
      const templateDoc = builder()
      const preservedSlug = isNew ? templateDoc.slug : doc.slug || templateDoc.slug
      const laidOut = await layoutGraphWithElk({...templateDoc, slug: preservedSlug}, {onlyMissing: false})
      if (applyValidatedDoc(laidOut)) {
        setSelectedNodeId(laidOut.nodes?.[0]?.id || null)
        setTestRun(null)
      }
    },
    [applyValidatedDoc, canManage, doc.slug, isNew],
  )

  const applyParsedJsonText = useCallback(
    async rawText => {
      let parsed
      try {
        parsed = JSON.parse(rawText)
      } catch (err) {
        setJsonErrors([
          {
            path: "$",
            code: "invalid_json",
            message: err?.message || "Invalid JSON syntax",
          },
        ])
        return false
      }

      const check = validateDeclarativeCheckDocument(parsed)
      if (!check.ok) {
        setJsonErrors(check.errors)
        return false
      }

      const mergedWithLayout = await layoutGraphWithElk(parsed, {onlyMissing: true})
      const applied = applyValidatedDoc(mergedWithLayout, {syncJson: false})
      if (applied) {
        setJsonErrors([])
        if (!mergedWithLayout.nodes.some(n => n.id === selectedNodeId)) {
          setSelectedNodeId(mergedWithLayout.nodes[0]?.id || null)
        }
      }
      return applied
    },
    [applyValidatedDoc, selectedNodeId],
  )

  const handleJsonChange = useCallback(
    nextText => {
      setJsonText(nextText)
      if (debounceTimerRef.current) clearTimeout(debounceTimerRef.current)
      debounceTimerRef.current = setTimeout(() => {
        applyParsedJsonText(nextText)
      }, 150)
    },
    [applyParsedJsonText],
  )

  const updateSelectedNode = useCallback(
    updater => {
      if (!selectedNode || !canManage) return
      const nextNodes = (doc.nodes || []).map(node =>
        node.id === selectedNode.id ? updater(node) : node,
      )
      applyValidatedDoc({...doc, nodes: nextNodes})
    },
    [applyValidatedDoc, canManage, doc, selectedNode],
  )

  const updateSelectedNodeConfig = useCallback(
    patch => {
      updateSelectedNode(node => ({
        ...node,
        config: {...(node.config || {}), ...patch},
      }))
    },
    [updateSelectedNode],
  )

  const handleUpdateParameterOverride = useCallback(
    (key, rawValue, inputType) => {
      const nextOverrides = {...(doc.parameter_overrides || {})}
      if (rawValue === "" || rawValue === null || rawValue === undefined) {
        delete nextOverrides[key]
      } else if (inputType === "number") {
        const num = Number(rawValue)
        if (Number.isFinite(num)) nextOverrides[key] = num
      } else if (inputType === "integer") {
        const num = parseInt(String(rawValue), 10)
        if (Number.isFinite(num)) nextOverrides[key] = num
      } else if (inputType === "boolean") {
        nextOverrides[key] = rawValue === true || rawValue === "true"
      } else {
        nextOverrides[key] = String(rawValue)
      }
      // Parameter overrides preserve template_fingerprint and managed: true!
      applyValidatedDoc({...doc, parameter_overrides: nextOverrides}, {bypassManagedGuard: true})
    },
    [applyValidatedDoc, doc],
  )

  const handleBindingChange = useCallback(
    (slotName, bindingKind, targetId) => {
      if (!canManage) return
      const filtered = bindings.filter(b => b.slot !== slotName)
      let nextBindings = filtered
      if (bindingKind === "secret" && targetId) {
        nextBindings = [
          ...filtered,
          {slot: slotName, binding_kind: "secret", credential_secret_id: targetId, credential_rule_id: null},
        ]
      } else if (bindingKind === "rule" && targetId) {
        nextBindings = [
          ...filtered,
          {slot: slotName, binding_kind: "rule", credential_secret_id: null, credential_rule_id: targetId},
        ]
      }
      setBindings(nextBindings)
      onDocumentChange?.(doc, nextBindings)
      pushEvent?.("canvas_change", {
        document: doc,
        credential_bindings: nextBindings,
        confirm_detach: confirmDetachState.confirmed,
      })
    },
    [bindings, canManage, confirmDetachState.confirmed, doc, onDocumentChange, pushEvent],
  )

  const handleTriggerTestRun = useCallback(() => {
    if (!canEvaluate) return
    const check = validateDeclarativeCheckDocument(doc)
    if (!check.ok) {
      setCanvasError(check.errors[0]?.message || "Fix validation errors before running Test Run.")
      return
    }
    setTestRunLoading(true)
    onTestRun?.(doc)
    pushEvent?.("run_test", {
      document: doc,
      parameter_overrides: doc.parameter_overrides || {},
    })
  }, [canEvaluate, doc, onTestRun, pushEvent])

  const handleSave = useCallback(() => {
    if (!canManage) return
    const check = validateDeclarativeCheckDocument(doc)
    if (!check.ok) {
      setCanvasError(check.errors[0]?.message || "Check has validation errors.")
      return
    }
    onSave?.(doc, bindings, confirmDetachState.confirmed)
    pushEvent?.("save_check", {
      document: doc,
      credential_bindings: bindings,
      confirm_detach: confirmDetachState.confirmed,
    })
  }, [bindings, canManage, confirmDetachState.confirmed, doc, onSave, pushEvent])

  const handleExport = useCallback(() => {
    const canonical = formatCanonicalCheckJson(doc)
    onExportJson?.(canonical, doc)
    pushEvent?.("export_json", {slug: doc.slug, canonical_json: canonical})
  }, [doc, onExportJson, pushEvent])

  return (
    <div
      className={`sr-bp6-scope${isDark ? " bp6-dark" : ""}`}
      data-bp-color-scheme={isDark ? "dark" : "light"}
      data-testid="declarative-check-builder-scope"
      style={{
        display: "flex",
        flexDirection: "column",
        gap: 10,
        minHeight: 680,
        width: "100%",
        position: "relative",
      }}
    >
      {/* Dedicated Blueprint v6 portal container strictly inside .sr-bp6-scope */}
      <div
        className={`sr-bp6-scope sr-bp6-portal-root${isDark ? " bp6-dark" : ""}`}
        data-testid="sr-bp6-portal-container"
        ref={setPortalContainer}
      />

      {/* Managed Pack Provenance Banner */}
      {doc.managed && (
        <Callout
          intent="primary"
          icon="lock"
          title={`Managed by Solution Pack (${doc.pack_id || "built-in"} ${doc.pack_version || ""})`}
          data-testid="managed-pack-banner"
        >
          <div style={{fontSize: 12}}>
            Tuning <code>parameter_overrides</code> and dragging nodes in <code>ui_layout</code>{" "}
            preserves <code>template_fingerprint</code> for seamless pack upgrades. Structural edits
            to nodes, edges, or schedules require detaching from pack management.
          </div>
        </Callout>
      )}

      {/* Confirm Detach Modal inside scoped portalContainer */}
      <Overlay2
        isOpen={Boolean(confirmDetachState.pendingNextDoc)}
        onClose={handleCancelDetach}
        usePortal={Boolean(portalContainer)}
        portalContainer={portalContainer || undefined}
      >
        <div
          style={{
            position: "fixed",
            inset: 0,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            background: "rgba(17, 20, 24, 0.55)",
            zIndex: 80,
          }}
        >
          <Card
            elevation={3}
            data-testid="confirm-detach-dialog"
            style={{maxWidth: 460, width: "100%", padding: 18}}
          >
            <h3 style={{marginTop: 0, marginBottom: 8, fontSize: 16, fontWeight: 600}}>
              Detach Managed Pack Check?
            </h3>
            <p style={{fontSize: 13, lineHeight: 1.45}}>
              This structural edit modifies the canonical DAG template of{" "}
              <strong>{doc.name || doc.slug}</strong> (<code>{doc.pack_id || "pack"}</code>).
              Detaching sets <code>managed: false</code> so future Solution Pack upgrades will not
              overwrite your custom graph.
            </p>
            <div style={{display: "flex", justifyContent: "flex-end", gap: 8, marginTop: 14}}>
              <Button onClick={handleCancelDetach} data-testid="cancel-detach-btn">
                Keep Managed
              </Button>
              <Button
                intent="warning"
                icon="unlock"
                onClick={handleConfirmDetach}
                data-testid="confirm-detach-btn"
              >
                Detach &amp; Apply Edit
              </Button>
            </div>
          </Card>
        </div>
      </Overlay2>

      {/* Builder Top Chrome */}
      <Card style={{padding: "8px 12px"}}>
        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            alignItems: "center",
            justifyContent: "space-between",
            gap: 10,
          }}
        >
          <div style={{display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap"}}>
            <ButtonGroup>
              <Button
                active={activeTab === "canvas"}
                icon="graph"
                onClick={() => setActiveTab("canvas")}
                data-testid="tab-visual-canvas"
              >
                Visual Canvas
              </Button>
              <Button
                active={activeTab === "json"}
                icon="code"
                onClick={() => setActiveTab("json")}
                data-testid="tab-monaco-json"
              >
                Monaco JSON
              </Button>
            </ButtonGroup>

            <PopoverNext
              usePortal={Boolean(portalContainer)}
              portalContainer={portalContainer || undefined}
              content={
                <div style={{padding: 8, display: "flex", flexDirection: "column", gap: 4}} data-testid="starter-templates-menu">
                  {Object.keys(STARTER_TEMPLATES).map(tplName => (
                    <Button
                      key={tplName}
                      minimal
                      alignText="left"
                      icon="lightning"
                      disabled={!canManage}
                      onClick={() => handleApplyStarterTemplate(tplName)}
                      data-testid={`starter-template-menu-${tplName}`}
                    >
                      {tplName}
                    </Button>
                  ))}
                </div>
              }
            >
              <Button
                icon="flash"
                endIcon="caret-down"
                disabled={!canManage}
                data-testid="starter-templates-trigger"
              >
                Starter Templates
              </Button>
            </PopoverNext>

            <Button
              icon="layout-hierarchy"
              onClick={handleAutoLayout}
              data-testid="auto-layout-btn"
            >
              Auto-Layout
            </Button>
          </div>

          <div style={{display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap"}}>
            {testRun && (
              <Tag
                intent={statusIntent(testRun.status)}
                large
                interactive
                onClick={() => setTraceDrawerOpen(true)}
                data-testid="test-run-verdict-banner"
              >
                Verdict: {testRun.status} ({testRun.verdict}) -- {testRun.duration_ms ?? 0}ms
              </Tag>
            )}

            <Button
              icon="play"
              intent="success"
              loading={testRunLoading}
              disabled={!canEvaluate}
              onClick={handleTriggerTestRun}
              data-testid="run-test-btn"
            >
              Test Run
            </Button>

            <Button
              icon="download"
              onClick={handleExport}
              data-testid="export-json-btn"
            >
              Export JSON
            </Button>

            <Button
              icon="floppy-disk"
              intent="primary"
              disabled={!canManage || jsonErrors.length > 0}
              onClick={handleSave}
              data-testid="save-check-btn"
            >
              Save Check
            </Button>
          </div>
        </div>

        {/* Quick 1-click starter template strip */}
        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            alignItems: "center",
            gap: 6,
            marginTop: 8,
            paddingTop: 8,
            borderTop: "1px solid var(--bp-surface-border-color-default, #e5e8eb)",
          }}
        >
          <span style={{fontSize: 11, fontWeight: 600, opacity: 0.75}}>1-Click Starters:</span>
          {Object.keys(STARTER_TEMPLATES).map(tplName => (
            <Button
              key={tplName}
              size="small"
              minimal
              icon="plus"
              disabled={!canManage}
              onClick={() => handleApplyStarterTemplate(tplName)}
              data-testid={`starter-template-${tplName}`}
            >
              {tplName}
            </Button>
          ))}
        </div>
      </Card>

      {canvasError && (
        <Callout intent="danger" title="Canvas Validation Guard" data-testid="canvas-guard-callout">
          <div style={{display: "flex", alignItems: "center", justifyContent: "space-between"}}>
            <span>{canvasError}</span>
            <Button size="small" minimal icon="cross" onClick={() => setCanvasError(null)} />
          </div>
        </Callout>
      )}

      {/* Main Workspace: Visual Canvas OR Monaco JSON */}
      {activeTab === "json" ? (
        <Card style={{flex: 1, minHeight: 540, padding: 12}}>
          <MonacoJsonPane
            jsonText={jsonText}
            onJsonChange={handleJsonChange}
            validationErrors={jsonErrors}
            isDark={isDark}
            readOnly={!canManage}
            onFormatCanonical={() => setJsonText(formatCanonicalCheckJson(doc))}
          />
        </Card>
      ) : (
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "250px minmax(0, 1fr) 360px",
            gap: 10,
            minHeight: 560,
          }}
        >
          {/* Left-hand Blueprint v6 Node Palette */}
          <Card
            style={{padding: 10, overflowY: "auto", maxHeight: 680}}
            data-testid="node-palette"
          >
            <div style={{fontWeight: 600, fontSize: 13, marginBottom: 8}}>Node Palette</div>

            {NODE_PALETTE_CATEGORIES.map(category => (
              <div key={category.id} style={{marginBottom: 12}}>
                <div
                  style={{
                    fontSize: 11,
                    fontWeight: 700,
                    textTransform: "uppercase",
                    letterSpacing: "0.04em",
                    opacity: 0.72,
                    marginBottom: 5,
                  }}
                >
                  {category.title}
                </div>
                <div style={{display: "flex", flexDirection: "column", gap: 5}}>
                  {category.items.map(item => (
                    <div
                      key={item.kind}
                      draggable={canManage}
                      onDragStart={event => {
                        event.dataTransfer?.setData("application/serviceradar-node-kind", item.kind)
                        if (event.dataTransfer) event.dataTransfer.effectAllowed = "move"
                      }}
                      data-testid={`palette-item-${item.kind}`}
                      style={{
                        display: "flex",
                        alignItems: "center",
                        justifyContent: "space-between",
                        gap: 6,
                        padding: "6px 8px",
                        borderRadius: 4,
                        border: "1px solid var(--bp-surface-border-color-default, #d3d8de)",
                        cursor: canManage ? "grab" : "default",
                      }}
                    >
                      <div style={{minWidth: 0}}>
                        <div style={{fontSize: 12, fontWeight: 600}}>{item.label}</div>
                        <div style={{fontSize: 10, opacity: 0.72}}>{item.kind}</div>
                      </div>
                      <Button
                        size="small"
                        minimal
                        icon="plus"
                        disabled={!canManage}
                        aria-label={`Add ${item.label}`}
                        data-testid={`add-node-${item.kind}`}
                        onClick={() => handleAddPaletteNode(item.kind)}
                      />
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </Card>

          {/* Center @xyflow/react DAG Canvas */}
          <Card
            style={{padding: 0, position: "relative", minHeight: 560, overflow: "hidden"}}
            data-testid="xyflow-canvas-wrapper"
            onDragOver={event => {
              event.preventDefault()
              if (event.dataTransfer) event.dataTransfer.dropEffect = "move"
            }}
            onDrop={event => {
              event.preventDefault()
              const kind = event.dataTransfer?.getData("application/serviceradar-node-kind")
              if (!kind) return
              const rect = event.currentTarget.getBoundingClientRect()
              handleAddPaletteNode(kind, {
                x: Math.max(20, Math.round(event.clientX - rect.left - 90)),
                y: Math.max(20, Math.round(event.clientY - rect.top - 30)),
              })
            }}
          >
            <div style={{width: "100%", height: 560}}>
              <ReactFlowProvider>
                <ReactFlow
                  nodes={rfNodes}
                  edges={rfEdges}
                  nodeTypes={NODE_TYPES}
                  onConnect={handleConnect}
                  onNodeDragStop={handleNodeDragStop}
                  onNodeClick={(_e, rfNode) => {
                    setSelectedNodeId(rfNode.id)
                  }}
                  colorMode={isDark ? "dark" : "light"}
                  fitView
                >
                  <Background gap={18} size={1} />
                  <Controls />
                  <MiniMap pannable zoomable />
                </ReactFlow>
              </ReactFlowProvider>
            </div>
          </Card>

          {/* Right-hand Blueprint v6 Property Inspector */}
          <Card
            style={{padding: 12, overflowY: "auto", maxHeight: 680}}
            data-testid="property-inspector"
          >
            <Tabs
              id="declarative-check-inspector-tabs"
              selectedTabId={inspectorTab}
              onChange={nextTab => setInspectorTab(String(nextTab))}
            >
              <Tab
                id="node"
                title="Node"
                panel={
                  <NodeInspectorPanel
                    node={selectedNode}
                    doc={doc}
                    canManage={canManage}
                    evaluatorItems={evaluatorItems}
                    portalContainer={portalContainer}
                    onUpdateNode={updateSelectedNode}
                    onUpdateConfig={updateSelectedNodeConfig}
                    onDeleteNode={handleDeleteNode}
                  />
                }
              />
              <Tab
                id="check"
                title="Check"
                panel={
                  <CheckSettingsInspectorPanel
                    doc={doc}
                    isNew={isNew}
                    canManage={canManage}
                    onUpdateDoc={patch => applyValidatedDoc({...doc, ...patch})}
                  />
                }
              />
              <Tab
                id="inputs"
                title="Inputs"
                panel={
                  <InputsAndOverridesPanel
                    doc={doc}
                    canManage={canManage}
                    onUpdateInputs={nextInputs => applyValidatedDoc({...doc, inputs: nextInputs})}
                    onUpdateOverride={handleUpdateParameterOverride}
                  />
                }
              />
              <Tab
                id="credentials"
                title="Credentials"
                panel={
                  <CredentialsInspectorPanel
                    doc={doc}
                    bindings={bindings}
                    credentialOptions={credentialOptions}
                    canManage={canManage}
                    onUpdateSlots={nextSlots => applyValidatedDoc({...doc, credential_slots: nextSlots})}
                    onChangeBinding={handleBindingChange}
                  />
                }
              />
              <Tab
                id="trace"
                title="Trace"
                panel={
                  <TraceInspectorPanel
                    testRun={testRun}
                    selectedNode={selectedNode}
                    selectedTrace={selectedTrace}
                    tracesByNodeId={tracesByNodeId}
                    onSelectNode={setSelectedNodeId}
                    onOpenFullDrawer={() => setTraceDrawerOpen(true)}
                  />
                }
              />
            </Tabs>
          </Card>
        </div>
      )}

      {/* Scoped Blueprint Drawer for Expanded Trace Inspection */}
      <Drawer
        isOpen={traceDrawerOpen}
        onClose={() => setTraceDrawerOpen(false)}
        title="Ephemeral Test Run Trace Inspector"
        icon="pulse"
        size="520px"
        usePortal={Boolean(portalContainer)}
        portalContainer={portalContainer || undefined}
      >
        <div style={{padding: 16, overflowY: "auto"}} data-testid="trace-inspector-drawer">
          <TraceInspectorPanel
            testRun={testRun}
            selectedNode={selectedNode}
            selectedTrace={selectedTrace}
            tracesByNodeId={tracesByNodeId}
            onSelectNode={setSelectedNodeId}
          />
        </div>
      </Drawer>
    </div>
  )
}

function NodeInspectorPanel({
  node,
  doc,
  canManage,
  evaluatorItems,
  portalContainer,
  onUpdateNode,
  onUpdateConfig,
  onDeleteNode,
}) {
  if (!node) {
    return (
      <Callout icon="info-sign" title="No Node Selected">
        Click a node on the canvas or add one from the left palette to inspect its configuration.
      </Callout>
    )
  }

  const cfg = node.config || {}
  const declaredSlots = (doc.credential_slots || []).map(s => s.slot).filter(Boolean)

  return (
    <div style={{display: "flex", flexDirection: "column", gap: 8}} data-testid="selected-node-inspector">
      <div style={{display: "flex", alignItems: "center", justifyContent: "space-between"}}>
        <Tag intent="primary" minimal>
          {node.kind} ({node.id})
        </Tag>
        <Button
          size="small"
          intent="danger"
          minimal
          icon="trash"
          disabled={!canManage}
          onClick={() => onDeleteNode(node.id)}
          data-testid={`delete-node-${node.id}`}
        >
          Remove
        </Button>
      </div>

      <FormGroup label="Node Label" labelFor="inspector-node-label">
        <InputGroup
          id="inspector-node-label"
          data-testid="inspector-node-label"
          value={node.label || ""}
          disabled={!canManage}
          onChange={e => onUpdateNode(curr => ({...curr, label: e.target.value}))}
        />
      </FormGroup>

      {node.kind === "platform_posture" && (
        <>
          <FormGroup label="Posture Evaluator (#6760 Registry)" labelFor="inspector-posture-evaluator">
            <div style={{display: "flex", flexDirection: "column", gap: 6}}>
              <Select
                items={evaluatorItems}
                filterable={false}
                disabled={!canManage}
                popoverProps={{
                  usePortal: Boolean(portalContainer),
                  portalContainer: portalContainer || undefined,
                }}
                itemRenderer={(item, {handleClick, modifiers}) => (
                  <MenuItem
                    key={item.id}
                    active={modifiers.active}
                    text={item.label || item.id}
                    label={item.id}
                    onClick={handleClick}
                  />
                )}
                onItemSelect={item => onUpdateConfig({evaluator: item.id})}
              >
                <Button
                  fill
                  alignText="left"
                  endIcon="double-caret-vertical"
                  disabled={!canManage}
                  data-testid="posture-evaluator-select-btn"
                >
                  {cfg.evaluator || "storage.entitlement_utilization"}
                </Button>
              </Select>
              <HTMLSelect
                id="inspector-posture-evaluator"
                data-testid="inspector-posture-evaluator"
                fill
                disabled={!canManage}
                value={cfg.evaluator || "storage.entitlement_utilization"}
                onChange={e => onUpdateConfig({evaluator: e.target.value})}
                options={evaluatorItems.map(ev => ({value: ev.id, label: ev.label || ev.id}))}
              />
            </div>
          </FormGroup>

          {cfg.evaluator === "camera.continuous_recording_silence" && (
            <FormGroup label="Silence Window (minutes)">
              <NumericInput
                fill
                min={1}
                max={1440}
                disabled={!canManage}
                value={cfg.silence_window_minutes ?? 15}
                onValueChange={val => onUpdateConfig({silence_window_minutes: val})}
              />
            </FormGroup>
          )}

          {cfg.evaluator === "storage.archive_credential_and_usage_health" && (
            <FormGroup label="Max Usage Report Age (hours)">
              <NumericInput
                fill
                min={1}
                max={720}
                disabled={!canManage}
                value={cfg.max_report_age_hours ?? 36}
                onValueChange={val => onUpdateConfig({max_report_age_hours: val})}
              />
            </FormGroup>
          )}
        </>
      )}

      {node.kind === "srql_query" && (
        <>
          <FormGroup label="Read-Only SRQL Query" labelFor="inspector-srql-query">
            <InputGroup
              id="inspector-srql-query"
              data-testid="inspector-srql-query"
              value={cfg.query || ""}
              disabled={!canManage}
              placeholder="in:devices is_available:false"
              onChange={e => onUpdateConfig({query: e.target.value})}
            />
          </FormGroup>
          <FormGroup label="Result Mode">
            <HTMLSelect
              fill
              disabled={!canManage}
              value={cfg.result_mode || "rows"}
              onChange={e => onUpdateConfig({result_mode: e.target.value})}
              options={[
                {value: "rows", label: "Rows"},
                {value: "count", label: "Count"},
                {value: "first_row", label: "First Row"},
              ]}
            />
          </FormGroup>
          <FormGroup label="Row Limit (1..1000)">
            <NumericInput
              fill
              min={1}
              max={1000}
              disabled={!canManage}
              value={cfg.limit ?? 100}
              onValueChange={val => onUpdateConfig({limit: Math.min(1000, Math.max(1, val || 1))})}
            />
          </FormGroup>
          <FormGroup label="Timeout (ms, <= 10000)">
            <NumericInput
              fill
              min={100}
              max={10000}
              stepSize={250}
              majorStepSize={1000}
              disabled={!canManage}
              value={cfg.timeout_ms ?? 5000}
              onValueChange={val =>
                onUpdateConfig({timeout_ms: Math.min(10000, Math.max(100, val || 1000))})
              }
            />
          </FormGroup>
        </>
      )}

      {node.kind === "http_request" && (
        <>
          <FormGroup label="URL" labelFor="inspector-http-url">
            <InputGroup
              id="inspector-http-url"
              data-testid="inspector-http-url"
              value={cfg.url || ""}
              disabled={!canManage}
              placeholder="https://api.example.com/v1/health"
              onChange={e => onUpdateConfig({url: e.target.value})}
            />
          </FormGroup>
          <FormGroup label="HTTP Method">
            <HTMLSelect
              fill
              disabled={!canManage}
              value={cfg.method || "GET"}
              onChange={e => onUpdateConfig({method: e.target.value})}
              options={["GET", "POST", "PUT", "HEAD"]}
            />
          </FormGroup>
          <FormGroup label="Credential Slot (SecretBroker)">
            <HTMLSelect
              fill
              disabled={!canManage}
              value={cfg.credential_slot || ""}
              onChange={e =>
                onUpdateConfig({
                  credential_slot: e.target.value ? e.target.value : undefined,
                })
              }
              options={[
                {value: "", label: "None (unauthenticated)"},
                ...declaredSlots.map(s => ({value: s, label: s})),
              ]}
            />
          </FormGroup>
          <Switch
            label="Follow Redirects"
            checked={cfg.follow_redirects !== false}
            disabled={!canManage}
            onChange={e => onUpdateConfig({follow_redirects: e.currentTarget.checked})}
          />
        </>
      )}

      {node.kind === "http_journey" && (
        <>
          <FormGroup label="Journey Credential Slot">
            <HTMLSelect
              fill
              disabled={!canManage}
              value={cfg.credential_slot || ""}
              onChange={e =>
                onUpdateConfig({credential_slot: e.target.value ? e.target.value : undefined})
              }
              options={[
                {value: "", label: "None"},
                ...declaredSlots.map(s => ({value: s, label: s})),
              ]}
            />
          </FormGroup>
          <div style={{fontSize: 12, fontWeight: 600}}>Synthetic Steps ({(cfg.steps || []).length})</div>
          {(cfg.steps || []).map((step, idx) => (
            <Card key={step.id || idx} style={{padding: 8}}>
              <FormGroup label={`Step ${idx + 1} Name`}>
                <InputGroup
                  value={step.name || ""}
                  disabled={!canManage}
                  onChange={e => {
                    const nextSteps = [...(cfg.steps || [])]
                    nextSteps[idx] = {...step, name: e.target.value}
                    onUpdateConfig({steps: nextSteps})
                  }}
                />
              </FormGroup>
              <FormGroup label="Step URL">
                <InputGroup
                  value={step.url || ""}
                  disabled={!canManage}
                  onChange={e => {
                    const nextSteps = [...(cfg.steps || [])]
                    nextSteps[idx] = {...step, url: e.target.value}
                    onUpdateConfig({steps: nextSteps})
                  }}
                />
              </FormGroup>
            </Card>
          ))}
          <Button
            size="small"
            icon="plus"
            disabled={!canManage || (cfg.steps || []).length >= 16}
            onClick={() => {
              const nextIdx = (cfg.steps || []).length + 1
              onUpdateConfig({
                steps: [
                  ...(cfg.steps || []),
                  {
                    id: `step_${nextIdx}`,
                    name: `Step ${nextIdx}`,
                    method: "GET",
                    url: "https://api.example.com/v1/step",
                    expected_statuses: [200],
                  },
                ],
              })
            }}
          >
            Add Journey Step
          </Button>
        </>
      )}

      {(node.kind === "tcp_connect" || node.kind === "tls_handshake") && (
        <>
          <FormGroup label="Host">
            <InputGroup
              value={cfg.host || ""}
              disabled={!canManage}
              onChange={e => onUpdateConfig({host: e.target.value})}
            />
          </FormGroup>
          <FormGroup label="Port">
            <NumericInput
              fill
              min={1}
              max={65535}
              disabled={!canManage}
              value={cfg.port ?? 443}
              onValueChange={val => onUpdateConfig({port: val})}
            />
          </FormGroup>
          {node.kind === "tls_handshake" && (
            <FormGroup label="Min Certificate Days Remaining">
              <NumericInput
                fill
                min={1}
                max={365}
                disabled={!canManage}
                value={cfg.min_days_remaining ?? 14}
                onValueChange={val => onUpdateConfig({min_days_remaining: val})}
              />
            </FormGroup>
          )}
        </>
      )}

      {node.kind === "dns_lookup" && (
        <>
          <FormGroup label="Hostname">
            <InputGroup
              value={cfg.hostname || ""}
              disabled={!canManage}
              onChange={e => onUpdateConfig({hostname: e.target.value})}
            />
          </FormGroup>
          <FormGroup label="Record Type">
            <HTMLSelect
              fill
              disabled={!canManage}
              value={cfg.record_type || "A"}
              onChange={e => onUpdateConfig({record_type: e.target.value})}
              options={["A", "AAAA", "CNAME", "TXT", "MX", "SRV"]}
            />
          </FormGroup>
        </>
      )}

      {node.kind === "vantage_point" && (
        <>
          <FormGroup label="Agent ID">
            <InputGroup
              value={cfg.agent_id || ""}
              disabled={!canManage}
              onChange={e => onUpdateConfig({agent_id: e.target.value})}
            />
          </FormGroup>
          <FormGroup label="Max Observation Age (s)">
            <NumericInput
              fill
              min={10}
              max={86400}
              disabled={!canManage}
              value={cfg.max_age_seconds ?? 300}
              onValueChange={val => onUpdateConfig({max_age_seconds: val})}
            />
          </FormGroup>
        </>
      )}

      {node.kind === "device_metadata" && (
        <FormGroup label="Metadata Path">
          <InputGroup
            value={cfg.path || ""}
            disabled={!canManage}
            onChange={e => onUpdateConfig({path: e.target.value})}
          />
        </FormGroup>
      )}

      {node.kind === "extract_field" && (
        <>
          <FormGroup label="Source Type">
            <HTMLSelect
              fill
              disabled={!canManage}
              value={cfg.source_type || "jsonpath"}
              onChange={e => onUpdateConfig({source_type: e.target.value})}
              options={[
                {value: "jsonpath", label: "Bounded JSONPath ($.field)"},
                {value: "header", label: "HTTP Header"},
                {value: "regex", label: "Linear-Time Regex"},
                {value: "srql_field", label: "SRQL Column"},
                {value: "field", label: "Payload Field"},
              ]}
            />
          </FormGroup>
          <FormGroup label="Selector Expression" labelFor="inspector-extract-expression">
            <InputGroup
              id="inspector-extract-expression"
              data-testid="inspector-extract-expression"
              value={cfg.expression || ""}
              disabled={!canManage}
              onChange={e => onUpdateConfig({expression: e.target.value})}
            />
          </FormGroup>
          <FormGroup label="Output Key">
            <InputGroup
              value={cfg.output_key || ""}
              disabled={!canManage}
              onChange={e => onUpdateConfig({output_key: e.target.value})}
            />
          </FormGroup>
        </>
      )}

      {node.kind === "threshold_assert" && (
        <>
          <FormGroup label="Target Field" labelFor="inspector-threshold-field">
            <InputGroup
              id="inspector-threshold-field"
              data-testid="inspector-threshold-field"
              value={cfg.field || ""}
              disabled={!canManage}
              onChange={e => onUpdateConfig({field: e.target.value})}
            />
          </FormGroup>
          <FormGroup label="Warning Comparator & Value">
            <div style={{display: "grid", gridTemplateColumns: "90px 1fr", gap: 6}}>
              <HTMLSelect
                disabled={!canManage}
                value={cfg.warn?.op || ">="}
                onChange={e =>
                  onUpdateConfig({warn: {op: e.target.value, value: cfg.warn?.value ?? 80}})
                }
                options={ALLOWED_COMPARATORS}
              />
              <InputGroup
                data-testid="inspector-threshold-warn-value"
                disabled={!canManage}
                value={cfg.warn?.value !== undefined ? String(cfg.warn.value) : ""}
                placeholder="85 or {{inputs.warn_percent}}"
                onChange={e => {
                  const raw = e.target.value
                  const parsed =
                    raw !== "" && !Number.isNaN(Number(raw)) && !raw.includes("{{")
                      ? Number(raw)
                      : raw
                  onUpdateConfig({
                    warn: raw === "" ? undefined : {op: cfg.warn?.op || ">=", value: parsed},
                  })
                }}
              />
            </div>
          </FormGroup>
          <FormGroup label="Critical Comparator & Value">
            <div style={{display: "grid", gridTemplateColumns: "90px 1fr", gap: 6}}>
              <HTMLSelect
                disabled={!canManage}
                value={cfg.crit?.op || ">="}
                onChange={e =>
                  onUpdateConfig({crit: {op: e.target.value, value: cfg.crit?.value ?? 95}})
                }
                options={ALLOWED_COMPARATORS}
              />
              <InputGroup
                data-testid="inspector-threshold-crit-value"
                disabled={!canManage}
                value={cfg.crit?.value !== undefined ? String(cfg.crit.value) : ""}
                placeholder="95 or {{inputs.crit_percent}}"
                onChange={e => {
                  const raw = e.target.value
                  const parsed =
                    raw !== "" && !Number.isNaN(Number(raw)) && !raw.includes("{{")
                      ? Number(raw)
                      : raw
                  onUpdateConfig({
                    crit: raw === "" ? undefined : {op: cfg.crit?.op || ">=", value: parsed},
                  })
                }}
              />
            </div>
          </FormGroup>
        </>
      )}

      {node.kind === "decision_table" && (
        <div style={{display: "flex", flexDirection: "column", gap: 6}}>
          <div style={{fontSize: 12, fontWeight: 600}}>
            Inputs ({(cfg.inputs || []).length}) &amp; Ordered Rules ({(cfg.rules || []).length})
          </div>
          {(cfg.inputs || []).map((inp, idx) => (
            <div key={inp.key || idx} style={{display: "grid", gridTemplateColumns: "1fr 90px", gap: 6}}>
              <InputGroup
                value={inp.key || ""}
                disabled={!canManage}
                placeholder="input key"
                onChange={e => {
                  const next = [...(cfg.inputs || [])]
                  next[idx] = {...inp, key: e.target.value}
                  onUpdateConfig({inputs: next})
                }}
              />
              <NumericInput
                min={1}
                max={604800}
                disabled={!canManage}
                value={inp.max_age_seconds ?? 300}
                onValueChange={val => {
                  const next = [...(cfg.inputs || [])]
                  next[idx] = {...inp, max_age_seconds: val}
                  onUpdateConfig({inputs: next})
                }}
              />
            </div>
          ))}
          <Callout intent="none" icon="endorsed">
            Last rule row enforces mandatory all-<code>*</code> catch-all fallback; stale inputs
            exceeding <code>max_age_seconds</code> coerce to <code>unknown</code>.
          </Callout>
        </div>
      )}

      {node.kind === "alert_output" && (
        <>
          {ALLOWED_STATUSES.map(st => (
            <FormGroup key={st} label={`Verdict Slug (${st})`}>
              <InputGroup
                value={cfg.verdict_map?.[st] || ""}
                disabled={!canManage}
                onChange={e =>
                  onUpdateConfig({
                    verdict_map: {...(cfg.verdict_map || {}), [st]: e.target.value},
                  })
                }
              />
            </FormGroup>
          ))}
        </>
      )}
    </div>
  )
}

function CheckSettingsInspectorPanel({doc, isNew, canManage, onUpdateDoc}) {
  const schedule = doc.schedule || {}
  const binding = doc.target_binding || {mode: "singleton"}
  const policy = doc.alert_policy || {}

  return (
    <div style={{display: "flex", flexDirection: "column", gap: 8}} data-testid="check-settings-inspector">
      <FormGroup label="Check Name" labelFor="inspector-check-name">
        <InputGroup
          id="inspector-check-name"
          data-testid="inspector-check-name"
          value={doc.name || ""}
          disabled={!canManage}
          onChange={e => onUpdateDoc({name: e.target.value})}
        />
      </FormGroup>

      <FormGroup label="Slug" labelFor="inspector-check-slug">
        <InputGroup
          id="inspector-check-slug"
          data-testid="inspector-check-slug"
          value={doc.slug || ""}
          disabled={!canManage || !isNew}
          onChange={e => onUpdateDoc({slug: e.target.value})}
        />
      </FormGroup>

      <FormGroup label="Description">
        <TextArea
          fill
          rows={2}
          disabled={!canManage}
          value={doc.description || ""}
          onChange={e => onUpdateDoc({description: e.target.value || null})}
        />
      </FormGroup>

      <FormGroup label="State">
        <HTMLSelect
          fill
          data-testid="inspector-check-state"
          disabled={!canManage}
          value={doc.state || "draft"}
          onChange={e => onUpdateDoc({state: e.target.value})}
          options={[
            {value: "draft", label: "Draft"},
            {value: "enabled", label: "Enabled"},
            {value: "disabled", label: "Disabled"},
          ]}
        />
      </FormGroup>

      <FormGroup label="Target Binding Mode">
        <HTMLSelect
          fill
          data-testid="inspector-target-mode"
          disabled={!canManage}
          value={binding.mode || "singleton"}
          onChange={e => {
            const mode = e.target.value
            if (mode === "srql_devices") {
              onUpdateDoc({target_binding: {mode, scope_query: binding.scope_query || "in:devices"}})
            } else if (mode === "service_targets") {
              onUpdateDoc({
                target_binding: {mode, selector_query: binding.selector_query || "in:services"},
              })
            } else {
              onUpdateDoc({target_binding: {mode: "singleton"}})
            }
          }}
          options={[
            {value: "singleton", label: "Singleton (Posture / Single Endpoint)"},
            {value: "srql_devices", label: "Dynamic SRQL Devices (in:devices ...)"},
            {value: "service_targets", label: "Service Targets Fan-Out"},
          ]}
        />
      </FormGroup>

      {binding.mode === "srql_devices" && (
        <FormGroup label="SRQL Device Scope Query">
          <InputGroup
            data-testid="inspector-scope-query"
            disabled={!canManage}
            value={binding.scope_query || ""}
            placeholder="in:devices tags.role:edge-gateway"
            onChange={e =>
              onUpdateDoc({target_binding: {...binding, scope_query: e.target.value}})
            }
          />
        </FormGroup>
      )}

      {binding.mode === "service_targets" && (
        <FormGroup label="Service Targets Selector Query">
          <InputGroup
            data-testid="inspector-service-selector"
            disabled={!canManage}
            value={binding.selector_query || ""}
            placeholder="in:services"
            onChange={e =>
              onUpdateDoc({target_binding: {...binding, selector_query: e.target.value}})
            }
          />
        </FormGroup>
      )}

      <FormGroup label="Schedule Interval (seconds, 30..86400)">
        <NumericInput
          fill
          min={30}
          max={86400}
          stepSize={30}
          majorStepSize={300}
          disabled={!canManage}
          value={schedule.interval_seconds ?? 300}
          onValueChange={val =>
            onUpdateDoc({
              schedule: {...schedule, interval_seconds: Math.max(30, val || 30)},
            })
          }
        />
      </FormGroup>

      <FormGroup label="Timeout (seconds, 1..300)">
        <NumericInput
          fill
          min={1}
          max={300}
          disabled={!canManage}
          value={schedule.timeout_seconds ?? 30}
          onValueChange={val =>
            onUpdateDoc({
              schedule: {...schedule, timeout_seconds: Math.min(300, Math.max(1, val || 10))},
            })
          }
        />
      </FormGroup>

      <Switch
        label="Emit OCSF health.state_change to JetStream"
        checked={policy.emit_ocsf_transition !== false}
        disabled={!canManage}
        onChange={e =>
          onUpdateDoc({
            alert_policy: {...policy, emit_ocsf_transition: e.currentTarget.checked},
          })
        }
      />
    </div>
  )
}

function InputsAndOverridesPanel({doc, canManage, onUpdateInputs, onUpdateOverride}) {
  const inputs = Array.isArray(doc.inputs) ? doc.inputs : []
  const overrides = doc.parameter_overrides || {}

  return (
    <div style={{display: "flex", flexDirection: "column", gap: 8}} data-testid="inputs-inspector">
      <div style={{display: "flex", alignItems: "center", justifyContent: "space-between"}}>
        <span style={{fontSize: 12, fontWeight: 600}}>Declared Inputs &amp; Overrides</span>
        <Button
          size="small"
          icon="plus"
          disabled={!canManage}
          data-testid="add-check-input-btn"
          onClick={() => {
            const idx = inputs.length + 1
            onUpdateInputs([
              ...inputs,
              {key: `param_${idx}`, type: "number", default: 80, description: ""},
            ])
          }}
        >
          Add Input
        </Button>
      </div>

      {inputs.length === 0 && (
        <Callout icon="info-sign">
          No parameterized inputs declared. Add inputs to expose safe <code>parameter_overrides</code>{" "}
          without changing <code>template_fingerprint</code>.
        </Callout>
      )}

      {inputs.map((inp, idx) => (
        <Card key={inp.key || idx} style={{padding: 8}}>
          <FormGroup label={`Input Key (${inp.type || "number"})`}>
            <InputGroup
              value={inp.key || ""}
              disabled={!canManage}
              onChange={e => {
                const next = [...inputs]
                next[idx] = {...inp, key: e.target.value}
                onUpdateInputs(next)
              }}
            />
          </FormGroup>
          <FormGroup label={`Deployment Override (default: ${String(inp.default ?? "")})`}>
            <InputGroup
              data-testid={`override-input-${inp.key}`}
              disabled={!canManage}
              value={overrides[inp.key] !== undefined ? String(overrides[inp.key]) : ""}
              placeholder={`Default: ${String(inp.default ?? "")}`}
              onChange={e => onUpdateOverride(inp.key, e.target.value, inp.type)}
            />
          </FormGroup>
        </Card>
      ))}
    </div>
  )
}

function CredentialsInspectorPanel({
  doc,
  bindings,
  credentialOptions,
  canManage,
  onUpdateSlots,
  onChangeBinding,
}) {
  const slots = Array.isArray(doc.credential_slots) ? doc.credential_slots : []
  const secrets = credentialOptions?.secrets || []
  const rules = credentialOptions?.rules || []

  return (
    <div style={{display: "flex", flexDirection: "column", gap: 8}} data-testid="credentials-inspector">
      <div style={{display: "flex", alignItems: "center", justifyContent: "space-between"}}>
        <span style={{fontSize: 12, fontWeight: 600}}>Abstract Credential Slots</span>
        <Button
          size="small"
          icon="plus"
          disabled={!canManage}
          data-testid="add-credential-slot-btn"
          onClick={() => {
            const idx = slots.length + 1
            onUpdateSlots([
              ...slots,
              {
                slot: `auth_slot_${idx}`,
                provider: "http_bearer",
                role: "reader",
                purpose: "synthetic_http",
                required: true,
              },
            ])
          }}
        >
          Add Slot
        </Button>
      </div>

      <Callout intent="none" icon="key">
        Check JSON exports only abstract <code>credential_slots</code>. Local bindings map slots to{" "}
        <code>network_credential_secrets</code> or <code>network_credential_rules</code> via{" "}
        <code>SecretBroker</code>.
      </Callout>

      {slots.map((slotItem, idx) => {
        const currentBinding = bindings.find(b => b.slot === slotItem.slot) || null
        const currentKind = currentBinding?.credential_rule_id
          ? "rule"
          : currentBinding?.credential_secret_id
            ? "secret"
            : "none"
        const currentTarget =
          currentBinding?.credential_rule_id || currentBinding?.credential_secret_id || ""

        return (
          <Card key={slotItem.slot || idx} style={{padding: 8}}>
            <FormGroup label="Slot Identifier">
              <InputGroup
                value={slotItem.slot || ""}
                disabled={!canManage}
                onChange={e => {
                  const next = [...slots]
                  next[idx] = {...slotItem, slot: e.target.value}
                  onUpdateSlots(next)
                }}
              />
            </FormGroup>

            <FormGroup label="Provider">
              <InputGroup
                value={slotItem.provider || ""}
                disabled={!canManage}
                onChange={e => {
                  const next = [...slots]
                  next[idx] = {...slotItem, provider: e.target.value}
                  onUpdateSlots(next)
                }}
              />
            </FormGroup>

            <FormGroup label="Local CNPG Binding Kind">
              <HTMLSelect
                fill
                data-testid={`slot-binding-kind-${slotItem.slot}`}
                disabled={!canManage}
                value={currentKind}
                onChange={e => {
                  const nextKind = e.target.value
                  if (nextKind === "secret") {
                    onChangeBinding(slotItem.slot, "secret", secrets[0]?.id || "")
                  } else if (nextKind === "rule") {
                    onChangeBinding(slotItem.slot, "rule", rules[0]?.id || "")
                  } else {
                    onChangeBinding(slotItem.slot, "none", "")
                  }
                }}
                options={[
                  {value: "none", label: "Unbound"},
                  {value: "secret", label: "Reusable Secret (network_credential_secrets)"},
                  {value: "rule", label: "Scoped Rule (network_credential_rules)"},
                ]}
              />
            </FormGroup>

            {currentKind === "secret" && (
              <FormGroup label="Bound Secret">
                <HTMLSelect
                  fill
                  data-testid={`slot-binding-secret-${slotItem.slot}`}
                  disabled={!canManage}
                  value={currentTarget}
                  onChange={e => onChangeBinding(slotItem.slot, "secret", e.target.value)}
                  options={[
                    {value: "", label: "Select secret..."},
                    ...secrets.map(s => ({
                      value: s.id,
                      label: `${s.name} (${s.provider})`,
                    })),
                  ]}
                />
              </FormGroup>
            )}

            {currentKind === "rule" && (
              <FormGroup label="Bound Credential Rule">
                <HTMLSelect
                  fill
                  data-testid={`slot-binding-rule-${slotItem.slot}`}
                  disabled={!canManage}
                  value={currentTarget}
                  onChange={e => onChangeBinding(slotItem.slot, "rule", e.target.value)}
                  options={[
                    {value: "", label: "Select credential rule..."},
                    ...rules.map(r => ({
                      value: r.id,
                      label: `${r.name} (${r.provider})`,
                    })),
                  ]}
                />
              </FormGroup>
            )}
          </Card>
        )
      })}
    </div>
  )
}

function TraceInspectorPanel({
  testRun,
  selectedNode,
  selectedTrace,
  tracesByNodeId,
  onSelectNode,
  onOpenFullDrawer,
}) {
  if (!testRun) {
    return (
      <Callout icon="play" title="No Test Run Executed Yet" data-testid="trace-empty-state">
        Click <strong>Test Run</strong> to execute the authored DAG ephemerally and inspect redacted
        per-node inputs, extracted values, timings, and final verdict without mutating ServiceState.
      </Callout>
    )
  }

  const activeTrace =
    selectedTrace || (tracesByNodeId.size > 0 ? [...tracesByNodeId.values()][0] : null)
  const waterfall =
    activeTrace?.output?.phases ||
    activeTrace?.output?.httptrace ||
    activeTrace?.phases ||
    null

  return (
    <div style={{display: "flex", flexDirection: "column", gap: 10}} data-testid="trace-inspector-panel">
      <Callout
        intent={statusIntent(testRun.status)}
        title={`Final Verdict: ${testRun.verdict || testRun.status} (${testRun.status})`}
      >
        <div style={{fontSize: 12}}>
          <div>Summary: {testRun.summary || "Ephemeral evaluation completed"}</div>
          <div>Total Duration: {testRun.duration_ms ?? 0}ms (ephemeral: ServiceState untouched)</div>
        </div>
      </Callout>

      {onOpenFullDrawer && (
        <Button size="small" icon="panel-stats" onClick={onOpenFullDrawer}>
          Expand Trace Drawer
        </Button>
      )}

      <div style={{display: "flex", flexWrap: "wrap", gap: 4}}>
        {[...tracesByNodeId.values()].map(t => (
          <Tag
            key={t.node_id}
            interactive
            intent={statusIntent(t.status)}
            minimal={selectedNode?.id !== t.node_id}
            onClick={() => onSelectNode?.(t.node_id)}
          >
            {t.node_id}: {t.status} ({t.duration_ms ?? 0}ms)
          </Tag>
        ))}
      </div>

      {activeTrace && (
        <Card style={{padding: 10}} data-testid={`trace-detail-${activeTrace.node_id}`}>
          <div style={{fontWeight: 600, fontSize: 12, marginBottom: 6}}>
            Node Trace: <code>{activeTrace.node_id}</code> ({activeTrace.kind})
          </div>

          {waterfall && typeof waterfall === "object" && (
            <div style={{marginBottom: 8}} data-testid="trace-httptrace-waterfall">
              <div style={{fontSize: 11, fontWeight: 600, marginBottom: 4}}>
                httptrace Phase Waterfall
              </div>
              <div style={{display: "flex", flexWrap: "wrap", gap: 4}}>
                {["dns_ms", "tcp_ms", "tls_ms", "ttfb_ms", "transfer_ms", "total_ms"].map(phase =>
                  waterfall[phase] !== undefined ? (
                    <Tag key={phase} minimal>
                      {phase}: {waterfall[phase]}ms
                    </Tag>
                  ) : null,
                )}
              </div>
            </div>
          )}

          <div style={{fontSize: 11, fontWeight: 600, marginBottom: 3}}>
            Resolved Inputs (Secrets Scrubbed)
          </div>
          <pre
            data-testid="trace-resolved-inputs"
            style={{
              fontSize: 11,
              padding: 8,
              borderRadius: 4,
              overflowX: "auto",
              background: "rgba(95, 107, 124, 0.12)",
            }}
          >
            {JSON.stringify(activeTrace.resolved_inputs || {}, null, 2)}
          </pre>

          <div style={{fontSize: 11, fontWeight: 600, marginTop: 6, marginBottom: 3}}>
            Extracted Output / Verdict
          </div>
          <pre
            data-testid="trace-node-output"
            style={{
              fontSize: 11,
              padding: 8,
              borderRadius: 4,
              overflowX: "auto",
              background: "rgba(95, 107, 124, 0.12)",
            }}
          >
            {JSON.stringify(activeTrace.output || {}, null, 2)}
          </pre>
        </Card>
      )}
    </div>
  )
}

export const Component = DeclarativeCheckBuilderCanvas
export default DeclarativeCheckBuilderCanvas
