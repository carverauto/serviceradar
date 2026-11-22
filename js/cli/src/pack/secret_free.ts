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
  "dashboard_id",
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
const LITERAL_AUTH_HEADER_REGEX = /\bauthorization\s*:\s*(?:bearer|basic|token|apikey|digest)\s+(?!\{\{|\$\{)\S+/i
const STANDALONE_BEARER_REGEX = /^\s*(?:bearer|basic|aws4-hmac-sha256)\s+(?!\{\{|\$\{)[A-Za-z0-9._~+/=-]{8,}/i

const TOKEN_PATTERNS: Array<{code: string; label: string; regex: RegExp}> = [
  {
    code: "secret_token_literal",
    label: "GitHub personal access token",
    regex: /\b(?:ghp_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|gho_[A-Za-z0-9]{16,}|ghs_[A-Za-z0-9]{16,}|ghu_[A-Za-z0-9]{16,})\b/,
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
