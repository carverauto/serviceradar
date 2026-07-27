// Theme initialization — must run synchronously in <head> before first paint
// to prevent flash of wrong theme. Loaded as a separate file to comply with CSP
// script-src restrictions (no inline scripts).
//
// App defaults to dark. The theme_toggle component is hidden in layouts but still
// works via phx:set-theme if re-enabled later.
(() => {
  const DEFAULT_THEME = "dark";

  const setTheme = (theme) => {
    if (theme === "system") {
      // Treat system as dark while the toggle is offline — avoids OS light flash.
      localStorage.setItem("phx:theme", DEFAULT_THEME);
      document.documentElement.setAttribute("data-theme", DEFAULT_THEME);
      return;
    }

    localStorage.setItem("phx:theme", theme);
    document.documentElement.setAttribute("data-theme", theme);
  };

  // Always start dark (ignore prior light preference while toggle is removed).
  setTheme(DEFAULT_THEME);

  window.addEventListener(
    "storage",
    (e) => e.key === "phx:theme" && setTheme(e.newValue || DEFAULT_THEME)
  );
  window.addEventListener("phx:set-theme", (e) => setTheme(e.target.dataset.phxTheme));
})();
