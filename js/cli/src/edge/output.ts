// Output helpers for the edge onboarding commands. `--json` always prints one
// JSON document on stdout (an array for lists, an object otherwise) so scripts
// can pipe it to `jq`; without it, lists render as aligned tables and single
// records as `key: value` blocks.

import {writeFile} from "node:fs/promises"
import {basename, resolve} from "node:path"

export interface Column {
  header: string
  value: (row: any) => unknown
}

export function wantsJson(options: Record<string, any>): boolean {
  return options.json === true
}

export function printJson(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`)
}

export function cell(value: unknown): string {
  if (value === null || value === undefined || value === "") return "-"
  if (typeof value === "object") return JSON.stringify(value)
  return String(value)
}

export function printTable(rows: any[], columns: Column[], emptyMessage: string): void {
  if (rows.length === 0) {
    console.log(emptyMessage)
    return
  }
  const matrix = rows.map((row) => columns.map((column) => cell(column.value(row))))
  const widths = columns.map((column, index) =>
    Math.max(column.header.length, ...matrix.map((cells) => cells[index].length)),
  )
  const line = (cells: string[]) =>
    cells.map((value, index) => (index === cells.length - 1 ? value : value.padEnd(widths[index]))).join("  ")
  console.log(line(columns.map((column) => column.header)))
  for (const cells of matrix) console.log(line(cells))
}

export function printRecord(title: string, fields: Array<[string, unknown]>): void {
  console.log(title)
  const width = Math.max(...fields.map(([key]) => key.length))
  for (const [key, value] of fields) {
    console.log(`  ${`${key}:`.padEnd(width + 1)} ${cell(value)}`)
  }
}

/** Name from a `content-disposition: attachment; filename="..."` header, if safe. */
export function attachmentFilename(header: string | null): string {
  if (!header) return ""
  const match = header.match(/filename="?([^";]+)"?/i)
  if (!match) return ""
  // Never let the server choose a directory: keep the basename only.
  const name = basename(match[1].trim())
  return name === "." || name === ".." ? "" : name
}

/**
 * Write a downloaded body to `-o <file>` (or `fallbackName` in the current
 * directory). `-o -` streams it to stdout. Returns the path written, or "-".
 */
export async function writeDownload(output: unknown, fallbackName: string, body: Buffer): Promise<string> {
  if (output === "-") {
    await new Promise<void>((res, rej) => {
      process.stdout.write(body, (error) => (error ? rej(error) : res()))
    })
    return "-"
  }
  const target = resolve(typeof output === "string" && output ? output : fallbackName)
  await writeFile(target, body, {mode: 0o600})
  return target
}
