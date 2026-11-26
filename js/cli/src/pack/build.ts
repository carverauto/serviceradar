// Deterministic `.srpack` archive builder (`serviceradar pack build`).

import {mkdirSync, writeFileSync} from "node:fs"
import {dirname, resolve} from "node:path"
import {
  buildSrpackArchive,
  collectPackDirectoryFiles,
  isVantageDevAuthoringPath,
  MAX_COMPRESSED_ARCHIVE_BYTES,
  MAX_UNCOMPRESSED_ARCHIVE_BYTES,
  MAX_V2_DASHBOARD_COMPRESSED_ARCHIVE_BYTES,
  MAX_V2_DASHBOARD_UNCOMPRESSED_ARCHIVE_BYTES,
  type ArchiveEntry,
} from "./archive.js"
import {isPlainObject, sha256Hex, writeCanonicalJsonPretty} from "./canonical.js"
import {
  computePackFileDigests,
  isVantagePackDirectory,
  PackValidationError,
  validatePackFiles,
  type PackResourceCounts,
} from "./validate.js"

export interface BuildPackOptions {
  dir: string
  outPath?: string
  refreshFiles?: boolean
  writeManifest?: boolean
}

export interface BuildPackResult {
  archivePath: string
  archiveBytes: Buffer
  sha256: string
  manifest: Record<string, unknown>
  resourceCounts: PackResourceCounts
}

export function buildPackFromDirectory(opts: BuildPackOptions): BuildPackResult {
  const resolvedDir = resolve(opts.dir)
  const excludePath = isVantagePackDirectory(resolvedDir) ? isVantageDevAuthoringPath : undefined
  const files = collectPackDirectoryFiles(resolvedDir, {excludePath})

  const manifestBuf = files.get("manifest.json")
  if (!manifestBuf) {
    throw new Error(`pack directory "${opts.dir}" is missing manifest.json`)
  }

  let parsedManifest: unknown
  try {
    parsedManifest = JSON.parse(manifestBuf.toString("utf8"))
  } catch (err: any) {
    throw new Error(`manifest.json is not valid JSON: ${err?.message || String(err)}`)
  }
  if (!isPlainObject(parsedManifest)) {
    throw new Error("manifest.json root must be a JSON object")
  }

  const computedDigests = computePackFileDigests(files)
  const existingFiles = parsedManifest.files
  const hasExistingEntries = isPlainObject(existingFiles) && Object.keys(existingFiles).length > 0
  const shouldRefresh = Boolean(opts.refreshFiles || opts.writeManifest || !hasExistingEntries)

  const workingFiles = new Map<string, Buffer>(files)

  if (shouldRefresh) {
    const refreshedManifest: Record<string, unknown> = {
      ...parsedManifest,
      files: computedDigests,
    }
    const serializedManifest = Buffer.from(writeCanonicalJsonPretty(refreshedManifest), "utf8")
    workingFiles.set("manifest.json", serializedManifest)
    if (opts.writeManifest || opts.refreshFiles) {
      writeFileSync(resolve(resolvedDir, "manifest.json"), serializedManifest)
    }
  }

  const validation = validatePackFiles(workingFiles, {verifyHashes: true})
  if (!validation.ok) {
    throw new PackValidationError(validation.issues)
  }

  const {manifest, resourceCounts} = validation.result
  const hasDashboardPackages =
    manifest.pack_format_version === 2 &&
    ((isPlainObject(manifest.resources) &&
      Array.isArray(manifest.resources.dashboard_packages) &&
      manifest.resources.dashboard_packages.length > 0) ||
      Array.from(workingFiles.keys()).some((p) => p.startsWith("dashboard_packages/")))

  const maxCompressedBytes = hasDashboardPackages
    ? MAX_V2_DASHBOARD_COMPRESSED_ARCHIVE_BYTES
    : MAX_COMPRESSED_ARCHIVE_BYTES
  const maxUncompressedBytes = hasDashboardPackages
    ? MAX_V2_DASHBOARD_UNCOMPRESSED_ARCHIVE_BYTES
    : MAX_UNCOMPRESSED_ARCHIVE_BYTES

  // Canonicalize manifest.json inside the archive if it wasn't already refreshed
  // so line endings or whitespace differences across OS checkouts never alter the
  // `.srpack` archive digest.
  const canonicalManifestBytes = Buffer.from(writeCanonicalJsonPretty(manifest), "utf8")
  workingFiles.set("manifest.json", canonicalManifestBytes)

  const entries: ArchiveEntry[] = []
  for (const [path, data] of workingFiles.entries()) {
    entries.push({path, data, mode: 0o644})
  }

  const archiveBytes = buildSrpackArchive(entries, {
    maxCompressedBytes,
    maxUncompressedBytes,
  })
  const digest = sha256Hex(archiveBytes)

  const defaultFileName = `${String(manifest.slug)}-${String(manifest.version)}.srpack`
  const archivePath = resolve(opts.outPath || defaultFileName)
  mkdirSync(dirname(archivePath), {recursive: true})
  writeFileSync(archivePath, archiveBytes)

  return {
    archivePath,
    archiveBytes,
    sha256: digest,
    manifest,
    resourceCounts,
  }
}

export async function buildCommand(options: Record<string, unknown>): Promise<void> {
  const positional = (options._ as string[] | undefined) || []
  const dir = (positional[0] || options.dir || process.cwd()) as string
  const outPath = (options.out || options.output) as string | undefined

  const built = buildPackFromDirectory({
    dir,
    outPath,
    refreshFiles: Boolean(options.refreshFiles),
    writeManifest: Boolean(options.writeManifest),
  })

  if (options.json) {
    console.log(
      JSON.stringify(
        {
          id: built.manifest.id,
          slug: built.manifest.slug,
          version: built.manifest.version,
          output: built.archivePath,
          sha256: built.sha256,
          size_bytes: built.archiveBytes.length,
          resource_counts: built.resourceCounts,
        },
        null,
        2,
      ),
    )
    return
  }

  console.log(`Built ${String(built.manifest.id)}@${String(built.manifest.version)} -> ${built.archivePath}`)
  console.log(`  sha256: ${built.sha256}`)
  console.log(`  size:   ${built.archiveBytes.length} bytes`)
}
