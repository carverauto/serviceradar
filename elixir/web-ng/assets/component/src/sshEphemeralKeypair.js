/**
 * Browser-side ephemeral Ed25519 keypair generation for SSO certificate remote access.
 *
 * Teleport-style model: the browser (or client) generates a short-lived keypair,
 * the control plane signs the public key with the ServiceRadar user CA, and the
 * private key never leaves browser memory (not pasted by the operator).
 *
 * Private key is exported as PKCS#8 PEM (accepted by golang.org/x/crypto/ssh).
 * Public key is OpenSSH authorized_keys format (required by the CA signer).
 */

const ED25519_SPKI_PREFIX = Uint8Array.from([
  0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
])

function bytesToBase64(bytes) {
  let binary = ""
  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary)
}

function encodeSshString(value) {
  const data = typeof value === "string" ? new TextEncoder().encode(value) : value
  const out = new Uint8Array(4 + data.length)
  const view = new DataView(out.buffer)
  view.setUint32(0, data.length)
  out.set(data, 4)
  return out
}

function concatBytes(parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0)
  const out = new Uint8Array(total)
  let offset = 0
  for (const part of parts) {
    out.set(part, offset)
    offset += part.length
  }
  return out
}

function pemEncode(label, derBytes) {
  const b64 = bytesToBase64(derBytes)
  const lines = b64.match(/.{1,64}/g) || []
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`
}

function rawPublicKeyFromSpki(spki) {
  if (spki.length < 32) {
    throw new Error("Invalid SPKI public key length.")
  }

  // Prefer structural strip of known Ed25519 SPKI prefix; fall back to last 32 bytes.
  if (spki.length === ED25519_SPKI_PREFIX.length + 32) {
    const prefix = spki.slice(0, ED25519_SPKI_PREFIX.length)
    let match = true
    for (let i = 0; i < ED25519_SPKI_PREFIX.length; i += 1) {
      if (prefix[i] !== ED25519_SPKI_PREFIX[i]) {
        match = false
        break
      }
    }
    if (match) {
      return spki.slice(ED25519_SPKI_PREFIX.length)
    }
  }

  return spki.slice(-32)
}

export function formatOpenSSHEd25519PublicKey(rawPublicKey, comment = "serviceradar-ephemeral") {
  const body = concatBytes([
    encodeSshString("ssh-ed25519"),
    encodeSshString(rawPublicKey),
  ])
  const commentPart = comment ? ` ${comment}` : ""
  return `ssh-ed25519 ${bytesToBase64(body)}${commentPart}`
}

export function supportsEphemeralEd25519() {
  return Boolean(
    globalThis.crypto?.subtle &&
      typeof globalThis.crypto.subtle.generateKey === "function" &&
      typeof globalThis.crypto.subtle.exportKey === "function"
  )
}

/**
 * @returns {Promise<{privateKeyPem: string, publicKeyOpenSSH: string, algorithm: string}>}
 */
export async function generateEphemeralEd25519Keypair(comment = "serviceradar-ephemeral") {
  if (!supportsEphemeralEd25519()) {
    throw new Error("This browser cannot generate ephemeral Ed25519 keys for SSO certificate login.")
  }

  let keyPair
  try {
    keyPair = await globalThis.crypto.subtle.generateKey({name: "Ed25519"}, true, ["sign", "verify"])
  } catch (error) {
    throw new Error(
      `Ephemeral Ed25519 key generation failed: ${error?.message || "unsupported algorithm"}`
    )
  }

  const pkcs8 = new Uint8Array(await globalThis.crypto.subtle.exportKey("pkcs8", keyPair.privateKey))
  const spki = new Uint8Array(await globalThis.crypto.subtle.exportKey("spki", keyPair.publicKey))
  const rawPublic = rawPublicKeyFromSpki(spki)

  return {
    algorithm: "Ed25519",
    privateKeyPem: pemEncode("PRIVATE KEY", pkcs8),
    publicKeyOpenSSH: formatOpenSSHEd25519PublicKey(rawPublic, comment),
  }
}

export const PREFERRED_SSH_USER_KEY = "serviceradar.remoteAccess.preferredSshUsername"

export function loadPreferredSshUsername() {
  try {
    return (globalThis.localStorage?.getItem(PREFERRED_SSH_USER_KEY) || "").trim()
  } catch (_error) {
    return ""
  }
}

export function savePreferredSshUsername(username) {
  try {
    const value = (username || "").trim()
    if (!value) {
      globalThis.localStorage?.removeItem(PREFERRED_SSH_USER_KEY)
      return
    }
    globalThis.localStorage?.setItem(PREFERRED_SSH_USER_KEY, value)
  } catch (_error) {
    // ignore storage failures
  }
}

export function pickDefaultUsername(accounts, preferred = "") {
  const names = (accounts || [])
    .map((account) => (typeof account === "string" ? account : account?.name))
    .filter((name) => typeof name === "string" && name.trim() !== "")
    .map((name) => name.trim())

  if (names.length === 0) {
    return preferred || ""
  }

  if (preferred && names.includes(preferred)) {
    return preferred
  }

  return names[0]
}
