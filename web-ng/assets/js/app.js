// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

import * as d3 from "d3"
import {sankey as d3Sankey, sankeyLinkHorizontal as d3SankeyLinkHorizontal} from "d3-sankey"
import mapboxgl from "mapbox-gl"

import {
  attachTimeTooltip as nfAttachTimeTooltip,
  buildLegend as nfBuildLegend,
  chartDims as nfChartDims,
  clearSVG as nfClearSVG,
  colorScale as nfColorScale,
  ensureTooltip as nfEnsureTooltip,
  ensureSVG as nfEnsureSVG,
  fmtPct as nfFmtPct,
  normalizeTimeSeries as nfNormalizeTimeSeries,
  parseSeriesData as nfParseSeriesData,
} from "./netflow_charts/util"

// Preload JDM editor CSS - ensures styles are bundled
import '@gorules/jdm-editor/dist/style.css'

// JDM Editor hydration (lazy loaded, CSS is statically imported above)
let JdmEditorModule = null;
async function loadJdmEditor() {
  if (!JdmEditorModule) {
    JdmEditorModule = await import('@gorules/jdm-editor');
  }
  return JdmEditorModule;
}

// Helper: Get current theme from Phoenix (data-theme attribute on html)
function getPhoenixTheme() {
  const dataTheme = document.documentElement.getAttribute('data-theme');
  // Map Phoenix themes to JDM editor themes
  // Common dark themes in daisyUI
  const darkThemes = ['dark', 'night', 'dracula', 'synthwave', 'halloween', 'forest', 'black', 'luxury', 'business', 'coffee', 'dim', 'sunset'];
  if (dataTheme && darkThemes.includes(dataTheme.toLowerCase())) {
    return 'dark';
  }
  // Check system preference if no explicit theme
  if (!dataTheme && window.matchMedia('(prefers-color-scheme: dark)').matches) {
    return 'dark';
  }
  return 'light';
}

// Custom hooks
const Hooks = {
  /**
   * JDM Editor Hook
   *
   * Hydrates the server-rendered GoRules JDM editor with client-side
   * interactivity. Syncs changes back to the LiveView via pushEvent.
   * Supports dark mode based on Phoenix theme.
   */
  JdmEditorHook: {
    async mounted() {
      const container = this.el;
      const propsData = container.dataset.props;

      if (!propsData) {
        console.error('JdmEditorHook: Missing data-props attribute');
        return;
      }

      const props = JSON.parse(propsData);
      const { createRoot } = await import('react-dom/client');
      const React = await import('react');
      const { JdmConfigProvider, DecisionGraph } = await loadJdmEditor();

      // Store reference for event handlers
      const hook = this;

      // Get initial theme
      let currentTheme = getPhoenixTheme();

      // Create a React element with event handlers and theme support
      const EditorWithHandlers = ({ initialTheme }) => {
        const [definition, setDefinition] = React.useState(props.definition);
        const [theme, setTheme] = React.useState(initialTheme);

        // Listen for theme changes
        React.useEffect(() => {
          const observer = new MutationObserver(() => {
            const newTheme = getPhoenixTheme();
            if (newTheme !== theme) {
              setTheme(newTheme);
            }
          });
          observer.observe(document.documentElement, {
            attributes: true,
            attributeFilter: ['data-theme']
          });

          // Also listen for system theme changes
          const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
          const handleMediaChange = () => setTheme(getPhoenixTheme());
          mediaQuery.addEventListener('change', handleMediaChange);

          return () => {
            observer.disconnect();
            mediaQuery.removeEventListener('change', handleMediaChange);
          };
        }, [theme]);

        const handleChange = React.useCallback((newDef) => {
          setDefinition(newDef);
          // Push change event to LiveView
          hook.pushEvent('jdm_editor_change', { definition: newDef });
        }, []);

        // Wrap in a full-height container - ReactFlow needs explicit height
        // Pass theme config with mode for JDM editor dark mode support
        const themeConfig = { mode: theme };

        return React.createElement('div', {
          style: { height: '100%', width: '100%' },
          className: theme === 'dark' ? 'grl-dark' : 'grl-light',
          'data-theme': theme
        },
          React.createElement(JdmConfigProvider, { theme: themeConfig },
            React.createElement(DecisionGraph, {
              value: definition,
              onChange: handleChange,
              disabled: props.readOnly
            })
          )
        );
      };

      // Clear container and render fresh (SSR may not work with complex React deps)
      container.innerHTML = '';
      this.reactRoot = createRoot(container);
      this.reactRoot.render(React.createElement(EditorWithHandlers, { initialTheme: currentTheme }));

      // Handle updates from LiveView
      this.handleEvent('jdm_editor_update', ({ definition }) => {
        // Re-render with new definition
        const UpdatedEditor = ({ initialTheme }) => {
          const [def, setDef] = React.useState(definition);
          const [theme, setTheme] = React.useState(initialTheme);

          React.useEffect(() => {
            const observer = new MutationObserver(() => {
              setTheme(getPhoenixTheme());
            });
            observer.observe(document.documentElement, {
              attributes: true,
              attributeFilter: ['data-theme']
            });
            return () => observer.disconnect();
          }, []);

          const handleChange = React.useCallback((newDef) => {
            setDef(newDef);
            hook.pushEvent('jdm_editor_change', { definition: newDef });
          }, []);

          // Wrap in a full-height container - ReactFlow needs explicit height
          const themeConfig = { mode: theme };

          return React.createElement('div', {
            style: { height: '100%', width: '100%' },
            className: theme === 'dark' ? 'grl-dark' : 'grl-light',
            'data-theme': theme
          },
            React.createElement(JdmConfigProvider, { theme: themeConfig },
              React.createElement(DecisionGraph, {
                value: def,
                onChange: handleChange,
                disabled: props.readOnly
              })
            )
          );
        };
        this.reactRoot.render(React.createElement(UpdatedEditor, { initialTheme: getPhoenixTheme() }));
      });
    },

    destroyed() {
      if (this.reactRoot) {
        this.reactRoot.unmount();
      }
    }
  },

  SRQLTimeCookie: {
    mounted() {
      this._input = this.el.querySelector('input[name="q"]')
      if (!this._input) return

      this._debounceTimer = null
      this._lastSynced = (this.el.dataset.query || "").toString()

      const hasQParam = () => {
        try {
          return new URLSearchParams(window.location.search).has("q")
        } catch (_e) {
          return false
        }
      }

      const cookieGet = (name) => {
        const needle = `${name}=`
        const parts = (document.cookie || "").split(";").map((s) => s.trim())
        for (const part of parts) {
          if (part.startsWith(needle)) return decodeURIComponent(part.slice(needle.length))
        }
        return null
      }

      const cookieSet = (name, value, days = 365) => {
        if (!value) return
        const maxAge = days * 24 * 60 * 60
        document.cookie = `${name}=${encodeURIComponent(value)}; Max-Age=${maxAge}; Path=/; SameSite=Lax`
      }

      const extractTimeToken = (q) => {
        if (!q || typeof q !== "string") return null
        const m = q.match(/(?:^|\\s)time:(?:\"([^\"]+)\"|(\\S+))/)
        return m ? (m[1] || m[2] || null) : null
      }

      const upsertTimeToken = (q, timeToken) => {
        if (!q || typeof q !== "string") q = ""
        const trimmed = q.trim()
        const replacement = ` time:${timeToken}`
        if (/(?:^|\\s)time:(?:\"[^\"]+\"|\\S+)/.test(trimmed)) {
          return trimmed.replace(/(?:^|\\s)time:(?:\"[^\"]+\"|\\S+)/, replacement).trim()
        }
        return (trimmed + replacement).trim()
      }

      const persistFromInput = () => {
        const token = extractTimeToken(this._input.value)
        if (token) cookieSet("srql_time", token)
      }

      const maybeRestore = () => {
        if (hasQParam()) {
          // Respect deep links; just persist whatever the URL/query contains.
          persistFromInput()
          return
        }

        const token = cookieGet("srql_time")
        if (!token) return

        const current = (this._input.value || "").toString()
        const next = upsertTimeToken(current, token)
        if (next !== current) {
          this._input.value = next
          if (typeof this.el.requestSubmit === "function") {
            this.el.requestSubmit()
          } else {
            this.el.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
          }
        }
      }

      this._onInput = () => {
        clearTimeout(this._debounceTimer)
        this._debounceTimer = setTimeout(() => persistFromInput(), 150)
      }
      this._onSubmit = () => persistFromInput()

      this._input.addEventListener("input", this._onInput)
      this.el.addEventListener("submit", this._onSubmit)

      maybeRestore()
    },
    updated() {
      // LiveView keeps form inputs "sticky" to preserve user typing, which is usually good.
      // For SRQL-driven pages, other UI controls can emit SRQL via push_patch, and we want
      // the topbar query to reflect that new query. Sync it when the input isn't focused.
      if (!this._input) return
      if (document.activeElement === this._input) return

      const desired = (this.el.dataset.query || "").toString()
      if (!desired) return

      const current = (this._input.value || "").toString()
      if (current !== desired) {
        this._input.value = desired
        this._lastSynced = desired
      }
    },
    destroyed() {
      if (this._input && this._onInput) this._input.removeEventListener("input", this._onInput)
      if (this._onSubmit) this.el.removeEventListener("submit", this._onSubmit)
      clearTimeout(this._debounceTimer)
    }
  },

  TimeseriesChart: {
    mounted() {
      const el = this.el
      const svg = el.querySelector('svg')
      const tooltip = el.querySelector('[data-tooltip]')
      const hoverLine = el.querySelector('[data-hover-line]')
      const pointsData = JSON.parse(el.dataset.points || '[]')
      const unit = el.dataset.unit || 'number'

      if (!svg || !tooltip || !hoverLine || pointsData.length === 0) return

      const svgContainer = svg.parentElement

      const formatBytes = (value) => {
        const abs = Math.abs(value)
        if (abs >= 1e9) return `${(value / 1e9).toFixed(2)} GB`
        if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} MB`
        if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} KB`
        return `${value.toFixed(1)} B`
      }

      const formatHz = (value) => {
        const abs = Math.abs(value)
        if (abs >= 1e9) return `${(value / 1e9).toFixed(2)} GHz`
        if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} MHz`
        if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} KHz`
        return `${value.toFixed(1)} Hz`
      }

      const formatCountPerSec = (value) => {
        const abs = Math.abs(value)
        if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} M/s`
        if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} K/s`
        return `${value.toFixed(2)} /s`
      }

      const formatValue = (value) => {
        if (typeof value !== 'number') return value
        switch (unit) {
          case 'percent':
            return `${value.toFixed(1)}%`
          case 'bytes_per_sec':
            return `${formatBytes(value)}/s`
          case 'bytes':
            return formatBytes(value)
          case 'hz':
            return formatHz(value)
          case 'count_per_sec':
            return formatCountPerSec(value)
          default:
            return value.toFixed(2)
        }
      }

      const showTooltip = (e) => {
        const rect = svg.getBoundingClientRect()
        const x = e.clientX - rect.left
        const pct = Math.max(0, Math.min(1, x / rect.width))
        const idx = Math.round(pct * (pointsData.length - 1))
        const point = pointsData[idx]

        if (point) {
          const value = formatValue(point.v)
          tooltip.textContent = `${value} @ ${point.dt}`
          tooltip.classList.remove('hidden')
          hoverLine.classList.remove('hidden')

          // Position tooltip
          const tooltipX = Math.min(rect.width - tooltip.offsetWidth - 8, Math.max(8, x - tooltip.offsetWidth / 2))
          tooltip.style.left = `${tooltipX}px`
          tooltip.style.top = '-24px'

          // Position hover line
          hoverLine.style.left = `${x}px`
        }
      }

      const hideTooltip = () => {
        tooltip.classList.add('hidden')
        hoverLine.classList.add('hidden')
      }

      svgContainer.addEventListener('mousemove', showTooltip)
      svgContainer.addEventListener('mouseleave', hideTooltip)

      // Store cleanup function
      this.cleanup = () => {
        svgContainer.removeEventListener('mousemove', showTooltip)
        svgContainer.removeEventListener('mouseleave', hideTooltip)
      }
    },
    destroyed() {
      if (this.cleanup) this.cleanup()
    }
  },

  TimeseriesCombinedChart: {
    mounted() {
      const el = this.el
      const svg = el.querySelector('svg')
      const tooltip = el.querySelector('[data-tooltip]')
      const hoverLine = el.querySelector('[data-hover-line]')
      const seriesData = JSON.parse(el.dataset.series || '[]')

      if (!svg || !tooltip || !hoverLine || seriesData.length === 0) return

      const svgContainer = svg.parentElement

      const formatBytes = (value) => {
        const abs = Math.abs(value)
        if (abs >= 1e9) return `${(value / 1e9).toFixed(2)} GB`
        if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} MB`
        if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} KB`
        return `${value.toFixed(1)} B`
      }

      const formatHz = (value) => {
        const abs = Math.abs(value)
        if (abs >= 1e9) return `${(value / 1e9).toFixed(2)} GHz`
        if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} MHz`
        if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} KHz`
        return `${value.toFixed(1)} Hz`
      }

      const formatCountPerSec = (value) => {
        const abs = Math.abs(value)
        if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} M/s`
        if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} K/s`
        return `${value.toFixed(2)} /s`
      }

      const formatValue = (value, unit) => {
        if (typeof value !== 'number') return value
        switch (unit) {
          case 'percent':
            return `${value.toFixed(1)}%`
          case 'bytes_per_sec':
            return `${formatBytes(value)}/s`
          case 'bytes':
            return formatBytes(value)
          case 'hz':
            return formatHz(value)
          case 'count_per_sec':
            return formatCountPerSec(value)
          default:
            return value.toFixed(2)
        }
      }

      const showTooltip = (e) => {
        const rect = svg.getBoundingClientRect()
        const x = e.clientX - rect.left
        const pct = Math.max(0, Math.min(1, x / rect.width))

        const rows = seriesData
          .map((series) => {
            const points = Array.isArray(series.points) ? series.points : []
            if (points.length === 0) return null
            const idx = Math.round(pct * (points.length - 1))
            const point = points[idx]
            if (!point) return null
            return {
              label: series.label || 'series',
              color: series.color || '#999',
              unit: series.unit || 'number',
              dt: point.dt,
              value: formatValue(point.v, series.unit || 'number')
            }
          })
          .filter(Boolean)

        if (rows.length === 0) return

        const timeLabel = rows.find((row) => row.dt)?.dt || ''
        const lines = rows
          .map((row) => {
            const bullet = `<span style="color:${row.color}">&bull;</span>`
            return `<div>${bullet} ${row.label}: ${row.value}</div>`
          })
          .join('')

        tooltip.innerHTML = `${lines}<div class="text-[10px] text-base-content/60 mt-1">${timeLabel}</div>`
        tooltip.classList.remove('hidden')
        hoverLine.classList.remove('hidden')

        const tooltipX = Math.min(rect.width - tooltip.offsetWidth - 8, Math.max(8, x - tooltip.offsetWidth / 2))
        tooltip.style.left = `${tooltipX}px`
        tooltip.style.top = '-24px'
        hoverLine.style.left = `${x}px`
      }

      const hideTooltip = () => {
        tooltip.classList.add('hidden')
        hoverLine.classList.add('hidden')
      }

      svgContainer.addEventListener('mousemove', showTooltip)
      svgContainer.addEventListener('mouseleave', hideTooltip)

      this.cleanup = () => {
        svgContainer.removeEventListener('mousemove', showTooltip)
        svgContainer.removeEventListener('mouseleave', hideTooltip)
      }
    },
    destroyed() {
      if (this.cleanup) this.cleanup()
    }
  },

  NetflowSankeyChart: {
    mounted() {
      this._render = () => this._draw()
      this._resizeObserver = new ResizeObserver(() => this._render())
      this._resizeObserver.observe(this.el)
      this._hiddenGroups = this._hiddenGroups || new Set()
      this._render()
    },
    updated() {
      this._render()
    },
    destroyed() {
      try { this._resizeObserver?.disconnect() } catch (_e) {}
      try { this._tooltipCleanup?.() } catch (_e) {}
    },
    _draw() {
      const hook = this
      const el = this.el
      const svg = el.querySelector("svg")
      if (!svg) return

      const tooltip = nfEnsureTooltip(el)
      tooltip.classList.add("hidden")

      const showTooltip = (evt, html) => {
        if (!html) return
        const rect = el.getBoundingClientRect()
        const x = evt.clientX - rect.left
        const y = evt.clientY - rect.top

        tooltip.innerHTML = html
        tooltip.classList.remove("hidden")

        const pad = 8
        const ttRect = tooltip.getBoundingClientRect()
        const maxLeft = rect.width - (ttRect.width || 180) - pad
        const left = Math.max(pad, Math.min(maxLeft, x + 12))
        const top = Math.max(pad, Math.min(rect.height - 48, y - 12))
        tooltip.style.left = `${left}px`
        tooltip.style.top = `${top}px`
      }

      const hideTooltip = () => {
        tooltip.classList.add("hidden")
      }

      let edges = []
      try {
        edges = JSON.parse(el.dataset.edges || "[]")
      } catch (_e) {
        edges = []
      }
      const width = Math.max(300, el.clientWidth || 0)
      const height = Math.max(220, el.clientHeight || 0)

      svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
      svg.setAttribute("preserveAspectRatio", "xMidYMid meet")

      // Clear
      while (svg.firstChild) svg.removeChild(svg.firstChild)

      if (!Array.isArray(edges) || edges.length === 0) {
        return
      }

      const formatBytes = (value) => {
        const abs = Math.abs(value || 0)
        if (abs >= 1e9) return `${(value / 1e9).toFixed(2)} GB`
        if (abs >= 1e6) return `${(value / 1e6).toFixed(2)} MB`
        if (abs >= 1e3) return `${(value / 1e3).toFixed(2)} KB`
        return `${(value || 0).toFixed(0)} B`
      }

      const nodeIds = new Map()
      const nodes = []
      const addNode = (id, group) => {
        if (!id) return
        if (nodeIds.has(id)) return
        nodeIds.set(id, true)
        nodes.push({ id, group })
      }

      const links = []
      for (const e of edges) {
        const src = e?.src
        const mid = e?.mid
        const dst = e?.dst
        const bytes = Number(e?.bytes || 0)
        const port = e?.port
        if (!src || !mid || !dst || !Number.isFinite(bytes) || bytes <= 0) continue

        addNode(src, "src")
        addNode(mid, "mid")
        addNode(dst, "dst")

        // Model as 2-hop links so d3-sankey lays out 3 columns.
        const mid_field = e?.mid_field ?? ""
        const mid_value = e?.mid_value ?? ""
        links.push({ source: src, target: mid, value: bytes, edge: { src, dst, port, mid_field, mid_value } })
        links.push({ source: mid, target: dst, value: bytes, edge: { src, dst, port, mid_field, mid_value } })
      }

      const sankey = d3Sankey()
        .nodeId((d) => d.id)
        .nodeWidth(12)
        .nodePadding(10)
        .extent([[12, 10], [width - 12, height - 10]])

      const graph = sankey({
        nodes: nodes.map((d) => ({ ...d })),
        links: links.map((d) => ({ ...d })),
      })

      const g = d3.select(svg).append("g")

      const color = d3.scaleOrdinal()
        .domain(["src", "mid", "dst"])
        .range(["#60a5fa", "#a78bfa", "#34d399"])

      const groupHidden = (grp) => hook._hiddenGroups?.has(grp)

      // Links
      g.append("g")
        .attr("fill", "none")
        .selectAll("path")
        .data(graph.links)
        .join("path")
        .attr("d", d3SankeyLinkHorizontal())
        .attr("stroke", (d) => {
          const grp = d?.source?.group || "src"
          return color(grp)
        })
        .attr("stroke-opacity", (d) => {
          const grp = d?.source?.group || "src"
          return groupHidden(grp) ? 0.03 : 0.25
        })
        .attr("stroke-width", (d) => Math.max(1, d.width || 1))
        .style("cursor", "pointer")
        .on("mousemove", (evt, d) => {
          const edge = d?.edge
          const s = edge?.src || d?.source?.id || ""
          const t = edge?.dst || d?.target?.id || ""
          const port = edge?.port ?? ""
          const html = `
            <div class="font-mono text-[11px]">${String(s)} -> ${String(t)}</div>
            <div class="mt-0.5 text-[11px] opacity-70">port: ${String(port || "-")}</div>
            <div class="mt-0.5 text-[11px] font-mono">${formatBytes(d?.value || 0)}</div>
          `
          showTooltip(evt, html)
        })
        .on("mouseleave", hideTooltip)
        .on("click", (_evt, d) => {
          const edge = d?.edge
          if (!edge) return
          this.pushEvent("netflow_sankey_edge", {
            src: edge.src,
            dst: edge.dst,
            port: edge.port ?? "",
            mid_field: edge.mid_field ?? "",
            mid_value: edge.mid_value ?? "",
          })
        })
        .append("title")
        .text((d) => {
          const s = d?.source?.id || ""
          const t = d?.target?.id || ""
          return `${s} -> ${t}\n${formatBytes(d.value)}`
        })

      // Nodes
      const node = g.append("g")
        .selectAll("g")
        .data(graph.nodes)
        .join("g")
        .attr("opacity", (d) => (groupHidden(d.group || "src") ? 0.15 : 1))
        .style("pointer-events", (d) => (groupHidden(d.group || "src") ? "none" : "all"))

      node.append("rect")
        .attr("x", (d) => d.x0)
        .attr("y", (d) => d.y0)
        .attr("height", (d) => Math.max(1, d.y1 - d.y0))
        .attr("width", (d) => Math.max(1, d.x1 - d.x0))
        .attr("rx", 3)
        .attr("fill", (d) => color(d.group || "src"))
        .attr("fill-opacity", 0.65)

      node.append("title")
        .text((d) => d.id)

      // Labels (trim aggressively to avoid overlap)
      node.append("text")
        .attr("x", (d) => (d.x0 < width / 2 ? d.x1 + 6 : d.x0 - 6))
        .attr("y", (d) => (d.y0 + d.y1) / 2)
        .attr("dy", "0.35em")
        .attr("text-anchor", (d) => (d.x0 < width / 2 ? "start" : "end"))
        .attr("font-size", 10)
        .attr("fill", "currentColor")
        .attr("opacity", 0.75)
        .text((d) => {
          const s = String(d.id || "")
          return s.length > 24 ? s.slice(0, 21) + "..." : s
        })
        .on("mousemove", (evt, d) => {
          const grp = d?.group || "src"
          const html = `
            <div class="text-[11px] font-mono">${String(d?.id || "")}</div>
            <div class="mt-0.5 text-[11px] opacity-70">group: ${String(grp)}</div>
          `
          showTooltip(evt, html)
        })
        .on("mouseleave", hideTooltip)

      // Group legend with toggles (keeps parity with other charts' legend toggles).
      const groups = ["src", "mid", "dst"]
      const legend = g.append("g").attr("transform", `translate(${width - 92}, 14)`)

      const legendItem = legend.selectAll("g")
        .data(groups)
        .join("g")
        .attr("transform", (_d, i) => `translate(0, ${i * 14})`)
        .style("cursor", "pointer")
        .on("click", (_evt, grp) => {
          if (hook._hiddenGroups.has(grp)) {
            hook._hiddenGroups.delete(grp)
          } else {
            hook._hiddenGroups.add(grp)
          }
          hook._render()
        })

      legendItem.append("rect")
        .attr("x", 0)
        .attr("y", -9)
        .attr("width", 10)
        .attr("height", 10)
        .attr("rx", 2)
        .attr("fill", (grp) => color(grp))
        .attr("fill-opacity", (grp) => (hook._hiddenGroups.has(grp) ? 0.15 : 0.85))

      legendItem.append("text")
        .attr("x", 14)
        .attr("y", 0)
        .attr("dy", "0.32em")
        .attr("font-size", 10)
        .attr("opacity", (grp) => (hook._hiddenGroups.has(grp) ? 0.4 : 0.75))
        .attr("fill", "currentColor")
        .text((grp) => grp)
    }
  },

  NetflowStackedAreaChart: {
    mounted() {
      this._render = () => this._draw()
      this._resizeObserver = new ResizeObserver(() => this._render())
      this._resizeObserver.observe(this.el)
      this._hidden = this._hidden || new Set()
      this._render()
    },
    updated() {
      this._render()
    },
    destroyed() {
      try { this._resizeObserver?.disconnect() } catch (_e) {}
      try { this._tooltipCleanup?.() } catch (_e) {}
    },
    _draw() {
      const el = this.el
      const svg = nfEnsureSVG(el)
      if (!svg) return

      const { raw, keys, colors } = nfParseSeriesData(el)
      let overlays = []
      try {
        overlays = JSON.parse(el.dataset.overlays || "[]")
      } catch (_e) {
        overlays = []
      }

      const { width, height, margin: m, iw, ih } = nfChartDims(el, {
        minW: 360,
        minH: 220,
        margin: { top: 8, right: 110, bottom: 18, left: 44 },
      })

      nfClearSVG(svg, width, height)

      if (!Array.isArray(raw) || raw.length === 0 || !Array.isArray(keys) || keys.length === 0) {
        return
      }

      const data = nfNormalizeTimeSeries(raw, keys)

      if (data.length === 0) return

      const visibleKeys = keys.filter((k) => !this._hidden.has(k))
      if (visibleKeys.length === 0) return

      const stack = d3.stack().keys(visibleKeys)
      const series = stack(data)

      const maxY = d3.max(series, (s) => d3.max(s, (d) => d[1])) || 1
      const x = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([0, iw])
      const y = d3.scaleLinear().domain([0, maxY]).nice().range([ih, 0])

      const g = d3.select(svg).append("g").attr("transform", `translate(${m.left},${m.top})`)

      const color = nfColorScale(keys, colors)

      const area = d3.area()
        .x((d) => x(d.data.t))
        .y0((d) => y(d[0]))
        .y1((d) => y(d[1]))
        .curve(d3.curveMonotoneX)

      g.append("g")
        .selectAll("path")
        .data(series)
        .join("path")
        .attr("d", area)
        .attr("fill", (d) => color(d.key))
        .attr("fill-opacity", 0.55)
        .attr("cursor", el.dataset.seriesField ? "pointer" : "default")
        .on("click", (_event, d) => {
          const field = el.dataset.seriesField || ""
          if (!field) return
          this.pushEvent("netflow_stack_series", { field, value: d.key })
        })

      // Total overlays: render dashed lines on top of the stacked area.
      // These come from SRQL (series-less) downsample queries and are keyed as `rev:*` and `prev:*`.
      if (Array.isArray(overlays) && overlays.length > 0) {
        const overlayStrokeForKey = (k) => {
          if (String(k).startsWith("prev:")) return "#94a3b8"
          if (String(k).startsWith("rev:")) return "#10b981"
          return "#94a3b8"
        }

        const overlayDashForKey = (k) => {
          if (String(k).startsWith("prev:")) return "6,4"
          if (String(k).startsWith("rev:")) return "3,2"
          return "6,4"
        }

        const line = d3.line()
          .x((d) => x(d.t))
          .y((d) => y(d.v))
          .curve(d3.curveMonotoneX)

        const og = g.append("g").attr("pointer-events", "none")

        for (const ov of overlays) {
          if (!ov || typeof ov.key !== "string") continue
          const k = String(ov.key || "")
          const pts = Array.isArray(ov?.points) ? ov.points : []
          const dataPts = pts
            .map((p) => ({ t: new Date(p.t), v: Number(p.v || 0) }))
            .filter((d) => d.t instanceof Date && !isNaN(d.t.getTime()) && isFinite(d.v))
            .sort((a, b) => a.t - b.t)

          if (dataPts.length === 0) continue

          og.append("path")
            .datum(dataPts)
            .attr("fill", "none")
            .attr("stroke", overlayStrokeForKey(k))
            .attr("stroke-width", 1.75)
            .attr("stroke-opacity", 0.8)
            .attr("stroke-dasharray", overlayDashForKey(k))
            .attr("d", line)

          const last = dataPts[dataPts.length - 1]
          const label = k.startsWith("prev:") ? "prev" : (k.startsWith("rev:") ? "rev" : k)

          og.append("text")
            .attr("x", Math.min(iw - 2, x(last.t) + 4))
            .attr("y", y(last.v))
            .attr("dy", "0.35em")
            .attr("font-size", 10)
            .attr("opacity", 0.7)
            .attr("fill", "currentColor")
            .text(label)
        }
      }

      const legend = g.append("g").attr("transform", `translate(${iw + 12}, 6)`)
      nfBuildLegend(legend, keys, color, this._hidden, (k) => {
        if (this._hidden.has(k)) {
          this._hidden.delete(k)
        } else {
          this._hidden.add(k)
        }
        this._render()
      })

      g.append("g")
        .attr("transform", `translate(0,${ih})`)
        .call(d3.axisBottom(x).ticks(5).tickSizeOuter(0))
        .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))

      g.append("g")
        .call(d3.axisLeft(y).ticks(4).tickSizeOuter(0))
        .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))

      try { this._tooltipCleanup?.() } catch (_e) {}
      this._tooltipCleanup = nfAttachTimeTooltip(el, {
        data,
        keys: visibleKeys,
        x,
        valueAt: (row, k) => row?.[k] || 0,
      })
    }
  },

  NetflowStacked100Chart: {
    mounted() {
      this._render = () => this._draw()
      this._resizeObserver = new ResizeObserver(() => this._render())
      this._resizeObserver.observe(this.el)
      this._hidden = this._hidden || new Set()
      this._render()
    },
    updated() {
      this._render()
    },
    destroyed() {
      try { this._resizeObserver?.disconnect() } catch (_e) {}
      try { this._tooltipCleanup?.() } catch (_e) {}
    },
    _draw() {
      const el = this.el
      const svg = nfEnsureSVG(el)
      if (!svg) return

      const { raw, keys, colors } = nfParseSeriesData(el)
      let overlays = []
      try {
        overlays = JSON.parse(el.dataset.overlays || "[]")
      } catch (_e) {
        overlays = []
      }
      const { width, height, margin: m, iw, ih } = nfChartDims(el, {
        minW: 360,
        minH: 220,
        margin: { top: 8, right: 110, bottom: 18, left: 44 },
      })

      nfClearSVG(svg, width, height)

      if (!Array.isArray(raw) || raw.length === 0 || !Array.isArray(keys) || keys.length === 0) {
        return
      }

      const visibleKeys = keys.filter((k) => !this._hidden.has(k))
      if (visibleKeys.length === 0) return

      const data = raw
        .map((d) => {
          const t = new Date(d.t)
          const out = { t }
          let sum = 0
          for (const k of visibleKeys) {
            const v = Number(d[k] || 0)
            out[k] = v
            sum += v
          }
          out.__sum = sum
          return out
        })
        .filter((d) => d.t instanceof Date && !isNaN(d.t.getTime()))
        .sort((a, b) => a.t - b.t)
        .map((d) => {
          const denom = d.__sum || 1
          const out = { t: d.t }
          for (const k of visibleKeys) out[k] = (Number(d[k] || 0) / denom)
          return out
        })

      if (data.length === 0) return

      const stack = d3.stack().keys(visibleKeys)
      const series = stack(data)

      const x = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([0, iw])
      const y = d3.scaleLinear().domain([0, 1]).nice().range([ih, 0])

      const g = d3.select(svg).append("g").attr("transform", `translate(${m.left},${m.top})`)

      const color = nfColorScale(keys, colors)

      const area = d3.area()
        .x((d) => x(d.data.t))
        .y0((d) => y(d[0]))
        .y1((d) => y(d[1]))
        .curve(d3.curveMonotoneX)

      g.append("g")
        .selectAll("path")
        .data(series)
        .join("path")
        .attr("d", area)
        .attr("fill", (d) => color(d.key))
        .attr("fill-opacity", 0.55)

      const normalizeToPct = (points) => {
        const data = points
          .map((d) => {
            const t = new Date(d.t)
            const out = { t }
            let sum = 0
            for (const k of visibleKeys) {
              const v = Number(d[k] || 0)
              out[k] = v
              sum += v
            }
            out.__sum = sum
            return out
          })
          .filter((d) => d.t instanceof Date && !isNaN(d.t.getTime()))
          .sort((a, b) => a.t - b.t)
          .map((d) => {
            const denom = d.__sum || 1
            const out = { t: d.t }
            for (const k of visibleKeys) out[k] = (Number(d[k] || 0) / denom)
            return out
          })

        return data
      }

      // Composition overlays: dashed boundary lines (y1) per series layer.
      // We keep the same keys so the overlay reads as "previous composition" / "reverse composition".
      if (Array.isArray(overlays) && overlays.length > 0) {
        const overlaysByType = overlays
          .filter((o) => o && typeof o.type === "string" && Array.isArray(o.points))

        const dashForType = (t) => {
          if (t === "prev") return "6,4"
          if (t === "rev") return "3,2"
          return "6,4"
        }

        const opacityForType = (t) => {
          if (t === "prev") return 0.45
          if (t === "rev") return 0.55
          return 0.45
        }

        for (const ov of overlaysByType) {
          const od = normalizeToPct(ov.points || [])
          if (!Array.isArray(od) || od.length === 0) continue

          const oseries = d3.stack().keys(visibleKeys)(od)
          const line = d3.line()
            .x((d) => x(d.data.t))
            .y((d) => y(d[1]))
            .curve(d3.curveMonotoneX)

          const og = g.append("g").attr("pointer-events", "none")

          og.selectAll("path")
            .data(oseries)
            .join("path")
            .attr("fill", "none")
            .attr("stroke", (d) => color(d.key))
            .attr("stroke-width", 1.1)
            .attr("stroke-opacity", opacityForType(ov.type))
            .attr("stroke-dasharray", dashForType(ov.type))
            .attr("d", (d) => line(d))
        }
      }

      const legend = g.append("g").attr("transform", `translate(${iw + 12}, 6)`)
      nfBuildLegend(legend, keys, color, this._hidden, (k) => {
        if (this._hidden.has(k)) {
          this._hidden.delete(k)
        } else {
          this._hidden.add(k)
        }
        this._render()
      })

      g.append("g")
        .attr("transform", `translate(0,${ih})`)
        .call(d3.axisBottom(x).ticks(5).tickSizeOuter(0))
        .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))

      g.append("g")
        .call(d3.axisLeft(y).ticks(4).tickFormat(d3.format(".0%")).tickSizeOuter(0))
        .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))

      try { this._tooltipCleanup?.() } catch (_e) {}
      this._tooltipCleanup = nfAttachTimeTooltip(el, {
        data,
        keys: visibleKeys,
        x,
        valueAt: (row, k) => row?.[k] || 0,
        formatValue: (v) => nfFmtPct(v),
      })
    }
  },

  NetflowLineSeriesChart: {
    mounted() {
      this._render = () => this._draw()
      this._resizeObserver = new ResizeObserver(() => this._render())
      this._resizeObserver.observe(this.el)
      this._hidden = this._hidden || new Set()
      this._render()
    },
    updated() {
      this._render()
    },
    destroyed() {
      try { this._resizeObserver?.disconnect() } catch (_e) {}
    },
    _draw() {
      const el = this.el
      const svg = nfEnsureSVG(el)
      if (!svg) return

      const { raw, keys, colors } = nfParseSeriesData(el)
      const { width, height, margin: m, iw, ih } = nfChartDims(el, {
        minW: 360,
        minH: 220,
        margin: { top: 8, right: 110, bottom: 18, left: 44 },
      })

      nfClearSVG(svg, width, height)

      if (!Array.isArray(raw) || raw.length === 0 || !Array.isArray(keys) || keys.length === 0) {
        return
      }

      const data = nfNormalizeTimeSeries(raw, keys)

      if (data.length === 0) return

      const visibleKeys = keys.filter((k) => !this._hidden.has(k))
      if (visibleKeys.length === 0) return

      const maxY = d3.max(visibleKeys, (k) => d3.max(data, (d) => d[k])) || 1
      const x = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([0, iw])
      const y = d3.scaleLinear().domain([0, maxY]).nice().range([ih, 0])

      const g = d3.select(svg).append("g").attr("transform", `translate(${m.left},${m.top})`)

      const color = nfColorScale(keys, colors)

      const strokeForKey = (k) => {
        if (String(k).startsWith("prev:")) return "#94a3b8"
        if (String(k).startsWith("rev:")) return color(String(k).slice(4))
        return color(k)
      }

      const dashForKey = (k) => {
        if (String(k).startsWith("prev:")) return "6,4"
        if (String(k).startsWith("rev:")) return "3,2"
        return null
      }

      const opacityForKey = (k) => {
        if (String(k).startsWith("prev:")) return 0.75
        if (String(k).startsWith("rev:")) return 0.65
        return 0.85
      }

      const line = (k) => d3.line()
        .x((d) => x(d.t))
        .y((d) => y(d[k]))
        .curve(d3.curveMonotoneX)

      g.append("g")
        .selectAll("path")
        .data(visibleKeys)
        .join("path")
        .attr("fill", "none")
        .attr("stroke", (k) => strokeForKey(k))
        .attr("stroke-opacity", (k) => opacityForKey(k))
        .attr("stroke-width", 1.75)
        .attr("stroke-dasharray", (k) => dashForKey(k))
        .attr("d", (k) => line(k)(data))

      const legend = g.append("g").attr("transform", `translate(${iw + 12}, 6)`)
      nfBuildLegend(legend, keys, strokeForKey, this._hidden, (k) => {
        if (this._hidden.has(k)) {
          this._hidden.delete(k)
        } else {
          this._hidden.add(k)
        }
        this._render()
      })

      g.append("g")
        .attr("transform", `translate(0,${ih})`)
        .call(d3.axisBottom(x).ticks(5).tickSizeOuter(0))
        .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))

      g.append("g")
        .call(d3.axisLeft(y).ticks(4).tickSizeOuter(0))
        .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))

      try { this._tooltipCleanup?.() } catch (_e) {}
      this._tooltipCleanup = nfAttachTimeTooltip(el, {
        data,
        keys: visibleKeys,
        x,
        valueAt: (row, k) => row?.[k] || 0,
      })
    }
  },

  NetflowGridChart: {
    mounted() {
      this._render = () => this._draw()
      this._resizeObserver = new ResizeObserver(() => this._render())
      this._resizeObserver.observe(this.el)
      this._hidden = this._hidden || new Set()
      this._render()
    },
    updated() {
      this._render()
    },
    destroyed() {
      try { this._resizeObserver?.disconnect() } catch (_e) {}
      try { this._tooltipCleanup?.() } catch (_e) {}
    },
    _draw() {
      const el = this.el
      const svg = nfEnsureSVG(el)
      if (!svg) return

      const { raw, keys, colors } = nfParseSeriesData(el)
      const { width, height, margin: m, iw, ih } = nfChartDims(el, {
        minW: 360,
        minH: 220,
        margin: { top: 10, right: 110, bottom: 10, left: 10 },
      })

      nfClearSVG(svg, width, height)

      if (!Array.isArray(raw) || raw.length === 0 || !Array.isArray(keys) || keys.length === 0) {
        return
      }

      const data = nfNormalizeTimeSeries(raw, keys)

      if (data.length === 0) return

      const visibleKeys = keys.filter((k) => !this._hidden.has(k))
      if (visibleKeys.length === 0) return

      const n = visibleKeys.length
      const cols = Math.ceil(Math.sqrt(n))
      const rows = Math.ceil(n / cols)
      const pad = 10
      const cw = Math.max(1, (iw - pad * (cols - 1)) / cols)
      const ch = Math.max(1, (ih - pad * (rows - 1)) / rows)

      const color = nfColorScale(keys, colors)

      const root = d3.select(svg).append("g").attr("transform", `translate(${m.left},${m.top})`)

      const legend = root.append("g").attr("transform", `translate(${iw + 12}, 6)`)
      nfBuildLegend(legend, keys, color, this._hidden, (k) => {
        if (this._hidden.has(k)) {
          this._hidden.delete(k)
        } else {
          this._hidden.add(k)
        }
        this._render()
      })

      for (let i = 0; i < n; i++) {
        const k = visibleKeys[i]
        const c = i % cols
        const r = Math.floor(i / cols)
        const x0 = c * (cw + pad)
        const y0 = r * (ch + pad)

        const panel = root.append("g").attr("transform", `translate(${x0},${y0})`)
        panel.append("rect")
          .attr("x", 0)
          .attr("y", 0)
          .attr("width", cw)
          .attr("height", ch)
          .attr("rx", 8)
          .attr("fill", "none")
          .attr("stroke", "currentColor")
          .attr("opacity", 0.12)

        const px = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([10, cw - 10])
        const maxY = d3.max(data, (d) => d[k]) || 1
        const py = d3.scaleLinear().domain([0, maxY]).nice().range([ch - 18, 18])

        const ln = d3.line()
          .x((d) => px(d.t))
          .y((d) => py(d[k]))
          .curve(d3.curveMonotoneX)

        panel.append("path")
          .datum(data)
          .attr("fill", "none")
          .attr("stroke", color(k))
          .attr("stroke-width", 1.75)
          .attr("stroke-opacity", 0.85)
          .attr("d", ln)

        panel.append("text")
          .attr("x", 10)
          .attr("y", 14)
          .attr("font-size", 10)
          .attr("opacity", 0.75)
          .text(String(k).length > 18 ? String(k).slice(0, 15) + "..." : String(k))
      }

      // Shared tooltip across all series (matches other time-series charts).
      const x = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([0, iw])
      try { this._tooltipCleanup?.() } catch (_e) {}
      this._tooltipCleanup = nfAttachTimeTooltip(el, {
        data,
        keys: visibleKeys,
        x,
        valueAt: (row, k) => row?.[k] || 0,
      })
    }
  },

  MapboxFlowMap: {
    mounted() {
      this._initOrUpdate()
      this._themeObserver = new MutationObserver(() => this._applyThemeStyle())
      // daisyUI typically drives theme via `data-theme` on <html>, but be resilient:
      // some pages/toggles may update `class`, inline styles, or set theme on <body>.
      this._themeObserver.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["data-theme", "class", "style"],
      })
      this._themeObserver.observe(document.body, {
        attributes: true,
        attributeFilter: ["data-theme", "class", "style"],
      })

      this._colorSchemeMql = window.matchMedia?.("(prefers-color-scheme: dark)") || null
      this._onColorSchemeChange = () => this._applyThemeStyle()
      if (this._colorSchemeMql?.addEventListener) {
        this._colorSchemeMql.addEventListener("change", this._onColorSchemeChange)
      } else if (this._colorSchemeMql?.addListener) {
        // Safari
        this._colorSchemeMql.addListener(this._onColorSchemeChange)
      }
    },
    updated() {
      this._initOrUpdate()
    },
    destroyed() {
      try {
        this._themeObserver?.disconnect()
      } catch (_e) {}
      try {
        if (this._colorSchemeMql?.removeEventListener && this._onColorSchemeChange) {
          this._colorSchemeMql.removeEventListener("change", this._onColorSchemeChange)
        } else if (this._colorSchemeMql?.removeListener && this._onColorSchemeChange) {
          this._colorSchemeMql.removeListener(this._onColorSchemeChange)
        }
      } catch (_e) {}
      try {
        this._map?.remove()
      } catch (_e) {}
      this._map = null
      this._markers = []
    },
    _initOrUpdate() {
      const token = this.el.dataset.accessToken || ""
      const enabled = (this.el.dataset.enabled || "false") === "true"
      const styleLight = this.el.dataset.styleLight || "mapbox://styles/mapbox/light-v11"
      const styleDark = this.el.dataset.styleDark || "mapbox://styles/mapbox/dark-v11"
      const markers = JSON.parse(this.el.dataset.markers || "[]")

      if (!enabled || !token || !Array.isArray(markers) || markers.length === 0) {
        try {
          this._map?.remove()
        } catch (_e) {}
        this._map = null
        this._markers = []
        return
      }

      this._token = token
      this._styleLight = styleLight
      this._styleDark = styleDark
      this._markerData = markers

      if (!this._map) {
        mapboxgl.accessToken = token
        const style = this._currentStyle()

        this._map = new mapboxgl.Map({
          container: this.el,
          style,
          center: [0, 0],
          zoom: 1.2,
          attributionControl: false,
        })

        this._map.addControl(new mapboxgl.NavigationControl({ showCompass: true }), "top-right")

        this._map.on("load", () => {
          this._syncMarkers()
          this._fitToMarkers()
          this._stampStyleUrl(style)
        })
      } else {
        if (mapboxgl.accessToken !== token) {
          try {
            this._map?.remove()
          } catch (_e) {}
          this._map = null
          this._markers = []
          this._initOrUpdate()
          return
        }

        this._applyThemeStyle()
        this._syncMarkers()
        this._fitToMarkers()
      }
    },
    _currentStyle() {
      return this._isDarkMode() ? this._styleDark : this._styleLight
    },
    _isDarkMode() {
      // 1) Prefer computed `color-scheme` (best signal when themes set it)
      try {
        const cs = window.getComputedStyle(document.documentElement).colorScheme
        if (typeof cs === "string") {
          if (cs.includes("dark")) return true
          if (cs.includes("light")) return false
        }
      } catch (_e) {}

      // 2) Fall back to explicit theme names for the common case
      const themeAttr =
        document.documentElement.getAttribute("data-theme") ||
        document.body?.getAttribute?.("data-theme") ||
        ""
      const theme = String(themeAttr || "").toLowerCase().trim()
      if (theme === "dark") return true
      if (theme === "light") return false

      // 3) Infer from background luminance (works even for custom themes)
      const bg =
        (document.body && window.getComputedStyle(document.body).backgroundColor) ||
        window.getComputedStyle(document.documentElement).backgroundColor ||
        ""
      const m = String(bg).match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/i)
      if (m) {
        const r = Number(m[1]) / 255
        const g = Number(m[2]) / 255
        const b = Number(m[3]) / 255
        // Relative luminance (sRGB)
        const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return lum < 0.45
      }

      // 4) Last resort: OS preference
      return !!this._colorSchemeMql?.matches
    },
    _styleUrlFromMeta() {
      try {
        const meta = this._map?.getStyle()?.metadata || {}
        return meta["sr_style_url"]
      } catch (_e) {
        return null
      }
    },
    _stampStyleUrl(url) {
      try {
        const style = this._map.getStyle()
        style.metadata = { ...(style.metadata || {}), sr_style_url: url }
      } catch (_e) {}
    },
    _applyThemeStyle() {
      if (!this._map) return
      const desired = this._currentStyle()
      const current = this._styleUrlFromMeta()
      if (current === desired) return

      this._map.setStyle(desired, { diff: true })
      this._map.once("style.load", () => {
        this._stampStyleUrl(desired)
        this._syncMarkers()
      })
    },
    _syncMarkers() {
      if (!this._map) return
      const data = Array.isArray(this._markerData) ? this._markerData : []

      for (const m of this._markers || []) {
        try {
          m.remove()
        } catch (_e) {}
      }
      this._markers = []

      for (const d of data) {
        const lng = Number(d?.lng)
        const lat = Number(d?.lat)
        if (!Number.isFinite(lng) || !Number.isFinite(lat)) continue

        const label = String(d?.label || "")
        const popup = label ? new mapboxgl.Popup({ offset: 20 }).setText(label) : null

        const marker = new mapboxgl.Marker().setLngLat([lng, lat])
        if (popup) marker.setPopup(popup)
        marker.addTo(this._map)

        this._markers.push(marker)
      }
    },
    _fitToMarkers() {
      if (!this._map || !Array.isArray(this._markerData) || this._markerData.length === 0) return

      const coords = this._markerData
        .map((d) => [Number(d?.lng), Number(d?.lat)])
        .filter(([lng, lat]) => Number.isFinite(lng) && Number.isFinite(lat))

      if (coords.length === 0) return

      if (coords.length === 1) {
        this._map.easeTo({ center: coords[0], zoom: 3.2, duration: 250 })
        return
      }

      const bounds = coords.reduce(
        (b, c) => b.extend(c),
        new mapboxgl.LngLatBounds(coords[0], coords[0])
      )

      this._map.fitBounds(bounds, { padding: 28, duration: 250, maxZoom: 6 })
    },
  },

  BulkEditTagsToggle: {
    mounted() {
      const container = this.el
      const form = container.closest('form')

      if (!form) return

      const handleChange = (e) => {
        if (e.target.name === 'bulk[action]') {
          if (e.target.value === 'add_tags') {
            container.classList.remove('hidden')
          } else {
            container.classList.add('hidden')
          }
        }
      }

      form.addEventListener('change', handleChange)
      this.cleanup = () => form.removeEventListener('change', handleChange)
    },
    destroyed() {
      if (this.cleanup) this.cleanup()
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#50fa7b"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

const fallbackCopy = (text) => {
  const textarea = document.createElement("textarea")
  textarea.value = text
  textarea.setAttribute("readonly", "")
  textarea.style.position = "fixed"
  textarea.style.top = "-1000px"
  textarea.style.opacity = "0"
  document.body.appendChild(textarea)
  textarea.select()
  document.execCommand("copy")
  document.body.removeChild(textarea)
}

window.addEventListener("phx:clipboard", async (event) => {
  const text = event.detail?.text
  if (!text) return

  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text)
    } else {
      fallbackCopy(text)
    }
  } catch (_err) {
    fallbackCopy(text)
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
