export default {
  mounted() {
    const container = this.el
    const form = container.closest("form")

    if (!form) return

    const handleChange = (e) => {
      if (e.target.name === "bulk[action]") {
        if (e.target.value === "add_tags") {
          container.classList.remove("hidden")
        } else {
          container.classList.add("hidden")
        }
      }
    }

    form.addEventListener("change", handleChange)
    this.cleanup = () => form.removeEventListener("change", handleChange)
  },
  destroyed() {
    if (this.cleanup) this.cleanup()
  },
}
