// Deterministic Solution Pack release catalog index generator
// (`serviceradar pack index` -> `serviceradar-pack-index.json`).

import {existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, writeFileSync} from "node:fs"
import {basename, dirname, join, resolve} from "node:path"
import {readSrpackArchive} from "./archive.js"
import {
  compareUtf8Keys,
  isPlainObject,
  normalizeSha256Hex,
  sha256Hex,
  writeCanonicalJsonPretty,
} from "./canonical.js"
import {SIGNATURE_ALGORITHM, verifyManifestAndHash, type UploadSignatureDocument} from "./sign.js"
import {PackValidationError, validatePackFiles, type PackResourceCounts} from "./validate.js"

export const DEFAULT_PACK_INDEX_FILENAME = "serviceradar-pack-index.json"

export interface PackIndexEntry {
  id: string
  slug: string
  name: string
  version: string
  description?: string
  author?: string
  license?: string
  categories: string[]
  icon?: string
  min_serviceradar_version?: string
  bundle_file: string
  bundle_url: string
  bundle_digest: string
  sha256: string
  signature_file: string
  signature_url: string
  upload_signature_url: string
  signed: boolean
  signing_key_id?: string
  resource_counts: PackResourceCounts
  manifest: Record<string, unknown>
}

export interface PackCatalogIndex {
  format_version: 1
  packs: PackIndexEntry[]
}

export interface BuildPackIndexOptions {
  inputs: string[]
  outPath?: string
  repo?: string
  releaseTag?: string
  baseUrl?: string
  requireSignatures?: boolean
  publicKey?: string
}

export function buildPackCatalogIndex(opts: BuildPackIndexOptions): {
  indexPath: string
  index: PackCatalogIndex
} {
  const baseAssetUrl = resolveAssetBaseUrl(opts)
  const srpackPaths = discoverSrpackFiles(opts.inputs.length > 0 ? opts.inputs : [process.cwd()])

  if (srpackPaths.length === 0) {
    throw new Error("no .srpack archives found in the provided paths")
  }

  const seenPackVersions = new Set<string>()
  const entries: PackIndexEntry[] = []

  for (const srpackPath of srpackPaths) {
    const archiveBytes = readFileSync(srpackPath)
    const archiveFiles = readSrpackArchive(archiveBytes)
    const validation = validatePackFiles(archiveFiles, {
      verifyHashes: true,
      compressedBytes: archiveBytes.length,
    })
    if (!validation.ok) {
      throw new PackValidationError(validation.issues)
    }

    const {manifest, resourceCounts} = validation.result
    const id = String(manifest.id)
    const version = String(manifest.version)
    const identityKey = `${id}@${version}`
    if (seenPackVersions.has(identityKey)) {
      throw new Error(`duplicate pack version "${identityKey}" encountered while building catalog index`)
    }
    seenPackVersions.add(identityKey)

    const bundleDigest = sha256Hex(archiveBytes)
    const bundleFile = basename(srpackPath)
    const signaturePath = `${srpackPath}.sig`
    const signatureFile = `${bundleFile}.sig`

    let signed = false
    let signingKeyId: string | undefined

    if (existsSync(signaturePath)) {
      const sigRaw = JSON.parse(readFileSync(signaturePath, "utf8"))
      if (!isPlainObject(sigRaw)) {
        throw new Error(`invalid signature JSON in "${signaturePath}"`)
      }
      const sigDoc = sigRaw as unknown as UploadSignatureDocument
      if ((sigDoc.algorithm || "").trim().toLowerCase() !== SIGNATURE_ALGORITHM) {
        throw new Error(`unsupported signature algorithm in "${signaturePath}": ${String(sigDoc.algorithm)}`)
      }
      const sigHash = normalizeSha256Hex(String(sigDoc.content_hash || ""))
      if (sigHash !== bundleDigest) {
        throw new Error(
          `signature content_hash mismatch for "${bundleFile}": sig=${sigHash}, archive=${bundleDigest}`,
        )
      }
      if (!sigDoc.key_id || typeof sigDoc.key_id !== "string" || sigDoc.key_id.trim() === "") {
        throw new Error(`signature "${signaturePath}" is missing key_id`)
      }
      signingKeyId = sigDoc.key_id.trim()

      if (opts.publicKey) {
        verifyManifestAndHash({
          signatureDoc: sigDoc,
          manifest,
          contentHash: bundleDigest,
          trustedPublicKeys: {
            [signingKeyId]: opts.publicKey,
          },
        })
      }
      signed = true
    } else if (opts.requireSignatures) {
      throw new Error(`missing required signature file "${signaturePath}" for "${bundleFile}"`)
    }

    const bundleUrl = baseAssetUrl ? `${baseAssetUrl}/${encodeURIComponent(bundleFile)}` : bundleFile
    const signatureUrl = baseAssetUrl ? `${baseAssetUrl}/${encodeURIComponent(signatureFile)}` : signatureFile

    const entry: PackIndexEntry = {
      id,
      slug: String(manifest.slug),
      name: String(manifest.name),
      version,
      categories: Array.isArray(manifest.categories) ? (manifest.categories as string[]) : [],
      bundle_file: bundleFile,
      bundle_url: bundleUrl,
      bundle_digest: bundleDigest,
      sha256: bundleDigest,
      signature_file: signatureFile,
      signature_url: signatureUrl,
      upload_signature_url: signatureUrl,
      signed,
      resource_counts: resourceCounts,
      manifest,
    }

    if (typeof manifest.description === "string") entry.description = manifest.description
    if (typeof manifest.author === "string") entry.author = manifest.author
    if (typeof manifest.license === "string") entry.license = manifest.license
    if (typeof manifest.icon === "string") entry.icon = manifest.icon
    if (typeof manifest.min_serviceradar_version === "string") {
      entry.min_serviceradar_version = manifest.min_serviceradar_version
    }
    if (signingKeyId) entry.signing_key_id = signingKeyId

    entries.push(entry)
  }

  entries.sort((a, b) => {
    const byId = compareUtf8Keys(a.id, b.id)
    if (byId !== 0) return byId
    return compareUtf8Keys(a.version, b.version)
  })

  const index: PackCatalogIndex = {
    format_version: 1,
    packs: entries,
  }

  const indexPath = resolve(opts.outPath || DEFAULT_PACK_INDEX_FILENAME)
  mkdirSync(dirname(indexPath), {recursive: true})
  writeFileSync(indexPath, writeCanonicalJsonPretty(index), "utf8")

  return {indexPath, index}
}

function resolveAssetBaseUrl(opts: BuildPackIndexOptions): string {
  const baseUrl = (opts.baseUrl || "").trim().replace(/\/+$/, "")
  const repo = (opts.repo || "").trim().replace(/\/+$/, "").replace(/\.git$/, "")
  const tag = (opts.releaseTag || "").trim()

  if (baseUrl && repo) {
    throw new Error("pass either --base-url or --repo/--release-tag, not both")
  }
  if (baseUrl) {
    return baseUrl
  }
  if (repo) {
    if (!tag) {
      throw new Error("--release-tag is required when --repo is specified")
    }
    const repoWebUrl = repo.startsWith("https://") || repo.startsWith("http://")
      ? repo
      : `https://github.com/${repo}`
    return `${repoWebUrl}/releases/download/${encodeURIComponent(tag)}`
  }
  if (tag) {
    throw new Error("--repo is required when --release-tag is specified")
  }
  return ""
}

function discoverSrpackFiles(inputs: string[]): string[] {
  const found = new Set<string>()

  function walkDir(dirPath: string): void {
    const entries = readdirSync(dirPath).sort(compareUtf8Keys)
    for (const name of entries) {
      if (name.startsWith(".") || name === "node_modules") continue
      const full = join(dirPath, name)
      const st = lstatSync(full)
      if (st.isSymbolicLink()) continue
      if (st.isDirectory()) {
        walkDir(full)
      } else if (st.isFile() && name.endsWith(".srpack")) {
        found.add(resolve(full))
      }
    }
  }

  for (const input of inputs) {
    const resolved = resolve(input)
    const st = lstatSync(resolved)
    if (st.isSymbolicLink()) {
      throw new Error(`unsafe symlink input "${input}"`)
    }
    if (st.isDirectory()) {
      walkDir(resolved)
    } else if (st.isFile()) {
      if (!resolved.endsWith(".srpack")) {
        throw new Error(`expected a .srpack file or directory, got "${input}"`)
      }
      found.add(resolved)
    }
  }

  return Array.from(found).sort(compareUtf8Keys)
}

export async function indexCommand(options: Record<string, unknown>): Promise<void> {
  const inputs = ((options._ as string[] | undefined) || []).slice()
  const outPath = (options.out || options.output) as string | undefined
  const repo = (options.repo || options.githubRepo) as string | undefined
  const releaseTag = (options.releaseTag || options.tag) as string | undefined
  const baseUrl = options.baseUrl as string | undefined
  const pubOpt = (options.publicKey || options.pubKey) as string | undefined
  const publicKey =
    pubOpt && existsSync(pubOpt.trim())
      ? readFileSync(pubOpt.trim(), "utf8").trim()
      : pubOpt?.trim()

  const built = buildPackCatalogIndex({
    inputs,
    outPath,
    repo,
    releaseTag,
    baseUrl,
    requireSignatures: Boolean(options.requireSignatures),
    publicKey,
  })

  if (options.json) {
    console.log(
      JSON.stringify(
        {
          output: built.indexPath,
          pack_count: built.index.packs.length,
          packs: built.index.packs.map((p) => ({
            id: p.id,
            version: p.version,
            bundle_url: p.bundle_url,
            sha256: p.sha256,
            signed: p.signed,
          })),
        },
        null,
        2,
      ),
    )
    return
  }

  console.log(`Wrote catalog index (${built.index.packs.length} pack${built.index.packs.length === 1 ? "" : "s"}) -> ${built.indexPath}`)
}
