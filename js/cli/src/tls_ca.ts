// Extra CA material for instances that present a private/corporate issuer.
// Node's fetch/undici uses the Mozilla bundle, not the OS trust store, so
// a curl that works can still fail here with UNABLE_TO_GET_ISSUER_CERT_LOCALLY.
//
// NODE_EXTRA_CA_CERTS is only read at process start. When we discover a CA
// file that is not already loaded, we re-exec once with it set.

import {spawnSync} from "node:child_process"
import {existsSync} from "node:fs"
import {join} from "node:path"

import {credentialsDir} from "./auth/credentials.js"

const REEXEC_ENV = "SERVICERADAR_CA_REEXEC"
const DEFAULT_BUNDLE = "ca-bundle.pem"

const TLS_TRUST_CODES = new Set([
  "UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
  "UNABLE_TO_GET_ISSUER_CERT",
  "UNABLE_TO_VERIFY_LEAF_SIGNATURE",
  "CERT_UNTRUSTED",
  "DEPTH_ZERO_SELF_SIGNED_CERT",
  "SELF_SIGNED_CERT_IN_CHAIN",
])

export function caFileFromArgv(argv: string[] = process.argv): string | undefined {
  // Both spellings: `--ca-file <pem>` and `--ca-file=<pem>`. This runs before
  // parseArgs (NODE_EXTRA_CA_CERTS has to be set before the process starts, so
  // the scan cannot wait for a parsed argv), which is why it handles the `=`
  // form itself rather than inheriting it.
  const inline = argv.find((entry) => entry.startsWith("--ca-file="))
  if (inline) return inline.slice("--ca-file=".length) || undefined

  const index = argv.indexOf("--ca-file")
  if (index === -1) return undefined
  const value = argv[index + 1]
  if (!value || value.startsWith("-")) return undefined
  return value
}

export function defaultCaBundlePath(): string {
  return join(credentialsDir(), DEFAULT_BUNDLE)
}

export function resolveExtraCaFile(argv: string[] = process.argv): string | undefined {
  const candidates = [
    caFileFromArgv(argv),
    process.env.SERVICERADAR_CA_FILE,
    process.env.NODE_EXTRA_CA_CERTS,
    defaultCaBundlePath(),
  ]
  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return candidate
  }
  return undefined
}

/**
 * If a CA bundle is configured but not yet loaded into this process, re-exec
 * with NODE_EXTRA_CA_CERTS. No-op when already loaded or nothing is configured.
 */
export function ensureExtraCaCertificates(argv: string[] = process.argv): void {
  if (process.env[REEXEC_ENV] === "1") return

  const caFile = resolveExtraCaFile(argv)
  if (!caFile) return
  if (process.env.NODE_EXTRA_CA_CERTS === caFile) return

  const result = spawnSync(process.execPath, process.argv.slice(1), {
    stdio: "inherit",
    env: {
      ...process.env,
      NODE_EXTRA_CA_CERTS: caFile,
      [REEXEC_ENV]: "1",
    },
  })
  process.exit(result.status === null ? 1 : result.status)
}

// Walk `cause`, and step into an AggregateError's first member: a fetch to a
// dual-stack host fails once per address and undici reports that as an
// AggregateError whose own `code` is undefined, so a cause-only walk gives up
// one link short of the reason.
function* causeChain(error: unknown): Generator<Record<string, any>> {
  let current: unknown = error
  for (let depth = 0; depth < 6 && current && typeof current === "object"; depth += 1) {
    const node = current as Record<string, any>
    yield node
    if (Array.isArray(node.errors) && node.errors.length > 0) current = node.errors[0]
    else current = node.cause
  }
}

export function unwrapErrorCode(error: unknown): string {
  for (const node of causeChain(error)) {
    if (typeof node.code === "string" && node.code) return node.code
  }
  return ""
}

/**
 * The most specific message in the chain. `fetch failed` is a wrapper with no
 * information in it; the sentence worth printing is always further down, and on
 * a cause that carries no `code` at all (undici's "bad port", for one) it is the
 * ONLY information there is.
 */
export function unwrapCauseMessage(error: unknown): string {
  let deepest = ""
  for (const node of causeChain(error)) {
    if (node === error) continue
    if (typeof node.message === "string" && node.message) deepest = node.message
  }
  return deepest
}

export function isTlsTrustError(error: unknown): boolean {
  const code = unwrapErrorCode(error)
  if (TLS_TRUST_CODES.has(code)) return true
  const message = error instanceof Error ? error.message : String(error || "")
  return /unable to get local issuer certificate|self[- ]signed certificate|unable to verify the first certificate/i.test(message)
}

/**
 * Top-level error text. Node reports a failed `fetch` as a bare
 * `TypeError: fetch failed` and hides the reason on `error.cause`, so printing
 * `error.message` alone tells the user nothing at all — which is exactly how a
 * corporate-CA misconfiguration reads as an unexplained crash.
 */
export function describeError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error)
  const code = unwrapErrorCode(error)
  const hasCause = Boolean(error && typeof error === "object" && "cause" in error)

  // A message that already carries its own detail (anything routed through
  // formatFetchFailure) is left alone rather than annotated twice.
  if (!hasCause && !code) return message
  if (code && message.includes(code)) return message
  return formatFetchFailure(error)
}

export function formatFetchFailure(error: unknown): string {
  const code = unwrapErrorCode(error)
  const message = error instanceof Error ? error.message : String(error)
  const reason = unwrapCauseMessage(error)

  let detail = message
  if (reason && !detail.includes(reason)) detail = `${detail}: ${reason}`
  if (code && !detail.includes(code)) detail = `${detail} (${code})`
  if (!isTlsTrustError(error)) return detail
  return [
    detail,
    "Node does not use the OS certificate store.",
    `Install the instance CA at ${defaultCaBundlePath()}`,
    "or pass --ca-file / set SERVICERADAR_CA_FILE or NODE_EXTRA_CA_CERTS.",
  ].join(" ")
}
