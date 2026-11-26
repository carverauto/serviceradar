// Ed25519 `UploadSignature` key generation, signing, and verification for
// `.srpack` Solution Pack archives (`serviceradar pack keygen|sign|verify`).
//
// Matches `ServiceRadarWebNG.Plugins.UploadSignature` and
// `build/wasm_plugins/upload_signature_tool.go` byte-for-byte:
//   - Canonical verification payload:
//       {"content_hash":"<lowercase-sha256>","manifest":<canonical-manifest>}
//   - Signature JSON document:
//       {
//         "algorithm": "ed25519",
//         "key_id": "<key-id>",
//         "signer": "<signer>",
//         "content_hash": "<lowercase-sha256>",
//         "signature": "<base64-std>"
//       }

import {
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign as cryptoSign,
  verify as cryptoVerify,
  type KeyObject,
} from "node:crypto"
import {existsSync, mkdirSync, readFileSync, writeFileSync} from "node:fs"
import {dirname, join, resolve} from "node:path"
import {readSrpackArchive} from "./archive.js"
import {isPlainObject, normalizeSha256Hex, sha256Hex, writeCanonicalJson} from "./canonical.js"
import {PackValidationError, validatePackFiles} from "./validate.js"

export const SIGNATURE_ALGORITHM = "ed25519"

// RFC 8410 ASN.1 DER prefixes for raw 32-byte Ed25519 keys.
const ED25519_PKCS8_PREFIX = Buffer.from("302e020100300506032b657004220420", "hex")
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex")

export interface UploadSignatureDocument {
  algorithm: string
  key_id: string
  signer?: string
  content_hash: string
  signature: string
}

export interface GeneratedKeypair {
  keyId: string
  privateKeySeedBase64: string
  publicKeyBase64: string
  seedBytes: Buffer
  publicKeyBytes: Buffer
}

export function generateEd25519Keypair(keyId = "pack-signing-1"): GeneratedKeypair {
  const {publicKey, privateKey} = generateKeyPairSync("ed25519")
  const pkcs8 = privateKey.export({format: "der", type: "pkcs8"}) as Buffer
  const spki = publicKey.export({format: "der", type: "spki"}) as Buffer
  const seedBytes = Buffer.from(pkcs8.subarray(pkcs8.length - 32))
  const publicKeyBytes = Buffer.from(spki.subarray(spki.length - 32))

  return {
    keyId,
    privateKeySeedBase64: seedBytes.toString("base64"),
    publicKeyBase64: publicKeyBytes.toString("base64"),
    seedBytes,
    publicKeyBytes,
  }
}

export function buildVerificationPayload(
  manifest: Record<string, unknown>,
  contentHash: string,
): Buffer {
  const payloadObj = {
    content_hash: normalizeSha256Hex(contentHash),
    manifest,
  }
  return Buffer.from(writeCanonicalJson(payloadObj), "utf8")
}

export function decodeSigningBytes(encoded: string): Buffer {
  const clean = encoded.trim()
  if (!clean) {
    throw new Error("signing key or signature value is empty")
  }

  // Hex (even number of hex chars: 64 chars = 32 bytes, 128 chars = 64 bytes)
  if (/^[0-9a-fA-F]+$/.test(clean) && clean.length % 2 === 0) {
    return Buffer.from(clean, "hex")
  }

  // Standard Base64 (padded or unpadded) or URL-safe Base64
  const normalizedB64 = clean.replace(/-/g, "+").replace(/_/g, "/")
  const padLen = (4 - (normalizedB64.length % 4)) % 4
  const padded = normalizedB64 + "=".repeat(padLen)
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(padded)) {
    throw new Error("invalid base64 or hex encoding for Ed25519 value")
  }
  return Buffer.from(padded, "base64")
}

export function parseEd25519PrivateKey(rawInput: string): {
  privateKey: KeyObject
  publicKeyBytes: Buffer
} {
  const clean = rawInput.trim()
  if (!clean) {
    throw new Error("Ed25519 private key is empty")
  }

  if (clean.includes("-----BEGIN")) {
    const privateKey = createPrivateKey(clean)
    const spki = createPublicKey(privateKey).export({format: "der", type: "spki"}) as Buffer
    return {
      privateKey,
      publicKeyBytes: Buffer.from(spki.subarray(spki.length - 32)),
    }
  }

  const keyBytes = decodeSigningBytes(clean)
  let seed: Buffer
  let expectedPub: Buffer | null = null

  if (keyBytes.length === 32) {
    seed = keyBytes
  } else if (keyBytes.length === 64) {
    // Go `ed25519.PrivateKey` format: 32-byte seed || 32-byte public key
    seed = keyBytes.subarray(0, 32)
    expectedPub = keyBytes.subarray(32, 64)
  } else {
    throw new Error(`invalid Ed25519 private key length: expected 32 or 64 bytes, got ${keyBytes.length}`)
  }

  const privateKey = createPrivateKey({
    key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]),
    format: "der",
    type: "pkcs8",
  })
  const spki = createPublicKey(privateKey).export({format: "der", type: "spki"}) as Buffer
  const publicKeyBytes = Buffer.from(spki.subarray(spki.length - 32))

  if (expectedPub && !publicKeyBytes.equals(expectedPub)) {
    throw new Error("invalid 64-byte Ed25519 private key: embedded public key does not match seed")
  }

  return {privateKey, publicKeyBytes}
}

export function parseEd25519PublicKey(rawInput: string): KeyObject {
  const clean = rawInput.trim()
  if (!clean) {
    throw new Error("Ed25519 public key is empty")
  }
  if (clean.includes("-----BEGIN")) {
    return createPublicKey(clean)
  }
  const keyBytes = decodeSigningBytes(clean)
  if (keyBytes.length !== 32) {
    throw new Error(`invalid Ed25519 public key length: expected 32 bytes, got ${keyBytes.length}`)
  }
  return createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, keyBytes]),
    format: "der",
    type: "spki",
  })
}

export function signManifestAndHash(params: {
  manifest: Record<string, unknown>
  contentHash: string
  privateKeyInput: string
  keyId: string
  signer?: string
}): UploadSignatureDocument {
  const keyId = params.keyId.trim()
  if (!keyId) {
    throw new Error("signing key id (--key-id) is required")
  }
  const signer = (params.signer || "").trim() || keyId
  const normalizedHash = normalizeSha256Hex(params.contentHash)
  const payload = buildVerificationPayload(params.manifest, normalizedHash)
  const {privateKey} = parseEd25519PrivateKey(params.privateKeyInput)
  const sigBytes = cryptoSign(null, payload, privateKey)

  return {
    algorithm: SIGNATURE_ALGORITHM,
    key_id: keyId,
    signer,
    content_hash: normalizedHash,
    signature: sigBytes.toString("base64"),
  }
}

export function verifyManifestAndHash(params: {
  signatureDoc: UploadSignatureDocument
  manifest: Record<string, unknown>
  contentHash: string
  trustedPublicKeys: Record<string, string>
}): void {
  const {signatureDoc, manifest, contentHash, trustedPublicKeys} = params
  if (!signatureDoc || typeof signatureDoc !== "object") {
    throw new Error("signature document is required")
  }
  if ((signatureDoc.algorithm || "").trim().toLowerCase() !== SIGNATURE_ALGORITHM) {
    throw new Error(`unsupported signature algorithm "${String(signatureDoc.algorithm)}"`)
  }
  const keyId = (signatureDoc.key_id || "").trim()
  if (!keyId) {
    throw new Error("signature key_id is missing")
  }
  const normalizedActualHash = normalizeSha256Hex(contentHash)
  if (signatureDoc.content_hash !== undefined) {
    const normalizedSigHash = normalizeSha256Hex(String(signatureDoc.content_hash))
    if (normalizedSigHash !== normalizedActualHash) {
      throw new Error(
        `signature content_hash mismatch: signature=${normalizedSigHash}, archive=${normalizedActualHash}`,
      )
    }
  }

  const encodedPub = trustedPublicKeys[keyId]
  if (!encodedPub) {
    throw new Error(`untrusted signing key_id "${keyId}"`)
  }

  const publicKey = parseEd25519PublicKey(encodedPub)
  const sigBytes = decodeSigningBytes(signatureDoc.signature || "")
  if (sigBytes.length !== 64) {
    throw new Error(`invalid Ed25519 signature length: expected 64 bytes, got ${sigBytes.length}`)
  }

  const payload = buildVerificationPayload(manifest, normalizedActualHash)
  const valid = cryptoVerify(null, payload, publicKey, sigBytes)
  if (!valid) {
    throw new Error("Ed25519 UploadSignature verification failed")
  }
}

export function signSrpackFile(params: {
  bundlePath: string
  outPath?: string
  privateKeyInput: string
  keyId: string
  signer?: string
}): {signaturePath: string; signatureDoc: UploadSignatureDocument; manifest: Record<string, unknown>} {
  const resolvedBundle = resolve(params.bundlePath)
  const archiveBytes = readFileSync(resolvedBundle)
  const archiveFiles = readSrpackArchive(archiveBytes)
  const validation = validatePackFiles(archiveFiles, {
    verifyHashes: true,
    compressedBytes: archiveBytes.length,
  })
  if (!validation.ok) {
    throw new PackValidationError(validation.issues)
  }

  const contentHash = sha256Hex(archiveBytes)
  const signatureDoc = signManifestAndHash({
    manifest: validation.result.manifest,
    contentHash,
    privateKeyInput: params.privateKeyInput,
    keyId: params.keyId,
    signer: params.signer,
  })

  const signaturePath = resolve(params.outPath || `${resolvedBundle}.sig`)
  mkdirSync(dirname(signaturePath), {recursive: true})
  writeFileSync(signaturePath, JSON.stringify(signatureDoc, null, 2) + "\n", {mode: 0o644})

  return {
    signaturePath,
    signatureDoc,
    manifest: validation.result.manifest,
  }
}

function resolvePrivateKeyFromOptions(options: Record<string, unknown>): string {
  const directKeyOpt = (options.key || options.privateKey) as string | undefined
  if (directKeyOpt && directKeyOpt.trim() !== "") {
    const trimmed = directKeyOpt.trim()
    if (existsSync(trimmed)) {
      return readFileSync(trimmed, "utf8").trim()
    }
    if (looksLikeFilePath(trimmed)) {
      throw new Error(`signing key file does not exist: "${trimmed}"`)
    }
    return trimmed
  }

  const keyFileOpt = (options.keyFile || options.privateKeyFile) as string | undefined
  if (keyFileOpt && keyFileOpt.trim() !== "") {
    return readFileSync(keyFileOpt.trim(), "utf8").trim()
  }

  const envKey =
    process.env.PACK_UPLOAD_SIGNING_PRIVATE_KEY?.trim() ||
    process.env.PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY?.trim()
  if (envKey) {
    return envKey
  }

  const envKeyFile =
    process.env.PACK_UPLOAD_SIGNING_PRIVATE_KEY_FILE?.trim() ||
    process.env.PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY_FILE?.trim()
  if (envKeyFile) {
    return readFileSync(envKeyFile, "utf8").trim()
  }

  throw new Error(
    "missing Ed25519 private key: pass --key <file-or-base64> or set PACK_UPLOAD_SIGNING_PRIVATE_KEY[_FILE]",
  )
}

function resolveKeyIdFromOptions(options: Record<string, unknown>): string {
  const id =
    (typeof options.keyId === "string" && options.keyId.trim()) ||
    process.env.PACK_UPLOAD_SIGNING_KEY_ID?.trim() ||
    process.env.PLUGIN_UPLOAD_SIGNING_KEY_ID?.trim() ||
    ""
  if (!id) {
    throw new Error("missing signing key id: pass --key-id <id> or set PACK_UPLOAD_SIGNING_KEY_ID")
  }
  return id
}

function resolveSignerFromOptions(options: Record<string, unknown>, keyId: string): string {
  return (
    (typeof options.signer === "string" && options.signer.trim()) ||
    process.env.PACK_UPLOAD_SIGNING_SIGNER?.trim() ||
    process.env.PLUGIN_UPLOAD_SIGNING_SIGNER?.trim() ||
    keyId
  )
}

function looksLikeFilePath(candidate: string): boolean {
  if (candidate.includes("-----BEGIN")) return false
  return (
    candidate.includes("/") ||
    candidate.includes("\\") ||
    candidate.endsWith(".key") ||
    candidate.endsWith(".pem") ||
    candidate.endsWith(".pub")
  )
}

export async function keygenCommand(options: Record<string, unknown>): Promise<void> {
  const keyId = (typeof options.keyId === "string" && options.keyId.trim()) || "pack-signing-1"
  const pair = generateEd25519Keypair(keyId)
  const force = Boolean(options.force)

  const prefixOut = (options.out || options.output) as string | undefined
  const outDir = options.outDir as string | undefined
  let privOutPath = (options.privateKeyOut || options.keyOut) as string | undefined
  let pubOutPath = options.publicKeyOut as string | undefined

  if (!privOutPath && !pubOutPath) {
    if (prefixOut) {
      privOutPath = `${prefixOut}.key`
      pubOutPath = `${prefixOut}.pub`
    } else if (outDir) {
      privOutPath = join(outDir, `${keyId}.key`)
      pubOutPath = join(outDir, `${keyId}.pub`)
    }
  }

  if (privOutPath) {
    const resolvedPriv = resolve(privOutPath)
    if (!force && existsSync(resolvedPriv)) {
      throw new Error(`refusing to overwrite existing key file "${resolvedPriv}" without --force`)
    }
    mkdirSync(dirname(resolvedPriv), {recursive: true})
    writeFileSync(resolvedPriv, `${pair.privateKeySeedBase64}\n`, {mode: 0o600})
    privOutPath = resolvedPriv
  }

  if (pubOutPath) {
    const resolvedPub = resolve(pubOutPath)
    if (!force && existsSync(resolvedPub)) {
      throw new Error(`refusing to overwrite existing public key file "${resolvedPub}" without --force`)
    }
    mkdirSync(dirname(resolvedPub), {recursive: true})
    writeFileSync(resolvedPub, `${pair.publicKeyBase64}\n`, {mode: 0o644})
    pubOutPath = resolvedPub
  }

  if (options.json) {
    const jsonOut: Record<string, unknown> = {
      algorithm: SIGNATURE_ALGORITHM,
      key_id: pair.keyId,
      public_key: pair.publicKeyBase64,
    }
    if (privOutPath) jsonOut.private_key_file = privOutPath
    else jsonOut.private_key = pair.privateKeySeedBase64
    if (pubOutPath) jsonOut.public_key_file = pubOutPath
    console.log(JSON.stringify(jsonOut, null, 2))
    return
  }

  if (privOutPath || pubOutPath) {
    console.log(`Generated Ed25519 signing keypair (${pair.keyId}):`)
    if (privOutPath) console.log(`  private key: ${privOutPath}`)
    if (pubOutPath) console.log(`  public key:  ${pubOutPath}`)
    console.log(`  public key (base64): ${pair.publicKeyBase64}`)
  } else {
    console.log(`key_id:      ${pair.keyId}`)
    console.log(`public_key:  ${pair.publicKeyBase64}`)
    console.log(`private_key: ${pair.privateKeySeedBase64}`)
  }
}

export async function signCommand(options: Record<string, unknown>): Promise<void> {
  const positional = (options._ as string[] | undefined) || []
  const bundlePath = (positional[0] || options.bundle) as string | undefined
  if (!bundlePath) {
    throw new Error("pack sign requires a .srpack path: `serviceradar pack sign <file.srpack> --key <privkey> --key-id <id>`")
  }

  const privateKeyInput = resolvePrivateKeyFromOptions(options)
  const keyId = resolveKeyIdFromOptions(options)
  const signer = resolveSignerFromOptions(options, keyId)
  const outPath = (options.out || options.output) as string | undefined

  const signed = signSrpackFile({
    bundlePath,
    outPath,
    privateKeyInput,
    keyId,
    signer,
  })

  if (options.json) {
    console.log(
      JSON.stringify(
        {
          signature_file: signed.signaturePath,
          ...signed.signatureDoc,
        },
        null,
        2,
      ),
    )
    return
  }

  console.log(`Signed ${String(signed.manifest.id)}@${String(signed.manifest.version)} -> ${signed.signaturePath}`)
  console.log(`  key_id:       ${signed.signatureDoc.key_id}`)
  console.log(`  content_hash: ${signed.signatureDoc.content_hash}`)
}

export async function verifyCommand(options: Record<string, unknown>): Promise<void> {
  const positional = (options._ as string[] | undefined) || []
  const bundlePath = (positional[0] || options.bundle) as string | undefined
  if (!bundlePath) {
    throw new Error("pack verify requires a .srpack path")
  }
  const resolvedBundle = resolve(bundlePath)
  const sigPath = resolve(((options.signature || options.sig) as string | undefined) || `${resolvedBundle}.sig`)

  const pubKeyOpt = (options.publicKey || options.pubKey) as string | undefined
  const rawPubKey =
    pubKeyOpt && existsSync(pubKeyOpt.trim())
      ? readFileSync(pubKeyOpt.trim(), "utf8").trim()
      : pubKeyOpt?.trim() ||
        process.env.PACK_UPLOAD_SIGNING_PUBLIC_KEY?.trim() ||
        process.env.PLUGIN_UPLOAD_SIGNING_PUBLIC_KEY?.trim()

  if (!rawPubKey) {
    throw new Error("pack verify requires --public-key <file-or-base64>")
  }

  const archiveBytes = readFileSync(resolvedBundle)
  const archiveFiles = readSrpackArchive(archiveBytes)
  const validation = validatePackFiles(archiveFiles, {
    verifyHashes: true,
    compressedBytes: archiveBytes.length,
  })
  if (!validation.ok) {
    throw new PackValidationError(validation.issues)
  }

  const sigRaw = JSON.parse(readFileSync(sigPath, "utf8"))
  if (!isPlainObject(sigRaw)) {
    throw new Error("signature file must contain a JSON object")
  }
  const signatureDoc = sigRaw as unknown as UploadSignatureDocument
  const expectedKeyId =
    (typeof options.keyId === "string" && options.keyId.trim()) || signatureDoc.key_id

  verifyManifestAndHash({
    signatureDoc,
    manifest: validation.result.manifest,
    contentHash: sha256Hex(archiveBytes),
    trustedPublicKeys: {
      [expectedKeyId]: rawPubKey,
    },
  })

  if (options.json) {
    console.log(
      JSON.stringify(
        {
          verified: true,
          key_id: signatureDoc.key_id,
          content_hash: sha256Hex(archiveBytes),
          id: validation.result.manifest.id,
          version: validation.result.manifest.version,
        },
        null,
        2,
      ),
    )
    return
  }

  console.log(
    `Verified signature for ${String(validation.result.manifest.id)}@${String(validation.result.manifest.version)} (key_id: ${signatureDoc.key_id})`,
  )
}
