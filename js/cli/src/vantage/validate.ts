// `serviceradar vantage validate` — validates a Vantage Solution Pack v2
// workspace (manifest, pipelines, signal_schemas, dashboard_packages, and
// optional worker entrypoints / secret-free checks).

import {existsSync, lstatSync, readdirSync, readFileSync} from "node:fs"
import {join, resolve} from "node:path"
import {collectPackDirectoryFiles, isVantageDevAuthoringPath} from "../pack/archive.js"
import {isPlainObject, type PackValidationIssue} from "../pack/canonical.js"
import {scanRawTextSecrets} from "../pack/secret_free.js"
import {
  PackValidationError,
  validatePackFiles,
  type PackResourceCounts,
} from "../pack/validate.js"

const WORKER_TEXT_EXTS = new Set([".py", ".rs", ".toml", ".json", ".md", ".txt"])
const IGNORED_WORKER_DIRS = new Set(["target", ".venv", "__pycache__", "node_modules", ".git"])

export interface ValidatedVantageProject {
  resolvedDir: string
  manifest: Record<string, unknown>
  files: Map<string, Buffer>
  resourceCounts: PackResourceCounts
  fileCount: number
  workerKind: "vlm" | "python-worker" | "rust-worker"
  pipelines: Array<Record<string, unknown>>
  signalSchemas: Map<string, Record<string, unknown>>
}

export function validateVantageProject(targetDir: string): ValidatedVantageProject {
  const resolvedDir = resolve(targetDir)
  if (!existsSync(resolvedDir)) {
    throw new Error(`vantage directory does not exist: "${resolvedDir}"`)
  }
  const st = lstatSync(resolvedDir)
  if (!st.isDirectory()) {
    throw new Error(`vantage target must be a directory: "${resolvedDir}"`)
  }

  const packFiles = collectPackDirectoryFiles(resolvedDir, {
    excludePath: isVantageDevAuthoringPath,
  })
  const validation = validatePackFiles(packFiles, {verifyHashes: true})
  if (!validation.ok) {
    throw new PackValidationError(validation.issues)
  }

  const {manifest, resourceCounts, computedFileDigests} = validation.result
  const issues: PackValidationIssue[] = []

  if (manifest.pack_format_version !== 2) {
    issues.push({
      file: "manifest.json",
      path: "$.pack_format_version",
      code: "vantage_requires_pack_v2",
      message: `vantage projects require pack_format_version 2, got ${JSON.stringify(manifest.pack_format_version)}`,
    })
  }

  if ((resourceCounts.vantage_pipelines ?? 0) === 0) {
    issues.push({
      file: "manifest.json",
      path: "$.resources.vantage_pipelines",
      code: "missing_vantage_pipelines",
      message: "vantage project must declare at least one entry in resources.vantage_pipelines",
    })
  }

  let workerKind: "vlm" | "python-worker" | "rust-worker" = "vlm"
  const workerDir = join(resolvedDir, "worker")
  const cargoToml = join(resolvedDir, "Cargo.toml")

  if (existsSync(workerDir)) {
    workerKind = "python-worker"
    if (!existsSync(join(workerDir, "main.py")) && !existsSync(join(workerDir, "__init__.py"))) {
      issues.push({
        file: "worker/main.py",
        path: "$",
        code: "missing_python_worker_entrypoint",
        message: "python-worker project requires worker/main.py or worker/__init__.py",
      })
    }
    scanWorkerTree(workerDir, "worker", issues)
  } else if (existsSync(cargoToml)) {
    workerKind = "rust-worker"
    const mainRs = join(resolvedDir, "src/main.rs")
    if (!existsSync(mainRs)) {
      issues.push({
        file: "src/main.rs",
        path: "$",
        code: "missing_rust_worker_entrypoint",
        message: "rust-worker project requires src/main.rs",
      })
    }
    issues.push(...scanRawTextSecrets(readFileSync(cargoToml, "utf8"), "Cargo.toml"))
    if (existsSync(join(resolvedDir, "src"))) {
      scanWorkerTree(join(resolvedDir, "src"), "src", issues)
    }
  }

  if (issues.length > 0) {
    throw new PackValidationError(issues)
  }

  const pipelines: Array<Record<string, unknown>> = []
  const res = isPlainObject(manifest.resources) ? manifest.resources : {}
  if (Array.isArray(res.vantage_pipelines)) {
    for (const entry of res.vantage_pipelines) {
      if (isPlainObject(entry) && typeof entry.file === "string") {
        const buf = packFiles.get(entry.file)
        if (buf) {
          pipelines.push(JSON.parse(buf.toString("utf8")) as Record<string, unknown>)
        }
      }
    }
  }

  const signalSchemas = new Map<string, Record<string, unknown>>()
  if (Array.isArray(res.signal_schemas)) {
    for (const entry of res.signal_schemas) {
      if (isPlainObject(entry) && typeof entry.id === "string") {
        const file = (entry.schema_file ?? entry.file) as string | undefined
        if (typeof file === "string") {
          const buf = packFiles.get(file)
          if (buf) {
            signalSchemas.set(entry.id, JSON.parse(buf.toString("utf8")) as Record<string, unknown>)
          }
        }
      }
    }
  }

  return {
    resolvedDir,
    manifest,
    files: packFiles,
    resourceCounts,
    fileCount: Object.keys(computedFileDigests).length,
    workerKind,
    pipelines,
    signalSchemas,
  }
}

function scanWorkerTree(absDir: string, relPrefix: string, issues: PackValidationIssue[]): void {
  for (const entry of readdirSync(absDir, {withFileTypes: true})) {
    if (IGNORED_WORKER_DIRS.has(entry.name)) {
      continue
    }
    const full = join(absDir, entry.name)
    const rel = `${relPrefix}/${entry.name}`
    if (entry.isSymbolicLink()) {
      issues.push({
        file: rel,
        path: "$",
        code: "unsafe_symlink",
        message: `unsafe symlink in worker directory: "${rel}"`,
      })
      continue
    }
    if (entry.isDirectory()) {
      scanWorkerTree(full, rel, issues)
      continue
    }
    if (entry.isFile()) {
      const dotIdx = entry.name.lastIndexOf(".")
      const ext = dotIdx >= 0 ? entry.name.slice(dotIdx).toLowerCase() : ""
      if (WORKER_TEXT_EXTS.has(ext)) {
        issues.push(...scanRawTextSecrets(readFileSync(full, "utf8"), rel))
      }
    }
  }
}

export async function validateCommand(options: Record<string, unknown>): Promise<void> {
  const positional = (options._ as string[] | undefined) || []
  const targetDir = (positional[0] || options.dir || process.cwd()) as string
  const validated = validateVantageProject(targetDir)

  if (options.json) {
    console.log(
      JSON.stringify(
        {
          valid: true,
          path: validated.resolvedDir,
          pack_format_version: validated.manifest.pack_format_version,
          id: validated.manifest.id,
          slug: validated.manifest.slug,
          version: validated.manifest.version,
          worker_kind: validated.workerKind,
          resource_counts: validated.resourceCounts,
          file_count: validated.fileCount,
        },
        null,
        2,
      ),
    )
    return
  }

  console.log(
    `Vantage pack is valid: ${String(validated.manifest.id)}@${String(validated.manifest.version)} (worker: ${validated.workerKind}, ${validated.resourceCounts.vantage_pipelines ?? 0} pipelines, ${validated.resourceCounts.signal_schemas ?? 0} signal_schemas, ${validated.resourceCounts.dashboard_packages ?? 0} dashboard_packages, ${validated.fileCount} files)`,
  )
}
