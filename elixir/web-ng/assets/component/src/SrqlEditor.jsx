import React, {useEffect, useRef} from "react"
import {applySrqlMarkers, createSrqlEditor, ensureSrqlLanguage} from "../../js/lib/srql/monaco_srql.js"

export default function SrqlEditor({value, onChange, completions = [], disabled = false, error = null, compact = false}) {
  const containerRef = useRef(null)
  const editorRef = useRef(null)
  const monacoRef = useRef(null)
  const onChangeRef = useRef(onChange)

  useEffect(() => {
    onChangeRef.current = onChange
  }, [onChange])

  useEffect(() => {
    if (!containerRef.current || editorRef.current) return undefined

    let disposed = false
    let subscription = null

    createSrqlEditor(containerRef.current, {value, completions, disabled, error, compact}).then(({monaco, editor}) => {
      if (disposed) {
        editor.dispose()
        return
      }

      monacoRef.current = monaco
      editorRef.current = editor
      subscription = editor.onDidChangeModelContent(() => onChangeRef.current(editor.getValue()))
    })

    return () => {
      disposed = true
      subscription?.dispose()
      editorRef.current?.dispose()
      editorRef.current = null
      monacoRef.current = null
    }
  }, [compact, disabled])

  useEffect(() => {
    if (!monacoRef.current) return
    ensureSrqlLanguage(monacoRef.current, completions)
  }, [completions])

  useEffect(() => {
    const editor = editorRef.current
    if (!editor) return
    const current = editor.getValue()
    if (current === (value || "")) return

    editor.setValue(value || "")
  }, [value])

  useEffect(() => {
    if (!monacoRef.current || !editorRef.current) return
    applySrqlMarkers(monacoRef.current, editorRef.current, error)
  }, [error])

  return (
    <div
      ref={containerRef}
      className={`${compact ? "h-9" : "min-h-28"} overflow-hidden rounded-lg border border-base-300 bg-base-100`}
    />
  )
}
