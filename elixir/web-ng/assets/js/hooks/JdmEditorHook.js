// Preload JDM editor CSS - ensures styles are bundled
import "@gorules/jdm-editor/dist/style.css"

// JDM Editor hydration (lazy loaded, CSS is statically imported above)
let JdmEditorModule = null

async function loadJdmEditor() {
  if (!JdmEditorModule) {
    JdmEditorModule = await import("@gorules/jdm-editor")
  }
  return JdmEditorModule
}

// Helper: Get current theme from Phoenix (data-theme attribute on html)
function getPhoenixTheme() {
  const dataTheme = document.documentElement.getAttribute("data-theme")
  // Map Phoenix themes to JDM editor themes
  // Common dark themes in daisyUI
  const darkThemes = [
    "dark",
    "night",
    "dracula",
    "synthwave",
    "halloween",
    "forest",
    "black",
    "luxury",
    "business",
    "coffee",
    "dim",
    "sunset",
  ]
  if (dataTheme && darkThemes.includes(dataTheme.toLowerCase())) {
    return "dark"
  }
  // Check system preference if no explicit theme
  if (!dataTheme && window.matchMedia("(prefers-color-scheme: dark)").matches) {
    return "dark"
  }
  return "light"
}

export default {
  async mounted() {
    const container = this.el
    const propsData = container.dataset.props

    if (!propsData) {
      console.error("JdmEditorHook: Missing data-props attribute")
      return
    }

    const props = JSON.parse(propsData)
    const {createRoot} = await import("react-dom/client")
    const React = await import("react")
    const {JdmConfigProvider, DecisionGraph} = await loadJdmEditor()

    // Store reference for event handlers
    const hook = this

    // Get initial theme
    const currentTheme = getPhoenixTheme()

    // Create a React element with event handlers and theme support
    const EditorWithHandlers = ({initialTheme}) => {
      const [definition, setDefinition] = React.useState(props.definition)
      const [theme, setTheme] = React.useState(initialTheme)

      // Listen for theme changes
      React.useEffect(() => {
        const observer = new MutationObserver(() => {
          const newTheme = getPhoenixTheme()
          if (newTheme !== theme) {
            setTheme(newTheme)
          }
        })
        observer.observe(document.documentElement, {
          attributes: true,
          attributeFilter: ["data-theme"],
        })

        // Also listen for system theme changes
        const mediaQuery = window.matchMedia("(prefers-color-scheme: dark)")
        const handleMediaChange = () => setTheme(getPhoenixTheme())
        mediaQuery.addEventListener("change", handleMediaChange)

        return () => {
          observer.disconnect()
          mediaQuery.removeEventListener("change", handleMediaChange)
        }
      }, [theme])

      const handleChange = React.useCallback((newDef) => {
        setDefinition(newDef)
        // Push change event to LiveView
        hook.pushEvent("jdm_editor_change", {definition: newDef})
      }, [])

      // Wrap in a full-height container - ReactFlow needs explicit height
      // Pass theme config with mode for JDM editor dark mode support
      const themeConfig = {mode: theme}

      return React.createElement(
        "div",
        {
          style: {height: "100%", width: "100%"},
          className: theme === "dark" ? "grl-dark" : "grl-light",
          "data-theme": theme,
        },
        React.createElement(
          JdmConfigProvider,
          {theme: themeConfig},
          React.createElement(DecisionGraph, {
            value: definition,
            onChange: handleChange,
            disabled: props.readOnly,
          }),
        ),
      )
    }

    // Clear container and render fresh (SSR may not work with complex React deps)
    container.innerHTML = ""
    this.reactRoot = createRoot(container)
    this.reactRoot.render(React.createElement(EditorWithHandlers, {initialTheme: currentTheme}))

    // Handle updates from LiveView
    this.handleEvent("jdm_editor_update", ({definition}) => {
      // Re-render with new definition
      const UpdatedEditor = ({initialTheme}) => {
        const [def, setDef] = React.useState(definition)
        const [theme, setTheme] = React.useState(initialTheme)

        React.useEffect(() => {
          const observer = new MutationObserver(() => {
            setTheme(getPhoenixTheme())
          })
          observer.observe(document.documentElement, {
            attributes: true,
            attributeFilter: ["data-theme"],
          })
          return () => observer.disconnect()
        }, [])

        const handleChange = React.useCallback((newDef) => {
          setDef(newDef)
          hook.pushEvent("jdm_editor_change", {definition: newDef})
        }, [])

        // Wrap in a full-height container - ReactFlow needs explicit height
        const themeConfig = {mode: theme}

        return React.createElement(
          "div",
          {
            style: {height: "100%", width: "100%"},
            className: theme === "dark" ? "grl-dark" : "grl-light",
            "data-theme": theme,
          },
          React.createElement(
            JdmConfigProvider,
            {theme: themeConfig},
            React.createElement(DecisionGraph, {
              value: def,
              onChange: handleChange,
              disabled: props.readOnly,
            }),
          ),
        )
      }
      this.reactRoot.render(React.createElement(UpdatedEditor, {initialTheme: getPhoenixTheme()}))
    })
  },

  destroyed() {
    if (this.reactRoot) {
      this.reactRoot.unmount()
    }
  },
}
