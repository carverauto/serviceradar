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
      const svg = el.querySelector("svg")
      if (!svg) return

      const edges = JSON.parse(el.dataset.edges || "[]")
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
        links.push({ source: src, target: mid, value: bytes, edge: { src, dst, port } })
        links.push({ source: mid, target: dst, value: bytes, edge: { src, dst, port } })
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
        .attr("stroke-opacity", 0.25)
        .attr("stroke-width", (d) => Math.max(1, d.width || 1))
        .style("cursor", "pointer")
        .on("click", (_evt, d) => {
          const edge = d?.edge
          if (!edge) return
          this.pushEvent("netflow_sankey_edge", {
            src: edge.src,
            dst: edge.dst,
            port: edge.port ?? "",
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
    }
  },

  NetflowStackedAreaChart: {
    mounted() {
      this._render = () => this._draw()
      this._resizeObserver = new ResizeObserver(() => this._render())
      this._resizeObserver.observe(this.el)
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
      const svg = el.querySelector("svg")
      if (!svg) return

      const raw = JSON.parse(el.dataset.points || "[]")
      const keys = JSON.parse(el.dataset.keys || "[]")
      const width = Math.max(360, el.clientWidth || 0)
      const height = Math.max(220, el.clientHeight || 0)
      const m = { top: 8, right: 10, bottom: 18, left: 36 }
      const iw = Math.max(1, width - m.left - m.right)
      const ih = Math.max(1, height - m.top - m.bottom)

      svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
      svg.setAttribute("preserveAspectRatio", "xMidYMid meet")
      while (svg.firstChild) svg.removeChild(svg.firstChild)

      if (!Array.isArray(raw) || raw.length === 0 || !Array.isArray(keys) || keys.length === 0) {
        return
      }

      const data = raw
        .map((d) => {
          const t = new Date(d.t)
          const out = { t }
          for (const k of keys) out[k] = Number(d[k] || 0)
          return out
        })
        .filter((d) => d.t instanceof Date && !isNaN(d.t.getTime()))
        .sort((a, b) => a.t - b.t)

      if (data.length === 0) return

      const stack = d3.stack().keys(keys)
      const series = stack(data)

      const maxY = d3.max(series, (s) => d3.max(s, (d) => d[1])) || 1
      const x = d3.scaleTime().domain(d3.extent(data, (d) => d.t)).range([0, iw])
      const y = d3.scaleLinear().domain([0, maxY]).nice().range([ih, 0])

      const g = d3.select(svg).append("g").attr("transform", `translate(${m.left},${m.top})`)

      const color = d3.scaleOrdinal()
        .domain(keys)
        .range(d3.schemeTableau10.concat(d3.schemeSet3).slice(0, keys.length))

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

      g.append("g")
        .attr("transform", `translate(0,${ih})`)
        .call(d3.axisBottom(x).ticks(5).tickSizeOuter(0))
        .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))

      g.append("g")
        .call(d3.axisLeft(y).ticks(4).tickSizeOuter(0))
        .call((gg) => gg.selectAll("text").attr("font-size", 10).attr("opacity", 0.7))
    }
  },

  MapboxFlowMap: {
    mounted() {
      this._initOrUpdate()
      this._themeObserver = new MutationObserver(() => this._applyThemeStyle())
      this._themeObserver.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["data-theme"],
      })
    },
    updated() {
      this._initOrUpdate()
    },
    destroyed() {
      try {
        this._themeObserver?.disconnect()
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
      const theme = document.documentElement.getAttribute("data-theme") || "light"
      return theme === "dark" ? this._styleDark : this._styleLight
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
