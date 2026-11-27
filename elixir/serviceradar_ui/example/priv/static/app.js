import {Socket} from "/vendor/phoenix.mjs"
import {LiveSocket} from "/vendor/phoenix_live_view.esm.js"
import {hooks} from "/serviceradar_ui/serviceradar_ui.js"

const csrf = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  hooks,
  params: {_csrf_token: csrf}
})

liveSocket.connect()
