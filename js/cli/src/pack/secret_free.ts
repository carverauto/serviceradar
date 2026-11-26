// Secret-free preflight guard (`SecretFreeValidator` parity) for Solution
// Packs (`pack_format_version: 1`).
//
// Rejects secret-bearing keys, literal authentication headers, known API/PAT
// token prefixes, PEM private key blocks, and deployment-local credential or
// database row UUID bindings.

import {isPlainObject, type PackValidationIssue} from "./canonical.js"

const FORBIDDEN_SECRET_KEYS: Set<string> = new Set([
  "password",
  "passwd",
  "encrypted_password",
  "secret",
  "client_secret",
  "secret_key",
  "secret_payload",
  "encrypted_secret_payload",
  "secret_access_key",
  "token",
  "api_token",
  "access_token",
  "refresh_token",
  "bearer_token",
  "auth_token",
  "session_token",
  "api_key",
  "x_api_key",
  "private_key",
  "ssh_private_key",
  "access_key",
  "access_key_id",
  "auth_passphrase",
  "priv_passphrase",
  "passphrase",
  "community_string",
  "credential_secret_id",
  "credential_rule_id",
  "credentials_encrypted",
])

const FORBIDDEN_INSTANCE_BINDING_KEYS: Set<string> = new Set([
  "credential_secret_id",
  "credential_rule_id",
  "owner_id",
  "actor_id",
  "created_by_id",
  "updated_by_id",
  "plugin_package_id",
  "catalog_repository_id",
  "installed_solution_pack_id",
])

const FORBIDDEN_AUTH_HEADER_NAMES: Set<string> = new Set([
  "authorization",
  "proxy-authorization",
  "x-api-key",
  "api-key",
  "x-auth-token",
])

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const PLACEHOLDER_ONLY_REGEX = /^\s*(?:\{\{[^{}]+\}\}|\$\{[^{}]+\})\s*$/
const PEM_PRIVATE_KEY_REGEX = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/
const LITERAL_AUTH_HEADER_REGEX =
  /\bauthorization\s*:\s*(?:bearer|basic|token|apikey|digest|aws4-hmac-sha256)(?:\s+|\\(?:r\\n|n|r|t))+(?!\{\{|\$\{)\S+/i
const RAW_JS_LITERAL_AUTH_HEADER_REGEX =
  /\bauthorization\s*:\s*(?:bearer|basic|token|apikey|digest|aws4-hmac-sha256)[ \t]+(?!\{\{|\$\{|["'`])[^\s"'`]+/i
const STANDALONE_BEARER_REGEX = /^\s*(?:bearer|basic|aws4-hmac-sha256)\s+(?!\{\{|\$\{)[A-Za-z0-9._~+/=-]{8,}/i

const TOKEN_PATTERNS: Array<{code: string; label: string; regex: RegExp}> = [
  {
    code: "secret_token_literal",
    label: "GitHub personal access token",
    regex: /\b(?:ghp_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|gho_[A-Za-z0-9]{16,}|ghs_[A-Za-z0-9]{16,}|ghu_[A-Za-z0-9]{16,}|ghr_[A-Za-z0-9]{16,})\b/,
  },
  {
    code: "secret_token_literal",
    label: "GitLab personal access token",
    regex: /\bglpat-[A-Za-z0-9_-]{12,}\b/,
  },
  {
    code: "secret_token_literal",
    label: "Slack API token",
    regex: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
  },
  {
    code: "secret_token_literal",
    label: "AWS access key ID",
    regex: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
  },
  {
    code: "secret_token_literal",
    label: "JWT bearer literal",
    regex: /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/,
  },
]

export function validateSecretFree(
  document: unknown,
  file: string,
  options: {isManifest?: boolean} = {},
): PackValidationIssue[] {
  const issues: PackValidationIssue[] = []
  scanNode(document, "$", false, file, Boolean(options.isManifest), issues)
  return issues
}

export function scanRawTextSecrets(text: string, file: string): PackValidationIssue[] {
  const issues: PackValidationIssue[] = []
  scanStringValue(text, "$", false, file, issues)
  return issues
}

// Scans compiled/minified JavaScript bundles for literal token strings, PEM
// private keys, and literal `Authorization: <scheme> <token>` strings without
// flagging normal JS identifiers or object property names like `token` or
// `password`, JS header-prefix concatenations (`"Authorization: Bearer " + t`),
// or comments (`// Authorization: Bearer\nconst x = 1;`).
export function scanJsBundleSecrets(jsSource: string, file: string): PackValidationIssue[] {
  if (!jsSource) {
    return []
  }

  const issues: PackValidationIssue[] = []
  let foundPem = false
  let foundLiteralAuth = false
  const foundTokenLabels = new Set<string>()

  const checkText = (text: string, allowRawAuthCheck: boolean): void => {
    if (!text || PLACEHOLDER_ONLY_REGEX.test(text)) {
      return
    }

    if (!foundPem && PEM_PRIVATE_KEY_REGEX.test(text)) {
      foundPem = true
      issues.push({
        file,
        path: "$",
        code: "pem_private_key",
        message: "PEM private key material is forbidden in Solution Packs",
      })
    }

    const authRegex = allowRawAuthCheck ? RAW_JS_LITERAL_AUTH_HEADER_REGEX : LITERAL_AUTH_HEADER_REGEX
    if (!foundLiteralAuth && authRegex.test(text)) {
      foundLiteralAuth = true
      issues.push({
        file,
        path: "$",
        code: "literal_auth_credential",
        message: "literal Authorization credential value is forbidden; reference a credential_slot instead",
      })
    }

    for (const pattern of TOKEN_PATTERNS) {
      if (!foundTokenLabels.has(pattern.label) && pattern.regex.test(text)) {
        foundTokenLabels.add(pattern.label)
        issues.push({
          file,
          path: "$",
          code: pattern.code,
          message: `${pattern.label} literal is forbidden in Solution Packs`,
        })
      }
    }
  }

  checkText(jsSource, true)

  for (const literal of extractJsStringLiterals(jsSource)) {
    checkText(literal, false)
  }

  return issues
}

const JS_REGEX_PREFIX_KEYWORDS = new Set([
  "return",
  "throw",
  "case",
  "default",
  "delete",
  "void",
  "typeof",
  "in",
  "instanceof",
  "new",
  "yield",
  "await",
  "else",
  "do",
  "of",
  "export",
  "import",
])

const JS_CONTROL_PAREN_KEYWORDS = new Set(["if", "while", "for", "with"])

function isJsWhitespace(code: number): boolean {
  return (
    code === 0x20 ||
    code === 0x09 ||
    code === 0x0a ||
    code === 0x0d ||
    code === 0x0b ||
    code === 0x0c ||
    code === 0xa0 ||
    code === 0xfeff
  )
}

function isJsIdentStart(code: number): boolean {
  return (
    (code >= 0x41 && code <= 0x5a) ||
    (code >= 0x61 && code <= 0x7a) ||
    code === 0x5f ||
    code === 0x24 ||
    code >= 0x80
  )
}

function isJsIdentPart(code: number): boolean {
  return isJsIdentStart(code) || (code >= 0x30 && code <= 0x39)
}

function isHexDigitChar(ch: string | undefined): boolean {
  return ch !== undefined && /^[0-9a-fA-F]$/.test(ch)
}

function decodeJsEscape(src: string, backslashIndex: number): {text: string; nextIndex: number} {
  const len = src.length
  const i = backslashIndex + 1
  if (i >= len) {
    return {text: "", nextIndex: len}
  }
  const esc = src[i]!
  switch (esc) {
    case "n":
      return {text: "\n", nextIndex: i + 1}
    case "r":
      return {text: "\r", nextIndex: i + 1}
    case "t":
      return {text: "\t", nextIndex: i + 1}
    case "b":
      return {text: "\b", nextIndex: i + 1}
    case "f":
      return {text: "\f", nextIndex: i + 1}
    case "v":
      return {text: "\v", nextIndex: i + 1}
    case "0":
      return {text: "\0", nextIndex: i + 1}
    case "\n":
    case "\u2028":
    case "\u2029":
      return {text: "", nextIndex: i + 1}
    case "\r":
      return {text: "", nextIndex: src[i + 1] === "\n" ? i + 2 : i + 1}
    case "x": {
      if (i + 2 < len && isHexDigitChar(src[i + 1]) && isHexDigitChar(src[i + 2])) {
        return {text: String.fromCharCode(Number.parseInt(src.slice(i + 1, i + 3), 16)), nextIndex: i + 3}
      }
      return {text: "x", nextIndex: i + 1}
    }
    case "u": {
      if (src[i + 1] === "{") {
        const closeIdx = src.indexOf("}", i + 2)
        if (closeIdx > i + 2 && closeIdx - (i + 2) <= 6) {
          const hex = src.slice(i + 2, closeIdx)
          if (/^[0-9a-fA-F]+$/.test(hex)) {
            const cp = Number.parseInt(hex, 16)
            if (cp <= 0x10ffff) {
              return {text: String.fromCodePoint(cp), nextIndex: closeIdx + 1}
            }
          }
        }
      } else if (
        i + 4 < len &&
        isHexDigitChar(src[i + 1]) &&
        isHexDigitChar(src[i + 2]) &&
        isHexDigitChar(src[i + 3]) &&
        isHexDigitChar(src[i + 4])
      ) {
        return {text: String.fromCharCode(Number.parseInt(src.slice(i + 1, i + 5), 16)), nextIndex: i + 5}
      }
      return {text: "u", nextIndex: i + 1}
    }
    default:
      return {text: esc, nextIndex: i + 1}
  }
}

function extractJsStringLiterals(jsSource: string): string[] {
  const len = jsSource.length
  const literals: string[] = []
  const templateBraceStack: number[] = []
  const parenStack: boolean[] = []
  let canRegexFollow = true
  let afterDot = false
  let pendingControlParen = false
  let pendingForControl = false
  let i = 0

  const readTemplateChunk = (startIdx: number): {kind: "end" | "expr" | "eof"; nextIndex: number} => {
    let out = ""
    let k = startIdx
    while (k < len) {
      const ch = jsSource[k]!
      if (ch === "`") {
        if (out.length > 0) {
          literals.push(out)
        }
        return {kind: "end", nextIndex: k + 1}
      }
      if (ch === "$" && jsSource[k + 1] === "{") {
        if (out.length > 0) {
          literals.push(out)
        }
        templateBraceStack.push(1)
        return {kind: "expr", nextIndex: k + 2}
      }
      if (ch === "\\") {
        const decoded = decodeJsEscape(jsSource, k)
        out += decoded.text
        k = decoded.nextIndex
        continue
      }
      out += ch
      k += 1
    }
    if (out.length > 0) {
      literals.push(out)
    }
    return {kind: "eof", nextIndex: len}
  }

  while (i < len) {
    const code = jsSource.charCodeAt(i)
    if (isJsWhitespace(code)) {
      i += 1
      continue
    }

    const ch = jsSource[i]!

    if (ch === "/") {
      const next = jsSource[i + 1]
      if (next === "/") {
        i += 2
        while (i < len && jsSource[i] !== "\n" && jsSource[i] !== "\r") {
          i += 1
        }
        continue
      }
      if (next === "*") {
        const closeIdx = jsSource.indexOf("*/", i + 2)
        i = closeIdx === -1 ? len : closeIdx + 2
        continue
      }
      if (canRegexFollow) {
        i += 1
        let inClass = false
        while (i < len) {
          const rc = jsSource[i]!
          if (rc === "\\") {
            i += 2
            continue
          }
          if (rc === "\n" || rc === "\r") {
            break
          }
          if (rc === "[") {
            inClass = true
          } else if (rc === "]") {
            inClass = false
          } else if (rc === "/" && !inClass) {
            i += 1
            while (i < len && /[a-zA-Z]/.test(jsSource[i]!)) {
              i += 1
            }
            break
          }
          i += 1
        }
        canRegexFollow = false
        afterDot = false
        pendingControlParen = false
        pendingForControl = false
        continue
      }
      i += next === "=" ? 2 : 1
      canRegexFollow = true
      afterDot = false
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if (ch === "'" || ch === '"') {
      const quote = ch
      let out = ""
      let k = i + 1
      while (k < len) {
        const sc = jsSource[k]!
        if (sc === quote) {
          k += 1
          break
        }
        if (sc === "\\") {
          const decoded = decodeJsEscape(jsSource, k)
          out += decoded.text
          k = decoded.nextIndex
          continue
        }
        out += sc
        k += 1
      }
      if (out.length > 0) {
        literals.push(out)
      }
      i = k
      canRegexFollow = false
      afterDot = false
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if (ch === "`") {
      const res = readTemplateChunk(i + 1)
      i = res.nextIndex
      canRegexFollow = res.kind === "expr"
      afterDot = false
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if (ch === "{") {
      if (templateBraceStack.length > 0) {
        templateBraceStack[templateBraceStack.length - 1] += 1
      }
      i += 1
      canRegexFollow = true
      afterDot = false
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if (ch === "}") {
      if (templateBraceStack.length > 0) {
        templateBraceStack[templateBraceStack.length - 1] -= 1
        if (templateBraceStack[templateBraceStack.length - 1] === 0) {
          templateBraceStack.pop()
          const res = readTemplateChunk(i + 1)
          i = res.nextIndex
          canRegexFollow = res.kind === "expr"
          afterDot = false
          pendingControlParen = false
          pendingForControl = false
          continue
        }
      }
      i += 1
      canRegexFollow = true
      afterDot = false
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if (ch === "(") {
      parenStack.push(pendingControlParen)
      i += 1
      canRegexFollow = true
      afterDot = false
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if (ch === ")") {
      const isControlParen = parenStack.pop() ?? false
      i += 1
      canRegexFollow = isControlParen
      afterDot = false
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if (ch === "]") {
      i += 1
      canRegexFollow = false
      afterDot = false
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if (ch === "." && !(code === 0x2e && jsSource.charCodeAt(i + 1) >= 0x30 && jsSource.charCodeAt(i + 1) <= 0x39)) {
      if (jsSource.startsWith("...", i)) {
        i += 3
        afterDot = false
      } else {
        i += 1
        afterDot = true
      }
      canRegexFollow = true
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if ((ch === "+" && jsSource[i + 1] === "+") || (ch === "-" && jsSource[i + 1] === "-")) {
      i += 2
      canRegexFollow = false
      afterDot = false
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if (
      (code >= 0x30 && code <= 0x39) ||
      (ch === "." && jsSource.charCodeAt(i + 1) >= 0x30 && jsSource.charCodeAt(i + 1) <= 0x39)
    ) {
      i += 1
      while (i < len) {
        const nc = jsSource[i]!
        const ncode = jsSource.charCodeAt(i)
        if (
          (ncode >= 0x30 && ncode <= 0x39) ||
          (ncode >= 0x41 && ncode <= 0x5a) ||
          (ncode >= 0x61 && ncode <= 0x7a) ||
          nc === "_" ||
          nc === "."
        ) {
          if ((nc === "e" || nc === "E") && (jsSource[i + 1] === "+" || jsSource[i + 1] === "-")) {
            i += 2
            continue
          }
          i += 1
          continue
        }
        break
      }
      canRegexFollow = false
      afterDot = false
      pendingControlParen = false
      pendingForControl = false
      continue
    }

    if (isJsIdentStart(code)) {
      const start = i
      i += 1
      while (i < len && isJsIdentPart(jsSource.charCodeAt(i))) {
        i += 1
      }
      const word = jsSource.slice(start, i)
      if (afterDot) {
        afterDot = false
        canRegexFollow = false
        pendingControlParen = false
        pendingForControl = false
      } else if (word === "for") {
        pendingControlParen = true
        pendingForControl = true
        canRegexFollow = false
      } else if (word === "await" && pendingForControl) {
        pendingControlParen = true
        pendingForControl = false
        canRegexFollow = true
      } else if (JS_CONTROL_PAREN_KEYWORDS.has(word)) {
        pendingControlParen = true
        pendingForControl = false
        canRegexFollow = false
      } else {
        pendingControlParen = false
        pendingForControl = false
        canRegexFollow = JS_REGEX_PREFIX_KEYWORDS.has(word)
      }
      continue
    }

    i += 1
    canRegexFollow = true
    afterDot = false
    pendingControlParen = false
    pendingForControl = false
  }

  return literals
}

function normalizeKeyName(key: string): string {
  return key.trim().toLowerCase().replace(/-/g, "_")
}

function scanNode(
  value: unknown,
  path: string,
  insideHeaders: boolean,
  file: string,
  isManifest: boolean,
  issues: PackValidationIssue[],
): void {
  if (typeof value === "string") {
    if (isManifest && /^\$\.dashboard_package_dependencies\[\d+\]$/.test(path)) {
      const trimmed = value.trim()
      const atIdx = trimmed.indexOf("@")
      const idPart = (atIdx > 0 ? trimmed.slice(0, atIdx) : trimmed).trim()
      if (UUID_REGEX.test(idPart)) {
        issues.push({
          file,
          path,
          code: "forbidden_instance_uuid",
          message: `live UUID value "${idPart}" in dashboard_package_dependencies is not permitted in portable Solution Packs`,
        })
        return
      }
    }
    scanStringValue(value, path, insideHeaders, file, issues)
    return
  }

  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i += 1) {
      scanNode(value[i], `${path}[${i}]`, false, file, isManifest, issues)
    }
    return
  }

  if (!isPlainObject(value)) {
    return
  }

  for (const [rawKey, childValue] of Object.entries(value)) {
    const childPath = `${path}.${rawKey}`
    const lowerTrimmed = rawKey.trim().toLowerCase()
    const normalizedKey = normalizeKeyName(rawKey)

    if (insideHeaders && FORBIDDEN_AUTH_HEADER_NAMES.has(lowerTrimmed)) {
      issues.push({
        file,
        path: childPath,
        code: "forbidden_auth_header",
        message: `forbidden authentication header "${rawKey}" in Solution Pack; bind external credentials through credential_slots`,
      })
      continue
    }

    if (FORBIDDEN_SECRET_KEYS.has(normalizedKey)) {
      issues.push({
        file,
        path: childPath,
        code: "forbidden_secret_key",
        message: `forbidden secret or credential binding key "${rawKey}" in Solution Pack; use abstract credential_slots instead`,
      })
      continue
    }

    if (FORBIDDEN_INSTANCE_BINDING_KEYS.has(normalizedKey)) {
      issues.push({
        file,
        path: childPath,
        code: "forbidden_instance_uuid_key",
        message: `forbidden deployment-local identifier key "${rawKey}" in Solution Pack`,
      })
      continue
    }

    if (
      typeof childValue === "string" &&
      UUID_REGEX.test(childValue.trim()) &&
      (normalizedKey === "id" || normalizedKey.endsWith("_id"))
    ) {
      issues.push({
        file,
        path: childPath,
        code: "forbidden_instance_uuid",
        message: `live UUID value "${childValue}" on "${rawKey}" is not permitted in portable Solution Packs`,
      })
      continue
    }

    // Check "$pack_param" is an allowed indirection wrapper, never a secret.
    const nextInsideHeaders = lowerTrimmed === "headers"
    scanNode(childValue, childPath, nextInsideHeaders, file, isManifest, issues)
  }
}

function scanStringValue(
  value: string,
  path: string,
  insideHeaders: boolean,
  file: string,
  issues: PackValidationIssue[],
): void {
  if (!value || PLACEHOLDER_ONLY_REGEX.test(value)) {
    return
  }

  if (PEM_PRIVATE_KEY_REGEX.test(value)) {
    issues.push({
      file,
      path,
      code: "pem_private_key",
      message: "PEM private key material is forbidden in Solution Packs",
    })
  }

  if (LITERAL_AUTH_HEADER_REGEX.test(value) || (insideHeaders && STANDALONE_BEARER_REGEX.test(value))) {
    issues.push({
      file,
      path,
      code: "literal_auth_credential",
      message: "literal Authorization credential value is forbidden; reference a credential_slot instead",
    })
  }

  for (const pattern of TOKEN_PATTERNS) {
    if (pattern.regex.test(value)) {
      issues.push({
        file,
        path,
        code: pattern.code,
        message: `${pattern.label} literal is forbidden in Solution Packs`,
      })
    }
  }
}
