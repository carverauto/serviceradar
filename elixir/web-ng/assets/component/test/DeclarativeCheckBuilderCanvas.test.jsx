// @vitest-environment happy-dom
import fs from "node:fs"
import path from "node:path"
import React, {act} from "react"
import {createRoot} from "react-dom/client"
import {afterEach, beforeEach, describe, expect, it, vi} from "vitest"

function splitCssSelectors(selectorHeader) {
  const selectors = []
  let current = ""
  let parenDepth = 0
  let bracketDepth = 0
  let quote = null

  for (let i = 0; i < selectorHeader.length; i += 1) {
    const ch = selectorHeader[i]
    if (quote) {
      current += ch
      if (ch === "\\" && i + 1 < selectorHeader.length) {
        current += selectorHeader[i + 1]
        i += 1
      } else if (ch === quote) {
        quote = null
      }
      continue
    }
    if (ch === '"' || ch === "'") {
      quote = ch
      current += ch
    } else if (ch === "(") {
      parenDepth += 1
      current += ch
    } else if (ch === ")" && parenDepth > 0) {
      parenDepth -= 1
      current += ch
    } else if (ch === "[") {
      bracketDepth += 1
      current += ch
    } else if (ch === "]" && bracketDepth > 0) {
      bracketDepth -= 1
      current += ch
    } else if (ch === "," && parenDepth === 0 && bracketDepth === 0) {
      if (current.trim()) selectors.push(current.trim())
      current = ""
    } else {
      current += ch
    }
  }
  if (current.trim()) selectors.push(current.trim())
  return selectors
}

function collectStyleRuleSelectors(cssText) {
  const stripped = cssText.replace(/\/\*[\s\S]*?\*\//g, "")
  const selectors = []

  function walkBlock(blockText) {
    let i = 0
    while (i < blockText.length) {
      while (i < blockText.length && /\s/.test(blockText[i])) i += 1
      if (i >= blockText.length) break

      let header = ""
      let quote = null
      while (i < blockText.length) {
        const ch = blockText[i]
        if (quote) {
          header += ch
          if (ch === "\\" && i + 1 < blockText.length) {
            header += blockText[i + 1]
            i += 1
          } else if (ch === quote) {
            quote = null
          }
          i += 1
          continue
        }
        if (ch === '"' || ch === "'") {
          quote = ch
          header += ch
          i += 1
          continue
        }
        if (ch === ";" || ch === "{") break
        header += ch
        i += 1
      }

      if (i >= blockText.length) break
      if (blockText[i] === ";") {
        i += 1
        continue
      }

      // Matched "{"
      i += 1
      let depth = 1
      let body = ""
      quote = null
      while (i < blockText.length && depth > 0) {
        const ch = blockText[i]
        if (quote) {
          body += ch
          if (ch === "\\" && i + 1 < blockText.length) {
            body += blockText[i + 1]
            i += 1
          } else if (ch === quote) {
            quote = null
          }
          i += 1
          continue
        }
        if (ch === '"' || ch === "'") {
          quote = ch
          body += ch
        } else if (ch === "{") {
          depth += 1
          body += ch
        } else if (ch === "}") {
          depth -= 1
          if (depth > 0) body += ch
        } else {
          body += ch
        }
        i += 1
      }

      const trimmedHeader = header.trim()
      if (!trimmedHeader) continue
      if (trimmedHeader.startsWith("@")) {
        const lower = trimmedHeader.toLowerCase()
        if (
          lower.startsWith("@keyframes") ||
          lower.startsWith("@-webkit-keyframes") ||
          lower.startsWith("@font-face") ||
          lower.startsWith("@property")
        ) {
          continue
        }
        walkBlock(body)
      } else {
        selectors.push(...splitCssSelectors(trimmedHeader))
      }
    }
  }

  walkBlock(stripped)
  return selectors
}

globalThis.IS_REACT_ACT_ENVIRONMENT = true

import {DeclarativeCheckBuilderCanvas} from "../src/DeclarativeCheckBuilderCanvas.jsx"
import {
  POSTURE_EVALUATORS,
  STARTER_TEMPLATES,
  formatCanonicalCheckJson,
  validateDeclarativeCheckDocument,
  validateEdgeConnection,
} from "../src/declarativeCheckModel.js"

class MockResizeObserver {
  constructor(callback) {
    this.callback = callback
  }

  observe(target) {
    this.callback?.([
      {
        target,
        contentRect: {width: 960, height: 560, x: 0, y: 0, top: 0, left: 0, right: 960, bottom: 560},
      },
    ])
  }

  unobserve() {}
  disconnect() {}
}

function setNativeInputValue(inputEl, value) {
  const proto =
    inputEl instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : inputEl instanceof HTMLSelectElement
        ? HTMLSelectElement.prototype
        : HTMLInputElement.prototype
  const descriptor = Object.getOwnPropertyDescriptor(proto, "value")
  if (descriptor?.set) {
    descriptor.set.call(inputEl, value)
  } else {
    inputEl.value = value
  }
  inputEl.dispatchEvent(new Event("input", {bubbles: true}))
  inputEl.dispatchEvent(new Event("change", {bubbles: true}))
}

describe("DeclarativeCheckBuilderCanvas", () => {
  let host = null
  let root = null
  let outsideChrome = null

  beforeEach(() => {
    globalThis.ResizeObserver = MockResizeObserver
    Object.defineProperty(HTMLElement.prototype, "offsetWidth", {
      configurable: true,
      get: () => 960,
    })
    Object.defineProperty(HTMLElement.prototype, "offsetHeight", {
      configurable: true,
      get: () => 560,
    })

    document.documentElement.setAttribute("data-theme", "light")
    outsideChrome = document.createElement("nav")
    outsideChrome.id = "outside-tailwind-daisy-nav"
    outsideChrome.className = "navbar btn"
    outsideChrome.textContent = "ServiceRadar Topbar"
    document.body.appendChild(outsideChrome)

    host = document.createElement("div")
    host.id = "builder-mount"
    document.body.appendChild(host)
    root = createRoot(host)
  })

  afterEach(() => {
    if (root) {
      act(() => {
        root.unmount()
      })
      root = null
    }
    host?.remove()
    outsideChrome?.remove()
    host = null
    outsideChrome = null
    vi.restoreAllMocks()
  })

  it("strictly scopes Blueprint v6 CSS rules under .sr-bp6-scope without global body/html resets", () => {
    const scopedCssPath = path.resolve(process.cwd(), "css/blueprint_bp6_scoped.css")
    const appCssPath = path.resolve(process.cwd(), "css/app.css")

    const scopedCss = fs.readFileSync(scopedCssPath, "utf8")
    const appCss = fs.readFileSync(appCssPath, "utf8")

    expect(appCss).toContain('@import "./blueprint_bp6_scoped.css";')
    expect(appCss).not.toContain("normalize.css")

    const allSelectors = collectStyleRuleSelectors(scopedCss)
    expect(allSelectors.length).toBeGreaterThan(100)

    const unscopedSelectors = allSelectors.filter(
      sel => !sel.startsWith(".sr-bp6-scope") && !sel.startsWith(".sr-bp6-portal-root"),
    )

    expect(unscopedSelectors).toEqual([])
  })

  it("synchronizes .bp6-dark with ServiceRadar theme and mounts Blueprint portals inside scoped portalContainer", async () => {
    document.documentElement.setAttribute("data-theme", "dark")

    const managedDoc = {
      ...STARTER_TEMPLATES["SRQL Posture Check"](),
      slug: "storage-entitlement-utilization",
      name: "Storage Entitlement Utilization",
      pack_id: "io.serviceradar.storage-and-nvr-health",
      pack_version: "1.0.0",
      managed: true,
    }

    await act(async () => {
      root.render(<DeclarativeCheckBuilderCanvas initialDocument={managedDoc} canManage canEvaluate />)
    })

    const scopeEl = host.querySelector('[data-testid="declarative-check-builder-scope"]')
    const portalEl = host.querySelector('[data-testid="sr-bp6-portal-container"]')
    expect(scopeEl).not.toBeNull()
    expect(portalEl).not.toBeNull()
    expect(scopeEl.classList.contains("bp6-dark")).toBe(true)
    expect(scopeEl.getAttribute("data-bp-color-scheme")).toBe("dark")
    expect(outsideChrome.classList.contains("bp6-dark")).toBe(false)

    // Switch ServiceRadar theme to light and verify MutationObserver removes .bp6-dark
    await act(async () => {
      document.documentElement.setAttribute("data-theme", "light")
      await new Promise(resolve => setTimeout(resolve, 10))
    })
    expect(scopeEl.classList.contains("bp6-dark")).toBe(false)
    expect(scopeEl.getAttribute("data-bp-color-scheme")).toBe("light")

    // Trigger structural edit on managed check -> Overlay2 confirm-detach modal must render inside portalContainer!
    const addExtractBtn = host.querySelector('[data-testid="add-node-extract_field"]')
    expect(addExtractBtn).not.toBeNull()
    await act(async () => {
      addExtractBtn.click()
    })

    const detachDialogInsidePortal = portalEl.querySelector('[data-testid="confirm-detach-dialog"]')
    expect(detachDialogInsidePortal).not.toBeNull()
    // Ensure zero Blueprint portals leaked onto document.body outside host
    const bodyDirectPortals = [...document.body.children].filter(
      el => el !== host && el !== outsideChrome && el.classList.contains("bp6-portal"),
    )
    expect(bodyDirectPortals).toHaveLength(0)
  })

  it("populates valid schema_version 1 graphs for all four 1-click starter templates", async () => {
    const templateNames = [
      "HTTP JSON API Check",
      "SRQL Posture Check",
      "Multi-Step Synthetic Journey",
      "Multi-Vantage Composite Check",
    ]
    const seenDocs = []

    await act(async () => {
      root.render(
        <DeclarativeCheckBuilderCanvas
          isNew
          canManage
          canEvaluate
          onDocumentChange={nextDoc => seenDocs.push(nextDoc)}
        />,
      )
    })

    for (const tplName of templateNames) {
      const btn = host.querySelector(`[data-testid="starter-template-${tplName}"]`)
      expect(btn).not.toBeNull()
      await act(async () => {
        btn.click()
        await new Promise(resolve => setTimeout(resolve, 25))
      })

      const latest = seenDocs[seenDocs.length - 1]
      expect(latest).toBeDefined()
      expect(latest.schema_version).toBe(1)
      expect(validateDeclarativeCheckDocument(latest)).toEqual({ok: true, errors: []})

      // Every node has deterministic ui_layout coordinates populated by elkjs
      for (const node of latest.nodes) {
        expect(Number.isFinite(latest.ui_layout?.nodes?.[node.id]?.x)).toBe(true)
        expect(Number.isFinite(latest.ui_layout?.nodes?.[node.id]?.y)).toBe(true)
      }
    }
  })

  it("exposes all four PR #6760 posture evaluators, edits node properties, and enforces cycle/port guards", async () => {
    expect(POSTURE_EVALUATORS.map(e => e.id)).toEqual([
      "storage.entitlement_utilization",
      "storage.hold_pin_pressure",
      "storage.archive_credential_and_usage_health",
      "camera.continuous_recording_silence",
    ])

    let latestDoc = null
    await act(async () => {
      root.render(
        <DeclarativeCheckBuilderCanvas
          isNew
          canManage
          canEvaluate
          onDocumentChange={doc => {
            latestDoc = doc
          }}
        />,
      )
    })

    // Add a platform_posture node from Core Signals palette
    const addPostureBtn = host.querySelector('[data-testid="add-node-platform_posture"]')
    expect(addPostureBtn).not.toBeNull()
    await act(async () => {
      addPostureBtn.click()
    })

    expect(latestDoc.nodes.some(n => n.kind === "platform_posture")).toBe(true)

    // Change evaluator via Blueprint Select (single control, no duplicate HTMLSelect)
    expect(host.querySelector('[data-testid="inspector-posture-evaluator"]')).toBeNull()
    const evaluatorSelectBtn = host.querySelector('[data-testid="posture-evaluator-select-btn"]')
    expect(evaluatorSelectBtn).not.toBeNull()
    await act(async () => {
      evaluatorSelectBtn.click()
    })
    const silenceOption = host.querySelector(
      '[data-testid="posture-evaluator-option-camera.continuous_recording_silence"]',
    )
    expect(silenceOption).not.toBeNull()
    await act(async () => {
      silenceOption.click()
    })
    const postureNode = latestDoc.nodes.find(n => n.kind === "platform_posture")
    expect(postureNode.config.evaluator).toBe("camera.continuous_recording_silence")

    // Edit node label via Blueprint InputGroup
    const labelInput = host.querySelector('[data-testid="inspector-node-label"]')
    await act(async () => {
      setNativeInputValue(labelInput, "NVR Camera Silence Check")
    })
    expect(latestDoc.nodes.find(n => n.id === postureNode.id).label).toBe("NVR Camera Silence Check")

    // Verify port & cycle-prevention guard
    const badPort = validateEdgeConnection(latestDoc.nodes, latestDoc.edges, {
      source: "http_1",
      sourceHandle: "signal",
      target: "out_1",
      targetHandle: "in",
    })
    expect(badPort.ok).toBe(false)
    expect(badPort.code).toBe("incompatible_handle_types")

    const cyclicNodes = [
      {id: "ext_a", kind: "extract_field", config: {source_type: "field", expression: "a"}},
      {id: "ext_b", kind: "extract_field", config: {source_type: "field", expression: "b"}},
      {id: "out_1", kind: "alert_output", config: {}},
    ]
    const cyclicEdges = [
      {id: "e1", source: "ext_a", source_handle: "value", target: "ext_b", target_handle: "in"},
    ]
    const cycleAttempt = validateEdgeConnection(cyclicNodes, cyclicEdges, {
      source: "ext_b",
      sourceHandle: "value",
      target: "ext_a",
      targetHandle: "in",
    })
    expect(cycleAttempt.ok).toBe(false)
    expect(cycleAttempt.code).toBe("cyclic_graph")
  })

  it("synchronizes bidirectionally between Visual Canvas and Monaco JSON while preserving ui_layout and rejecting embedded secrets", async () => {
    let latestDoc = STARTER_TEMPLATES["HTTP JSON API Check"]()

    await act(async () => {
      root.render(
        <DeclarativeCheckBuilderCanvas
          initialDocument={latestDoc}
          isNew
          canManage
          canEvaluate
          onDocumentChange={doc => {
            latestDoc = doc
          }}
        />,
      )
    })

    // Switch to Monaco JSON tab
    const jsonTabBtn = host.querySelector('[data-testid="tab-monaco-json"]')
    await act(async () => {
      jsonTabBtn.click()
    })

    const jsonEditor = host.querySelector('[data-testid="declarative-check-json-editor"]')
    expect(jsonEditor).not.toBeNull()
    expect(jsonEditor.value).toContain('"slug": "http-json-api-check"')
    expect(jsonEditor.value).toContain('"x": 60')

    // Inject a secret-bearing field -> validation guard must reject without mutating latestDoc!
    const secretPayload = JSON.stringify(
      {
        ...latestDoc,
        password: "synthetic-placeholder-forbidden",
      },
      null,
      2,
    )
    await act(async () => {
      setNativeInputValue(jsonEditor, secretPayload)
      await new Promise(resolve => setTimeout(resolve, 200))
    })

    const diagCallout = host.querySelector('[data-testid="monaco-validation-errors"]')
    expect(diagCallout).not.toBeNull()
    expect(diagCallout.textContent).toContain("secret_forbidden")
    expect(latestDoc).not.toHaveProperty("password")

    // Now edit valid JSON adding a new node without ui_layout coordinates while keeping http_1 at x=60, y=120
    const updatedValid = {
      ...latestDoc,
      name: "Round-Trip Synced Check",
      nodes: [
        ...latestDoc.nodes,
        {
          id: "dns_extra",
          kind: "dns_lookup",
          label: "Synthetic DNS Probe",
          config: {hostname: "api.example.com", record_type: "A", timeout_ms: 3000},
        },
      ],
    }
    await act(async () => {
      setNativeInputValue(jsonEditor, formatCanonicalCheckJson(updatedValid))
      await new Promise(resolve => setTimeout(resolve, 220))
    })

    expect(host.querySelector('[data-testid="monaco-validation-errors"]')).toBeNull()
    expect(latestDoc.name).toBe("Round-Trip Synced Check")
    // Existing ui_layout preserved!
    expect(latestDoc.ui_layout.nodes.http_1).toEqual({x: 60, y: 120})
    // Newly added JSON node received elkjs coordinates!
    expect(Number.isFinite(latestDoc.ui_layout.nodes.dns_extra?.x)).toBe(true)
    expect(Number.isFinite(latestDoc.ui_layout.nodes.dns_extra?.y)).toBe(true)
  })

  it("renders Test Run node trace badges, httptrace waterfalls, and scrubs secrets to [REDACTED]", async () => {
    const doc = STARTER_TEMPLATES["HTTP JSON API Check"]()
    const sampleTrace = {
      schema_version: 1,
      ephemeral: true,
      slug: doc.slug,
      status: "healthy",
      verdict: "api_healthy",
      summary: "Synthetic test run succeeded",
      duration_ms: 42,
      node_traces: [
        {
          node_id: "http_1",
          kind: "http_request",
          status: "healthy",
          duration_ms: 38,
          resolved_inputs: {
            url: "https://api.example.com/v1/health",
            credential_slot: "Bearer synthetic-should-never-appear",
            headers: {
              Authorization: "Bearer synthetic-should-never-appear",
              Accept: "application/json",
            },
          },
          output: {
            status_code: 200,
            phases: {
              dns_ms: 4,
              tcp_ms: 7,
              tls_ms: 11,
              ttfb_ms: 14,
              transfer_ms: 2,
              total_ms: 38,
            },
          },
        },
      ],
    }

    await act(async () => {
      root.render(
        <DeclarativeCheckBuilderCanvas
          initialDocument={doc}
          initialTestRun={sampleTrace}
          canManage
          canEvaluate
        />,
      )
    })

    const verdictBanner = host.querySelector('[data-testid="test-run-verdict-banner"]')
    expect(verdictBanner).not.toBeNull()
    expect(verdictBanner.textContent).toContain("healthy")
    expect(verdictBanner.textContent).toContain("api_healthy")
    expect(verdictBanner.textContent).toContain("42ms")

    // Switch inspector to Trace tab and verify httptrace waterfall + [REDACTED] scrubbing
    const traceTab = [...host.querySelectorAll('[role="tab"]')].find(el => el.textContent === "Trace")
    expect(traceTab).not.toBeUndefined()
    await act(async () => {
      traceTab.click()
    })

    const waterfallEl = host.querySelector('[data-testid="trace-httptrace-waterfall"]')
    expect(waterfallEl).not.toBeNull()
    expect(waterfallEl.textContent).toContain("dns_ms: 4ms")
    expect(waterfallEl.textContent).toContain("tls_ms: 11ms")
    expect(waterfallEl.textContent).toContain("ttfb_ms: 14ms")

    const resolvedInputsEl = host.querySelector('[data-testid="trace-resolved-inputs"]')
    expect(resolvedInputsEl).not.toBeNull()
    expect(resolvedInputsEl.textContent).toContain("[REDACTED]")
    expect(resolvedInputsEl.textContent).not.toContain("synthetic-should-never-appear")
  })
})
