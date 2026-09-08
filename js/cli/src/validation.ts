// Static check of a dashboard project. Same code path the build invokes
// pre-flight; lifted into a standalone command so authors can run it without
// bundling. Two layers:
//
//  1. JSON Schema (ajv, draft 2020-12) catches typos
//     (additionalProperties), wrong primitives (type), bad id / version
//     patterns, and missing required fields with structured error paths.
//  2. File-system + cross-reference checks confirm the renderer entry and
//     declared sample-frames / sample-settings actually exist on disk and
//     match the manifest's data-frame declarations.
//
// Schema-layer failures short-circuit the file-system layer so authors aren't
// drowned in noisy downstream errors when the config is structurally invalid.

import {existsSync, readFileSync} from "node:fs"
import {join, resolve} from "node:path"

import type {ErrorObject} from "ajv"

import type {NormalizedManifest} from "./manifest.js"
import {DEFAULT_RENDERER_ENTRY, normalizeManifest, rendererArtifact} from "./manifest.js"
import {SCHEMAS_DIR} from "./paths.js"
import {errorMessage, relativePath} from "./utils.js"

export interface ValidationFailure {
  category: "config" | "manifest" | "renderer" | "samples"
  message: string
  where?: string
  suggest?: string
}

export interface ValidationResult {
  failures: ValidationFailure[]
  notes: string[]
}

export async function validateProject(
  projectDir: string,
  config: Record<string, any>,
  options: {skipDigestCheck?: boolean} = {},
): Promise<ValidationResult> {
  const failures: ValidationFailure[] = []
  const notes: string[] = []
  const skipDigestCheck = options.skipDigestCheck !== false

  if (!config || typeof config !== "object") {
    failures.push({category: "config", message: "dashboard config is missing or not an object", suggest: "create dashboard.config.mjs or run `serviceradar-cli dashboard init`"})
    return {failures, notes}
  }

  const schemaFailures = await validateConfigSchema(config)
  if (schemaFailures.length > 0) {
    return {failures: schemaFailures, notes}
  }

  let manifest: NormalizedManifest
  try {
    manifest = normalizeManifest(config, {
      artifact: rendererArtifact(config, {}),
      digest: skipDigestCheck ? "0".repeat(64) : "missing",
    })
  } catch (error) {
    failures.push({category: "manifest", message: errorMessage(error), suggest: "set the missing field in `dashboard.config.mjs#manifest`"})
    return {failures, notes}
  }

  notes.push(`manifest id ${manifest.id}@${manifest.version}`)
  if (Array.isArray(manifest.data_frames)) {
    notes.push(`${manifest.data_frames.length} declared data frames`)
  }

  validateRendererEntry(projectDir, config, failures)
  validateSampleFrames(projectDir, config, manifest, failures, notes)
  validateSampleSettings(projectDir, config, manifest, failures, notes)

  return {failures, notes}
}

type SchemaValidator = ((value: unknown) => boolean) & {errors?: ErrorObject[] | null}

let cachedSchemaValidator: SchemaValidator | null = null

/**
 * Lazy-loads ajv + the dashboard-config schema on first call. Subsequent
 * calls reuse the compiled validator. Returned function is the standard
 * ajv-style `(value) => boolean` with `.errors` on failure.
 */
async function getSchemaValidator(): Promise<SchemaValidator> {
  if (cachedSchemaValidator) return cachedSchemaValidator
  // Use the draft-2020-12 build of Ajv to match the `$schema` URI declared
  // in dashboard-config.schema.json. The plain `ajv` entrypoint defaults to
  // draft-07 metaschemas and would refuse to compile.
  const {default: Ajv2020} = await import("ajv/dist/2020.js")
  const schemaPath = join(SCHEMAS_DIR, "dashboard-config.schema.json")
  const schema = JSON.parse(readFileSync(schemaPath, "utf8"))
  const ajv = new Ajv2020({allErrors: true, strict: false})
  cachedSchemaValidator = ajv.compile(schema) as SchemaValidator
  return cachedSchemaValidator
}

async function validateConfigSchema(config: Record<string, unknown>): Promise<ValidationFailure[]> {
  const validate = await getSchemaValidator()
  if (validate(config)) return []
  return (validate.errors || []).map((err) => ({
    category: "config" as const,
    message: ajvErrorMessage(err),
    where: err.instancePath || "/",
    suggest: ajvErrorSuggestion(err),
  }))
}

function ajvErrorMessage(err: ErrorObject): string {
  const loc = err.instancePath || "/"
  if (err.keyword === "required") {
    return `${loc}: missing required property "${(err.params as any).missingProperty}"`
  }
  if (err.keyword === "additionalProperties") {
    return `${loc}: unknown property "${(err.params as any).additionalProperty}"`
  }
  if (err.keyword === "type") {
    const t = (err.params as any).type
    return `${loc}: expected ${Array.isArray(t) ? t.join(" or ") : t}`
  }
  if (err.keyword === "pattern") {
    return `${loc}: value "${typeof err.data === "string" ? err.data : ""}" does not match required pattern`
  }
  return `${loc}: ${err.message || "schema violation"}`
}

function ajvErrorSuggestion(err: ErrorObject): string | undefined {
  if (err.keyword === "required") {
    return `add "${(err.params as any).missingProperty}" under ${err.instancePath || "the config root"}`
  }
  if (err.keyword === "additionalProperties") {
    return `remove "${(err.params as any).additionalProperty}" or check for typos against the dashboard-config schema`
  }
  if (err.keyword === "pattern" && err.instancePath?.endsWith("/id")) {
    return "use a reverse-DNS package id like com.acme.network"
  }
  if (err.keyword === "pattern" && err.instancePath?.endsWith("/version")) {
    return "use semver, e.g. 1.0.0 or 0.2.1-beta.4"
  }
  if (err.keyword === "pattern" && err.instancePath?.endsWith("/sha256")) {
    return "rebuild via `serviceradar-cli dashboard build` so the digest is regenerated"
  }
  return undefined
}

function validateRendererEntry(projectDir: string, config: Record<string, any>, failures: ValidationFailure[]): void {
  const entry = resolve(projectDir, config.renderer?.entry || config.entry || DEFAULT_RENDERER_ENTRY)
  if (!existsSync(entry)) {
    failures.push({
      category: "renderer",
      message: `renderer entry does not exist: ${relativePath(projectDir, entry)}`,
      where: relativePath(projectDir, entry),
      suggest: "set `renderer.entry` in dashboard.config.mjs to the correct path, or create the entry file",
    })
  }
}

function validateSampleFrames(
  projectDir: string,
  config: Record<string, any>,
  manifest: NormalizedManifest,
  failures: ValidationFailure[],
  notes: string[],
): void {
  const spec = config.samples?.frames
  if (!spec) return
  const source = typeof spec === "string" ? spec : spec.source
  if (!source) return
  const path = resolve(projectDir, source)
  if (!existsSync(path)) {
    failures.push({
      category: "samples",
      message: `samples.frames source does not exist: ${relativePath(projectDir, path)}`,
      where: relativePath(projectDir, path),
      suggest: "create the sample frames JSON or update `samples.frames`",
    })
    return
  }

  let payload: any
  try {
    payload = JSON.parse(readFileSync(path, "utf8"))
  } catch (error: any) {
    failures.push({
      category: "samples",
      message: `samples.frames is not valid JSON: ${error.message}`,
      where: relativePath(projectDir, path),
    })
    return
  }

  const frames = Array.isArray(payload) ? payload : Array.isArray(payload?.frames) ? payload.frames : null
  if (!Array.isArray(frames)) {
    failures.push({
      category: "samples",
      message: "samples.frames must be a frame array or an object with a `frames` array",
      where: relativePath(projectDir, path),
    })
    return
  }

  const declaredFrames = Array.isArray(manifest.data_frames) ? manifest.data_frames : []
  const declaredById = new Map(declaredFrames.map((entry) => [String(entry.id), entry]))
  const sampleIds = new Set<string>()

  for (let index = 0; index < frames.length; index += 1) {
    const frame = frames[index]
    if (!frame || typeof frame !== "object") {
      failures.push({
        category: "samples",
        message: `samples.frames[${index}] is not an object`,
        where: relativePath(projectDir, path),
      })
      continue
    }
    const id = String(frame.id || "")
    if (!id) {
      failures.push({
        category: "samples",
        message: `samples.frames[${index}] is missing an id`,
        where: relativePath(projectDir, path),
      })
      continue
    }
    sampleIds.add(id)
    if (declaredById.size > 0 && !declaredById.has(id)) {
      notes.push(`samples.frames[${index}].id "${id}" is not declared in manifest.data_frames; harness will still load it`)
    }
    const results = frame.results ?? frame.rows
    if (results !== undefined && !Array.isArray(results)) {
      failures.push({
        category: "samples",
        message: `samples.frames[${index}].results must be an array when present`,
        where: relativePath(projectDir, path),
      })
    }
  }

  for (const declared of declaredFrames) {
    if (declared.required === false) continue
    if (!sampleIds.has(String(declared.id))) {
      failures.push({
        category: "samples",
        message: `manifest.data_frames declares "${declared.id}" but samples.frames does not provide a sample`,
        where: relativePath(projectDir, path),
        suggest: "add a sample frame for this id, or mark the manifest entry with `required: false`",
      })
    }
  }
}

function validateSampleSettings(
  projectDir: string,
  config: Record<string, any>,
  manifest: NormalizedManifest,
  failures: ValidationFailure[],
  notes: string[],
): void {
  const spec = config.samples?.settings
  if (!spec) return
  const source = typeof spec === "string" ? spec : spec.source
  if (!source) return
  const path = resolve(projectDir, source)
  if (!existsSync(path)) {
    failures.push({
      category: "samples",
      message: `samples.settings source does not exist: ${relativePath(projectDir, path)}`,
      where: relativePath(projectDir, path),
      suggest: "create the sample settings JSON or update `samples.settings`",
    })
    return
  }
  try {
    const payload = JSON.parse(readFileSync(path, "utf8"))
    if (manifest.settings_schema && typeof manifest.settings_schema === "object") {
      const declaredKeys = Array.isArray(manifest.settings_schema.required)
        ? manifest.settings_schema.required
        : []
      const provided = payload && typeof payload === "object" ? Object.keys(payload) : []
      for (const key of declaredKeys) {
        if (!provided.includes(key)) {
          notes.push(`samples.settings is missing the schema-declared key "${key}"`)
        }
      }
    }
  } catch (error: any) {
    failures.push({
      category: "samples",
      message: `samples.settings is not valid JSON: ${error.message}`,
      where: relativePath(projectDir, path),
    })
  }
}

export function formatValidationFailures(failures: ValidationFailure[]): string {
  const header = "Dashboard config validation failed:"
  const body = failures.map((failure) => {
    const lines = [`  ✗ [${failure.category}] ${failure.message}`]
    if (failure.where) lines.push(`      at ${failure.where}`)
    if (failure.suggest) lines.push(`      → ${failure.suggest}`)
    return lines.join("\n")
  })
  return [header, ...body].join("\n")
}
