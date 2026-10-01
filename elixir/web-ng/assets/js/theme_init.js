// Theme initialization — must run synchronously in <head> before first paint
// to prevent flash of wrong theme. Loaded as a separate file to comply with CSP
// script-src restrictions (no inline scripts).
(() => {
  const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");
  const setTheme = (theme) => {
    if (theme === "system") {
      localStorage.removeItem("phx:theme");
    } else {
      localStorage.setItem("phx:theme", theme);
    }
    // Keep the selected preference separate from the effective palette so all
    // theme consumers, including the operations shell, follow the OS together.
    document.documentElement.setAttribute("data-theme-preference", theme);
    document.documentElement.setAttribute(
      "data-theme",
      theme === "system" ? (systemTheme.matches ? "dark" : "light") : theme
    );
  };
  setTheme(localStorage.getItem("phx:theme") || "system");
  systemTheme.addEventListener("change", () => {
    if (!localStorage.getItem("phx:theme")) setTheme("system");
  });
  window.addEventListener("storage", (e) => e.key === "phx:theme" && setTheme(e.newValue || "system"));
  window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme));
})();
