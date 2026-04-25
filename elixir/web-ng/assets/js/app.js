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
import HookModules from "./hooks"
import {registerGlobalWindowEvents, registerLiveReloadHelpers} from "./utils/window_events"

// Custom hooks
const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  // Demo is currently falling back to longpoll instead of websocket for LiveView.
  // Keep the fallback enabled, but avoid a multi-second blank wait before mount.
  longPollFallbackMs: 250,
  params: {_csrf_token: csrfToken},
  hooks: {...HookModules},
})

// Show a thin progress bar on live navigation and form submits.
topbar.config({
  barThickness: 2,
  barColors: {0: "#38BDF8", 1: "#22C55E"},
  className: "sr-page-loading-bar",
  shadowBlur: 0,
  shadowColor: "transparent",
})

let topbarFallbackTimer = null
const hideTopbar = () => {
  if (topbarFallbackTimer) {
    clearTimeout(topbarFallbackTimer)
    topbarFallbackTimer = null
  }

  topbar.hide()
}

window.addEventListener("phx:page-loading-start", _info => {
  hideTopbar()
  topbar.show(120)
  topbarFallbackTimer = setTimeout(() => topbar.hide(), 2500)
})
window.addEventListener("phx:page-loading-stop", _info => hideTopbar())
registerGlobalWindowEvents()

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
registerLiveReloadHelpers()
