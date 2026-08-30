import {formatUserTime} from "../utils/user_time"

function serverAriaLabel(canonical, timeZone) {
  return `${canonical} UTC; display zone ${timeZone}`
}

export default {
  mounted() {
    this._apply()
  },

  updated() {
    this._apply()
  },

  _apply() {
    const canonical = this.el.dataset.userTimeIso || ""
    const timeZone = this.el.dataset.userTimeZone || ""

    if (this._userTimeCanonical !== canonical) {
      this._userTimeCanonical = canonical
      this._userTimeFallback = this.el.textContent
    }

    const fallback = this._userTimeFallback || this.el.textContent
    const result = formatUserTime(canonical, {timeZone, style: this.el.dataset.userTimeStyle || "full"})

    if (!result) {
      this.el.textContent = fallback
      this.el.setAttribute("aria-label", serverAriaLabel(canonical, timeZone))
      return
    }

    this.el.textContent = result.text
    this.el.setAttribute(
      "aria-label",
      `${result.text}; ${result.offset}; display zone ${timeZone}; canonical UTC ${result.canonical}`,
    )
  },
}
