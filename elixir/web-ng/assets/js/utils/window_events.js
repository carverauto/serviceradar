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

export function registerGlobalWindowEvents() {
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

  window.addEventListener("phx:download_csv", (event) => {
    const filename = event.detail?.filename
    const content = event.detail?.content
    if (!filename || typeof content !== "string") return

    const blob = new Blob([content], {type: "text/csv;charset=utf-8"})
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
}

export function registerLiveReloadHelpers() {
  if (process.env.NODE_ENV !== "development") return

  // The lines below enable quality of life phoenix_live_reload development features:
  // 1. stream server logs to the browser console
  // 2. click on elements to jump to their definitions in your code editor
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    // * click with "c" key pressed to open at caller location
    // * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", (e) => (keyDown = e.key))
    window.addEventListener("keyup", (_e) => (keyDown = null))
    window.addEventListener(
      "click",
      (e) => {
        if (keyDown === "c") {
          e.preventDefault()
          e.stopImmediatePropagation()
          reloader.openEditorAtCaller(e.target)
        } else if (keyDown === "d") {
          e.preventDefault()
          e.stopImmediatePropagation()
          reloader.openEditorAtDef(e.target)
        }
      },
      true,
    )

    window.liveReloader = reloader
  })
}
