import {formatUserTime} from "../utils/user_time"

function serverAriaLabel(canonical, timeZone) {
  return `${canonical} UTC; display zone ${timeZone}`
}

function synchronizeServerFallback(el) {
  const canonical = el.dataset.userTimeIso || ""
  const timeZone = el.dataset.userTimeZone || ""
  const fallback = el.dataset.userTimeFallback || canonical
  const title = el.dataset.userTimeTitle || `${canonical} (UTC); display zone ${timeZone}`
  const ariaLabel = el.dataset.userTimeAriaLabel || serverAriaLabel(canonical, timeZone)

  el.textContent = fallback
  el.setAttribute("datetime", canonical)
  el.setAttribute("title", title)
  el.setAttribute("aria-label", ariaLabel)

  return {canonical, timeZone}
}

export default {
  mounted() {
    this._apply()
  },

  updated() {
    this._apply()
  },

  _apply() {
    const {canonical, timeZone} = synchronizeServerFallback(this.el)
    const result = formatUserTime(canonical, {timeZone, style: this.el.dataset.userTimeStyle || "full"})

    if (!result) return

    this.el.textContent = result.text
    const offset = result.text.includes(result.offset) ? "" : `; ${result.offset}`
    this.el.setAttribute(
      "aria-label",
      `${result.text}${offset}; display zone ${timeZone}; canonical UTC ${result.canonical}`,
    )
  },
}
