// Theme initialization — must run synchronously in <head> before first paint
// to prevent flash of wrong theme. Loaded as a separate file to comply with CSP
// script-src restrictions (no inline scripts).
(() => {
  const setTheme = (theme) => {
    localStorage.setItem("phx:theme", theme);
    document.documentElement.setAttribute("data-theme", theme);
  };
  setTheme(localStorage.getItem("phx:theme") || "dark");
  window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "dark"));
  window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme));
})();
