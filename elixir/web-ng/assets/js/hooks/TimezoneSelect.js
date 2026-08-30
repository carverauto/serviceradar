import {filterTimezoneOptions} from "../utils/timezone_options"

function optionValues(datalist) {
  return [...datalist.children]
    .filter((option) => option.value)
    .map((option) => option.value)
}

export default {
  mounted() {
    this._filterOptions()
  },

  updated() {
    this._filterOptions()
  },

  _filterOptions() {
    const optionsId = this.el.dataset.optionsId
    const datalist = optionsId && this.el.ownerDocument.getElementById(optionsId)

    if (!datalist) return

    const inputValue = this.el.value
    const serverOptions = [...datalist.children]
    const supported = new Set(
      filterTimezoneOptions(optionValues(datalist), this.el.dataset.currentTimezone, {intl: globalThis.Intl}),
    )

    datalist.replaceChildren(...serverOptions.filter((option) => supported.has(option.value)))
    this.el.value = inputValue
  },
}
