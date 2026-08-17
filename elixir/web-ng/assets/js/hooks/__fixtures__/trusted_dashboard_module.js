export function mountDashboard(el, _host, api) {
  el.dataset.mounted = api.version
  return {
    destroy() {
      el.dataset.destroyed = "true"
    },
  }
}
