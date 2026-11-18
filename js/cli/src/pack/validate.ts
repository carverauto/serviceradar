// Solution Pack (`pack_format_version: 1`) directory and `.srpack` archive
// validator (`serviceradar pack validate`).

import {lstatSync, readFileSync} from "node:fs"
import {resolve} from "node:path"
import {collectPackDirectoryFiles, readSrpackArchive} from "./archive.js"
import {
  compareUtf8Keys,
  isPlainObject,
  normalizeSha256Hex,
  sha256Hex,
  type PackValidationIssue,
} from "./canonical.js"
import {scanRawTextSecrets, validateSecretFree} from "./secret_free.js"
import {validateSvgContent} from "./svg.js"

const REVERSE_DNS_ID_REGEX = /^[a-z0-9]+(?:-[a-z0-9]+)*(?:\.[a-z0-9]+(?:-[a-z0-9]+)*)+$/
const PACK_SLUG_REGEX = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
const CHECK_SLUG_REGEX = /^[a-z0-9][a-z0-9._-]{0,126}$/
const DASHBOARD_SLUG_REGEX = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/
const SEMVER_REGEX = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/
const SHA256_HEX_REGEX = /^[0-9a-f]{64}$/
const CONFIG_KEY_REGEX = /^[a-zA-Z][a-zA-Z0-9_]{0,126}$/
const SLOT_ID_REGEX = /^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,126}$/

const ALLOWED_CONFIG_TYPES = new Set([
  "string",
  "integer",
  "number",
  "boolean",
  "duration_seconds",
  "srql_filter",
])

const ALLOWED_CHECK_NODE_KINDS = new Set([
  "srql_query",
  "platform_posture",
  "vantage_point",
  "device_metadata",
  "http_request",
  "http_journey",
  "tcp_connect",
  "tls_handshake",
  "dns_lookup",
  "extract_field",
  "threshold_assert",
  "decision_table",
  "alert_output",
])

const ALLOWED_RULE_KINDS = new Set(["stateful_alert_rule", "event_rule", "zen_rule"])
const ALLOWED_INSTALL_STATES = new Set(["enabled", "paused"])

const ALLOWED_DASHBOARD_VISUAL_TYPES = new Set([
  "table",
  "stat",
  "count",
  "gauge",
  "availability",
  "line",
  "area",
  "bar",
  "category",
  "status_list",
  "pivot",
])

const DASHBOARD_GRID_COLUMNS = 12

export interface ValidatedPackResult {
  manifest: Record<string, unknown>
  files: Map<string, Buffer>
  computedFileDigests: Record<string, string>
  resourceCounts: {
    checks: number
    rules: number
    dashboards: number
  }
}

export class PackValidationError extends Error {
  readonly issues: PackValidationIssue[]

  constructor(issues: PackValidationIssue[]) {
    const summary = issues
      .map((issue) => `  - [${issue.code}] ${issue.file} (${issue.path}): ${issue.message}`)
      .join("\n")
    super(`Solution Pack validation failed (${issues.length} issue${issues.length === 1 ? "" : "s"}):\n${summary}`)
    this.name = "PackValidationError"
    this.issues = issues
  }
}

export function loadPackSource(targetPath: string): {
  kind: "directory" | "archive"
  resolvedPath: string
  files: Map<string, Buffer>
} {
  const resolvedPath = resolve(targetPath)
  const st = lstatSync(resolvedPath)
  if (st.isSymbolicLink()) {
    throw new Error(`unsafe symlink target "${targetPath}"`)
  }
  if (st.isDirectory()) {
    return {
      kind: "directory",
      resolvedPath,
      files: collectPackDirectoryFiles(resolvedPath),
    }
  }
  if (st.isFile()) {
    const raw = readFileSync(resolvedPath)
    return {
      kind: "archive",
      resolvedPath,
      files: readSrpackArchive(raw),
    }
  }
  throw new Error(`pack path "${targetPath}" is neither a directory nor a .srpack file`)
}

export function computePackFileDigests(files: Map<string, Buffer>): Record<string, string> {
  const paths = Array.from(files.keys())
    .filter((path) => path !== "manifest.json")
    .sort(compareUtf8Keys)
  const out: Record<string, string> = {}
  for (const path of paths) {
    const content = files.get(path)
    if (content) {
      out[path] = sha256Hex(content)
    }
  }
  return out
}

export function validatePackFiles(
  files: Map<string, Buffer>,
  options: {verifyHashes?: boolean} = {},
):
  | {ok: true; result: ValidatedPackResult; issues?: undefined}
  | {ok: false; issues: PackValidationIssue[]; result?: undefined} {
  const verifyHashes = options.verifyHashes !== false
  const issues: PackValidationIssue[] = []

  const manifestBuf = files.get("manifest.json")
  if (!manifestBuf) {
    issues.push({
      file: "manifest.json",
      path: "$",
      code: "missing_manifest",
      message: "pack is missing required root manifest.json",
    })
    return {ok: false, issues}
  }

  let manifestRaw: unknown
  try {
    manifestRaw = JSON.parse(manifestBuf.toString("utf8"))
  } catch (err: any) {
    issues.push({
      file: "manifest.json",
      path: "$",
      code: "invalid_json",
      message: `manifest.json is not valid JSON: ${err?.message || String(err)}`,
    })
    return {ok: false, issues}
  }

  if (!isPlainObject(manifestRaw)) {
    issues.push({
      file: "manifest.json",
      path: "$",
      code: "invalid_manifest_type",
      message: "manifest.json root must be a JSON object",
    })
    return {ok: false, issues}
  }

  issues.push(...validateSecretFree(manifestRaw, "manifest.json", {isManifest: true}))

  // 1. Validate pack_format_version
  if (manifestRaw.pack_format_version !== 1) {
    issues.push({
      file: "manifest.json",
      path: "$.pack_format_version",
      code: "unsupported_pack_format_version",
      message: `unsupported pack_format_version ${JSON.stringify(manifestRaw.pack_format_version)}; expected 1`,
    })
  }

  // 2. Identity & metadata fields
  if (typeof manifestRaw.id !== "string" || !REVERSE_DNS_ID_REGEX.test(manifestRaw.id)) {
    issues.push({
      file: "manifest.json",
      path: "$.id",
      code: "invalid_pack_id",
      message: `pack id ${JSON.stringify(manifestRaw.id)} must be reverse-DNS lowercase alphanumeric (e.g. "io.serviceradar.my-pack")`,
    })
  }

  if (typeof manifestRaw.slug !== "string" || !PACK_SLUG_REGEX.test(manifestRaw.slug)) {
    issues.push({
      file: "manifest.json",
      path: "$.slug",
      code: "invalid_pack_slug",
      message: `pack slug ${JSON.stringify(manifestRaw.slug)} must be lowercase kebab-case`,
    })
  }

  if (typeof manifestRaw.name !== "string" || manifestRaw.name.trim() === "") {
    issues.push({
      file: "manifest.json",
      path: "$.name",
      code: "missing_pack_name",
      message: "manifest.name must be a non-empty string",
    })
  }

  if (typeof manifestRaw.version !== "string" || !SEMVER_REGEX.test(manifestRaw.version)) {
    issues.push({
      file: "manifest.json",
      path: "$.version",
      code: "invalid_pack_version",
      message: `manifest.version ${JSON.stringify(manifestRaw.version)} must be a valid SemVer string`,
    })
  }

  for (const strKey of ["author", "license", "description"] as const) {
    if (manifestRaw[strKey] !== undefined) {
      if (typeof manifestRaw[strKey] !== "string" || (manifestRaw[strKey] as string).trim() === "") {
        issues.push({
          file: "manifest.json",
          path: `$.${strKey}`,
          code: "invalid_string_field",
          message: `manifest.${strKey} must be a non-empty string when provided`,
        })
      }
    }
  }

  if (manifestRaw.min_serviceradar_version !== undefined) {
    if (
      typeof manifestRaw.min_serviceradar_version !== "string" ||
      !SEMVER_REGEX.test(manifestRaw.min_serviceradar_version)
    ) {
      issues.push({
        file: "manifest.json",
        path: "$.min_serviceradar_version",
        code: "invalid_min_serviceradar_version",
        message: "manifest.min_serviceradar_version must be a valid SemVer string",
      })
    }
  }

  if (manifestRaw.categories !== undefined) {
    if (
      !Array.isArray(manifestRaw.categories) ||
      manifestRaw.categories.some((cat) => typeof cat !== "string" || cat.trim() === "")
    ) {
      issues.push({
        file: "manifest.json",
        path: "$.categories",
        code: "invalid_categories",
        message: "manifest.categories must be an array of non-empty strings",
      })
    }
  }

  if (manifestRaw.icon !== undefined) {
    if (typeof manifestRaw.icon !== "string") {
      issues.push({
        file: "manifest.json",
        path: "$.icon",
        code: "invalid_icon",
        message: "manifest.icon must be an inline <svg> or data:image/svg+xml;base64,... string",
      })
    } else {
      issues.push(...validateSvgContent(manifestRaw.icon, "manifest.json", "$.icon", {allowDataUri: true}))
    }
  }

  // 3. Config parameters
  const declaredConfigKeys = new Set<string>()
  if (manifestRaw.config !== undefined) {
    if (!Array.isArray(manifestRaw.config)) {
      issues.push({
        file: "manifest.json",
        path: "$.config",
        code: "invalid_config",
        message: "manifest.config must be an array",
      })
    } else {
      manifestRaw.config.forEach((entry, idx) => {
        const entryPath = `$.config[${idx}]`
        if (!isPlainObject(entry)) {
          issues.push({
            file: "manifest.json",
            path: entryPath,
            code: "invalid_config_entry",
            message: "config entry must be an object",
          })
          return
        }
        const key = entry.key
        if (typeof key !== "string" || !CONFIG_KEY_REGEX.test(key)) {
          issues.push({
            file: "manifest.json",
            path: `${entryPath}.key`,
            code: "invalid_config_key",
            message: `config key ${JSON.stringify(key)} is invalid`,
          })
        } else if (declaredConfigKeys.has(key)) {
          issues.push({
            file: "manifest.json",
            path: `${entryPath}.key`,
            code: "duplicate_config_key",
            message: `duplicate config key "${key}"`,
          })
        } else {
          declaredConfigKeys.add(key)
        }

        const type = entry.type
        if (typeof type !== "string" || !ALLOWED_CONFIG_TYPES.has(type)) {
          issues.push({
            file: "manifest.json",
            path: `${entryPath}.type`,
            code: "invalid_config_type",
            message: `unsupported config type ${JSON.stringify(type)}`,
          })
        } else if (entry.default !== undefined && entry.default !== null) {
          validateConfigScalarValue(entry.default, type, `${entryPath}.default`, issues)
        }
      })
    }
  }

  // 4. Credential slots
  if (manifestRaw.credential_slots !== undefined) {
    if (!Array.isArray(manifestRaw.credential_slots)) {
      issues.push({
        file: "manifest.json",
        path: "$.credential_slots",
        code: "invalid_credential_slots",
        message: "manifest.credential_slots must be an array",
      })
    } else {
      const seenSlots = new Set<string>()
      manifestRaw.credential_slots.forEach((slotEntry, idx) => {
        const slotPath = `$.credential_slots[${idx}]`
        if (!isPlainObject(slotEntry)) {
          issues.push({
            file: "manifest.json",
            path: slotPath,
            code: "invalid_credential_slot",
            message: "credential_slot entry must be an object",
          })
          return
        }
        if (typeof slotEntry.slot !== "string" || !SLOT_ID_REGEX.test(slotEntry.slot)) {
          issues.push({
            file: "manifest.json",
            path: `${slotPath}.slot`,
            code: "invalid_credential_slot_name",
            message: "credential_slot.slot must be a valid identifier",
          })
        } else if (seenSlots.has(slotEntry.slot)) {
          issues.push({
            file: "manifest.json",
            path: `${slotPath}.slot`,
            code: "duplicate_credential_slot",
            message: `duplicate credential_slot "${slotEntry.slot}"`,
          })
        } else {
          seenSlots.add(slotEntry.slot)
        }
        if (typeof slotEntry.provider !== "string" || slotEntry.provider.trim() === "") {
          issues.push({
            file: "manifest.json",
            path: `${slotPath}.provider`,
            code: "missing_credential_provider",
            message: "credential_slot.provider must be a non-empty string",
          })
        }
      })
    }
  }

  // 5. Plugin dependencies
  if (manifestRaw.plugin_dependencies !== undefined) {
    if (!Array.isArray(manifestRaw.plugin_dependencies)) {
      issues.push({
        file: "manifest.json",
        path: "$.plugin_dependencies",
        code: "invalid_plugin_dependencies",
        message: "manifest.plugin_dependencies must be an array",
      })
    } else {
      manifestRaw.plugin_dependencies.forEach((dep, idx) => {
        const depPath = `$.plugin_dependencies[${idx}]`
        if (!isPlainObject(dep)) {
          issues.push({
            file: "manifest.json",
            path: depPath,
            code: "invalid_plugin_dependency",
            message: "plugin_dependencies entry must be an object",
          })
          return
        }
        if (typeof dep.package_id !== "string" || dep.package_id.trim() === "") {
          issues.push({
            file: "manifest.json",
            path: `${depPath}.package_id`,
            code: "missing_plugin_package_id",
            message: "plugin_dependencies.package_id must be a non-empty string",
          })
        }
        if (typeof dep.version_constraint !== "string" || dep.version_constraint.trim() === "") {
          issues.push({
            file: "manifest.json",
            path: `${depPath}.version_constraint`,
            code: "missing_plugin_version_constraint",
            message: "plugin_dependencies.version_constraint must be a non-empty string",
          })
        }
      })
    }
  }

  // 6. Resources inventory
  const declaredCheckFiles = new Map<string, {slug: string; index: number}>()
  const declaredRuleFiles = new Map<
    string,
    {kind: string; name: string; install_state?: string; index: number}
  >()
  const declaredDashboardFiles = new Map<string, {slug: string; index: number}>()

  if (!isPlainObject(manifestRaw.resources)) {
    issues.push({
      file: "manifest.json",
      path: "$.resources",
      code: "missing_resources",
      message: "manifest.resources must be a JSON object",
    })
  } else {
    const res = manifestRaw.resources
    const checksList = res.checks ?? []
    const rulesList = res.rules ?? []
    const dashboardsList = res.dashboards ?? []

    if (!Array.isArray(checksList)) {
      issues.push({
        file: "manifest.json",
        path: "$.resources.checks",
        code: "invalid_resources_checks",
        message: "manifest.resources.checks must be an array",
      })
    } else {
      checksList.forEach((item, idx) => {
        const p = `$.resources.checks[${idx}]`
        if (!isPlainObject(item)) {
          issues.push({file: "manifest.json", path: p, code: "invalid_check_ref", message: "must be an object"})
          return
        }
        const file = item.file
        const slug = item.slug
        if (typeof file !== "string" || !/^checks\/[A-Za-z0-9._-]+\.json$/.test(file)) {
          issues.push({
            file: "manifest.json",
            path: `${p}.file`,
            code: "invalid_check_file_path",
            message: `check file ${JSON.stringify(file)} must match "checks/<name>.json"`,
          })
        } else if (declaredCheckFiles.has(file)) {
          issues.push({
            file: "manifest.json",
            path: `${p}.file`,
            code: "duplicate_resource_file",
            message: `duplicate check file "${file}" in manifest.resources.checks`,
          })
        } else if (typeof slug !== "string" || !CHECK_SLUG_REGEX.test(slug)) {
          issues.push({
            file: "manifest.json",
            path: `${p}.slug`,
            code: "invalid_check_slug",
            message: `check slug ${JSON.stringify(slug)} is invalid`,
          })
        } else {
          declaredCheckFiles.set(file, {slug, index: idx})
        }
      })
    }

    if (!Array.isArray(rulesList)) {
      issues.push({
        file: "manifest.json",
        path: "$.resources.rules",
        code: "invalid_resources_rules",
        message: "manifest.resources.rules must be an array",
      })
    } else {
      rulesList.forEach((item, idx) => {
        const p = `$.resources.rules[${idx}]`
        if (!isPlainObject(item)) {
          issues.push({file: "manifest.json", path: p, code: "invalid_rule_ref", message: "must be an object"})
          return
        }
        const file = item.file
        const kind = item.kind
        const name = item.name
        const installState = item.install_state
        if (typeof file !== "string" || !/^rules\/[A-Za-z0-9._-]+\.json$/.test(file)) {
          issues.push({
            file: "manifest.json",
            path: `${p}.file`,
            code: "invalid_rule_file_path",
            message: `rule file ${JSON.stringify(file)} must match "rules/<name>.json"`,
          })
          return
        }
        if (declaredRuleFiles.has(file)) {
          issues.push({
            file: "manifest.json",
            path: `${p}.file`,
            code: "duplicate_resource_file",
            message: `duplicate rule file "${file}" in manifest.resources.rules`,
          })
          return
        }
        if (typeof kind !== "string" || !ALLOWED_RULE_KINDS.has(kind)) {
          issues.push({
            file: "manifest.json",
            path: `${p}.kind`,
            code: "invalid_rule_kind",
            message: `rule kind ${JSON.stringify(kind)} must be stateful_alert_rule, event_rule, or zen_rule`,
          })
        }
        if (typeof name !== "string" || name.trim() === "") {
          issues.push({
            file: "manifest.json",
            path: `${p}.name`,
            code: "missing_rule_name",
            message: "rule entry requires a non-empty name",
          })
        }
        if (
          installState !== undefined &&
          (typeof installState !== "string" || !ALLOWED_INSTALL_STATES.has(installState))
        ) {
          issues.push({
            file: "manifest.json",
            path: `${p}.install_state`,
            code: "invalid_install_state",
            message: `install_state ${JSON.stringify(installState)} must be "enabled" or "paused"`,
          })
        }
        if (typeof kind === "string" && typeof name === "string") {
          declaredRuleFiles.set(file, {
            kind,
            name,
            install_state: typeof installState === "string" ? installState : undefined,
            index: idx,
          })
        }
      })
    }

    if (!Array.isArray(dashboardsList)) {
      issues.push({
        file: "manifest.json",
        path: "$.resources.dashboards",
        code: "invalid_resources_dashboards",
        message: "manifest.resources.dashboards must be an array",
      })
    } else {
      dashboardsList.forEach((item, idx) => {
        const p = `$.resources.dashboards[${idx}]`
        if (!isPlainObject(item)) {
          issues.push({file: "manifest.json", path: p, code: "invalid_dashboard_ref", message: "must be an object"})
          return
        }
        const file = item.file
        const slug = item.slug
        if (typeof file !== "string" || !/^dashboards\/[A-Za-z0-9._-]+\.json$/.test(file)) {
          issues.push({
            file: "manifest.json",
            path: `${p}.file`,
            code: "invalid_dashboard_file_path",
            message: `dashboard file ${JSON.stringify(file)} must match "dashboards/<name>.json"`,
          })
        } else if (declaredDashboardFiles.has(file)) {
          issues.push({
            file: "manifest.json",
            path: `${p}.file`,
            code: "duplicate_resource_file",
            message: `duplicate dashboard file "${file}" in manifest.resources.dashboards`,
          })
        } else if (typeof slug !== "string" || !DASHBOARD_SLUG_REGEX.test(slug)) {
          issues.push({
            file: "manifest.json",
            path: `${p}.slug`,
            code: "invalid_dashboard_slug",
            message: `dashboard slug ${JSON.stringify(slug)} must be lowercase kebab-case`,
          })
        } else {
          declaredDashboardFiles.set(file, {slug, index: idx})
        }
      })
    }
  }

  // 7. File layout, unlisted-file guard, and SHA-256 `manifest.files` verification
  const computedFileDigests = computePackFileDigests(files)

  for (const relPath of Object.keys(computedFileDigests)) {
    if (relPath === "README.md") {
      continue
    }
    if (relPath.startsWith("checks/")) {
      if (!declaredCheckFiles.has(relPath)) {
        issues.push({
          file: relPath,
          path: "$",
          code: "unlisted_resource_file",
          message: `check file "${relPath}" is not declared in manifest.resources.checks`,
        })
      }
      continue
    }
    if (relPath.startsWith("rules/")) {
      if (!declaredRuleFiles.has(relPath)) {
        issues.push({
          file: relPath,
          path: "$",
          code: "unlisted_resource_file",
          message: `rule file "${relPath}" is not declared in manifest.resources.rules`,
        })
      }
      continue
    }
    if (relPath.startsWith("dashboards/")) {
      if (!declaredDashboardFiles.has(relPath)) {
        issues.push({
          file: relPath,
          path: "$",
          code: "unlisted_resource_file",
          message: `dashboard file "${relPath}" is not declared in manifest.resources.dashboards`,
        })
      }
      continue
    }
    if (relPath.startsWith("assets/")) {
      continue
    }
    issues.push({
      file: relPath,
      path: "$",
      code: "unlisted_file",
      message: `unexpected file "${relPath}" outside allowed pack directories (README.md, checks/, rules/, dashboards/, assets/)`,
    })
  }

  if (verifyHashes) {
    if (!isPlainObject(manifestRaw.files)) {
      issues.push({
        file: "manifest.json",
        path: "$.files",
        code: "missing_files_table",
        message: "manifest.files must be an object mapping relative paths to lowercase SHA-256 digests",
      })
    } else {
      const manifestFiles = manifestRaw.files
      if ("manifest.json" in manifestFiles) {
        issues.push({
          file: "manifest.json",
          path: "$.files[\"manifest.json\"]",
          code: "invalid_files_entry",
          message: "manifest.files must not list manifest.json itself",
        })
      }

      for (const [listedPath, expectedRaw] of Object.entries(manifestFiles)) {
        if (listedPath === "manifest.json") continue
        if (typeof expectedRaw !== "string" || !SHA256_HEX_REGEX.test(normalizeSha256Hex(expectedRaw))) {
          issues.push({
            file: "manifest.json",
            path: `$.files[${JSON.stringify(listedPath)}]`,
            code: "invalid_sha256_digest",
            message: `manifest.files entry "${listedPath}" must be a 64-character lowercase SHA-256 hex digest`,
          })
          continue
        }
        const actual = computedFileDigests[listedPath]
        if (!actual) {
          issues.push({
            file: "manifest.json",
            path: `$.files[${JSON.stringify(listedPath)}]`,
            code: "missing_pack_file",
            message: `file "${listedPath}" listed in manifest.files is missing from pack`,
          })
          continue
        }
        const expected = normalizeSha256Hex(expectedRaw)
        if (actual !== expected) {
          issues.push({
            file: listedPath,
            path: `$.files[${JSON.stringify(listedPath)}]`,
            code: "file_digest_mismatch",
            message: `SHA-256 digest mismatch for "${listedPath}": manifest.files has ${expected}, actual is ${actual}`,
          })
        }
      }

      for (const actualPath of Object.keys(computedFileDigests)) {
        if (!(actualPath in manifestFiles)) {
          issues.push({
            file: actualPath,
            path: "$.files",
            code: "unlisted_file",
            message: `pack file "${actualPath}" is omitted from manifest.files`,
          })
        }
      }
    }
  }

  // 8. Validate README.md and assets/*
  const readmeBuf = files.get("README.md")
  if (readmeBuf) {
    const readmeText = readmeBuf.toString("utf8")
    issues.push(...scanRawTextSecrets(readmeText, "README.md"))
    if (/<script\b/i.test(readmeText)) {
      issues.push({
        file: "README.md",
        path: "$",
        code: "forbidden_markdown_script",
        message: "README.md must not embed <script> tags",
      })
    }
  }

  for (const [filePath, buf] of files.entries()) {
    if (filePath.startsWith("assets/") && filePath.toLowerCase().endsWith(".svg")) {
      const svgText = buf.toString("utf8")
      issues.push(...scanRawTextSecrets(svgText, filePath))
      issues.push(...validateSvgContent(svgText, filePath, "$", {allowDataUri: false}))
    }
  }

  // 9. Validate declared check documents
  for (const [checkFile, meta] of declaredCheckFiles.entries()) {
    const buf = files.get(checkFile)
    if (!buf) {
      issues.push({
        file: "manifest.json",
        path: `$.resources.checks[${meta.index}].file`,
        code: "missing_resource_file",
        message: `declared check file "${checkFile}" does not exist`,
      })
      continue
    }
    validateCheckFile(buf, checkFile, meta.slug, declaredConfigKeys, issues)
  }

  // 10. Validate declared rule documents
  for (const [ruleFile, meta] of declaredRuleFiles.entries()) {
    const buf = files.get(ruleFile)
    if (!buf) {
      issues.push({
        file: "manifest.json",
        path: `$.resources.rules[${meta.index}].file`,
        code: "missing_resource_file",
        message: `declared rule file "${ruleFile}" does not exist`,
      })
      continue
    }
    validateRuleFile(buf, ruleFile, meta.kind, meta.name, declaredConfigKeys, issues)
  }

  // 11. Validate declared dashboard documents
  for (const [dashFile, meta] of declaredDashboardFiles.entries()) {
    const buf = files.get(dashFile)
    if (!buf) {
      issues.push({
        file: "manifest.json",
        path: `$.resources.dashboards[${meta.index}].file`,
        code: "missing_resource_file",
        message: `declared dashboard file "${dashFile}" does not exist`,
      })
      continue
    }
    validateDashboardFile(buf, dashFile, meta.slug, declaredConfigKeys, issues)
  }

  if (issues.length > 0) {
    return {ok: false, issues}
  }

  return {
    ok: true,
    result: {
      manifest: manifestRaw,
      files,
      computedFileDigests,
      resourceCounts: {
        checks: declaredCheckFiles.size,
        rules: declaredRuleFiles.size,
        dashboards: declaredDashboardFiles.size,
      },
    },
  }
}

function validateConfigScalarValue(
  val: unknown,
  type: string,
  path: string,
  issues: PackValidationIssue[],
): void {
  const ok =
    (type === "string" || type === "srql_filter")
      ? typeof val === "string"
      : (type === "integer" || type === "duration_seconds")
        ? typeof val === "number" && Number.isInteger(val)
        : type === "number"
          ? typeof val === "number" && Number.isFinite(val)
          : type === "boolean"
            ? typeof val === "boolean"
            : false

  if (!ok) {
    issues.push({
      file: "manifest.json",
      path,
      code: "invalid_config_default",
      message: `value ${JSON.stringify(val)} does not match declared config type "${type}"`,
    })
  }
}

function validatePackParamRefs(
  value: unknown,
  file: string,
  path: string,
  declaredConfigKeys: Set<string>,
  issues: PackValidationIssue[],
): void {
  if (Array.isArray(value)) {
    value.forEach((child, idx) =>
      validatePackParamRefs(child, file, `${path}[${idx}]`, declaredConfigKeys, issues),
    )
    return
  }
  if (!isPlainObject(value)) {
    return
  }
  if ("$pack_param" in value) {
    const keys = Object.keys(value)
    const paramKey = value.$pack_param
    if (keys.length !== 1 || typeof paramKey !== "string" || paramKey.trim() === "") {
      issues.push({
        file,
        path,
        code: "invalid_pack_param_ref",
        message: '$pack_param reference must have exact shape {"$pack_param": "<config_key>"}',
      })
      return
    }
    if (!declaredConfigKeys.has(paramKey)) {
      issues.push({
        file,
        path,
        code: "undeclared_pack_param",
        message: `$pack_param references undeclared manifest.config key "${paramKey}"`,
      })
    }
    return
  }
  for (const [k, child] of Object.entries(value)) {
    validatePackParamRefs(child, file, `${path}.${k}`, declaredConfigKeys, issues)
  }
}

function validateCheckFile(
  buf: Buffer,
  file: string,
  expectedSlug: string,
  declaredConfigKeys: Set<string>,
  issues: PackValidationIssue[],
): void {
  let doc: unknown
  try {
    doc = JSON.parse(buf.toString("utf8"))
  } catch (err: any) {
    issues.push({
      file,
      path: "$",
      code: "invalid_json",
      message: `invalid JSON: ${err?.message || String(err)}`,
    })
    return
  }
  if (!isPlainObject(doc)) {
    issues.push({file, path: "$", code: "invalid_check", message: "check document must be a JSON object"})
    return
  }

  issues.push(...validateSecretFree(doc, file))
  validatePackParamRefs(doc, file, "$", declaredConfigKeys, issues)

  if (doc.schema_version !== 1) {
    issues.push({
      file,
      path: "$.schema_version",
      code: "unsupported_check_schema_version",
      message: `check schema_version must be 1, got ${JSON.stringify(doc.schema_version)}`,
    })
  }

  if (doc.slug !== expectedSlug) {
    issues.push({
      file,
      path: "$.slug",
      code: "check_slug_mismatch",
      message: `check slug ${JSON.stringify(doc.slug)} does not match manifest.resources.checks slug "${expectedSlug}"`,
    })
  }

  if (!Array.isArray(doc.nodes) || doc.nodes.length === 0) {
    issues.push({
      file,
      path: "$.nodes",
      code: "missing_check_nodes",
      message: "declarative check must define a non-empty nodes array",
    })
    return
  }

  const nodeIds = new Set<string>()
  doc.nodes.forEach((node, idx) => {
    const np = `$.nodes[${idx}]`
    if (!isPlainObject(node)) {
      issues.push({file, path: np, code: "invalid_node", message: "node must be an object"})
      return
    }
    if (typeof node.id !== "string" || node.id.trim() === "") {
      issues.push({file, path: `${np}.id`, code: "missing_node_id", message: "node.id must be a non-empty string"})
    } else if (nodeIds.has(node.id)) {
      issues.push({file, path: `${np}.id`, code: "duplicate_node_id", message: `duplicate node.id "${node.id}"`})
    } else {
      nodeIds.add(node.id)
    }

    if (typeof node.kind !== "string" || !ALLOWED_CHECK_NODE_KINDS.has(node.kind)) {
      issues.push({
        file,
        path: `${np}.kind`,
        code: "invalid_node_kind",
        message: `unsupported declarative check node kind ${JSON.stringify(node.kind)}`,
      })
    }
  })

  const edges = doc.edges ?? []
  if (!Array.isArray(edges)) {
    issues.push({file, path: "$.edges", code: "invalid_edges", message: "check edges must be an array"})
    return
  }

  const adjacency = new Map<string, string[]>()
  const inDegree = new Map<string, number>()
  for (const id of nodeIds) {
    adjacency.set(id, [])
    inDegree.set(id, 0)
  }

  edges.forEach((edge, idx) => {
    const ep = `$.edges[${idx}]`
    if (!isPlainObject(edge)) {
      issues.push({file, path: ep, code: "invalid_edge", message: "edge must be an object"})
      return
    }
    const src = edge.source
    const dst = edge.target
    if (typeof src !== "string" || !nodeIds.has(src)) {
      issues.push({
        file,
        path: `${ep}.source`,
        code: "unknown_edge_source",
        message: `edge source ${JSON.stringify(src)} does not match any node.id`,
      })
    }
    if (typeof dst !== "string" || !nodeIds.has(dst)) {
      issues.push({
        file,
        path: `${ep}.target`,
        code: "unknown_edge_target",
        message: `edge target ${JSON.stringify(dst)} does not match any node.id`,
      })
    }
    if (typeof src === "string" && typeof dst === "string" && nodeIds.has(src) && nodeIds.has(dst)) {
      adjacency.get(src)!.push(dst)
      inDegree.set(dst, (inDegree.get(dst) || 0) + 1)
    }
  })

  // Cycle detection via Kahn's topological sort
  const queue: string[] = []
  for (const [id, deg] of inDegree.entries()) {
    if (deg === 0) queue.push(id)
  }
  let visited = 0
  while (queue.length > 0) {
    const cur = queue.shift()!
    visited += 1
    for (const next of adjacency.get(cur) || []) {
      const nextDeg = (inDegree.get(next) || 0) - 1
      inDegree.set(next, nextDeg)
      if (nextDeg === 0) queue.push(next)
    }
  }
  if (visited !== nodeIds.size) {
    issues.push({
      file,
      path: "$.edges",
      code: "cyclic_check_dag",
      message: "declarative check graph contains a cycle",
    })
  }
}

function validateRuleFile(
  buf: Buffer,
  file: string,
  expectedKind: string,
  expectedName: string,
  declaredConfigKeys: Set<string>,
  issues: PackValidationIssue[],
): void {
  let doc: unknown
  try {
    doc = JSON.parse(buf.toString("utf8"))
  } catch (err: any) {
    issues.push({
      file,
      path: "$",
      code: "invalid_json",
      message: `invalid JSON: ${err?.message || String(err)}`,
    })
    return
  }
  if (!isPlainObject(doc)) {
    issues.push({file, path: "$", code: "invalid_rule", message: "rule document must be a JSON object"})
    return
  }

  issues.push(...validateSecretFree(doc, file))
  validatePackParamRefs(doc, file, "$", declaredConfigKeys, issues)

  if (doc.name !== expectedName) {
    issues.push({
      file,
      path: "$.name",
      code: "rule_name_mismatch",
      message: `rule name ${JSON.stringify(doc.name)} does not match manifest.resources.rules name "${expectedName}"`,
    })
  }

  if (doc.kind !== undefined && doc.kind !== expectedKind) {
    issues.push({
      file,
      path: "$.kind",
      code: "rule_kind_mismatch",
      message: `rule kind ${JSON.stringify(doc.kind)} does not match manifest.resources.rules kind "${expectedKind}"`,
    })
  }

  if (
    doc.install_state !== undefined &&
    (typeof doc.install_state !== "string" || !ALLOWED_INSTALL_STATES.has(doc.install_state))
  ) {
    issues.push({
      file,
      path: "$.install_state",
      code: "invalid_install_state",
      message: `rule install_state ${JSON.stringify(doc.install_state)} must be "enabled" or "paused"`,
    })
  }

  if (expectedKind === "zen_rule") {
    if (typeof doc.subject !== "string" || doc.subject.trim() === "") {
      issues.push({
        file,
        path: "$.subject",
        code: "missing_zen_subject",
        message: "zen_rule template requires a non-empty subject",
      })
    }
    if (typeof doc.template !== "string" && !isPlainObject(doc.jdm_definition)) {
      issues.push({
        file,
        path: "$",
        code: "missing_zen_definition",
        message: "zen_rule requires either a template name or jdm_definition object",
      })
    }
  }
}

function validateDashboardFile(
  buf: Buffer,
  file: string,
  expectedSlug: string,
  declaredConfigKeys: Set<string>,
  issues: PackValidationIssue[],
): void {
  let doc: unknown
  try {
    doc = JSON.parse(buf.toString("utf8"))
  } catch (err: any) {
    issues.push({
      file,
      path: "$",
      code: "invalid_json",
      message: `invalid JSON: ${err?.message || String(err)}`,
    })
    return
  }
  if (!isPlainObject(doc)) {
    issues.push({
      file,
      path: "$",
      code: "invalid_dashboard",
      message: "dashboard definition must be a JSON object",
    })
    return
  }

  issues.push(...validateSecretFree(doc, file))
  validatePackParamRefs(doc, file, "$", declaredConfigKeys, issues)

  if (doc.version !== 1) {
    issues.push({
      file,
      path: "$.version",
      code: "unsupported_dashboard_version",
      message: `dashboard definition version must be 1, got ${JSON.stringify(doc.version)}`,
    })
  }

  if (doc.slug !== expectedSlug) {
    issues.push({
      file,
      path: "$.slug",
      code: "dashboard_slug_mismatch",
      message: `dashboard slug ${JSON.stringify(doc.slug)} does not match manifest.resources.dashboards slug "${expectedSlug}"`,
    })
  } else if (typeof doc.slug !== "string" || !DASHBOARD_SLUG_REGEX.test(doc.slug)) {
    issues.push({
      file,
      path: "$.slug",
      code: "invalid_dashboard_slug",
      message: `dashboard slug ${JSON.stringify(doc.slug)} must be lowercase kebab-case`,
    })
  }

  if (typeof doc.title !== "string" || doc.title.trim() === "") {
    issues.push({
      file,
      path: "$.title",
      code: "missing_dashboard_title",
      message: "dashboard requires a non-empty title",
    })
  }

  if (!Array.isArray(doc.panels) || doc.panels.length === 0) {
    issues.push({
      file,
      path: "$.panels",
      code: "missing_dashboard_panels",
      message: "dashboard panels must be a non-empty array",
    })
    return
  }

  const occupiedCells = new Set<string>()
  let sawOverlap = false

  doc.panels.forEach((panel, idx) => {
    const pp = `$.panels[${idx}]`
    if (!isPlainObject(panel)) {
      issues.push({file, path: pp, code: "invalid_panel", message: "panel must be an object"})
      return
    }
    if (typeof panel.title !== "string" || panel.title.trim() === "") {
      issues.push({file, path: `${pp}.title`, code: "missing_panel_title", message: "panel requires a non-empty title"})
    }
    const query = panel.srql_query
    if (typeof query !== "string" || query.trim() === "") {
      issues.push({
        file,
        path: `${pp}.srql_query`,
        code: "missing_panel_query",
        message: "panel requires a non-empty srql_query",
      })
    }
    if (typeof panel.visual_type !== "string" || !ALLOWED_DASHBOARD_VISUAL_TYPES.has(panel.visual_type)) {
      issues.push({
        file,
        path: `${pp}.visual_type`,
        code: "invalid_panel_visual_type",
        message: `panel visual_type ${JSON.stringify(panel.visual_type)} is not supported`,
      })
    }

    const layout = panel.layout
    if (!isPlainObject(layout)) {
      issues.push({
        file,
        path: `${pp}.layout`,
        code: "missing_panel_layout",
        message: "panel requires a grid layout {x, y, w, h}",
      })
    } else {
      const {x, y, w, h} = layout
      if (
        typeof x !== "number" ||
        !Number.isInteger(x) ||
        typeof y !== "number" ||
        !Number.isInteger(y) ||
        typeof w !== "number" ||
        !Number.isInteger(w) ||
        typeof h !== "number" ||
        !Number.isInteger(h)
      ) {
        issues.push({
          file,
          path: `${pp}.layout`,
          code: "invalid_panel_layout",
          message: "panel layout requires integer x, y, w, and h",
        })
      } else if (x < 0 || x >= DASHBOARD_GRID_COLUMNS || w < 1 || x + w > DASHBOARD_GRID_COLUMNS || y < 0 || h < 1) {
        issues.push({
          file,
          path: `${pp}.layout`,
          code: "panel_layout_out_of_bounds",
          message: `panel layout {x:${x}, y:${y}, w:${w}, h:${h}} overflows the ${DASHBOARD_GRID_COLUMNS}-column grid`,
        })
      } else {
        for (let cx = x; cx < x + w; cx += 1) {
          for (let cy = y; cy < y + h; cy += 1) {
            const cellKey = `${cx},${cy}`
            if (occupiedCells.has(cellKey)) {
              sawOverlap = true
            }
            occupiedCells.add(cellKey)
          }
        }
      }
    }

    if (panel.data_binding !== undefined && typeof query === "string") {
      if (!isPlainObject(panel.data_binding)) {
        issues.push({
          file,
          path: `${pp}.data_binding`,
          code: "invalid_panel_binding",
          message: "panel data_binding must be a JSON object",
        })
      } else {
        for (const [bindKey, field] of Object.entries(panel.data_binding)) {
          if (typeof field !== "string" || !srqlQuerySelectsField(query, field)) {
            issues.push({
              file,
              path: `${pp}.data_binding.${bindKey}`,
              code: "unbound_panel_field",
              message: `panel data_binding "${bindKey}" names "${String(field)}", which is not selected by srql_query`,
            })
          }
        }
      }
    }
  })

  if (sawOverlap) {
    issues.push({
      file,
      path: "$.panels",
      code: "overlapping_dashboard_panels",
      message: "dashboard panels overlap in the 12-column grid",
    })
  }
}

function srqlQuerySelectsField(query: string, field: string): boolean {
  const escaped = field.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  if (new RegExp(` as ${escaped}(?!\\w)`).test(query)) {
    return true
  }
  if (extractGroupDimensions(query).includes(field)) {
    return true
  }
  if (field === "bucket" && query.includes("by time:")) {
    return true
  }
  return false
}

function extractGroupDimensions(query: string): string[] {
  const idx = query.indexOf(" by ")
  if (idx === -1) return []
  const afterBy = query.slice(idx + 4)
  const head = afterBy.split(/ sort:| limit:/)[0] || ""
  return head
    .split(/[ ,]+/)
    .map((tok) => tok.replace(/^["']+|["']+$/g, ""))
    .filter((tok) => tok.length > 0)
}

export async function validateCommand(options: Record<string, unknown>): Promise<void> {
  const positional = (options._ as string[] | undefined) || []
  const target = (positional[0] || options.dir || options.bundle || options.pack || process.cwd()) as string
  const source = loadPackSource(target)
  const outcome = validatePackFiles(source.files, {verifyHashes: true})

  if (!outcome.ok) {
    throw new PackValidationError(outcome.issues)
  }

  const {manifest, resourceCounts, computedFileDigests} = outcome.result
  const fileCount = Object.keys(computedFileDigests).length

  if (options.json) {
    console.log(
      JSON.stringify(
        {
          valid: true,
          source_kind: source.kind,
          path: source.resolvedPath,
          id: manifest.id,
          slug: manifest.slug,
          version: manifest.version,
          resource_counts: resourceCounts,
          file_count: fileCount,
        },
        null,
        2,
      ),
    )
    return
  }

  console.log(
    `Pack is valid: ${String(manifest.id)}@${String(manifest.version)} (${resourceCounts.checks} checks, ${resourceCounts.rules} rules, ${resourceCounts.dashboards} dashboards, ${fileCount} files)`,
  )
}
