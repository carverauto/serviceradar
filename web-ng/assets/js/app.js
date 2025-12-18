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

// Custom hooks
const Hooks = {
  TimeseriesChart: {
    mounted() {
      const el = this.el
      const svg = el.querySelector('svg')
      const tooltip = el.querySelector('[data-tooltip]')
      const hoverLine = el.querySelector('[data-hover-line]')
      const pointsData = JSON.parse(el.dataset.points || '[]')

      if (!svg || !tooltip || !hoverLine || pointsData.length === 0) return

      const svgContainer = svg.parentElement

      const showTooltip = (e) => {
        const rect = svg.getBoundingClientRect()
        const x = e.clientX - rect.left
        const pct = Math.max(0, Math.min(1, x / rect.width))
        const idx = Math.round(pct * (pointsData.length - 1))
        const point = pointsData[idx]

        if (point) {
          const value = typeof point.v === 'number'
            ? point.v.toFixed(2)
            : point.v
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
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

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
