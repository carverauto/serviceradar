// Deterministic canonical JSON serialization and SHA-256 helpers shared by
// Solution Pack validation, `.srpack` archive building, `UploadSignature`
// verification payload construction, and `serviceradar-pack-index.json`.
//
// Matches `ServiceRadarWebNG.Plugins.UploadSignature.write_canonical_json/1`
// and `build/wasm_plugins/upload_signature_tool.go` byte-for-byte:
//   - Object keys sorted in UTF-8 lexicographical byte order at every level
//     (independent of V8 integer-index property iteration order).
//   - Minimal RFC 8259 string escaping (`<`, `>`, and `&` stay literal, never
//     HTML-escaped).
//   - Empty arrays serialize as `[]` and empty objects serialize as `{}`.

import {createHash} from "node:crypto"

export interface PackValidationIssue {
  file: string
  path: string
  code: string
  message: string
}

export function compareUtf8Keys(a: string, b: string): number {
  if (a === b) return 0
  return Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"))
}

export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value) && !Buffer.isBuffer(value)
}

export function sha256Hex(data: Buffer | string): string {
  return createHash("sha256").update(data).digest("hex")
}

export function normalizeSha256Hex(value: string): string {
  return value.trim().toLowerCase()
}

export function writeCanonicalJson(value: unknown): string {
  if (value === null || typeof value === "boolean") {
    return JSON.stringify(value)
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error(`non-finite JSON number is not permitted: ${String(value)}`)
    }
    return JSON.stringify(Object.is(value, -0) ? 0 : value)
  }
  if (typeof value === "string") {
    return JSON.stringify(value)
  }
  if (Array.isArray(value)) {
    if (value.length === 0) return "[]"
    return "[" + value.map((item) => writeCanonicalJson(item === undefined ? null : item)).join(",") + "]"
  }
  if (isPlainObject(value)) {
    const entries = Object.entries(value)
      .filter(([, child]) => child !== undefined)
      .sort(([keyA], [keyB]) => compareUtf8Keys(keyA, keyB))
    if (entries.length === 0) return "{}"
    return (
      "{" +
      entries
        .map(([key, child]) => `${JSON.stringify(key)}:${writeCanonicalJson(child)}`)
        .join(",") +
      "}"
    )
  }
  throw new Error(`unsupported JSON value type: ${typeof value}`)
}

export function writeCanonicalJsonPretty(value: unknown, indent = 0): string {
  return formatCanonicalPretty(value, indent) + "\n"
}

function formatCanonicalPretty(value: unknown, depth: number): string {
  if (
    value === null ||
    typeof value === "boolean" ||
    typeof value === "number" ||
    typeof value === "string"
  ) {
    return writeCanonicalJson(value)
  }
  const pad = "  ".repeat(depth)
  const childPad = "  ".repeat(depth + 1)

  if (Array.isArray(value)) {
    if (value.length === 0) return "[]"
    const items = value.map(
      (item) => `${childPad}${formatCanonicalPretty(item === undefined ? null : item, depth + 1)}`,
    )
    return `[\n${items.join(",\n")}\n${pad}]`
  }

  if (isPlainObject(value)) {
    const entries = Object.entries(value)
      .filter(([, child]) => child !== undefined)
      .sort(([keyA], [keyB]) => compareUtf8Keys(keyA, keyB))
    if (entries.length === 0) return "{}"
    const lines = entries.map(
      ([key, child]) => `${childPad}${JSON.stringify(key)}: ${formatCanonicalPretty(child, depth + 1)}`,
    )
    return `{\n${lines.join(",\n")}\n${pad}}`
  }

  throw new Error(`unsupported JSON value type: ${typeof value}`)
}
