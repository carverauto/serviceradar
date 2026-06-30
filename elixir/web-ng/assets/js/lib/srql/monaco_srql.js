const SRQL_LANGUAGE_ID = "serviceradar-srql"
const SRQL_MARKER_OWNER = "serviceradar-srql"
let monacoPromise = null

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
        [/\b(limit|sort|time|where|group|by|from|select|as|and|or|not|latest)\b/, "keyword"],
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
    triggerCharacters: [":", " ", ".", "$", "_"],
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
        const insertText = afterInPrefix && isEntity ? label.slice(3) : label

        return {
          label: insertText,
          insertText,
          detail: isEntity ? "entity" : isControl ? "operator" : "field",
          kind: isEntity
            ? monaco.languages.CompletionItemKind.Module
            : isControl
              ? monaco.languages.CompletionItemKind.Keyword
              : monaco.languages.CompletionItemKind.Field,
          sortText: `${isEntity ? "0" : isControl ? "1" : "2"}-${label}`,
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
      ...markerRangeForError(model, error),
      severity: monaco.MarkerSeverity.Error,
      message: errorMessage(error),
    },
  ])
}

export function loadSrqlMonaco() {
  if (!monacoPromise) {
    monacoPromise = import("monaco-editor/esm/vs/editor/editor.api")
  }

  return monacoPromise
}

export async function createSrqlEditor(container, options = {}) {
  const monaco = await loadSrqlMonaco()
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
    glyphMargin: false,
    lightbulb: {enabled: false},
    lineDecorationsWidth: compact ? 0 : 8,
    lineNumbers: compact ? "off" : "on",
    lineNumbersMinChars: compact ? 0 : 3,
    minimap: {enabled: false},
    overviewRulerLanes: 0,
    parameterHints: {enabled: false},
    quickSuggestions: {other: true, comments: false, strings: false},
    renderLineHighlight: compact ? "none" : "line",
    scrollBeyondLastLine: false,
    scrollbar: {vertical: compact ? "hidden" : "auto", horizontal: "auto", alwaysConsumeMouseWheel: false},
    suggest: {
      preview: true,
      showFields: true,
      showKeywords: true,
      showWords: false,
    },
    suggestOnTriggerCharacters: true,
    tabCompletion: "on",
    wordBasedSuggestions: "off",
    wordWrap: compact ? "off" : "on",
  })

  applySrqlMarkers(monaco, editor, options.error)

  return {monaco, editor}
}

function errorMessage(error) {
  if (!error) return ""
  if (typeof error === "string") return error
  return error.message || String(error)
}

function markerRangeForError(model, error) {
  const explicit = explicitRangeForError(model, error)
  if (explicit) return explicit

  const tokenRange = tokenRangeForError(model, errorMessage(error))
  if (tokenRange) return tokenRange

  const firstLine = firstNonBlankLine(model)
  const text = model.getLineContent(firstLine)
  const startIndex = text.search(/\S/)
  const startColumn = startIndex >= 0 ? startIndex + 1 : 1

  return {
    startLineNumber: firstLine,
    startColumn,
    endLineNumber: firstLine,
    endColumn: Math.max(startColumn + 1, model.getLineMaxColumn(firstLine)),
  }
}

function explicitRangeForError(model, error) {
  if (!error || typeof error !== "object") return null

  const line = integerInRange(error.line || error.startLineNumber, 1, model.getLineCount())
  const column = integerInRange(error.column || error.startColumn, 1, model.getLineMaxColumn(line || 1))
  if (!line || !column) return null

  const endLine = integerInRange(error.endLine || error.endLineNumber, line, model.getLineCount()) || line
  const endColumn =
    integerInRange(error.endColumn, column + 1, model.getLineMaxColumn(endLine)) ||
    Math.min(column + String(error.token || "").length + 1, model.getLineMaxColumn(endLine)) ||
    column + 1

  return {
    startLineNumber: line,
    startColumn: column,
    endLineNumber: endLine,
    endColumn: Math.max(column + 1, endColumn),
  }
}

function tokenRangeForError(model, message) {
  const candidates = errorTokenCandidates(message)

  for (const candidate of candidates) {
    for (let lineNumber = 1; lineNumber <= model.getLineCount(); lineNumber += 1) {
      const line = model.getLineContent(lineNumber)
      const index = line.indexOf(candidate)
      if (index >= 0) {
        return {
          startLineNumber: lineNumber,
          startColumn: index + 1,
          endLineNumber: lineNumber,
          endColumn: index + candidate.length + 1,
        }
      }
    }
  }

  return null
}

function errorTokenCandidates(message) {
  if (!message) return []

  const quoted = [...String(message).matchAll(/["']([^"']{1,160})["']/g)].map(match => match[1])
  const bare =
    String(message)
      .match(/\b(?:in|time|sort|limit|bucket|agg|value_field|series|[a-zA-Z_][\w.-]*):[^\s,\]}]+/g) || []

  return [...quoted, ...bare]
    .map(candidate => candidate.trim())
    .filter(candidate => candidate.length > 0)
    .sort((a, b) => b.length - a.length)
}

function firstNonBlankLine(model) {
  for (let lineNumber = 1; lineNumber <= model.getLineCount(); lineNumber += 1) {
    if (model.getLineContent(lineNumber).trim() !== "") return lineNumber
  }

  return 1
}

function integerInRange(value, min, max) {
  const integer = Number(value)
  if (!Number.isInteger(integer)) return null
  return Math.min(max, Math.max(min, integer))
}
