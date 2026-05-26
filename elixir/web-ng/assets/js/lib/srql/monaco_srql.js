const SRQL_LANGUAGE_ID = "serviceradar-srql"
const SRQL_MARKER_OWNER = "serviceradar-srql"

function globalState() {
  window.__serviceradarSrqlEditor = window.__serviceradarSrqlEditor || {
    completions: [],
    languageRegistered: false,
  }

  return window.__serviceradarSrqlEditor
}

export function setSrqlCompletions(completions = []) {
  globalState().completions = completions
}

export function ensureSrqlLanguage(monaco, completions = []) {
  const state = globalState()
  state.completions = completions

  if (state.languageRegistered) return
  state.languageRegistered = true

  monaco.languages.register({id: SRQL_LANGUAGE_ID})
  monaco.languages.setMonarchTokensProvider(SRQL_LANGUAGE_ID, {
    tokenizer: {
      root: [
        [/\bin:[a-zA-Z0-9_-]+/, "keyword"],
        [/\b(limit|sort|time|where|group|by|from|select|as|and|or|not)\b/, "keyword"],
        [/\b(ok|warn|fail|unknown|true|false|null)\b/, "constant"],
        [/"[^"]*"/, "string"],
        [/'[^']*'/, "string"],
        [/\b\d+(\.\d+)?\b/, "number"],
        [/[<>!=]=?|=~/, "operator"],
        [/[a-zA-Z_][\w.-]*/, "identifier"],
      ],
    },
  })
  monaco.languages.setLanguageConfiguration(SRQL_LANGUAGE_ID, {
    brackets: [["(", ")"], ["[", "]"]],
    autoClosingPairs: [
      {open: "\"", close: "\""},
      {open: "'", close: "'"},
      {open: "(", close: ")"},
      {open: "[", close: "]"},
    ],
  })
  monaco.languages.registerCompletionItemProvider(SRQL_LANGUAGE_ID, {
    triggerCharacters: [":", " ", ".", "$"],
    provideCompletionItems(model, position) {
      const word = model.getWordUntilPosition(position)
      const linePrefix = model.getValueInRange({
        startLineNumber: position.lineNumber,
        startColumn: 1,
        endLineNumber: position.lineNumber,
        endColumn: position.column,
      })
      const range = {
        startLineNumber: position.lineNumber,
        endLineNumber: position.lineNumber,
        startColumn: word.startColumn,
        endColumn: word.endColumn,
      }
      const afterInPrefix = /\bin:$/.test(linePrefix)
      const suggestions = (globalState().completions || []).map(label => {
        const isEntity = label.startsWith("in:")
        const isControl = label.endsWith(":") || isEntity

        return {
          label: afterInPrefix && isEntity ? label.slice(3) : label,
          insertText: afterInPrefix && isEntity ? label.slice(3) : label,
          detail: isEntity ? "entity" : isControl ? "operator" : "field",
          kind: isEntity
            ? monaco.languages.CompletionItemKind.Module
            : isControl
              ? monaco.languages.CompletionItemKind.Keyword
              : monaco.languages.CompletionItemKind.Field,
          range,
        }
      })

      return {suggestions}
    },
  })
}

export function applySrqlMarkers(monaco, editor, error) {
  const model = editor?.getModel()
  if (!model) return

  if (!error) {
    monaco.editor.setModelMarkers(model, SRQL_MARKER_OWNER, [])
    return
  }

  monaco.editor.setModelMarkers(model, SRQL_MARKER_OWNER, [
    {
      startLineNumber: 1,
      startColumn: 1,
      endLineNumber: model.getLineCount(),
      endColumn: Math.max(2, model.getLineMaxColumn(model.getLineCount())),
      severity: monaco.MarkerSeverity.Error,
      message: error,
    },
  ])
}

export async function createSrqlEditor(container, options = {}) {
  const monaco = await import("monaco-editor/esm/vs/editor/editor.api")
  ensureSrqlLanguage(monaco, options.completions || [])

  const compact = options.compact === true
  const darkTheme = document.documentElement.dataset.theme === "dark" || document.documentElement.classList.contains("dark")
  const editor = monaco.editor.create(container, {
    value: options.value || "",
    language: SRQL_LANGUAGE_ID,
    theme: darkTheme ? "vs-dark" : "vs",
    readOnly: options.disabled === true,
    automaticLayout: true,
    fixedOverflowWidgets: true,
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
    fontSize: compact ? 11 : 12,
    lineDecorationsWidth: compact ? 0 : 8,
    lineNumbers: compact ? "off" : "on",
    lineNumbersMinChars: compact ? 0 : 3,
    minimap: {enabled: false},
    overviewRulerLanes: 0,
    renderLineHighlight: compact ? "none" : "line",
    scrollBeyondLastLine: false,
    scrollbar: {vertical: compact ? "hidden" : "auto", horizontal: "auto", alwaysConsumeMouseWheel: false},
    wordWrap: compact ? "off" : "on",
  })

  applySrqlMarkers(monaco, editor, options.error)

  return {monaco, editor}
}
