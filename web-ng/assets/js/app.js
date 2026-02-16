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
import {tableFromIPC} from "apache-arrow"

import * as d3 from "d3"
import {sankey as d3Sankey, sankeyLinkHorizontal as d3SankeyLinkHorizontal} from "d3-sankey"
import mapboxgl from "mapbox-gl"
import {COORDINATE_SYSTEM, Deck, Layer, OrthographicView, picking, project32} from "@deck.gl/core"
import {ArcLayer, LineLayer, ScatterplotLayer, TextLayer} from "@deck.gl/layers"
import {Geometry, Model} from "@luma.gl/engine"
import {GodViewWasmEngine} from "./wasm/god_view_exec_runtime"

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

function nfFormatBytes(n) {
  const v = Number(n || 0)
  if (!Number.isFinite(v)) return "0 B"
  const abs = Math.abs(v)
  if (abs >= 1e12) return `${(v / 1e12).toFixed(2)} TB`
  if (abs >= 1e9) return `${(v / 1e9).toFixed(2)} GB`
  if (abs >= 1e6) return `${(v / 1e6).toFixed(2)} MB`
  if (abs >= 1e3) return `${(v / 1e3).toFixed(2)} KB`
  return `${v.toFixed(0)} B`
}

function nfFormatBits(n) {
  const v = Number(n || 0)
  if (!Number.isFinite(v)) return "0 b"
  const abs = Math.abs(v)
  if (abs >= 1e12) return `${(v / 1e12).toFixed(2)} Tb`
  if (abs >= 1e9) return `${(v / 1e9).toFixed(2)} Gb`
  if (abs >= 1e6) return `${(v / 1e6).toFixed(2)} Mb`
  if (abs >= 1e3) return `${(v / 1e3).toFixed(2)} Kb`
  return `${v.toFixed(0)} b`
}

function nfFormatCountPerSec(n) {
  const v = Number(n || 0)
  if (!Number.isFinite(v)) return "0 /s"
  const abs = Math.abs(v)
  if (abs >= 1e9) return `${(v / 1e9).toFixed(2)} G/s`
  if (abs >= 1e6) return `${(v / 1e6).toFixed(2)} M/s`
  if (abs >= 1e3) return `${(v / 1e3).toFixed(2)} K/s`
  return `${v.toFixed(2)} /s`
}

function nfFormatRateValue(units, n) {
  const u = String(units || "").trim()
  if (u === "bps") return `${nfFormatBits(n)}/s`
  if (u === "Bps") return `${nfFormatBytes(n)}/s`
  if (u === "pps") return nfFormatCountPerSec(n)
  return nfFormatBytes(n)
}

const packetFlowVS = `\
#define SHADER_NAME sr-packet-flow-layer-vs
attribute vec2 a_from;
attribute vec2 a_to;
attribute float a_seed;
attribute float a_speed;
attribute float a_size;
attribute float a_jitter;
attribute vec4 a_color;

uniform float u_time;

varying vec4 vColor;

float hash(float n) {
  return fract(sin(n) * 43758.5453123);
}

void main(void) {
  float t = fract((u_time * a_speed) + a_seed);
  float eased = pow(t, 1.18);
  vec2 base = mix(a_from, a_to, eased);

  vec2 dir = normalize(max(vec2(0.0001), a_to - a_from));
  vec2 normal = vec2(-dir.y, dir.x);

  float jitterSeed = hash(a_seed * 91.733);
  float spread = (jitterSeed - 0.5) * a_jitter;
  float wobble = sin(u_time * 7.5 + a_seed * 29.0) * (a_jitter * 0.28);

  vec2 pos = base + normal * (spread + wobble);

  vColor = a_color;
  float tailFade = 1.0 - smoothstep(0.82, 1.0, t);
  float headBoost = 0.74 + (1.0 - t) * 0.26;
  vColor.a = clamp(vColor.a * tailFade * headBoost, 0.0, 1.0);
  gl_Position = project_position_to_clipspace(vec3(pos, 0.0), vec3(0.0), vec3(0.0));
  gl_PointSize = a_size;
}
`

const packetFlowFS = `\
#define SHADER_NAME sr-packet-flow-layer-fs
precision highp float;
varying vec4 vColor;

void main(void) {
  vec2 p = gl_PointCoord * 2.0 - 1.0;
  float r = length(p);
  if (r > 1.0) {
    discard;
  }
  float glow = 1.0 - pow(r, 1.2);
  float alpha = glow * vColor.a;
  gl_FragColor = vec4(vColor.rgb, alpha);
}
`

class PacketFlowLayer extends Layer {
  getShaders() {
    return {vs: packetFlowVS, fs: packetFlowFS, modules: [project32, picking]}
  }

  initializeState() {
    const attributeManager = this.getAttributeManager()
    attributeManager.addInstanced({
      a_from: {size: 2, accessor: "getFrom"},
      a_to: {size: 2, accessor: "getTo"},
      a_seed: {size: 1, accessor: "getSeed"},
      a_speed: {size: 1, accessor: "getSpeed"},
      a_size: {size: 1, accessor: "getSize"},
      a_jitter: {size: 1, accessor: "getJitter"},
      a_color: {size: 4, type: 5121, normalized: true, accessor: "getColor"},
    })

    this.setState({
      model: this._getModel(),
    })
  }

  _getModel() {
    return new Model(this.context.device, {
      ...this.getShaders(),
      geometry: new Geometry({
        topology: "point-list",
        attributes: {
          positions: {value: new Float32Array([0, 0, 0]), size: 3},
        },
      }),
      isInstanced: true,
    })
  }

  draw({uniforms}) {
    const model = this.state.model
    if (!model) return
    model.setUniforms({
      ...uniforms,
      u_time: Number(this.props.time || 0),
    })
    model.draw()
  }

  finalizeState() {
    this.state.model?.delete?.()
  }
}

PacketFlowLayer.defaultProps = {
  getFrom: (d) => d.from,
  getTo: (d) => d.to,
  getSeed: (d) => d.seed,
  getSpeed: (d) => d.speed,
  getSize: (d) => d.size,
  getJitter: (d) => d.jitter,
  getColor: (d) => d.color,
  time: 0,
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

		      const renderMessage = (msg, detail) => {
		        // Clear existing SVG children.
		        while (svg.firstChild) svg.removeChild(svg.firstChild)

		        const width = Math.max(300, el.clientWidth || 0)
		        const height = Math.max(220, el.clientHeight || 0)
		        svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
		        svg.setAttribute("preserveAspectRatio", "xMidYMid meet")

		        const g = document.createElementNS("http://www.w3.org/2000/svg", "g")
		        const text = document.createElementNS("http://www.w3.org/2000/svg", "text")
		        text.setAttribute("x", "16")
		        text.setAttribute("y", "24")
		        text.setAttribute("fill", "currentColor")
		        text.setAttribute("font-size", "12")
		        text.textContent = msg || "No Sankey edges in this window."
		        g.appendChild(text)

		        if (detail) {
		          const t2 = document.createElementNS("http://www.w3.org/2000/svg", "text")
		          t2.setAttribute("x", "16")
		          t2.setAttribute("y", "44")
		          t2.setAttribute("fill", "currentColor")
		          t2.setAttribute("font-size", "11")
		          t2.setAttribute("opacity", "0.7")
		          t2.textContent = detail
		          g.appendChild(t2)
		        }

		        svg.appendChild(g)
		      }

		      const groupLabel = {
		        src: el.dataset.srcLabel || "Source",
		        mid: el.dataset.midLabel || "Middle",
		        dst: el.dataset.dstLabel || "Destination",
		      }

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

	      try {
	        svg.setAttribute("viewBox", `0 0 ${width} ${height}`)
	        svg.setAttribute("preserveAspectRatio", "xMidYMid meet")

	        // Clear
	        while (svg.firstChild) svg.removeChild(svg.firstChild)

	        if (!Array.isArray(edges) || edges.length === 0) {
	          renderMessage("No Sankey edges in this window.", "Try widening the time range or switching dimensions.")
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
	      const nodeKey = (group, label) => `${String(group || "")}:${String(label || "")}`
	      const addNode = (id, group) => {
	        if (!id) return
	        const key = nodeKey(group, id)
	        if (nodeIds.has(key)) return
	        nodeIds.set(key, true)
	        // Keep a stable, namespaced id for layout, but preserve the original label for display.
	        nodes.push({ id: key, label: id, group })
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
	        links.push({ source: nodeKey("src", src), target: nodeKey("mid", mid), value: bytes, edge: { src, dst, port, mid_field, mid_value } })
	        links.push({ source: nodeKey("mid", mid), target: nodeKey("dst", dst), value: bytes, edge: { src, dst, port, mid_field, mid_value } })
	      }

	      const buildSankey = (nodeList, linkList) => {
	        const sankey = d3Sankey()
	          .nodeId((d) => d.id)
	          .nodeWidth(12)
	          .nodePadding(10)
	          .extent([[12, 10], [width - 12, height - 10]])

	        return sankey({
	          nodes: nodeList.map((d) => ({ ...d })),
	          links: linkList.map((d) => ({ ...d })),
	        })
	      }

	      // d3-sankey requires a DAG. In practice we only emit src->mid->dst edges, but if upstream
	      // data ever produces a cycle (or the browser is running a stale bundle), degrade gracefully
	      // to a 2-column sankey (src->dst aggregated across the middle).
	      let graph
	      let degraded = false
	      try {
	        graph = buildSankey(nodes, links)
	      } catch (e) {
	        const msg = String(e?.message || e || "")
	        if (!msg.toLowerCase().includes("circular link")) throw e
	        degraded = true

	        // Aggregate to src->dst only.
	        const nodeIds2 = new Map()
	        const nodes2 = []
	        const add2 = (id, group) => {
	          if (!id) return
	          const key = nodeKey(group, id)
	          if (nodeIds2.has(key)) return
	          nodeIds2.set(key, true)
	          nodes2.push({ id: key, label: id, group })
	        }

	        const byPair = new Map()
	        for (const e2 of edges) {
	          const src2 = e2?.src
	          const dst2 = e2?.dst
	          const bytes2 = Number(e2?.bytes || 0)
	          if (!src2 || !dst2 || !Number.isFinite(bytes2) || bytes2 <= 0) continue
	          add2(src2, "src")
	          add2(dst2, "dst")
	          const key = `${nodeKey("src", src2)}|${nodeKey("dst", dst2)}`
	          const cur = byPair.get(key) || 0
	          byPair.set(key, cur + bytes2)
	        }

	        const links2 = []
	        for (const [key, value] of byPair.entries()) {
	          const [s, t] = key.split("|")
	          if (!s || !t) continue
	          links2.push({ source: s, target: t, value })
	        }

	        graph = buildSankey(nodes2, links2)
	      }

      const g = d3.select(svg).append("g")
	      if (degraded) {
	        g.append("text")
	          .attr("x", width - 12)
	          .attr("y", height - 10)
	          .attr("text-anchor", "end")
	          .attr("font-size", 10)
	          .attr("opacity", 0.6)
	          .attr("fill", "currentColor")
	          .text("Simplified (cycle detected)")
	      }

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
	          const mf = String(edge?.mid_field || "")
	          const mv = String(edge?.mid_value || "")

	          const midLabel = (() => {
	            if (mf === "dst_port" || mf === "dst_endpoint_port") return `${groupLabel.mid}: ${String(port || mv || "-")}`
	            if (mf === "app") return `${groupLabel.mid}: ${mv || "-"}`
	            if (mf === "protocol_group") return `${groupLabel.mid}: ${mv || "-"}`
	            return `${groupLabel.mid}: ${mv || port || "-"}`
	          })()
	          const html = `
	            <div class="text-[11px]"><span class="opacity-70">${groupLabel.src}:</span> <span class="font-mono">${String(s)}</span></div>
	            <div class="mt-0.5 text-[11px] opacity-70">${midLabel}</div>
	            <div class="mt-0.5 text-[11px]"><span class="opacity-70">${groupLabel.dst}:</span> <span class="font-mono">${String(t)}</span></div>
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
	          const s = d?.source?.label || d?.source?.id || ""
	          const t = d?.target?.label || d?.target?.id || ""
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
	        .text((d) => d.label || d.id)

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
	          const s = String(d.label || d.id || "")
	          return s.length > 24 ? s.slice(0, 21) + "..." : s
	        })
		        .on("mousemove", (evt, d) => {
		          const grp = d?.group || "src"
		          const html = `
		            <div class="text-[11px] font-mono">${String(d?.label || d?.id || "")}</div>
		            <div class="mt-0.5 text-[11px] opacity-70">${String(groupLabel[grp] || grp)}</div>
		          `
		          showTooltip(evt, html)
		        })
        .on("mouseleave", hideTooltip)

	      // Column headers (what each column represents).
	      try {
	        const centers = {}
	        for (const n of graph.nodes || []) {
	          const grp = n?.group || "src"
	          const cx = (Number(n.x0) + Number(n.x1)) / 2
	          if (!Number.isFinite(cx)) continue
	          if (!centers[grp]) centers[grp] = []
	          centers[grp].push(cx)
	        }

	        const headerY = 10
	        for (const grp of ["src", "mid", "dst"]) {
	          const xs = centers[grp] || []
	          if (xs.length === 0) continue
	          const x = xs.reduce((a, b) => a + b, 0) / xs.length
	          g.append("text")
	            .attr("x", x)
	            .attr("y", headerY)
	            .attr("text-anchor", "middle")
	            .attr("font-size", 10)
	            .attr("opacity", 0.7)
	            .attr("fill", "currentColor")
	            .text(String(groupLabel[grp] || grp))
		        }
		      } catch (_e) {}

		      } catch (e) {
		        renderMessage("Sankey failed to render.", String(e?.message || e || "unknown error"))
		        return
		      }

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

      // Draw order matters: if the largest series is drawn last, it visually hides thin layers.
      // Sort keys by descending total so big series go "under" smaller ones.
      const keyTotals = new Map()
      for (const k of visibleKeys) {
        let sum = 0
        for (const row of data) sum += Number(row?.[k] || 0)
        keyTotals.set(k, sum)
      }
      const stackKeys = visibleKeys.slice().sort((a, b) => (keyTotals.get(b) || 0) - (keyTotals.get(a) || 0))

      const stack = d3.stack().keys(stackKeys)
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
        formatValue: (v) => nfFormatRateValue(el.dataset.units, v),
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
        formatValue: (v) => nfFormatRateValue(el.dataset.units, v),
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
          .attr("fill", "currentColor")
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
        formatValue: (v) => nfFormatRateValue(el.dataset.units, v),
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
      try { this._map?.resize() } catch (_e) {}
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
      let markers = []
      try {
        markers = JSON.parse(this.el.dataset.markers || "[]")
      } catch (_e) {
        markers = []
      }

      if (!enabled || !token) {
        try {
          this._map?.remove()
        } catch (_e) {}
        this._map = null
        this._markers = []
        this._showFallback(
          !enabled ? "Maps are disabled" : "Mapbox access token not configured"
        )
        return
      }

      this._clearFallback()
      this._token = token
      this._styleLight = styleLight
      this._styleDark = styleDark
      this._markerData = Array.isArray(markers) ? markers : []

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
          this._map.resize()
          this._syncMarkers()
          this._fitToMarkers()
          this._stampStyleUrl(style)
        })

        this._map.on("error", (e) => {
          const msg = e?.error?.message || e?.message || "Unknown map error"
          console.warn("[MapboxFlowMap] map error:", msg)
          if (msg.includes("access token") || msg.includes("401") || msg.includes("403")) {
            this._showFallback("Invalid Mapbox access token")
          }
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

        const side =
          label.toLowerCase().startsWith("source") ? "source" :
          label.toLowerCase().startsWith("dest") ? "dest" : null

        const markerColor =
          side === "source" ? "#22c55e" : // green-500
          side === "dest" ? "#ef4444" :   // red-500
          "#64748b"                       // slate-500

        const marker = new mapboxgl.Marker({ color: markerColor }).setLngLat([lng, lat])
        if (popup) marker.setPopup(popup)
        marker.addTo(this._map)

        this._markers.push(marker)
      }

      this._syncLine()
    },
    _syncLine() {
      if (!this._map) return

      const coords = (Array.isArray(this._markerData) ? this._markerData : [])
        .map((d) => [Number(d?.lng), Number(d?.lat)])
        .filter(([lng, lat]) => Number.isFinite(lng) && Number.isFinite(lat))

      const sourceId = "sr-flow-line"
      const layerId = "sr-flow-line-layer"

      // Remove if we don't have a full src/dst pair.
      if (coords.length < 2) {
        try { if (this._map.getLayer(layerId)) this._map.removeLayer(layerId) } catch (_e) {}
        try { if (this._map.getSource(sourceId)) this._map.removeSource(sourceId) } catch (_e) {}
        return
      }

      const line = {
        type: "FeatureCollection",
        features: [{
          type: "Feature",
          geometry: { type: "LineString", coordinates: [coords[0], coords[1]] },
          properties: {},
        }],
      }

      if (this._map.getSource(sourceId)) {
        try { this._map.getSource(sourceId).setData(line) } catch (_e) {}
      } else {
        try {
          this._map.addSource(sourceId, { type: "geojson", data: line })
          this._map.addLayer({
            id: layerId,
            type: "line",
            source: sourceId,
            paint: {
              "line-color": "#0ea5e9", // sky-500
              "line-width": 3,
              "line-opacity": 0.75,
            },
          })
        } catch (_e) {}
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
    _showFallback(message) {
      if (!this.el) return
      let fb = this.el.querySelector("[data-map-fallback]")
      if (!fb) {
        fb = document.createElement("div")
        fb.setAttribute("data-map-fallback", "")
        fb.className =
          "flex items-center justify-center h-full w-full text-xs text-base-content/50"
        this.el.appendChild(fb)
      }
      fb.textContent = message
      fb.style.display = ""
    },
    _clearFallback() {
      if (!this.el) return
      const fb = this.el.querySelector("[data-map-fallback]")
      if (fb) fb.style.display = "none"
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
  },

  GodViewControlsState: {
    storageKey: "sr:god_view:controls_collapsed",
    mounted() {
      this.syncFromStorage()
    },
    updated() {
      this.persistCurrentState()
    },
    syncFromStorage() {
      const stored = window.localStorage?.getItem(this.storageKey)
      if (stored !== "true" && stored !== "false") {
        this.persistCurrentState()
        return
      }

      const domCollapsed = this.el.dataset.collapsed === "true"
      const desired = stored === "true"
      if (desired !== domCollapsed) {
        this.pushEvent("set_controls_panel", {collapsed: desired})
      }
    },
    persistCurrentState() {
      const collapsed = this.el.dataset.collapsed === "true"
      window.localStorage?.setItem(this.storageKey, collapsed ? "true" : "false")
    },
  },

  GodViewBinaryStream: {
    mounted() {
      this.canvas = null
      this.summary = null
      this.details = null
      this.deck = null
      this.channel = null
      this.rendererMode = "initializing"
      this.filters = {root_cause: true, affected: true, healthy: true, unknown: true}
      this.lastGraph = null
      this.wasmEngine = null
      this.wasmReady = false
      this.selectedNodeIndex = null
      this.hoveredEdgeKey = null
      this.selectedEdgeKey = null
      this.pendingAnimationFrame = null
      this.zoomMode = "local"
      this.zoomTier = "local"
      this.hasAutoFit = false
      this.userCameraLocked = false
      this.dragState = null
      this.isProgrammaticViewUpdate = false
      this.lastSnapshotAt = 0
      this.channelJoined = false
      this.lastVisibleNodeCount = 0
      this.lastVisibleEdgeCount = 0
      this.pollTimer = null
      this.animationTimer = null
      this.animationPhase = 0
      this.layers = {mantle: true, crust: true, atmosphere: true, security: false}
      this.layoutMode = "auto"
      this.layoutRevision = null
      this.lastRevision = null
      this.lastTopologyStamp = null
      this.snapshotUrl = this.el.dataset.url || null
      this.pollIntervalMs = Number.parseInt(this.el.dataset.intervalMs || "5000", 10) || 5000
      this.visual = {
        bg: [10, 10, 10, 255],
        mantleEdge: [42, 42, 42, 170],
        crustArc: [214, 97, 255, 180],
        atmosphereParticle: [0, 224, 255, 185],
        nodeRoot: [255, 64, 64, 255],
        nodeAffected: [255, 162, 50, 255],
        nodeHealthy: [0, 224, 255, 255],
        nodeUnknown: [122, 141, 168, 255],
        label: [226, 232, 240, 230],
        edgeLabel: [148, 163, 184, 220],
        pulse: [255, 64, 64, 220],
      }
      this.viewState = {
        target: [320, 160, 0],
        zoom: 1.4,
        minZoom: -2,
        maxZoom: 5,
      }

      this.ensureDOM = this.ensureDOM.bind(this)
      this.resizeCanvas = this.resizeCanvas.bind(this)
      this.renderGraph = this.renderGraph.bind(this)
      this.ensureDeck = this.ensureDeck.bind(this)
      this.pollSnapshot = this.pollSnapshot.bind(this)
      this.startPolling = this.startPolling.bind(this)
      this.stopPolling = this.stopPolling.bind(this)
      this.visibilityMask = this.visibilityMask.bind(this)
      this.computeTraversalMask = this.computeTraversalMask.bind(this)
      this.handlePick = this.handlePick.bind(this)
      this.animateTransition = this.animateTransition.bind(this)
      this.parseSnapshotMessage = this.parseSnapshotMessage.bind(this)
      this.resolveZoomTier = this.resolveZoomTier.bind(this)
      this.setZoomTier = this.setZoomTier.bind(this)
      this.reshapeGraph = this.reshapeGraph.bind(this)
      this.reclusterByState = this.reclusterByState.bind(this)
      this.reclusterByGrid = this.reclusterByGrid.bind(this)
      this.clusterEdges = this.clusterEdges.bind(this)
      this.autoFitViewState = this.autoFitViewState.bind(this)
      this.ensureBitmapMetadata = this.ensureBitmapMetadata.bind(this)
      this.buildBitmapFallbackMetadata = this.buildBitmapFallbackMetadata.bind(this)
      this.startAnimationLoop = this.startAnimationLoop.bind(this)
      this.stopAnimationLoop = this.stopAnimationLoop.bind(this)
      this.buildPacketFlowInstances = this.buildPacketFlowInstances.bind(this)
      this.prepareGraphLayout = this.prepareGraphLayout.bind(this)
      this.shouldUseGeoLayout = this.shouldUseGeoLayout.bind(this)
      this.projectGeoLayout = this.projectGeoLayout.bind(this)
      this.forceDirectedLayout = this.forceDirectedLayout.bind(this)
      this.renderSelectionDetails = this.renderSelectionDetails.bind(this)
      this.geoGridData = this.geoGridData.bind(this)
      this.getNodeTooltip = this.getNodeTooltip.bind(this)
      this.handleHover = this.handleHover.bind(this)
      this.handleWheelZoom = this.handleWheelZoom.bind(this)
      this.handlePanStart = this.handlePanStart.bind(this)
      this.handlePanMove = this.handlePanMove.bind(this)
      this.handlePanEnd = this.handlePanEnd.bind(this)

      this.ensureDOM()
      this.resizeCanvas()
      window.addEventListener("resize", this.resizeCanvas)
      this.canvas.addEventListener("wheel", this.handleWheelZoom, {passive: false})
      this.canvas.addEventListener("pointerdown", this.handlePanStart)
      window.addEventListener("pointermove", this.handlePanMove)
      window.addEventListener("pointerup", this.handlePanEnd)
      window.addEventListener("pointercancel", this.handlePanEnd)
      this.startAnimationLoop()
      GodViewWasmEngine.init()
        .then((engine) => {
          this.wasmEngine = engine
          this.wasmReady = true
        })
        .catch((_err) => {
          this.wasmReady = false
          this.wasmEngine = null
        })
      this.handleEvent("god_view:set_filters", ({filters}) => {
        if (filters && typeof filters === "object") {
          this.filters = {
            root_cause: filters.root_cause !== false,
            affected: filters.affected !== false,
            healthy: filters.healthy !== false,
            unknown: filters.unknown !== false,
          }
          if (this.lastGraph) this.renderGraph(this.lastGraph)
        }
      })
      this.handleEvent("god_view:set_zoom_mode", ({mode}) => {
        const normalized = mode === "global" || mode === "regional" || mode === "local" ? mode : "auto"
        this.zoomMode = normalized

        if (!this.deck) return

        if (normalized === "auto") {
          this.setZoomTier(this.resolveZoomTier(this.viewState.zoom || 0), true)
          return
        }

        const zoomByTier = {global: -0.9, regional: 0.35, local: 1.65}
        this.viewState = {
          ...this.viewState,
          zoom: zoomByTier[normalized] || this.viewState.zoom,
        }
        this.userCameraLocked = true
        this.isProgrammaticViewUpdate = true
        this.deck.setProps({viewState: this.viewState})
        this.setZoomTier(normalized, true)
      })
      this.handleEvent("god_view:set_layers", ({layers}) => {
        if (layers && typeof layers === "object") {
          this.layers = {
            mantle: layers.mantle !== false,
            crust: layers.crust !== false,
            atmosphere: layers.atmosphere !== false,
            security: layers.security !== false,
          }
          if (this.lastGraph) this.renderGraph(this.lastGraph)
        }
      })

      if (!window.godViewSocket) {
        window.godViewSocket = new Socket("/socket", {params: {_csrf_token: csrfToken}})
        window.godViewSocket.connect()
      }

      this.channel = window.godViewSocket.channel("topology:god_view", {})
      this.channel.on("snapshot", (msg) => this.handleSnapshot(msg))
      this.channel.on("snapshot_error", (msg) => {
        this.summary.textContent = "snapshot stream error"
        this.pushEvent("god_view_stream_error", {reason: msg?.reason || "snapshot_error"})
        this.pollSnapshot()
      })
      this.channel
        .join()
        .receive("ok", () => {
          this.channelJoined = true
          this.summary.textContent = "topology channel connected"
          this.startPolling()
        })
        .receive("error", (reason) => {
          this.channelJoined = false
          this.summary.textContent = "topology channel failed"
          this.pushEvent("god_view_stream_error", {reason: reason?.reason || "join_failed"})
          this.startPolling(true)
        })
    },
    destroyed() {
      window.removeEventListener("resize", this.resizeCanvas)
      if (this.canvas) this.canvas.removeEventListener("wheel", this.handleWheelZoom)
      if (this.canvas) this.canvas.removeEventListener("pointerdown", this.handlePanStart)
      window.removeEventListener("pointermove", this.handlePanMove)
      window.removeEventListener("pointerup", this.handlePanEnd)
      window.removeEventListener("pointercancel", this.handlePanEnd)
      this.stopAnimationLoop()
      this.stopPolling()
      if (this.channel) {
        this.channel.leave()
        this.channel = null
      }
      if (this.pendingAnimationFrame) {
        cancelAnimationFrame(this.pendingAnimationFrame)
        this.pendingAnimationFrame = null
      }
      if (this.deck) {
        this.deck.finalize()
        this.deck = null
      }
    },
    startAnimationLoop() {
      if (this.animationTimer) return
      const tick = () => {
        this.animationPhase = performance.now() / 1000
        if (this.deck && this.lastGraph) {
          try {
            this.renderGraph(this.lastGraph)
          } catch (error) {
            if (this.summary) this.summary.textContent = `animation render error: ${String(error)}`
          }
        }
        this.animationTimer = window.requestAnimationFrame(tick)
      }
      this.animationTimer = window.requestAnimationFrame(tick)
    },
    stopAnimationLoop() {
      if (!this.animationTimer) return
      window.cancelAnimationFrame(this.animationTimer)
      this.animationTimer = null
    },
    handlePanStart(event) {
      if (!this.deck) return
      if (event.button !== 0) return

      event.preventDefault()
      this.dragState = {
        pointerId: event.pointerId,
        lastX: Number(event.clientX || 0),
        lastY: Number(event.clientY || 0),
      }
      this.canvas.style.cursor = "grabbing"
      if (typeof this.canvas.setPointerCapture === "function") {
        try {
          this.canvas.setPointerCapture(event.pointerId)
        } catch (_err) {
          // Ignore capture failures and continue with window listeners.
        }
      }
    },
    handlePanMove(event) {
      if (!this.deck || !this.dragState) return
      if (event.pointerId !== this.dragState.pointerId) return

      event.preventDefault()
      const clientX = Number(event.clientX || 0)
      const clientY = Number(event.clientY || 0)
      const dx = clientX - this.dragState.lastX
      const dy = clientY - this.dragState.lastY
      this.dragState.lastX = clientX
      this.dragState.lastY = clientY

      const zoom = Number(this.viewState.zoom || 0)
      const scale = Math.max(0.0001, 2 ** zoom)
      const [targetX = 0, targetY = 0, targetZ = 0] = this.viewState.target || [0, 0, 0]

      this.viewState = {
        ...this.viewState,
        target: [targetX - dx / scale, targetY - dy / scale, targetZ],
      }
      this.userCameraLocked = true
      this.isProgrammaticViewUpdate = true
      this.deck.setProps({viewState: this.viewState})
    },
    handlePanEnd(event) {
      if (!this.dragState) return
      if (event && event.pointerId !== this.dragState.pointerId) return

      if (this.canvas && typeof this.canvas.releasePointerCapture === "function") {
        try {
          this.canvas.releasePointerCapture(this.dragState.pointerId)
        } catch (_err) {
          // Ignore capture release failures.
        }
      }
      this.dragState = null
      if (this.canvas) this.canvas.style.cursor = "grab"
    },
    handleWheelZoom(event) {
      if (!this.deck) return
      event.preventDefault()

      const delta = Number(event.deltaY || 0)
      const direction = delta > 0 ? -1 : 1
      const zoomStep = 0.12
      const nextZoom = (this.viewState.zoom || 0) + direction * zoomStep
      const clamped = Math.max(this.viewState.minZoom, Math.min(this.viewState.maxZoom, nextZoom))

      this.viewState = {...this.viewState, zoom: clamped}
      this.userCameraLocked = true
      this.isProgrammaticViewUpdate = true
      this.deck.setProps({viewState: this.viewState})
      if (this.zoomMode === "auto") {
        this.setZoomTier(this.resolveZoomTier(clamped), true)
      }
    },
    handleSnapshot(msg) {
      const startedAt = performance.now()
      try {
        const snapshot = this.parseSnapshotMessage(msg)
        const bytes = snapshot?.payload
        if (!bytes || bytes.byteLength === 0) throw new Error("missing payload")

        const decodeStart = performance.now()
        const rawGraph = this.decodeArrowGraph(bytes)
        const revision = Number.isFinite(Number(snapshot.revision)) ? Number(snapshot.revision) : this.lastRevision
        const topologyStamp = this.graphTopologyStamp(rawGraph)
        const graph = this.prepareGraphLayout(rawGraph, revision, topologyStamp)
        const decodeMs = Math.round((performance.now() - decodeStart) * 100) / 100
        const bitmapMetadata = this.ensureBitmapMetadata(snapshot.bitmapMetadata, graph.nodes)

        const renderStart = performance.now()
        const previousGraph = this.lastGraph
        this.lastGraph = graph
        if (this.sameTopology(previousGraph, graph, topologyStamp, revision)) {
          this.renderGraph(graph)
        } else {
          this.animateTransition(previousGraph, graph)
        }
        this.lastRevision = revision
        this.lastTopologyStamp = topologyStamp
        this.lastSnapshotAt = Date.now()
        this.summary.textContent =
          `schema=${snapshot.schemaVersion} revision=${snapshot.revision} nodes=${graph.nodes.length} ` +
          `edges=${graph.edges.length} payload=${bytes.byteLength}B selected=` +
          `${this.selectedNodeIndex === null ? "none" : this.selectedNodeIndex} visible=` +
          `${this.lastVisibleNodeCount}/${graph.nodes.length}`
        const renderMs = Math.round((performance.now() - renderStart) * 100) / 100
        const networkMs = Math.round((performance.now() - startedAt) * 100) / 100

        this.pushEvent("god_view_stream_stats", {
          schema_version: snapshot.schemaVersion,
          revision: snapshot.revision,
          node_count: graph.nodes.length,
          edge_count: graph.edges.length,
          generated_at: snapshot.generatedAt,
          bitmap_metadata: bitmapMetadata,
          bytes: bytes.byteLength,
          renderer_mode: this.rendererMode,
          zoom_tier: this.zoomTier,
          zoom_mode: this.zoomMode,
          network_ms: networkMs,
          decode_ms: decodeMs,
          render_ms: renderMs,
        })
      } catch (error) {
        this.summary.textContent = "snapshot decode failed"
        this.pushEvent("god_view_stream_error", {reason: "decode_error", message: `${error}`})
      }
    },
    parseSnapshotMessage(msg) {
      if (msg instanceof ArrayBuffer) {
        return this.parseBinarySnapshotFrame(msg)
      }
      if (msg?.binary instanceof ArrayBuffer) {
        return this.parseBinarySnapshotFrame(msg.binary)
      }
      if (ArrayBuffer.isView(msg)) {
        return this.parseBinarySnapshotFrame(
          msg.buffer.slice(msg.byteOffset, msg.byteOffset + msg.byteLength),
        )
      }
      if (Array.isArray(msg) && msg[0] === "binary" && typeof msg[1] === "string") {
        return this.parseBinarySnapshotFrame(this.base64ToArrayBuffer(msg[1]))
      }
      throw new Error("snapshot payload is not a binary frame")
    },
    base64ToArrayBuffer(b64) {
      const binary = atob(b64)
      const bytes = new Uint8Array(binary.length)
      for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
      return bytes.buffer
    },
    startPolling(force = false) {
      if (!this.snapshotUrl) return
      if (this.pollTimer && !force) return
      if (force && this.pollTimer) {
        window.clearInterval(this.pollTimer)
        this.pollTimer = null
      }
      this.pollSnapshot()
      this.pollTimer = window.setInterval(this.pollSnapshot, this.pollIntervalMs)
    },
    stopPolling() {
      if (!this.pollTimer) return
      window.clearInterval(this.pollTimer)
      this.pollTimer = null
    },
    async pollSnapshot() {
      if (!this.snapshotUrl) return
      if (this.channelJoined && this.lastSnapshotAt > 0) {
        const staleAfterMs = Math.max(this.pollIntervalMs * 2, 10_000)
        if (Date.now() - this.lastSnapshotAt < staleAfterMs) return
      }
      const startedAt = performance.now()
      try {
        const response = await fetch(this.snapshotUrl, {
          method: "GET",
          credentials: "same-origin",
          cache: "no-store",
          headers: {Accept: "application/octet-stream"},
        })
        if (!response.ok) {
          throw new Error(`snapshot_http_${response.status}`)
        }

        const buffer = await response.arrayBuffer()
        if (!buffer || buffer.byteLength === 0) {
          throw new Error("snapshot_empty")
        }

        const revisionHeader = response.headers.get("x-sr-god-view-revision")
        const parsedRevision = revisionHeader ? Number(revisionHeader) : null
        const revision = Number.isFinite(parsedRevision) ? parsedRevision : this.lastRevision

        const decodeStart = performance.now()
        const rawGraph = this.decodeArrowGraph(new Uint8Array(buffer))
        const topologyStamp = this.graphTopologyStamp(rawGraph)
        const graph = this.prepareGraphLayout(rawGraph, revision, topologyStamp)
        const decodeMs = Math.round((performance.now() - decodeStart) * 100) / 100

        const renderStart = performance.now()
        const previousGraph = this.lastGraph
        this.lastGraph = graph
        if (this.sameTopology(previousGraph, graph, topologyStamp, revision)) {
          this.renderGraph(graph)
        } else {
          this.animateTransition(previousGraph, graph)
        }
        this.lastRevision = revision
        this.lastTopologyStamp = topologyStamp
        this.lastSnapshotAt = Date.now()
        const renderMs = Math.round((performance.now() - renderStart) * 100) / 100
        const networkMs = Math.round((performance.now() - startedAt) * 100) / 100

        const schemaHeader = response.headers.get("x-sr-god-view-schema")

        const bitmapMetadata = {
          root_cause: {
            bytes: Number(response.headers.get("x-sr-god-view-bitmap-root-bytes") || 0),
            count: Number(response.headers.get("x-sr-god-view-bitmap-root-count") || 0),
          },
          affected: {
            bytes: Number(response.headers.get("x-sr-god-view-bitmap-affected-bytes") || 0),
            count: Number(response.headers.get("x-sr-god-view-bitmap-affected-count") || 0),
          },
          healthy: {
            bytes: Number(response.headers.get("x-sr-god-view-bitmap-healthy-bytes") || 0),
            count: Number(response.headers.get("x-sr-god-view-bitmap-healthy-count") || 0),
          },
          unknown: {
            bytes: Number(response.headers.get("x-sr-god-view-bitmap-unknown-bytes") || 0),
            count: Number(response.headers.get("x-sr-god-view-bitmap-unknown-count") || 0),
          },
        }
        const effectiveBitmapMetadata = this.ensureBitmapMetadata(bitmapMetadata, graph.nodes)

        this.summary.textContent =
          `snapshot revision=${revisionHeader || "—"} nodes=${graph.nodes.length} ` +
          `edges=${graph.edges.length} payload=${buffer.byteLength}B selected=` +
          `${this.selectedNodeIndex === null ? "none" : this.selectedNodeIndex} visible=` +
          `${this.lastVisibleNodeCount}/${graph.nodes.length}`

        this.pushEvent("god_view_stream_stats", {
          schema_version: schemaHeader ? Number(schemaHeader) : null,
          revision: revisionHeader ? Number(revisionHeader) : null,
          node_count: graph.nodes.length,
          edge_count: graph.edges.length,
          generated_at: response.headers.get("x-sr-god-view-generated-at"),
          bitmap_metadata: effectiveBitmapMetadata,
          bytes: buffer.byteLength,
          renderer_mode: this.rendererMode,
          zoom_tier: this.zoomTier,
          zoom_mode: this.zoomMode,
          network_ms: networkMs,
          decode_ms: decodeMs,
          render_ms: renderMs,
        })
      } catch (error) {
        this.summary.textContent = "snapshot polling error"
        if (!this.channelJoined || this.lastSnapshotAt === 0) {
          this.pushEvent("god_view_stream_error", {
            reason: "poll_error",
            message: `${error}`,
          })
        }
      }
    },
    parseBinarySnapshotFrame(buffer) {
      const bytes = new Uint8Array(buffer)
      if (bytes.byteLength < 53) throw new Error("invalid binary snapshot frame")

      const magic = String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3])
      if (magic !== "GVB1") throw new Error("unexpected binary snapshot magic")

      const view = new DataView(buffer)
      const schemaVersion = view.getUint8(4)
      const revision = Number(view.getBigUint64(5, false))
      const generatedAtMs = Number(view.getBigInt64(13, false))
      const rootBytes = view.getUint32(21, false)
      const affectedBytes = view.getUint32(25, false)
      const healthyBytes = view.getUint32(29, false)
      const unknownBytes = view.getUint32(33, false)
      const rootCount = view.getUint32(37, false)
      const affectedCount = view.getUint32(41, false)
      const healthyCount = view.getUint32(45, false)
      const unknownCount = view.getUint32(49, false)
      const generatedAt = Number.isFinite(generatedAtMs)
        ? new Date(generatedAtMs).toISOString()
        : null

      return {
        schemaVersion,
        revision,
        generatedAt,
        bitmapMetadata: {
          root_cause: {bytes: rootBytes, count: rootCount},
          affected: {bytes: affectedBytes, count: affectedCount},
          healthy: {bytes: healthyBytes, count: healthyCount},
          unknown: {bytes: unknownBytes, count: unknownCount},
        },
        payload: bytes.slice(53),
      }
    },
    decodeArrowGraph(bytes) {
      const table = tableFromIPC(bytes)
      const rowType = table.getChild("row_type")
      const nodeX = table.getChild("node_x")
      const nodeY = table.getChild("node_y")
      const nodeState = table.getChild("node_state")
      const nodeLabel = table.getChild("node_label")
      const nodePps = table.getChild("node_pps")
      const nodeOperUp = table.getChild("node_oper_up")
      const nodeDetails = table.getChild("node_details")
      const edgeSource = table.getChild("edge_source")
      const edgeTarget = table.getChild("edge_target")
      const edgePps = table.getChild("edge_pps")
      const edgeFlowBps = table.getChild("edge_flow_bps")
      const edgeCapacityBps = table.getChild("edge_capacity_bps")
      const edgeLabel = table.getChild("edge_label")

      const nodes = []
      const edges = []
      const edgeSourceIndex = []
      const edgeTargetIndex = []
      const rowCount = table.numRows || 0

      for (let i = 0; i < rowCount; i += 1) {
        const t = rowType?.get(i)
        if (t === 0) {
          const fallbackLabel = `node-${nodes.length + 1}`
          let parsedDetails = {}
          const rawDetails = nodeDetails?.get(i)
          if (typeof rawDetails === "string" && rawDetails.trim() !== "") {
            try {
              parsedDetails = JSON.parse(rawDetails)
            } catch (_err) {
              parsedDetails = {}
            }
          }
          const detailLat = Number(parsedDetails?.geo_lat)
          const detailLon = Number(parsedDetails?.geo_lon)
          nodes.push({
            id: this.normalizeDisplayLabel(parsedDetails?.id, fallbackLabel),
            x: Number(nodeX?.get(i) || 0),
            y: Number(nodeY?.get(i) || 0),
            state: Number(nodeState?.get(i) || 3),
            label: this.normalizeDisplayLabel(nodeLabel?.get(i), fallbackLabel),
            pps: Number(nodePps?.get(i) || 0),
            operUp: Number(nodeOperUp?.get(i) || 0),
            geoLat: Number.isFinite(detailLat) ? detailLat : NaN,
            geoLon: Number.isFinite(detailLon) ? detailLon : NaN,
            details: parsedDetails,
          })
        } else if (t === 1) {
          const source = Number(edgeSource?.get(i) || 0)
          const target = Number(edgeTarget?.get(i) || 0)
          edges.push({
            source,
            target,
            flowPps: Number(edgePps?.get(i) || 0),
            flowBps: Number(edgeFlowBps?.get(i) || 0),
            capacityBps: Number(edgeCapacityBps?.get(i) || 0),
            label: this.normalizeDisplayLabel(edgeLabel?.get(i), ""),
          })
          edgeSourceIndex.push(source)
          edgeTargetIndex.push(target)
        }
      }

      return {
        nodes,
        edges,
        edgeSourceIndex: Uint32Array.from(edgeSourceIndex),
        edgeTargetIndex: Uint32Array.from(edgeTargetIndex),
      }
    },
    ensureDOM() {
      if (this.canvas && this.summary) return

      this.el.innerHTML = ""
      this.el.classList.add("relative")
      this.canvas = document.createElement("canvas")
      this.canvas.className = "h-full w-full rounded border border-base-300 bg-neutral"
      this.canvas.style.cursor = "grab"

      this.summary = document.createElement("div")
      this.summary.className =
        "pointer-events-none absolute bottom-2 left-2 rounded bg-base-100/85 px-2 py-1 text-[11px] opacity-90"
      this.summary.textContent = "waiting for snapshot..."

      this.details = document.createElement("div")
      this.details.className =
        "absolute left-2 top-2 z-30 max-w-sm whitespace-pre-line rounded border border-primary/30 bg-base-100/95 px-3 py-2 text-xs shadow-xl hidden"
      this.details.textContent = "Select a node for details"

      this.el.appendChild(this.canvas)
      this.el.appendChild(this.summary)
      this.el.appendChild(this.details)
    },
    resizeCanvas() {
      if (!this.canvas) return
      const width = Math.max(320, Math.floor(this.el.clientWidth || 0))
      const height = Math.max(260, Math.floor(this.el.clientHeight || 0))
      this.canvas.style.width = `${width}px`
      this.canvas.style.height = `${height}px`
      if (this.deck) {
        this.deck.setProps({width, height})
        this.deck.redraw(true)
      }
    },
    ensureDeck() {
      if (this.deck) return
      this.ensureDOM()
      const width = Math.max(320, Math.floor(this.el.clientWidth || 0))
      const height = Math.max(260, Math.floor(this.el.clientHeight || 0))
      const mode = navigator.gpu ? "webgpu" : "webgl"
      this.rendererMode = mode

      try {
        this.deck = new Deck({
          canvas: this.canvas,
          width,
          height,
          views: new OrthographicView({id: "god-view-ortho"}),
          controller: {
            dragPan: true,
            dragRotate: false,
            scrollZoom: true,
            doubleClickZoom: false,
            touchZoom: true,
            touchRotate: false,
            keyboard: false,
          },
          useDevicePixels: true,
          initialViewState: this.viewState,
          parameters: {
            clearColor: this.visual.bg,
            blend: true,
            blendFunc: [770, 771],
          },
          getTooltip: this.getNodeTooltip,
          onHover: this.handleHover,
          onClick: this.handlePick,
          onViewStateChange: ({viewState}) => {
            this.viewState = viewState
            if (!this.isProgrammaticViewUpdate) this.userCameraLocked = true
            this.isProgrammaticViewUpdate = false
            if (this.zoomMode === "auto") {
              this.setZoomTier(this.resolveZoomTier(viewState.zoom || 0), false)
            }
          },
        })
      } catch (_error) {
        this.rendererMode = "webgl-fallback"
        this.deck = new Deck({
          canvas: this.canvas,
          width,
          height,
          views: new OrthographicView({id: "god-view-ortho"}),
          controller: {
            dragPan: true,
            dragRotate: false,
            scrollZoom: true,
            doubleClickZoom: false,
            touchZoom: true,
            touchRotate: false,
            keyboard: false,
          },
          useDevicePixels: true,
          initialViewState: this.viewState,
          parameters: {
            clearColor: this.visual.bg,
            blend: true,
            blendFunc: [770, 771],
          },
          getTooltip: this.getNodeTooltip,
          onHover: this.handleHover,
          onClick: this.handlePick,
          onViewStateChange: ({viewState}) => {
            this.viewState = viewState
            if (!this.isProgrammaticViewUpdate) this.userCameraLocked = true
            this.isProgrammaticViewUpdate = false
            if (this.zoomMode === "auto") {
              this.setZoomTier(this.resolveZoomTier(viewState.zoom || 0), false)
            }
          },
        })
      }
    },
    resolveZoomTier(zoom) {
      if (zoom < -0.3) return "global"
      if (zoom < 1.1) return "regional"
      return "local"
    },
    setZoomTier(nextTier, forceRender) {
      if (!nextTier) return
      if (!forceRender && this.zoomTier === nextTier) return
      this.zoomTier = nextTier
      if (nextTier !== "local") this.selectedNodeIndex = null
      if (this.lastGraph) this.renderGraph(this.lastGraph)
    },
    reshapeGraph(graph) {
      const tier = this.zoomMode === "auto" ? this.zoomTier : this.zoomMode
      if (tier === "local") return {shape: "local", ...graph}
      if (tier === "global") return this.reclusterByState(graph)
      return this.reclusterByGrid(graph)
    },
    reclusterByState(graph) {
      const clusters = new Map()
      const clusterByNode = new Array(graph.nodes.length)

      graph.nodes.forEach((node, index) => {
        const key = `state:${node.state}`
        const existing = clusters.get(key) || {
          id: key,
          sumX: 0,
          sumY: 0,
          count: 0,
          sumPps: 0,
          upCount: 0,
          downCount: 0,
          stateHistogram: {0: 0, 1: 0, 2: 0, 3: 0},
          sampleNode: null,
        }
        existing.sumX += node.x
        existing.sumY += node.y
        existing.count += 1
        existing.sumPps += Number(node.pps || 0)
        if (Number(node.operUp) === 1) existing.upCount += 1
        if (Number(node.operUp) === 2) existing.downCount += 1
        existing.stateHistogram[node.state] = (existing.stateHistogram[node.state] || 0) + 1
        if (!existing.sampleNode && node.details) existing.sampleNode = node
        clusters.set(key, existing)
        clusterByNode[index] = key
      })

      const nodes = Array.from(clusters.values()).map((cluster) => ({
        id: cluster.id,
        x: cluster.sumX / cluster.count,
        y: cluster.sumY / cluster.count,
        state: Number(cluster.id.split(":")[1]),
        clusterCount: cluster.count,
        pps: cluster.sumPps,
        operUp: cluster.upCount > 0 ? 1 : (cluster.downCount > 0 ? 2 : 0),
        label: `${this.stateDisplayName(Number(cluster.id.split(":")[1]))} Cluster`,
        details: this.clusterDetails(cluster, "global"),
      }))

      const edges = this.clusterEdges(graph.edges, clusterByNode)
      return {shape: "global", nodes, edges}
    },
    reclusterByGrid(graph) {
      const cell = 180
      const clusters = new Map()
      const clusterByNode = new Array(graph.nodes.length)

      graph.nodes.forEach((node, index) => {
        const gx = Math.floor(node.x / cell)
        const gy = Math.floor(node.y / cell)
        const key = `grid:${gx}:${gy}`
        const existing = clusters.get(key) || {
          id: key,
          sumX: 0,
          sumY: 0,
          count: 0,
          sumPps: 0,
          upCount: 0,
          downCount: 0,
          stateHistogram: {0: 0, 1: 0, 2: 0, 3: 0},
          sampleNode: null,
        }
        existing.sumX += node.x
        existing.sumY += node.y
        existing.count += 1
        existing.sumPps += Number(node.pps || 0)
        if (Number(node.operUp) === 1) existing.upCount += 1
        if (Number(node.operUp) === 2) existing.downCount += 1
        existing.stateHistogram[node.state] = (existing.stateHistogram[node.state] || 0) + 1
        if (!existing.sampleNode && node.details) existing.sampleNode = node
        clusters.set(key, existing)
        clusterByNode[index] = key
      })

      const nodes = Array.from(clusters.values()).map((cluster) => {
        const dominantState = [0, 1, 2, 3].sort(
          (a, b) => (cluster.stateHistogram[b] || 0) - (cluster.stateHistogram[a] || 0),
        )[0]
        const keyParts = String(cluster.id).split(":")
        const gridX = keyParts.length >= 3 ? keyParts[1] : "0"
        const gridY = keyParts.length >= 3 ? keyParts[2] : "0"
        return {
          id: cluster.id,
          x: cluster.sumX / cluster.count,
          y: cluster.sumY / cluster.count,
          state: dominantState,
          clusterCount: cluster.count,
          pps: cluster.sumPps,
          operUp: cluster.upCount > 0 ? 1 : (cluster.downCount > 0 ? 2 : 0),
          label: `Regional Cluster ${gridX},${gridY}`,
          details: this.clusterDetails(cluster, "regional"),
        }
      })

      const edges = this.clusterEdges(graph.edges, clusterByNode)
      return {shape: "regional", nodes, edges}
    },
    clusterDetails(cluster, scope) {
      const sample = cluster.sampleNode?.details || {}
      const sampleLabel = cluster.sampleNode?.label || null
      const sampleIp = sample.ip || null
      const sampleType = sample.type || null
      const bucketType = scope === "global" ? "State Cluster" : "Regional Cluster"
      return {
        id: cluster.id,
        ip: sampleIp || "cluster",
        type: sampleType || bucketType,
        model: sample.model || null,
        vendor: sample.vendor || null,
        asn: sample.asn || null,
        geo_city: sample.geo_city || null,
        geo_country: sample.geo_country || null,
        last_seen: sample.last_seen || null,
        cluster_scope: scope,
        cluster_count: cluster.count,
        sample_label: sampleLabel,
      }
    },
    clusterEdges(edges, clusterByNode) {
      const acc = new Map()
      edges.forEach((edge) => {
        const a = clusterByNode[edge.source]
        const b = clusterByNode[edge.target]
        if (!a || !b || a === b) return
        const key = a < b ? `${a}|${b}` : `${b}|${a}`
        const current = acc.get(key) || {
          sourceCluster: a < b ? a : b,
          targetCluster: a < b ? b : a,
          weight: 0,
          flowPps: 0,
          flowBps: 0,
          capacityBps: 0,
        }
        current.weight += 1
        current.flowPps += Number(edge.flowPps || 0)
        current.flowBps += Number(edge.flowBps || 0)
        current.capacityBps += Number(edge.capacityBps || 0)
        acc.set(key, current)
      })
      return Array.from(acc.values())
    },
    animateTransition(previousGraph, nextGraph) {
      if (this.pendingAnimationFrame) {
        cancelAnimationFrame(this.pendingAnimationFrame)
        this.pendingAnimationFrame = null
      }

      const shouldAnimate =
        previousGraph &&
        previousGraph.nodes.length > 0 &&
        previousGraph.nodes.length === nextGraph.nodes.length

      if (!shouldAnimate) {
        this.renderGraph(nextGraph)
        return
      }

      const durationMs = 220
      const prevXY = this.xyBuffer(previousGraph.nodes)
      const nextXY = this.xyBuffer(nextGraph.nodes)
      const startedAt = performance.now()

      const step = (now) => {
        const t = Math.min((now - startedAt) / durationMs, 1)
        const frameNodes = this.interpolateNodes(previousGraph.nodes, nextGraph.nodes, prevXY, nextXY, t)
        this.renderGraph({...nextGraph, nodes: frameNodes})

        if (t < 1) {
          this.pendingAnimationFrame = requestAnimationFrame(step)
        } else {
          this.pendingAnimationFrame = null
        }
      }

      this.pendingAnimationFrame = requestAnimationFrame(step)
    },
    xyBuffer(nodes) {
      const xy = new Float32Array(nodes.length * 2)
      for (let i = 0; i < nodes.length; i += 1) {
        xy[i * 2] = nodes[i].x
        xy[i * 2 + 1] = nodes[i].y
      }
      return xy
    },
    interpolateNodes(previousNodes, nextNodes, prevXY, nextXY, t) {
      if (this.wasmReady && this.wasmEngine) {
        try {
          const xy = this.wasmEngine.computeInterpolatedXY(prevXY, nextXY, t)
          const out = new Array(nextNodes.length)
          for (let i = 0; i < nextNodes.length; i += 1) {
            out[i] = {
              ...(nextNodes[i] || {}),
              x: xy[i * 2],
              y: xy[i * 2 + 1],
            }
          }
          return out
        } catch (_err) {
          this.wasmReady = false
        }
      }

      const clamped = Math.max(0, Math.min(t, 1))
      const out = new Array(nextNodes.length)
      for (let i = 0; i < nextNodes.length; i += 1) {
        const a = previousNodes[i]
        const b = nextNodes[i]
        out[i] = {
          ...(b || {}),
          x: a.x + (b.x - a.x) * clamped,
          y: a.y + (b.y - a.y) * clamped,
        }
      }
      return out
    },
    prepareGraphLayout(graph, revision, topologyStamp) {
      if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return graph
      const stamp =
        typeof topologyStamp === "string" && topologyStamp.length > 0
          ? topologyStamp
          : this.graphTopologyStamp(graph)

      if (this.lastGraph && stamp === this.lastTopologyStamp) {
        const reused = this.reusePreviousPositions(graph, this.lastGraph)
        reused._layoutMode = this.layoutMode || "auto"
        reused._layoutRevision = revision
        return reused
      }

      if (this.lastGraph && Number.isFinite(revision) && this.layoutRevision === revision) {
        const reused = this.reusePreviousPositions(graph, this.lastGraph)
        reused._layoutMode = this.layoutMode || "auto"
        reused._layoutRevision = revision
        return reused
      }
      if (graph._layoutRevision && graph._layoutRevision === revision) return graph

      const mode = this.shouldUseGeoLayout(graph) ? "geo" : "force"
      const laidOut = mode === "geo" ? this.projectGeoLayout(graph) : this.forceDirectedLayout(graph)
      laidOut._layoutMode = mode
      laidOut._layoutRevision = revision
      this.layoutMode = mode
      this.layoutRevision = revision
      return laidOut
    },
    graphTopologyStamp(graph) {
      if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges)) return "0:0"
      let nodeHash = 0
      for (let i = 0; i < graph.nodes.length; i += 1) {
        const id = String(graph.nodes[i]?.id || "")
        for (let j = 0; j < id.length; j += 1) nodeHash = ((nodeHash << 5) - nodeHash + id.charCodeAt(j)) | 0
      }
      let edgeHash = 0
      for (let i = 0; i < graph.edges.length; i += 1) {
        const s = Number(graph.edges[i]?.source || 0)
        const t = Number(graph.edges[i]?.target || 0)
        edgeHash = (((edgeHash << 5) - edgeHash + s * 31 + t * 131) | 0)
      }
      return `${graph.nodes.length}:${graph.edges.length}:${nodeHash}:${edgeHash}`
    },
    sameTopology(previousGraph, nextGraph, stamp, revision) {
      if (!previousGraph || !nextGraph) return false
      if (!Number.isFinite(revision) || !Number.isFinite(this.lastRevision)) return false
      return (
        revision === this.lastRevision &&
        stamp === this.lastTopologyStamp &&
        previousGraph.nodes.length === nextGraph.nodes.length &&
        previousGraph.edges.length === nextGraph.edges.length
      )
    },
    reusePreviousPositions(nextGraph, previousGraph) {
      if (!nextGraph || !previousGraph) return nextGraph
      const byId = new Map((previousGraph.nodes || []).map((n) => [n.id, n]))
      const nodes = (nextGraph.nodes || []).map((n) => {
        const prev = byId.get(n.id)
        if (!prev) return n
        return {...n, x: Number(prev.x || n.x || 0), y: Number(prev.y || n.y || 0)}
      })
      return {...nextGraph, nodes}
    },
    shouldUseGeoLayout(graph) {
      const nodes = graph?.nodes || []
      if (nodes.length < 6) return false
      let geoCount = 0
      for (const node of nodes) {
        if (Number.isFinite(node?.geoLat) && Number.isFinite(node?.geoLon)) geoCount += 1
      }
      return geoCount / Math.max(1, nodes.length) >= 0.25
    },
    projectGeoLayout(graph) {
      const width = 640
      const height = 320
      const pad = 20
      const nodes = graph.nodes.map((node) => ({...node}))
      let fallbackIdx = 0
      for (const node of nodes) {
        const lat = Number(node?.geoLat)
        const lon = Number(node?.geoLon)
        if (Number.isFinite(lat) && Number.isFinite(lon)) {
          const clampedLat = Math.max(-85, Math.min(85, lat))
          const x = ((lon + 180) / 360) * (width - pad * 2) + pad
          const rad = clampedLat * (Math.PI / 180)
          const mercY = (1 - Math.log(Math.tan(Math.PI / 4 + rad / 2)) / Math.PI) / 2
          const y = mercY * (height - pad * 2) + pad
          node.x = x
          node.y = y
        } else {
          const angle = fallbackIdx * 0.72
          const ring = 22 + (fallbackIdx % 14) * 7
          node.x = width / 2 + Math.cos(angle) * ring
          node.y = height / 2 + Math.sin(angle) * ring
          fallbackIdx += 1
        }
      }
      return {...graph, nodes}
    },
    forceDirectedLayout(graph) {
      const width = 640
      const height = 320
      const pad = 20
      const nodes = graph.nodes.map((node) => ({...node}))
      if (nodes.length <= 2) return {...graph, nodes}

      const links = graph.edges
        .filter((edge) => Number.isInteger(edge?.source) && Number.isInteger(edge?.target))
        .map((edge) => ({source: edge.source, target: edge.target, weight: Number(edge.weight || 1)}))

      const simulation = d3.forceSimulation(nodes)
        .alphaMin(0.02)
        .force("charge", d3.forceManyBody().strength(nodes.length > 500 ? -20 : -45))
        .force("link", d3.forceLink(links).id((_d, i) => i).distance((l) => {
          const w = Number(l?.weight || 1)
          return Math.max(22, Math.min(90, 52 - Math.log2(Math.max(1, w)) * 8))
        }).strength(0.34))
        .force("collide", d3.forceCollide().radius(7).strength(0.8))
        .force("center", d3.forceCenter(width / 2, height / 2))
        .stop()

      const iterations = Math.min(220, Math.max(70, Math.round(30 + nodes.length * 0.32)))
      for (let i = 0; i < iterations; i += 1) simulation.tick()

      const xs = nodes.map((n) => Number(n.x || 0))
      const ys = nodes.map((n) => Number(n.y || 0))
      const minX = Math.min(...xs)
      const maxX = Math.max(...xs)
      const minY = Math.min(...ys)
      const maxY = Math.max(...ys)
      const dx = Math.max(1, maxX - minX)
      const dy = Math.max(1, maxY - minY)
      for (const n of nodes) {
        n.x = pad + ((Number(n.x || 0) - minX) / dx) * (width - pad * 2)
        n.y = pad + ((Number(n.y || 0) - minY) / dy) * (height - pad * 2)
      }

      return {...graph, nodes}
    },
    geoGridData() {
      if (this.layoutMode !== "geo") return []
      const width = 640
      const height = 320
      const pad = 20
      const project = (lat, lon) => {
        const clampedLat = Math.max(-85, Math.min(85, lat))
        const x = ((lon + 180) / 360) * (width - pad * 2) + pad
        const rad = clampedLat * (Math.PI / 180)
        const mercY = (1 - Math.log(Math.tan(Math.PI / 4 + rad / 2)) / Math.PI) / 2
        const y = mercY * (height - pad * 2) + pad
        return [x, y, -2]
      }

      const lines = []
      for (let lon = -150; lon <= 150; lon += 30) {
        for (let lat = -80; lat < 80; lat += 10) {
          lines.push({sourcePosition: project(lat, lon), targetPosition: project(lat + 10, lon)})
        }
      }
      for (let lat = -60; lat <= 60; lat += 20) {
        for (let lon = -180; lon < 180; lon += 15) {
          lines.push({sourcePosition: project(lat, lon), targetPosition: project(lat, lon + 15)})
        }
      }
      return lines
    },
    getNodeTooltip({object, layer}) {
      if (!object) return null
      if (layer?.id === "god-view-edges-mantle" || layer?.id === "god-view-edges-crust") {
        const connection = object.connectionLabel || "LINK"
        return {text: `${connection}\n${this.formatPps(object.flowPps || 0)}\n${this.formatCapacity(object.capacityBps || 0)}`}
      }
      if (layer?.id !== "god-view-nodes") return null
      const d = object?.details || {}
      const geo = [d.geo_city, d.geo_country].filter(Boolean).join(", ")
      return {
        text:
          `${object.label}\n${d.ip || "ip: unknown"}\n${d.type || "type: unknown"}` +
          `${geo ? `\n${geo}` : ""}${d.asn ? `\nASN ${d.asn}` : ""}`,
      }
    },
    edgeLayerId(layerId) {
      return layerId === "god-view-edges-mantle" || layerId === "god-view-edges-crust"
    },
    handleHover(info) {
      const layerId = info?.layer?.id || ""
      const nextKey =
        this.edgeLayerId(layerId) && typeof info?.object?.interactionKey === "string"
          ? info.object.interactionKey
          : null
      if (this.hoveredEdgeKey === nextKey) return
      this.hoveredEdgeKey = nextKey
      if (this.lastGraph) this.renderGraph(this.lastGraph)
    },
    edgeIsFocused(edge) {
      if (!edge) return false
      const key = edge.interactionKey
      return key != null && (key === this.hoveredEdgeKey || key === this.selectedEdgeKey)
    },
    renderSelectionDetails(node) {
      if (!this.details) return
      if (!node) {
        this.details.classList.add("hidden")
        this.details.textContent = "Select a node for details"
        return
      }

      const d = node.details || {}
      const lines = [
        `${node.label}`,
        `ID: ${d.id || node.id || "unknown"}`,
        `IP: ${d.ip || "unknown"}`,
        `Type: ${d.type || "unknown"}`,
        `Vendor/Model: ${d.vendor || "—"} ${d.model || ""}`.trim(),
        `Last Seen: ${d.last_seen || "unknown"}`,
        `ASN: ${d.asn || "unknown"}`,
        `Geo: ${[d.geo_city, d.geo_country].filter(Boolean).join(", ") || "unknown"}`,
      ]
      this.details.textContent = lines.join("\n")
      this.details.classList.remove("hidden")
    },
    handlePick(info) {
      const layerId = info?.layer?.id || ""
      if (this.edgeLayerId(layerId)) {
        const key = typeof info?.object?.interactionKey === "string" ? info.object.interactionKey : null
        if (!key) return
        this.selectedEdgeKey = this.selectedEdgeKey === key ? null : key
        if (this.lastGraph) this.renderGraph(this.lastGraph)
        return
      }

      const tier = this.zoomMode === "auto" ? this.zoomTier : this.zoomMode
      if (tier === "local") {
        const picked = info?.object?.index
        if (Number.isInteger(picked)) {
          this.selectedNodeIndex = this.selectedNodeIndex === picked ? null : picked
          if (this.lastGraph) this.renderGraph(this.lastGraph)
          return
        }
      }

      if (info && info.picked === false) {
        let changed = false
        if (this.selectedNodeIndex !== null) {
          this.selectedNodeIndex = null
          changed = true
        }
        if (this.selectedEdgeKey !== null) {
          this.selectedEdgeKey = null
          changed = true
        }
        if (changed && this.lastGraph) this.renderGraph(this.lastGraph)
      }
    },
    renderGraph(graph) {
      this.ensureDeck()
      this.autoFitViewState(graph)
      const effective = this.reshapeGraph(graph)

      const states = Uint8Array.from(effective.nodes.map((node) => node.state))
      const stateMask = this.visibilityMask(states)
      const traversalMask = effective.shape === "local" ? this.computeTraversalMask(effective) : null
      const mask = new Uint8Array(effective.nodes.length)

      for (let i = 0; i < effective.nodes.length; i += 1) {
        const stateVisible = stateMask[i] === 1
        const traversalVisible = !traversalMask || traversalMask[i] === 1
        mask[i] = stateVisible && traversalVisible ? 1 : 0
      }

      const visibleNodes = effective.nodes.map((node, index) => ({
        ...node,
        index,
        selected: this.selectedNodeIndex === index,
        visible: mask[index] === 1,
      }))
      const visibleById = new Map(visibleNodes.map((node) => [node.id, node]))

      const edgeData = effective.edges
        .map((edge, edgeIndex) => {
          const src =
            effective.shape === "local"
              ? visibleNodes[edge.source]
              : visibleById.get(edge.sourceCluster)
          const dst =
            effective.shape === "local"
              ? visibleNodes[edge.target]
              : visibleById.get(edge.targetCluster)
          if (!src || !dst || !src.visible || !dst.visible) return null
          const label =
            effective.shape === "local"
              ? String(edge.label || `${src.label || src.id || "node"} -> ${dst.label || dst.id || "node"}`)
              : `${this.formatPps(edge.flowPps || 0)} / ${this.formatCapacity(edge.capacityBps || 0)}`
          const connectionLabel = this.connectionKindFromLabel(label)
          const sourceId = effective.shape === "local" ? src.id : src.id || edge.sourceCluster || "src"
          const targetId = effective.shape === "local" ? dst.id : dst.id || edge.targetCluster || "dst"
          const rawEdgeId = edge.id || edge.edge_id || edge.label || edge.type || `${sourceId}:${targetId}:${edgeIndex}`
          return {
            sourcePosition: [src.x, src.y, 0],
            targetPosition: [dst.x, dst.y, 0],
            weight: edge.weight || 1,
            flowPps: Number(edge.flowPps || 0),
            flowBps: Number(edge.flowBps || 0),
            capacityBps: Number(edge.capacityBps || 0),
            midpoint: [(src.x + dst.x) / 2, (src.y + dst.y) / 2, 0],
            label: label.length > 56 ? `${label.slice(0, 56)}...` : label,
            connectionLabel,
            interactionKey: `${effective.shape}:${rawEdgeId}`,
          }
        })
        .filter(Boolean)
      const edgeKeys = new Set(edgeData.map((edge) => edge.interactionKey))
      if (this.hoveredEdgeKey && !edgeKeys.has(this.hoveredEdgeKey)) this.hoveredEdgeKey = null
      if (this.selectedEdgeKey && !edgeKeys.has(this.selectedEdgeKey)) this.selectedEdgeKey = null
      const edgeLabelData = this.selectEdgeLabels(edgeData, effective.shape)

      const nodeData = visibleNodes
        .filter((node) => node.visible)
        .map((node) => ({
          id: node.id,
          position: [node.x, node.y, 0],
          index: node.index,
          state: node.state,
          selected: node.selected,
          clusterCount: node.clusterCount || 1,
          pps: Number(node.pps || 0),
          operUp: Number(node.operUp || 0),
          details: node.details || {},
          label:
            this.normalizeDisplayLabel(node.label, node.id || `node-${node.index + 1}`),
          metricText: this.nodeMetricText(node, effective.shape),
          statusIcon: this.nodeStatusIcon(node.operUp),
        }))
      this.lastVisibleNodeCount = nodeData.length
      this.lastVisibleEdgeCount = edgeData.length
      const pulse = (Math.sin(this.animationPhase * 3.5) + 1) / 2
      const pulseRadius = 14 + pulse * 20
      const pulseAlpha = Math.floor(80 + pulse * 130)
      const rootPulseNodes = nodeData.filter((d) => d.state === 0)
      const packetFlowData = this.buildPacketFlowInstances(edgeData)
      const securityEnabled = this.layers.security
      const mantleLayers = this.layers.mantle
        ? [
            new LineLayer({
              id: "god-view-edges-mantle",
              data: edgeData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getSourcePosition: (d) => d.sourcePosition,
              getTargetPosition: (d) => d.targetPosition,
              getColor: (d) => this.edgeTelemetryColor(d.flowBps, d.capacityBps, d.flowPps, false),
              getWidth: (d) => this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) + (this.edgeIsFocused(d) ? 1.25 : 0),
              widthUnits: "pixels",
              widthMinPixels: 1,
              pickable: true,
              parameters: {
                blend: true,
                blendFunc: [770, 1, 1, 1],
                depthTest: false,
              },
            }),
          ]
        : []
      const crustLayers =
        this.layers.crust
          ? [
              new ArcLayer({
                id: "god-view-edges-crust",
                data: edgeData,
                coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                getSourcePosition: (d) => [d.sourcePosition[0], d.sourcePosition[1], 8],
                getTargetPosition: (d) => [d.targetPosition[0], d.targetPosition[1], 8],
                getSourceColor: (d) => this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).source,
                getTargetColor: (d) => this.edgeTelemetryArcColors(d.flowBps, d.capacityBps, d.flowPps).target,
                getWidth: (d) => {
                  const base = Math.max(1.1, Math.min(this.edgeWidthPixels(d.capacityBps, d.flowPps, d.flowBps) * 0.85, 4.8))
                  return this.edgeIsFocused(d) ? Math.min(5.8, base + 0.9) : base
                },
                widthUnits: "pixels",
                greatCircle: false,
                getTilt: effective.shape === "local" ? 16 : 24,
                pickable: true,
                parameters: {
                  blend: true,
                  blendFunc: [770, 1, 1, 1],
                },
              }),
            ]
          : []
      const atmosphereLayers = this.layers.atmosphere
        ? [
            new PacketFlowLayer({
              id: "god-view-atmosphere-particles",
              data: packetFlowData,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              pickable: false,
              time: this.animationPhase,
              parameters: {
                blend: true,
                blendFunc: [770, 1, 1, 1],
                depthTest: false,
              },
            }),
          ]
        : []
      const securityLayers = this.layers.security
        ? [
            new ScatterplotLayer({
              id: "god-view-security-pulse",
              data: rootPulseNodes,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getPosition: (d) => d.position,
              getRadius: pulseRadius,
              radiusUnits: "pixels",
              radiusMinPixels: 8,
              filled: false,
              stroked: true,
              lineWidthUnits: "pixels",
              getLineWidth: 2,
              getLineColor: [
                this.visual.pulse[0],
                this.visual.pulse[1],
                this.visual.pulse[2],
                pulseAlpha,
              ],
              pickable: false,
            }),
          ]
        : []

      const baseGeoLines = this.geoGridData()
      const baseLayers = baseGeoLines.length > 0
        ? [
            new LineLayer({
              id: "god-view-geo-grid",
              data: baseGeoLines,
              coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
              getSourcePosition: (d) => d.sourcePosition,
              getTargetPosition: (d) => d.targetPosition,
              getColor: [32, 62, 88, 65],
              getWidth: 1,
              widthUnits: "pixels",
              pickable: false,
            }),
          ]
        : []

      const selectedVisibleNode =
        effective.shape !== "local" || this.selectedNodeIndex === null
          ? null
          : nodeData.find((node) => node.index === this.selectedNodeIndex)
      this.renderSelectionDetails(selectedVisibleNode)

      this.deck.setProps({
        layers: [
          ...baseLayers,
          ...mantleLayers,
          ...crustLayers,
          new ScatterplotLayer({
            id: "god-view-nodes",
            data: nodeData,
            coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
            getPosition: (d) => d.position,
            getRadius: (d) => Math.min(8 + ((d.clusterCount || 1) - 1) * 0.45, 26),
            radiusUnits: "pixels",
            radiusMinPixels: 4,
            stroked: true,
            filled: true,
            lineWidthUnits: "pixels",
            pickable: true,
            getLineWidth: (d) => (d.selected ? 3 : 1),
            getLineColor: [15, 23, 42, 255],
            getFillColor: (d) => (securityEnabled ? this.nodeColor(d.state) : this.nodeNeutralColor(d.operUp)),
          }),
          ...securityLayers,
          ...atmosphereLayers,
          ...(this.layers.mantle && (effective.shape === "local" || effective.shape === "regional" || effective.shape === "global")
            ? [
                new TextLayer({
                  id: "god-view-node-labels",
                  data: nodeData,
                  coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                  getPosition: (d) => d.position,
                  getText: (d) => d.label,
                  getSize: effective.shape === "local" ? 12 : 10,
                  sizeUnits: "pixels",
                  sizeMinPixels: effective.shape === "local" ? 10 : 8,
                  getColor: this.visual.label,
                  getPixelOffset: [0, -16],
                  billboard: true,
                  pickable: false,
                }),
                new TextLayer({
                  id: "god-view-node-metrics",
                  data: nodeData,
                  coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                  getPosition: (d) => d.position,
                  getText: (d) => d.metricText,
                  getSize: effective.shape === "local" ? 10 : 9,
                  sizeUnits: "pixels",
                  sizeMinPixels: 8,
                  getColor: [148, 163, 184, 220],
                  getPixelOffset: [0, -3],
                  billboard: true,
                  pickable: false,
                }),
                new TextLayer({
                  id: "god-view-node-status-icon",
                  data: nodeData,
                  coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                  getPosition: (d) => d.position,
                  getText: (d) => d.statusIcon,
                  getSize: effective.shape === "local" ? 12 : 11,
                  sizeUnits: "pixels",
                  sizeMinPixels: 9,
                  getColor: (d) => this.nodeStatusColor(d.operUp),
                  getPixelOffset: [-18, -16],
                  billboard: true,
                  pickable: false,
                }),
              ]
            : []),
          ...(this.layers.mantle && (effective.shape === "local" || effective.shape === "regional")
            ? [
                new TextLayer({
                  id: "god-view-edge-labels",
                  data: edgeLabelData,
                  coordinateSystem: COORDINATE_SYSTEM.CARTESIAN,
                  getPosition: (d) => d.midpoint,
                  getText: (d) => d.connectionLabel,
                  getSize: 10,
                  sizeUnits: "pixels",
                  sizeMinPixels: 8,
                  getColor: this.visual.edgeLabel,
                  billboard: true,
                  pickable: false,
                }),
              ]
            : []),
        ],
      })
    },
    ensureBitmapMetadata(metadata, nodes) {
      const fallback = this.buildBitmapFallbackMetadata(nodes)
      const value = metadata && typeof metadata === "object" ? metadata : {}

      const pick = (key) => {
        const item = value[key] || value[String(key)] || {}
        const bytes = Number(item.bytes || 0)
        const count = Number(item.count || 0)
        return {
          bytes: Number.isFinite(bytes) ? bytes : 0,
          count: Number.isFinite(count) ? count : 0,
        }
      }

      const normalized = {
        root_cause: pick("root_cause"),
        affected: pick("affected"),
        healthy: pick("healthy"),
        unknown: pick("unknown"),
      }

      const sumCounts =
        normalized.root_cause.count +
        normalized.affected.count +
        normalized.healthy.count +
        normalized.unknown.count
      const sumBytes =
        normalized.root_cause.bytes +
        normalized.affected.bytes +
        normalized.healthy.bytes +
        normalized.unknown.bytes

      if (sumCounts === 0 && sumBytes === 0 && Array.isArray(nodes) && nodes.length > 0) {
        return fallback
      }

      return normalized
    },
    buildBitmapFallbackMetadata(nodes) {
      const safeNodes = Array.isArray(nodes) ? nodes : []
      const byteWidth = Math.ceil(safeNodes.length / 8)
      const counts = {root_cause: 0, affected: 0, healthy: 0, unknown: 0}

      for (let i = 0; i < safeNodes.length; i += 1) {
        const category = this.stateCategory(Number(safeNodes[i]?.state))
        counts[category] = (counts[category] || 0) + 1
      }

      return {
        root_cause: {bytes: byteWidth, count: counts.root_cause || 0},
        affected: {bytes: byteWidth, count: counts.affected || 0},
        healthy: {bytes: byteWidth, count: counts.healthy || 0},
        unknown: {bytes: byteWidth, count: counts.unknown || 0},
      }
    },
    autoFitViewState(graph) {
      if (!this.deck || !graph || !Array.isArray(graph.nodes) || graph.nodes.length === 0) return
      if (this.hasAutoFit || this.userCameraLocked) return

      let minX = Number.POSITIVE_INFINITY
      let maxX = Number.NEGATIVE_INFINITY
      let minY = Number.POSITIVE_INFINITY
      let maxY = Number.NEGATIVE_INFINITY

      for (let i = 0; i < graph.nodes.length; i += 1) {
        const node = graph.nodes[i]
        const x = Number(node?.x)
        const y = Number(node?.y)
        if (!Number.isFinite(x) || !Number.isFinite(y)) continue
        minX = Math.min(minX, x)
        maxX = Math.max(maxX, x)
        minY = Math.min(minY, y)
        maxY = Math.max(maxY, y)
      }

      if (!Number.isFinite(minX) || !Number.isFinite(minY)) return

      const width = Math.max(1, this.el.clientWidth || 1)
      const height = Math.max(1, this.el.clientHeight || 1)
      const spanX = Math.max(1, maxX - minX)
      const spanY = Math.max(1, maxY - minY)
      const padding = 0.88
      const zoomX = Math.log2((width * padding) / spanX)
      const zoomY = Math.log2((height * padding) / spanY)
      const zoom = Math.max(this.viewState.minZoom, Math.min(this.viewState.maxZoom, Math.min(zoomX, zoomY)))

      this.viewState = {
        ...this.viewState,
        target: [(minX + maxX) / 2, (minY + maxY) / 2, 0],
        zoom,
      }

      this.hasAutoFit = true
      this.isProgrammaticViewUpdate = true
      this.deck.setProps({viewState: this.viewState})
      if (this.zoomMode === "auto") {
        this.setZoomTier(this.resolveZoomTier(zoom), true)
      }
    },
    visibilityMask(states) {
      if (this.wasmReady && this.wasmEngine) {
        try {
          return this.wasmEngine.computeStateMask(states, this.filters)
        } catch (_err) {
          this.wasmReady = false
        }
      }

      const mask = new Uint8Array(states.length)
      for (let i = 0; i < states.length; i += 1) {
        const category = this.stateCategory(states[i])
        mask[i] = this.filters[category] !== false ? 1 : 0
      }
      return mask
    },
    computeTraversalMask(graph) {
      if (!graph || this.selectedNodeIndex === null) return null
      if (this.selectedNodeIndex >= graph.nodes.length) return null

      if (this.wasmReady && this.wasmEngine) {
        try {
          return this.wasmEngine.computeThreeHopMask(
            graph.nodes.length,
            graph.edgeSourceIndex,
            graph.edgeTargetIndex,
            this.selectedNodeIndex,
          )
        } catch (_err) {
          this.wasmReady = false
        }
      }

      const mask = new Uint8Array(graph.nodes.length)
      const frontier = [this.selectedNodeIndex]
      mask[this.selectedNodeIndex] = 1

      for (let hop = 0; hop < 3; hop += 1) {
        if (frontier.length === 0) break
        const next = []

        for (const node of frontier) {
          for (let i = 0; i < graph.edges.length; i += 1) {
            const edge = graph.edges[i]
            const a = edge.source
            const b = edge.target

            if (a === node && b < graph.nodes.length && mask[b] === 0) {
              mask[b] = 1
              next.push(b)
            } else if (b === node && a < graph.nodes.length && mask[a] === 0) {
              mask[a] = 1
              next.push(a)
            }
          }
        }

        frontier.length = 0
        frontier.push(...next)
      }

      return mask
    },
    stateCategory(state) {
      if (state === 0) return "root_cause"
      if (state === 1) return "affected"
      if (state === 2) return "healthy"
      return "unknown"
    },
    stateDisplayName(state) {
      if (state === 0) return "Root Cause"
      if (state === 1) return "Affected"
      if (state === 2) return "Healthy"
      return "Unknown"
    },
    nodeMetricText(node, shape) {
      const clusterCount = Number(node?.clusterCount || 1)
      if (shape === "global" || shape === "regional") {
        return `${clusterCount} node${clusterCount === 1 ? "" : "s"}`
      }
      return this.formatPps(node?.pps || 0)
    },
    nodeColor(state) {
      if (state === 0) return this.visual.nodeRoot
      if (state === 1) return this.visual.nodeAffected
      if (state === 2) return this.visual.nodeHealthy
      return this.visual.nodeUnknown
    },
    nodeNeutralColor(operUp) {
      if (Number(operUp) === 1) return [56, 189, 248, 230]
      if (Number(operUp) === 2) return [120, 113, 108, 220]
      return [100, 116, 139, 220]
    },
    formatPps(value) {
      const n = Number(value || 0)
      if (!Number.isFinite(n) || n <= 0) return "0 pps"
      if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)} Mpps`
      if (n >= 1_000) return `${(n / 1_000).toFixed(1)} Kpps`
      return `${Math.round(n)} pps`
    },
    formatCapacity(value) {
      const n = Number(value || 0)
      if (!Number.isFinite(n) || n <= 0) return "UNK"
      if (n >= 100_000_000_000) return `${Math.round(n / 1_000_000_000)}G`
      if (n >= 10_000_000_000) return `${Math.round(n / 1_000_000_000)}G`
      if (n >= 1_000_000_000) return `${Math.round(n / 1_000_000_000)}G`
      if (n >= 100_000_000) return `${Math.round(n / 1_000_000)}M`
      return `${Math.max(1, Math.round(n / 1_000_000))}M`
    },
    nodeStatusIcon(operUp) {
      if (Number(operUp) === 1) return "●"
      if (Number(operUp) === 2) return "○"
      return "◌"
    },
    nodeStatusColor(operUp) {
      if (Number(operUp) === 1) return [34, 197, 94, 230]
      if (Number(operUp) === 2) return [239, 68, 68, 230]
      return [148, 163, 184, 220]
    },
    edgeTelemetryColor(flowBps, capacityBps, flowPps, vivid = false) {
      const bps = Number(flowBps || 0)
      const cap = Number(capacityBps || 0)
      const pps = Number(flowPps || 0)
      const util = cap > 0 ? Math.min(1, bps / cap) : 0
      const spark = pps > 0 ? Math.min(1, Math.log10(Math.max(10, pps)) / 6) : 0
      const t = Math.min(1, Math.max(util, spark))

      const low = vivid ? [48, 226, 255, 65] : [40, 170, 220, 45]
      const high = vivid ? [255, 74, 212, 90] : [214, 97, 255, 70]

      return [
        Math.round(low[0] * (1 - t) + high[0] * t),
        Math.round(low[1] * (1 - t) + high[1] * t),
        Math.round(low[2] * (1 - t) + high[2] * t),
        Math.round(low[3] * (1 - t) + high[3] * t),
      ]
    },
    edgeTelemetryArcColors(flowBps, capacityBps, flowPps) {
      const source = this.edgeTelemetryColor(flowBps, capacityBps, flowPps, true)
      const target = this.edgeTelemetryColor(flowBps, capacityBps, flowPps, false)
      return {source, target}
    },
    edgeWidthPixels(capacityBps, flowPps, flowBps) {
      const cap = Number(capacityBps || 0)
      const pps = Number(flowPps || 0)
      const bps = Number(flowBps || 0)

      let base = 0.75
      if (cap >= 100_000_000_000) base = 3.5
      else if (cap >= 40_000_000_000) base = 2.8
      else if (cap >= 10_000_000_000) base = 2
      else if (cap >= 1_000_000_000) base = 1.5
      else if (cap >= 100_000_000) base = 1

      const ppsBoost = Math.min(2.8, Math.log10(Math.max(1, pps)) * 0.85)
      const utilization = cap > 0 ? Math.min(1, bps / cap) : 0
      const bpsBoost = utilization > 0 ? Math.min(3.2, Math.sqrt(utilization) * 3.2) : 0
      const flowBoost = Math.max(ppsBoost, bpsBoost) * 0.6
      return Math.min(4.5, Math.max(0.75, base + flowBoost))
    },
    normalizeDisplayLabel(value, fallback = "node") {
      const label = String(value == null ? "" : value).trim()
      if (label === "") return fallback
      const lowered = label.toLowerCase()
      if (lowered === "nil" || lowered === "null" || lowered === "undefined") return fallback
      return label
    },
    connectionKindFromLabel(label) {
      const text = String(label == null ? "" : label).trim()
      if (text === "") return "LINK"
      const token = text.split(/\s+/)[0] || ""
      const clean = token.replace(/[^a-zA-Z0-9_-]/g, "").toUpperCase()
      if (!clean || clean === "NODE") return "LINK"
      return clean
    },
    selectEdgeLabels(edgeData, shape) {
      if (!Array.isArray(edgeData) || edgeData.length === 0) return []
      if (shape !== "local" && shape !== "regional") return []

      const selected = this.selectedEdgeKey
      const hovered = this.hoveredEdgeKey
      if (!selected && !hovered) return []

      const picked = []
      const seen = new Set()
      for (let i = 0; i < edgeData.length; i += 1) {
        const edge = edgeData[i]
        if (edge.interactionKey !== selected && edge.interactionKey !== hovered) continue
        if (seen.has(edge.interactionKey)) continue
        seen.add(edge.interactionKey)
        picked.push(edge)
      }
      return picked
    },
    buildPacketFlowInstances(edgeData) {
      if (!Array.isArray(edgeData) || edgeData.length === 0) return []
      const maxParticles = 22000
      const particles = []

      for (let i = 0; i < edgeData.length; i += 1) {
        if (particles.length >= maxParticles) break
        const edge = edgeData[i]
        const src = edge?.sourcePosition
        const dst = edge?.targetPosition
        if (!Array.isArray(src) || !Array.isArray(dst)) continue
        const pps = Number(edge?.flowPps || 0)
        const bps = Number(edge?.flowBps || 0)
        const cap = Number(edge?.capacityBps || 0)
        const utilization = cap > 0 ? Math.min(1, bps / cap) : 0
        const ppsSignal = pps > 0 ? Math.log10(Math.max(10, pps)) : 0
        const bpsSignal = utilization > 0 ? utilization * 3.2 : 0
        const baseline = 1.05 + Math.min(1.1, Math.log10(Math.max(1, edge.weight || 1)) * 0.72)
        const intensity = Math.max(baseline, ppsSignal, bpsSignal)
        const particlesOnEdge = Math.max(24, Math.min(140, Math.floor(intensity * 10.5)))
        const baseSpeed = 0.11 + Math.min(1.35, intensity * 0.11)

        for (let j = 0; j < particlesOnEdge; j += 1) {
          if (particles.length >= maxParticles) break
          const seed = (((i * 17 + j * 37) % 997) + 1) / 997
          const speedModifier = 0.7 + (((j * 43) % 101) / 100) * 0.6
          const particleSpeed = baseSpeed * speedModifier
          const hue = Math.min(1, intensity / 4)
          const cyan = [73, 231, 255, 95]
          const magenta = [244, 114, 255, 120]
          const color = [
            Math.round(cyan[0] * (1 - hue) + magenta[0] * hue),
            Math.round(cyan[1] * (1 - hue) + magenta[1] * hue),
            Math.round(cyan[2] * (1 - hue) + magenta[2] * hue),
            Math.round(cyan[3] * (1 - hue) + magenta[3] * hue),
          ]
          particles.push({
            from: [src[0], src[1]],
            to: [dst[0], dst[1]],
            seed,
            speed: particleSpeed,
            jitter: 8 + Math.min(26, intensity * 6.5),
            size: Math.min(24.0, 10.0 + intensity * 2.5),
            color,
          })
        }
      }

      return particles
    },
  },

  LocalTime: {
    mounted() {
      this._apply()
    },
    updated() {
      this._apply()
    },
    _apply() {
      const iso = this.el.dataset.iso || ""
      if (!iso) return
      const d = new Date(iso)
      if (!(d instanceof Date) || isNaN(d.getTime())) return

      // Local time. Full ISO remains on the parent cell title.
      try {
        this.el.textContent = d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })
      } catch (_e) {
        this.el.textContent = d.toISOString().slice(11, 19)
      }
    },
  },
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

window.addEventListener("phx:download_yaml", (event) => {
  const filename = event.detail?.filename
  const content = event.detail?.content
  if (!filename || typeof content !== "string") return

  const blob = new Blob([content], {type: "application/x-yaml;charset=utf-8"})
  const url = window.URL.createObjectURL(blob)

  try {
    const anchor = document.createElement("a")
    anchor.href = url
    anchor.download = filename
    document.body.appendChild(anchor)
    anchor.click()
    document.body.removeChild(anchor)
  } finally {
    window.URL.revokeObjectURL(url)
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
