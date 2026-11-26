// Solution Pack (`pack_format_version: 1 | 2`) directory and `.srpack` archive
// validator (`serviceradar pack validate`).

import {existsSync, lstatSync, readFileSync} from "node:fs"
import {join, resolve} from "node:path"
import {
  collectPackDirectoryFiles,
  isVantageDevAuthoringPath,
  MAX_ARCHIVE_ENTRIES,
  MAX_COMPRESSED_ARCHIVE_BYTES,
  MAX_DASHBOARD_RENDERER_BYTES,
  MAX_UNCOMPRESSED_ARCHIVE_BYTES,
  MAX_V2_DASHBOARD_COMPRESSED_ARCHIVE_BYTES,
  MAX_V2_DASHBOARD_UNCOMPRESSED_ARCHIVE_BYTES,
  readSrpackArchive,
} from "./archive.js"
import {
  compareUtf8Keys,
  isPlainObject,
  normalizeSha256Hex,
  sha256Hex,
  type PackValidationIssue,
} from "./canonical.js"
import {validateJsonSchemaDocument} from "./json_schema.js"
import {scanJsBundleSecrets, scanRawTextSecrets, validateSecretFree} from "./secret_free.js"
import {validateSvgContent} from "./svg.js"

const REVERSE_DNS_ID_REGEX = /^[a-z0-9]+(?:-[a-z0-9]+)*(?:\.[a-z0-9]+(?:-[a-z0-9]+)*)+$/
const PIPELINE_ID_REGEX = /^[a-z][a-z0-9-]*(?:\.[a-z0-9][a-z0-9._-]*)+$/
const PACK_SLUG_REGEX = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
const CHECK_SLUG_REGEX = /^[a-z0-9][a-z0-9._-]{0,126}$/
const DASHBOARD_SLUG_REGEX = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/
const DASHBOARD_PACKAGE_ID_REGEX = /^[a-z0-9][a-z0-9._-]{1,127}$/
const SIGNAL_SCHEMA_ID_REGEX = /^[a-z0-9][a-z0-9._-]{0,127}$/
const SEMVER_REGEX = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/
const SHA256_HEX_REGEX = /^[0-9a-f]{64}$/
const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const CONFIG_KEY_REGEX = /^[a-zA-Z][a-zA-Z0-9_]{0,126}$/
const SLOT_ID_REGEX = /^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,126}$/

export const MAX_DASHBOARD_MANIFEST_BYTES = 262_144

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

// The keys the alert engine reads from a stateful rule's `match`. It ignores any
// other key, so a rule written with one matches every record instead of none.
// Mirrors ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher.
const STATEFUL_RULE_MATCH_KEYS = new Set([
  "always",
  "recovery",
  "subject_prefix",
  "service_name",
  "body_contains",
  "severity_number_min",
  "severity_number_max",
  "severity_text",
  "attribute_equals",
  "resource_attribute_equals",
  "metric_name",
  "metric_type",
  "unit",
  "device_id",
  "agent_id",
  "gateway_id",
  "partition",
  "series_key",
  "tag_equals",
  "metadata_equals",
  "condition",
  "metric_condition",
  "threshold_condition",
])

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

const ALLOWED_VANTAGE_SOURCE_MODES = new Set(["recorded_block", "live_keyframe_tap"])
const ALLOWED_VANTAGE_TRIGGER_KINDS = new Set([
  "on_sealed_block",
  "on_stage1_detection",
  "live_keyframe_tap",
])
const ALLOWED_VANTAGE_INPUT_MODES = new Set([
  "full_frame",
  "detection_crop",
  "multi_frame_track",
])
const ALLOWED_VANTAGE_RUNNERS = new Set(["camera_vlm", "external_worker"])

const ALLOWED_DASHBOARD_CAPABILITIES = new Set([
  "srql.execute",
  "saved_queries.read",
  "dashboard.preferences.read",
  "dashboard.preferences.write",
  "navigation.open",
  "popup.open",
  "details.open",
  "map.basemap.read",
  "map.deck.render",
  "camera.stream.view",
  "actions.invoke",
  "events.subscribe",
])

const ALLOWED_DASHBOARD_MANIFEST_KEYS = new Set([
  "schema_version",
  "id",
  "name",
  "version",
  "description",
  "vendor",
  "renderer",
  "data_frames",
  "capabilities",
  "settings_schema",
  "source",
])

const ALLOWED_DASHBOARD_RENDERER_KEYS = new Set([
  "kind",
  "interface_version",
  "artifact",
  "sha256",
  "entrypoint",
  "exports",
  "trust",
])

const ALLOWED_DATA_FRAME_KEYS = new Set([
  "id",
  "query",
  "encoding",
  "required",
  "limit",
  "refresh_interval_ms",
  "fields",
  "coordinates",
])

const ALLOWED_DATA_FRAME_ENCODINGS = new Set(["json_rows", "arrow_ipc"])

const DASHBOARD_GRID_COLUMNS = 12

export interface PackResourceCounts {
  checks: number
  rules: number
  dashboards: number
  vantage_pipelines?: number
  signal_schemas?: number
  dashboard_packages?: number
}

export interface ValidatedPackResult {
  manifest: Record<string, unknown>
  files: Map<string, Buffer>
  computedFileDigests: Record<string, string>
  resourceCounts: PackResourceCounts
}

export class PackValidationError extends Error {
  readonly issues: PackValidationIssue[]

  constructor(issues: PackValidationIssue[]) {
    const summary = issues
      .map((issue) => `  - [${issue.code}] ${issue.file} (${issue.path}): ${issue.message}`)
      .join("\n")
    super(
      `Solution Pack validation failed (${issues.length} issue${issues.length === 1 ? "" : "s"}):\n${summary}`,
    )
    this.name = "PackValidationError"
    this.issues = issues
  }
}

export function isVantagePackDirectory(dirPath: string): boolean {
  const manifestPath = join(dirPath, "manifest.json")
  if (!existsSync(manifestPath)) {
    return false
  }
  try {
    const parsed = JSON.parse(readFileSync(manifestPath, "utf8"))
    return (
      isPlainObject(parsed) &&
      parsed.pack_format_version === 2 &&
      isPlainObject(parsed.resources) &&
      Array.isArray(parsed.resources.vantage_pipelines) &&
      parsed.resources.vantage_pipelines.length > 0
    )
  } catch {
    return false
  }
}

export function loadPackSource(targetPath: string): {
  kind: "directory" | "archive"
  resolvedPath: string
  files: Map<string, Buffer>
  compressedBytes?: number
} {
  const resolvedPath = resolve(targetPath)
  const st = lstatSync(resolvedPath)
  if (st.isSymbolicLink()) {
    throw new Error(`unsafe symlink target "${targetPath}"`)
  }
  if (st.isDirectory()) {
    const excludePath = isVantagePackDirectory(resolvedPath) ? isVantageDevAuthoringPath : undefined
    return {
      kind: "directory",
      resolvedPath,
      files: collectPackDirectoryFiles(resolvedPath, {excludePath}),
    }
  }
  if (st.isFile()) {
    const raw = readFileSync(resolvedPath)
    return {
      kind: "archive",
      resolvedPath,
      files: readSrpackArchive(raw),
      compressedBytes: raw.length,
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
  options: {verifyHashes?: boolean; compressedBytes?: number} = {},
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

  // 1. Validate pack_format_version (1 or 2)
  const formatVersion = manifestRaw.pack_format_version
  const isV1 = formatVersion === 1
  const isV2 = formatVersion === 2
  if (!isV1 && !isV2) {
    issues.push({
      file: "manifest.json",
      path: "$.pack_format_version",
      code: "unsupported_pack_format_version",
      message: `unsupported pack_format_version ${JSON.stringify(formatVersion)}; expected 1 or 2`,
    })
  }

  // Enforce v1 strictness against v2-only fields
  if (isV1) {
    for (const v2RootKey of ["worker_dependencies", "dashboard_package_dependencies"] as const) {
      if (v2RootKey in manifestRaw && manifestRaw[v2RootKey] !== undefined) {
        issues.push({
          file: "manifest.json",
          path: `$.${v2RootKey}`,
          code: "forbidden_v2_field",
          message: `${v2RootKey} is forbidden in pack_format_version=1`,
        })
      }
    }
    if (isPlainObject(manifestRaw.resources)) {
      for (const v2ResKey of [
        "vantage_pipelines",
        "signal_schemas",
        "dashboard_packages",
      ] as const) {
        if (v2ResKey in manifestRaw.resources && manifestRaw.resources[v2ResKey] !== undefined) {
          issues.push({
            file: "manifest.json",
            path: `$.resources.${v2ResKey}`,
            code: "forbidden_v2_field",
            message: `resources.${v2ResKey} is forbidden in pack_format_version=1`,
          })
        }
      }
    }
  }

  // Enforce archive size limits based on format version and dashboard_packages presence
  const hasDashboardPackages =
    isV2 &&
    ((isPlainObject(manifestRaw.resources) &&
      Array.isArray(manifestRaw.resources.dashboard_packages) &&
      manifestRaw.resources.dashboard_packages.length > 0) ||
      Array.from(files.keys()).some((p) => p.startsWith("dashboard_packages/")))

  if (files.size > MAX_ARCHIVE_ENTRIES) {
    issues.push({
      file: "manifest.json",
      path: "$",
      code: "too_many_archive_entries",
      message: `pack entry count ${files.size} exceeds ${MAX_ARCHIVE_ENTRIES}`,
    })
  }

  let totalUncompressedBytes = 0
  for (const buf of files.values()) {
    totalUncompressedBytes += buf.length
  }
  const maxUncompressedBytes = hasDashboardPackages
    ? MAX_V2_DASHBOARD_UNCOMPRESSED_ARCHIVE_BYTES
    : MAX_UNCOMPRESSED_ARCHIVE_BYTES
  if (totalUncompressedBytes > maxUncompressedBytes) {
    issues.push({
      file: "manifest.json",
      path: "$",
      code: "uncompressed_archive_too_large",
      message: `pack uncompressed size ${totalUncompressedBytes} exceeds ${maxUncompressedBytes} bytes`,
    })
  }

  if (options.compressedBytes !== undefined) {
    const maxCompressedBytes = hasDashboardPackages
      ? MAX_V2_DASHBOARD_COMPRESSED_ARCHIVE_BYTES
      : MAX_COMPRESSED_ARCHIVE_BYTES
    if (options.compressedBytes > maxCompressedBytes) {
      issues.push({
        file: "manifest.json",
        path: "$",
        code: "compressed_archive_too_large",
        message: `compressed .srpack size ${options.compressedBytes} exceeds ${maxCompressedBytes} bytes`,
      })
    }
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

  // 5b. v2 worker_dependencies & dashboard_package_dependencies
  if (isV2 && manifestRaw.worker_dependencies !== undefined) {
    if (!Array.isArray(manifestRaw.worker_dependencies)) {
      issues.push({
        file: "manifest.json",
        path: "$.worker_dependencies",
        code: "invalid_worker_dependencies",
        message: "manifest.worker_dependencies must be an array",
      })
    } else {
      manifestRaw.worker_dependencies.forEach((dep, idx) => {
        const dp = `$.worker_dependencies[${idx}]`
        if (!isPlainObject(dep)) {
          issues.push({
            file: "manifest.json",
            path: dp,
            code: "invalid_worker_dependency",
            message: "worker_dependencies entry must be an object",
          })
          return
        }
        if (typeof dep.capability !== "string" || dep.capability.trim() === "") {
          issues.push({
            file: "manifest.json",
            path: `${dp}.capability`,
            code: "missing_worker_capability",
            message: "worker_dependencies.capability must be a non-empty string",
          })
        }
        if (
          dep.min_protocol_version !== undefined &&
          dep.min_protocol_version !== null &&
          (typeof dep.min_protocol_version !== "string" || dep.min_protocol_version.trim() === "")
        ) {
          issues.push({
            file: "manifest.json",
            path: `${dp}.min_protocol_version`,
            code: "invalid_worker_protocol_version",
            message: "worker_dependencies.min_protocol_version must be a non-empty string",
          })
        }
        if (dep.optional !== undefined && typeof dep.optional !== "boolean") {
          issues.push({
            file: "manifest.json",
            path: `${dp}.optional`,
            code: "invalid_worker_optional",
            message: "worker_dependencies.optional must be a boolean",
          })
        }
        if (
          dep.fallback_runner !== undefined &&
          dep.fallback_runner !== null &&
          (typeof dep.fallback_runner !== "string" ||
            !ALLOWED_VANTAGE_RUNNERS.has(dep.fallback_runner))
        ) {
          issues.push({
            file: "manifest.json",
            path: `${dp}.fallback_runner`,
            code: "invalid_fallback_runner",
            message: `worker_dependencies.fallback_runner must be one of ${Array.from(ALLOWED_VANTAGE_RUNNERS).join(", ")}`,
          })
        }
      })
    }
  }

  if (isV2 && manifestRaw.dashboard_package_dependencies !== undefined) {
    if (!Array.isArray(manifestRaw.dashboard_package_dependencies)) {
      issues.push({
        file: "manifest.json",
        path: "$.dashboard_package_dependencies",
        code: "invalid_dashboard_package_dependencies",
        message: "manifest.dashboard_package_dependencies must be an array",
      })
    } else {
      manifestRaw.dashboard_package_dependencies.forEach((dep, idx) => {
        const dp = `$.dashboard_package_dependencies[${idx}]`
        if (typeof dep === "string") {
          const atIdx = dep.indexOf("@")
          const idPart = (atIdx > 0 ? dep.slice(0, atIdx) : dep).trim()
          const verPart = atIdx > 0 ? dep.slice(atIdx + 1).trim() : ""
          if (UUID_REGEX.test(idPart)) {
            if (
              !issues.some(
                (i) =>
                  i.file === "manifest.json" &&
                  i.path === dp &&
                  i.code === "forbidden_instance_uuid",
              )
            ) {
              issues.push({
                file: "manifest.json",
                path: dp,
                code: "forbidden_instance_uuid",
                message: `live UUID value "${idPart}" in dashboard_package_dependencies is not permitted in portable Solution Packs`,
              })
            }
          } else if (atIdx <= 0 || !DASHBOARD_PACKAGE_ID_REGEX.test(idPart) || verPart === "") {
            issues.push({
              file: "manifest.json",
              path: dp,
              code: "invalid_dashboard_package_dependency",
              message: `dashboard_package_dependencies string "${dep}" must have form "<dashboard_id>@<version>"`,
            })
          }
          return
        }
        if (!isPlainObject(dep)) {
          issues.push({
            file: "manifest.json",
            path: dp,
            code: "invalid_dashboard_package_dependency",
            message: "dashboard_package_dependencies entry must be a string or object",
          })
          return
        }
        if (
          typeof dep.dashboard_id !== "string" ||
          !DASHBOARD_PACKAGE_ID_REGEX.test(dep.dashboard_id)
        ) {
          issues.push({
            file: "manifest.json",
            path: `${dp}.dashboard_id`,
            code: "invalid_dashboard_package_id",
            message: "dashboard_package_dependencies.dashboard_id must be a valid dashboard package id",
          })
        }
        for (const verKey of ["version_constraint", "version_range", "version"] as const) {
          if (
            dep[verKey] !== undefined &&
            (typeof dep[verKey] !== "string" || (dep[verKey] as string).trim() === "")
          ) {
            issues.push({
              file: "manifest.json",
              path: `${dp}.${verKey}`,
              code: "invalid_dashboard_version_constraint",
              message: `dashboard_package_dependencies.${verKey} must be a non-empty string`,
            })
          }
        }
        if (dep.required !== undefined && typeof dep.required !== "boolean") {
          issues.push({
            file: "manifest.json",
            path: `${dp}.required`,
            code: "invalid_dashboard_dependency_required",
            message: "dashboard_package_dependencies.required must be a boolean",
          })
        }
        if (
          dep.route !== undefined &&
          (typeof dep.route !== "string" || dep.route.trim() === "")
        ) {
          issues.push({
            file: "manifest.json",
            path: `${dp}.route`,
            code: "invalid_dashboard_dependency_route",
            message: "dashboard_package_dependencies.route must be a non-empty string",
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
  const declaredVantagePipelineFiles = new Map<
    string,
    {id?: string; slug?: string; index: number}
  >()
  const declaredSignalSchemaFiles = new Map<
    string,
    {
      id: string
      version?: string
      schemaFile: string
      displayFile?: string
      index: number
    }
  >()
  const declaredSignalSchemaIds = new Map<
    string,
    {version?: string; schemaFile: string; displayFile?: string}
  >()
  const declaredSignalSchemaPaths = new Set<string>()
  const declaredDashboardPackages = new Map<
    string,
    {
      slug: string
      dir: string
      manifestFile: string
      rendererFile: string
      index: number
    }
  >()
  const declaredDashboardPackagePaths = new Set<string>()

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
          issues.push({
            file: "manifest.json",
            path: p,
            code: "invalid_check_ref",
            message: "must be an object",
          })
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
          issues.push({
            file: "manifest.json",
            path: p,
            code: "invalid_rule_ref",
            message: "must be an object",
          })
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
          issues.push({
            file: "manifest.json",
            path: p,
            code: "invalid_dashboard_ref",
            message: "must be an object",
          })
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

    if (isV2) {
      // 6b. resources.vantage_pipelines
      if (res.vantage_pipelines !== undefined && res.vantage_pipelines !== null) {
        if (!Array.isArray(res.vantage_pipelines)) {
          issues.push({
            file: "manifest.json",
            path: "$.resources.vantage_pipelines",
            code: "invalid_resources_vantage_pipelines",
            message: "manifest.resources.vantage_pipelines must be an array",
          })
        } else {
          res.vantage_pipelines.forEach((item, idx) => {
            const p = `$.resources.vantage_pipelines[${idx}]`
            if (!isPlainObject(item)) {
              issues.push({
                file: "manifest.json",
                path: p,
                code: "invalid_vantage_pipeline_ref",
                message: "must be an object",
              })
              return
            }
            const file = item.file
            const hasId = item.id !== undefined && item.id !== null
            const hasPipelineId = item.pipeline_id !== undefined && item.pipeline_id !== null
            const rawId = typeof item.id === "string" ? item.id.trim() : ""
            const rawPipelineId = typeof item.pipeline_id === "string" ? item.pipeline_id.trim() : ""
            const id = rawId || rawPipelineId || undefined
            const slug = typeof item.slug === "string" ? item.slug.trim() : undefined
            if (typeof file !== "string" || !/^vantage_pipelines\/[A-Za-z0-9._-]+\.json$/.test(file)) {
              issues.push({
                file: "manifest.json",
                path: `${p}.file`,
                code: "invalid_vantage_pipeline_file_path",
                message: `vantage pipeline file ${JSON.stringify(file)} must match "vantage_pipelines/<name>.json"`,
              })
              return
            }
            if (declaredVantagePipelineFiles.has(file)) {
              issues.push({
                file: "manifest.json",
                path: `${p}.file`,
                code: "duplicate_resource_file",
                message: `duplicate vantage pipeline file "${file}" in manifest.resources.vantage_pipelines`,
              })
              return
            }
            if (hasId && (!rawId || !PIPELINE_ID_REGEX.test(rawId))) {
              issues.push({
                file: "manifest.json",
                path: `${p}.id`,
                code: "invalid_vantage_pipeline_id",
                message: `vantage pipeline id ${JSON.stringify(item.id)} must be reverse-DNS`,
              })
            }
            if (hasPipelineId && (!rawPipelineId || !PIPELINE_ID_REGEX.test(rawPipelineId))) {
              issues.push({
                file: "manifest.json",
                path: `${p}.pipeline_id`,
                code: "invalid_vantage_pipeline_id",
                message: `vantage pipeline pipeline_id ${JSON.stringify(item.pipeline_id)} must be reverse-DNS`,
              })
            }
            if (rawId && rawPipelineId && rawId !== rawPipelineId) {
              issues.push({
                file: "manifest.json",
                path: `${p}.pipeline_id`,
                code: "pipeline_id_mismatch",
                message: `vantage pipeline pipeline_id ${JSON.stringify(rawPipelineId)} does not match id ${JSON.stringify(rawId)}`,
              })
            }
            if (!id && !slug) {
              issues.push({
                file: "manifest.json",
                path: p,
                code: "missing_vantage_pipeline_identity",
                message: "vantage_pipelines entry requires non-empty id, pipeline_id, or slug",
              })
              return
            }
            if (slug && !CHECK_SLUG_REGEX.test(slug)) {
              issues.push({
                file: "manifest.json",
                path: `${p}.slug`,
                code: "invalid_vantage_pipeline_slug",
                message: `vantage pipeline slug ${JSON.stringify(slug)} is invalid`,
              })
            }
            declaredVantagePipelineFiles.set(file, {id, slug, index: idx})
          })
        }
      }

      // 6c. resources.signal_schemas
      if (res.signal_schemas !== undefined && res.signal_schemas !== null) {
        if (!Array.isArray(res.signal_schemas)) {
          issues.push({
            file: "manifest.json",
            path: "$.resources.signal_schemas",
            code: "invalid_resources_signal_schemas",
            message: "manifest.resources.signal_schemas must be an array",
          })
        } else {
          res.signal_schemas.forEach((item, idx) => {
            const p = `$.resources.signal_schemas[${idx}]`
            if (!isPlainObject(item)) {
              issues.push({
                file: "manifest.json",
                path: p,
                code: "invalid_signal_schema_ref",
                message: "must be an object",
              })
              return
            }
            const id = item.id
            const version = item.version
            const schemaFile = item.schema_file ?? item.file
            const displayFile = item.display_file

            if (typeof id !== "string" || !SIGNAL_SCHEMA_ID_REGEX.test(id)) {
              issues.push({
                file: "manifest.json",
                path: `${p}.id`,
                code: "invalid_signal_schema_id",
                message: `signal_schemas.id ${JSON.stringify(id)} must be a valid identifier`,
              })
            }
            if (version !== undefined && (typeof version !== "string" || !SEMVER_REGEX.test(version))) {
              issues.push({
                file: "manifest.json",
                path: `${p}.version`,
                code: "invalid_signal_schema_version",
                message: `signal_schemas.version ${JSON.stringify(version)} must be a valid SemVer string`,
              })
            }
            if (
              typeof schemaFile !== "string" ||
              !/^signal_schemas\/[A-Za-z0-9._-]+\.json$/.test(schemaFile)
            ) {
              issues.push({
                file: "manifest.json",
                path: `${p}.file`,
                code: "invalid_signal_schema_file_path",
                message: `signal schema file ${JSON.stringify(schemaFile)} must match "signal_schemas/<name>.json"`,
              })
              return
            }
            if (declaredSignalSchemaPaths.has(schemaFile)) {
              issues.push({
                file: "manifest.json",
                path: `${p}.file`,
                code: "duplicate_resource_file",
                message: `duplicate signal schema file "${schemaFile}"`,
              })
              return
            }
            if (displayFile !== undefined && displayFile !== null) {
              if (
                typeof displayFile !== "string" ||
                !/^signal_schemas\/[A-Za-z0-9._-]+\.json$/.test(displayFile)
              ) {
                issues.push({
                  file: "manifest.json",
                  path: `${p}.display_file`,
                  code: "invalid_display_file_path",
                  message: `signal schema display_file ${JSON.stringify(displayFile)} must match "signal_schemas/<name>.json"`,
                })
                return
              }
              if (declaredSignalSchemaPaths.has(displayFile) || displayFile === schemaFile) {
                issues.push({
                  file: "manifest.json",
                  path: `${p}.display_file`,
                  code: "duplicate_resource_file",
                  message: `duplicate signal schema display_file "${displayFile}"`,
                })
                return
              }
              declaredSignalSchemaPaths.add(displayFile)
            }
            declaredSignalSchemaPaths.add(schemaFile)

            if (typeof id === "string") {
              declaredSignalSchemaFiles.set(schemaFile, {
                id,
                version: typeof version === "string" ? version : undefined,
                schemaFile,
                displayFile: typeof displayFile === "string" ? displayFile : undefined,
                index: idx,
              })
              declaredSignalSchemaIds.set(id, {
                version: typeof version === "string" ? version : undefined,
                schemaFile,
                displayFile: typeof displayFile === "string" ? displayFile : undefined,
              })
            }
          })
        }
      }

      // 6d. resources.dashboard_packages
      if (res.dashboard_packages !== undefined && res.dashboard_packages !== null) {
        if (!Array.isArray(res.dashboard_packages)) {
          issues.push({
            file: "manifest.json",
            path: "$.resources.dashboard_packages",
            code: "invalid_resources_dashboard_packages",
            message: "manifest.resources.dashboard_packages must be an array",
          })
        } else {
          res.dashboard_packages.forEach((item, idx) => {
            const p = `$.resources.dashboard_packages[${idx}]`
            if (!isPlainObject(item)) {
              issues.push({
                file: "manifest.json",
                path: p,
                code: "invalid_dashboard_package_ref",
                message: "must be an object",
              })
              return
            }
            const slug = item.slug
            if (typeof slug !== "string" || !DASHBOARD_SLUG_REGEX.test(slug)) {
              issues.push({
                file: "manifest.json",
                path: `${p}.slug`,
                code: "invalid_dashboard_package_slug",
                message: `dashboard_packages.slug ${JSON.stringify(slug)} must be lowercase kebab-case`,
              })
              return
            }
            if (declaredDashboardPackages.has(slug)) {
              issues.push({
                file: "manifest.json",
                path: `${p}.slug`,
                code: "duplicate_dashboard_package_slug",
                message: `duplicate dashboard_packages slug "${slug}"`,
              })
              return
            }
            const expectedDir = `dashboard_packages/${slug}`
            if (item.dir !== undefined && item.dir !== expectedDir) {
              issues.push({
                file: "manifest.json",
                path: `${p}.dir`,
                code: "invalid_dashboard_package_dir",
                message: `dashboard_packages.dir must be "${expectedDir}"`,
              })
            }
            const manifestFile =
              typeof item.manifest_file === "string"
                ? item.manifest_file
                : `${expectedDir}/manifest.json`
            const rendererFile =
              typeof item.renderer_file === "string"
                ? item.renderer_file
                : `${expectedDir}/renderer.js`

            if (manifestFile !== `${expectedDir}/manifest.json`) {
              issues.push({
                file: "manifest.json",
                path: `${p}.manifest_file`,
                code: "invalid_dashboard_package_manifest_file",
                message: `dashboard_packages.manifest_file must be "${expectedDir}/manifest.json"`,
              })
            }
            if (rendererFile !== `${expectedDir}/renderer.js`) {
              issues.push({
                file: "manifest.json",
                path: `${p}.renderer_file`,
                code: "invalid_dashboard_package_renderer_file",
                message: `dashboard_packages.renderer_file must be "${expectedDir}/renderer.js"`,
              })
            }

            declaredDashboardPackages.set(slug, {
              slug,
              dir: expectedDir,
              manifestFile,
              rendererFile,
              index: idx,
            })
            declaredDashboardPackagePaths.add(manifestFile)
            declaredDashboardPackagePaths.add(rendererFile)
          })
        }
      }
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
    if (isV2 && relPath.startsWith("vantage_pipelines/")) {
      if (!declaredVantagePipelineFiles.has(relPath)) {
        issues.push({
          file: relPath,
          path: "$",
          code: "unlisted_resource_file",
          message: `vantage pipeline file "${relPath}" is not declared in manifest.resources.vantage_pipelines`,
        })
      }
      continue
    }
    if (isV2 && relPath.startsWith("signal_schemas/")) {
      if (!declaredSignalSchemaPaths.has(relPath)) {
        issues.push({
          file: relPath,
          path: "$",
          code: "unlisted_resource_file",
          message: `signal schema file "${relPath}" is not declared in manifest.resources.signal_schemas`,
        })
      }
      continue
    }
    if (isV2 && relPath.startsWith("dashboard_packages/")) {
      if (!declaredDashboardPackagePaths.has(relPath)) {
        issues.push({
          file: relPath,
          path: "$",
          code: "unlisted_resource_file",
          message: `dashboard package file "${relPath}" is not declared in manifest.resources.dashboard_packages`,
        })
      }
      continue
    }
    if (
      isV1 &&
      (relPath.startsWith("vantage_pipelines/") ||
        relPath.startsWith("signal_schemas/") ||
        relPath.startsWith("dashboard_packages/"))
    ) {
      issues.push({
        file: relPath,
        path: "$",
        code: "forbidden_v2_directory",
        message: `v2 directory file "${relPath}" is forbidden in pack_format_version=1`,
      })
      continue
    }
    issues.push({
      file: relPath,
      path: "$",
      code: "unlisted_file",
      message: `unexpected file "${relPath}" outside allowed pack directories`,
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
          path: '$.files["manifest.json"]',
          code: "invalid_files_entry",
          message: "manifest.files must not list manifest.json itself",
        })
      }

      for (const [listedPath, expectedRaw] of Object.entries(manifestFiles)) {
        if (listedPath === "manifest.json") continue
        if (
          typeof expectedRaw !== "string" ||
          !SHA256_HEX_REGEX.test(normalizeSha256Hex(expectedRaw))
        ) {
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
    validateCheckFile(buf, checkFile, meta.slug, declaredConfigKeys, isV2, issues)
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
    validateRuleFile(buf, ruleFile, meta.kind, meta.name, declaredConfigKeys, isV2, issues)
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
    validateDashboardFile(buf, dashFile, meta.slug, declaredConfigKeys, isV2, issues)
  }

  // 12. Validate v2 signal_schemas, vantage_pipelines, and dashboard_packages
  const displayContractIds = new Set<string>()
  if (isV2) {
    for (const [schemaFile, meta] of declaredSignalSchemaFiles.entries()) {
      const schemaBuf = files.get(schemaFile)
      if (!schemaBuf) {
        issues.push({
          file: "manifest.json",
          path: `$.resources.signal_schemas[${meta.index}].file`,
          code: "missing_resource_file",
          message: `declared signal schema file "${schemaFile}" does not exist`,
        })
      } else {
        validateSignalSchemaFile(schemaBuf, schemaFile, meta.id, meta.version, issues)
      }

      if (meta.displayFile) {
        const displayBuf = files.get(meta.displayFile)
        if (!displayBuf) {
          issues.push({
            file: "manifest.json",
            path: `$.resources.signal_schemas[${meta.index}].display_file`,
            code: "missing_resource_file",
            message: `declared signal schema display_file "${meta.displayFile}" does not exist`,
          })
        } else {
          const parsedDisplayId = validateDisplayContractFile(
            displayBuf,
            meta.displayFile,
            meta.id,
            declaredConfigKeys,
            issues,
          )
          if (parsedDisplayId) {
            displayContractIds.add(parsedDisplayId)
          }
        }
      }
    }

    for (const [pipelineFile, meta] of declaredVantagePipelineFiles.entries()) {
      const buf = files.get(pipelineFile)
      if (!buf) {
        issues.push({
          file: "manifest.json",
          path: `$.resources.vantage_pipelines[${meta.index}].file`,
          code: "missing_resource_file",
          message: `declared vantage pipeline file "${pipelineFile}" does not exist`,
        })
        continue
      }
      validateVantagePipelineFile(
        buf,
        pipelineFile,
        meta,
        declaredConfigKeys,
        declaredSignalSchemaIds,
        displayContractIds,
        issues,
      )
    }

    for (const [, meta] of declaredDashboardPackages.entries()) {
      validateDashboardPackageEntry(files, manifestRaw, meta, verifyHashes, issues)
    }
  }

  if (issues.length > 0) {
    return {ok: false, issues}
  }

  const resourceCounts: PackResourceCounts = isV2
    ? {
        checks: declaredCheckFiles.size,
        rules: declaredRuleFiles.size,
        dashboards: declaredDashboardFiles.size,
        vantage_pipelines: declaredVantagePipelineFiles.size,
        signal_schemas: declaredSignalSchemaFiles.size,
        dashboard_packages: declaredDashboardPackages.size,
      }
    : {
        checks: declaredCheckFiles.size,
        rules: declaredRuleFiles.size,
        dashboards: declaredDashboardFiles.size,
      }

  return {
    ok: true,
    result: {
      manifest: manifestRaw,
      files,
      computedFileDigests,
      resourceCounts,
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
    type === "string" || type === "srql_filter"
      ? typeof val === "string"
      : type === "integer" || type === "duration_seconds"
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

function isPackParamRef(value: unknown): value is {$pack_param: string} {
  return (
    isPlainObject(value) &&
    "$pack_param" in value &&
    Object.keys(value).length === 1 &&
    typeof value.$pack_param === "string" &&
    value.$pack_param.trim() !== ""
  )
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
  isV2: boolean,
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
      code: "invalid_check",
      message: "check document must be a JSON object",
    })
    return
  }

  issues.push(...validateSecretFree(doc, file))
  validatePackParamRefs(doc, file, "$", declaredConfigKeys, issues)

  if (doc.slug !== expectedSlug) {
    issues.push({
      file,
      path: "$.slug",
      code: "check_slug_mismatch",
      message: `check slug ${JSON.stringify(doc.slug)} does not match manifest.resources.checks slug "${expectedSlug}"`,
    })
  }

  // Pack v2 supports declarative worker capability health checks alongside DAG checks.
  if (isV2 && doc.kind === "vantage_worker_capability" && doc.nodes === undefined) {
    if (typeof doc.capability !== "string" || doc.capability.trim() === "") {
      issues.push({
        file,
        path: "$.capability",
        code: "missing_check_capability",
        message: "vantage_worker_capability check requires a non-empty capability",
      })
    }
    if (
      doc.interval_seconds !== undefined &&
      (typeof doc.interval_seconds !== "number" ||
        !Number.isInteger(doc.interval_seconds) ||
        doc.interval_seconds < 1)
    ) {
      issues.push({
        file,
        path: "$.interval_seconds",
        code: "invalid_check_interval",
        message: "check interval_seconds must be a positive integer",
      })
    }
    return
  }

  if (doc.schema_version !== 1) {
    issues.push({
      file,
      path: "$.schema_version",
      code: "unsupported_check_schema_version",
      message: `check schema_version must be 1, got ${JSON.stringify(doc.schema_version)}`,
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
      issues.push({
        file,
        path: `${np}.id`,
        code: "missing_node_id",
        message: "node.id must be a non-empty string",
      })
    } else if (nodeIds.has(node.id)) {
      issues.push({
        file,
        path: `${np}.id`,
        code: "duplicate_node_id",
        message: `duplicate node.id "${node.id}"`,
      })
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
    issues.push({
      file,
      path: "$.edges",
      code: "invalid_edges",
      message: "check edges must be an array",
    })
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
  isV2: boolean,
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
      code: "invalid_rule",
      message: "rule document must be a JSON object",
    })
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

  const isV2SignalScopedRule =
    isV2 && typeof doc.signal_schema_id === "string" && doc.signal_schema_id.trim() !== ""

  if (expectedKind === "stateful_alert_rule" && isPlainObject(doc.match) && !isV2SignalScopedRule) {
    const clauses: Array<[string, Record<string, unknown>, boolean]> = [["$.match", doc.match, true]]
    if (isPlainObject(doc.match.recovery)) {
      clauses.push(["$.match.recovery", doc.match.recovery, false])
    }
    for (const [path, clause, allowRecovery] of clauses) {
      for (const key of Object.keys(clause).sort()) {
        if (!STATEFUL_RULE_MATCH_KEYS.has(key) || (key === "recovery" && !allowRecovery)) {
          issues.push({
            file,
            path: `${path}.${key}`,
            code: "unknown_match_key",
            message: `the alert engine does not read match key ${JSON.stringify(key)}; put record fields under attribute_equals`,
          })
        }
      }
    }
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
  isV2: boolean,
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

  // Pack v2 supports simplified SRQL widget overview dashboards alongside v1 grid panels.
  if (isV2 && Array.isArray(doc.widgets) && doc.panels === undefined && doc.version === undefined) {
    if (doc.widgets.length === 0) {
      issues.push({
        file,
        path: "$.widgets",
        code: "missing_dashboard_widgets",
        message: "dashboard widgets must be a non-empty array",
      })
      return
    }
    doc.widgets.forEach((widget, idx) => {
      const wp = `$.widgets[${idx}]`
      if (!isPlainObject(widget)) {
        issues.push({file, path: wp, code: "invalid_widget", message: "widget must be an object"})
        return
      }
      if (typeof widget.title !== "string" || widget.title.trim() === "") {
        issues.push({
          file,
          path: `${wp}.title`,
          code: "missing_widget_title",
          message: "widget requires a non-empty title",
        })
      }
      if (typeof widget.query !== "string" || widget.query.trim() === "") {
        issues.push({
          file,
          path: `${wp}.query`,
          code: "missing_widget_query",
          message: "widget requires a non-empty query",
        })
      }
    })
    return
  }

  if (doc.version !== 1) {
    issues.push({
      file,
      path: "$.version",
      code: "unsupported_dashboard_version",
      message: `dashboard definition version must be 1, got ${JSON.stringify(doc.version)}`,
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
      issues.push({
        file,
        path: `${pp}.title`,
        code: "missing_panel_title",
        message: "panel requires a non-empty title",
      })
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
      } else if (
        x < 0 ||
        x >= DASHBOARD_GRID_COLUMNS ||
        w < 1 ||
        x + w > DASHBOARD_GRID_COLUMNS ||
        y < 0 ||
        h < 1
      ) {
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

function validateSignalSchemaFile(
  buf: Buffer,
  file: string,
  expectedId: string,
  expectedVersion: string | undefined,
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
      code: "invalid_signal_schema",
      message: "signal schema must be a JSON object",
    })
    return
  }

  issues.push(...validateSecretFree(doc, file))
  if (doc.id !== undefined && doc.id !== expectedId) {
    issues.push({
      file,
      path: "$.id",
      code: "signal_schema_id_mismatch",
      message: `signal schema id ${JSON.stringify(doc.id)} does not match manifest.resources.signal_schemas id "${expectedId}"`,
    })
  }
  if (expectedVersion && doc.version !== undefined && doc.version !== expectedVersion) {
    issues.push({
      file,
      path: "$.version",
      code: "signal_schema_version_mismatch",
      message: `signal schema version ${JSON.stringify(doc.version)} does not match "${expectedVersion}"`,
    })
  }
  validateJsonSchemaDocument(doc, file, issues)
}

function validateDisplayContractFile(
  buf: Buffer,
  file: string,
  expectedId: string,
  declaredConfigKeys: Set<string>,
  issues: PackValidationIssue[],
): string | null {
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
    return null
  }
  if (!isPlainObject(doc)) {
    issues.push({
      file,
      path: "$",
      code: "invalid_display_contract",
      message: "signal schema display contract must be a JSON object",
    })
    return null
  }

  issues.push(...validateSecretFree(doc, file))
  validatePackParamRefs(doc, file, "$", declaredConfigKeys, issues)

  const displayId = typeof doc.id === "string" && doc.id.trim() !== "" ? doc.id.trim() : expectedId
  if (doc.id !== undefined && doc.id !== expectedId) {
    issues.push({
      file,
      path: "$.id",
      code: "display_contract_id_mismatch",
      message: `display contract id ${JSON.stringify(doc.id)} does not match signal schema id "${expectedId}"`,
    })
  }
  if (doc.version !== undefined && (typeof doc.version !== "string" || !SEMVER_REGEX.test(doc.version))) {
    issues.push({
      file,
      path: "$.version",
      code: "invalid_display_contract_version",
      message: `display contract version ${JSON.stringify(doc.version)} must be a valid SemVer string`,
    })
  }
  return displayId
}

function validateVantagePipelineFile(
  buf: Buffer,
  file: string,
  meta: {id?: string; slug?: string; index: number},
  declaredConfigKeys: Set<string>,
  declaredSignalSchemaIds: Map<string, {version?: string; schemaFile: string; displayFile?: string}>,
  displayContractIds: Set<string>,
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
      code: "invalid_vantage_pipeline",
      message: "vantage pipeline document must be a JSON object",
    })
    return
  }

  issues.push(...validateSecretFree(doc, file))
  validatePackParamRefs(doc, file, "$", declaredConfigKeys, issues)

  if (typeof doc.pipeline_id !== "string" || !PIPELINE_ID_REGEX.test(doc.pipeline_id)) {
    issues.push({
      file,
      path: "$.pipeline_id",
      code: "invalid_pipeline_id",
      message: `pipeline_id ${JSON.stringify(doc.pipeline_id)} must be a valid reverse-DNS identifier`,
    })
  } else if (meta.id && doc.pipeline_id !== meta.id) {
    issues.push({
      file,
      path: "$.pipeline_id",
      code: "pipeline_id_mismatch",
      message: `pipeline_id ${JSON.stringify(doc.pipeline_id)} does not match manifest.resources.vantage_pipelines id "${meta.id}"`,
    })
  }

  if (typeof doc.version !== "string" || !SEMVER_REGEX.test(doc.version)) {
    issues.push({
      file,
      path: "$.version",
      code: "invalid_pipeline_version",
      message: `pipeline version ${JSON.stringify(doc.version)} must be a valid SemVer string`,
    })
  }

  if (typeof doc.name !== "string" || doc.name.trim() === "") {
    issues.push({
      file,
      path: "$.name",
      code: "missing_pipeline_name",
      message: "vantage pipeline requires a non-empty name",
    })
  }

  if (typeof doc.source_mode !== "string" || !ALLOWED_VANTAGE_SOURCE_MODES.has(doc.source_mode)) {
    issues.push({
      file,
      path: "$.source_mode",
      code: "invalid_source_mode",
      message: `source_mode must be one of ${Array.from(ALLOWED_VANTAGE_SOURCE_MODES).join(", ")}`,
    })
  }

  if (typeof doc.trigger_kind !== "string" || !ALLOWED_VANTAGE_TRIGGER_KINDS.has(doc.trigger_kind)) {
    issues.push({
      file,
      path: "$.trigger_kind",
      code: "invalid_trigger_kind",
      message: `trigger_kind must be one of ${Array.from(ALLOWED_VANTAGE_TRIGGER_KINDS).join(", ")}`,
    })
  }

  if (typeof doc.input_mode !== "string" || !ALLOWED_VANTAGE_INPUT_MODES.has(doc.input_mode)) {
    issues.push({
      file,
      path: "$.input_mode",
      code: "invalid_input_mode",
      message: `input_mode must be one of ${Array.from(ALLOWED_VANTAGE_INPUT_MODES).join(", ")}`,
    })
  }

  const runner = doc.runner
  if (typeof runner !== "string" || !ALLOWED_VANTAGE_RUNNERS.has(runner)) {
    issues.push({
      file,
      path: "$.runner",
      code: "invalid_runner",
      message: `runner must be one of ${Array.from(ALLOWED_VANTAGE_RUNNERS).join(", ")}`,
    })
  }

  const fallbackRunner = doc.fallback_runner
  if (
    fallbackRunner !== undefined &&
    fallbackRunner !== null &&
    (typeof fallbackRunner !== "string" || !ALLOWED_VANTAGE_RUNNERS.has(fallbackRunner))
  ) {
    issues.push({
      file,
      path: "$.fallback_runner",
      code: "invalid_fallback_runner",
      message: `fallback_runner must be one of ${Array.from(ALLOWED_VANTAGE_RUNNERS).join(", ")}`,
    })
  }

  if (runner === "external_worker") {
    if (typeof doc.capability !== "string" || doc.capability.trim() === "") {
      issues.push({
        file,
        path: "$.capability",
        code: "missing_pipeline_capability",
        message: 'external_worker pipeline requires a non-empty "capability"',
      })
    }
  } else if (
    doc.capability !== undefined &&
    doc.capability !== null &&
    (typeof doc.capability !== "string" || doc.capability.trim() === "")
  ) {
    issues.push({
      file,
      path: "$.capability",
      code: "invalid_pipeline_capability",
      message: "pipeline capability must be a non-empty string when provided",
    })
  }

  const selectorValid =
    (typeof doc.camera_selector === "string" && doc.camera_selector.trim() !== "") ||
    isPlainObject(doc.camera_selector)
  if (!selectorValid) {
    issues.push({
      file,
      path: "$.camera_selector",
      code: "invalid_camera_selector",
      message: "camera_selector must be a non-empty selector string or object",
    })
  }

  if (doc.min_confidence !== undefined && !isPackParamRef(doc.min_confidence)) {
    if (
      typeof doc.min_confidence !== "number" ||
      !Number.isFinite(doc.min_confidence) ||
      doc.min_confidence < 0 ||
      doc.min_confidence > 1
    ) {
      issues.push({
        file,
        path: "$.min_confidence",
        code: "invalid_min_confidence",
        message: "min_confidence must be a number in [0, 1]",
      })
    }
  }

  if (doc.roi_polygons !== undefined) {
    if (!Array.isArray(doc.roi_polygons)) {
      issues.push({
        file,
        path: "$.roi_polygons",
        code: "invalid_roi_polygons",
        message: "roi_polygons must be an array",
      })
    } else {
      doc.roi_polygons.forEach((poly, idx) => {
        const pp = `$.roi_polygons[${idx}]`
        const points = Array.isArray(poly)
          ? poly
          : isPlainObject(poly) && Array.isArray(poly.points)
            ? poly.points
            : null
        if (!points || points.length < 3) {
          issues.push({
            file,
            path: pp,
            code: "invalid_roi_polygon",
            message: "each ROI polygon must contain at least 3 coordinate points",
          })
          return
        }
        points.forEach((pt, ptIdx) => {
          const validPair =
            (Array.isArray(pt) &&
              pt.length === 2 &&
              typeof pt[0] === "number" &&
              Number.isFinite(pt[0]) &&
              typeof pt[1] === "number" &&
              Number.isFinite(pt[1])) ||
            (isPlainObject(pt) &&
              typeof pt.x === "number" &&
              Number.isFinite(pt.x) &&
              typeof pt.y === "number" &&
              Number.isFinite(pt.y))
          if (!validPair) {
            issues.push({
              file,
              path: `${pp}[${ptIdx}]`,
              code: "invalid_roi_point",
              message: "ROI point must be [x, y] or {x, y} with finite numbers",
            })
          }
        })
      })
    }
  }

  if (doc.crop_policy !== undefined) {
    if (!isPlainObject(doc.crop_policy)) {
      issues.push({
        file,
        path: "$.crop_policy",
        code: "invalid_crop_policy",
        message: "crop_policy must be a JSON object",
      })
    } else {
      const cp = doc.crop_policy
      if (
        cp.padding_ratio !== undefined &&
        (typeof cp.padding_ratio !== "number" ||
          !Number.isFinite(cp.padding_ratio) ||
          cp.padding_ratio < 0 ||
          cp.padding_ratio > 1)
      ) {
        issues.push({
          file,
          path: "$.crop_policy.padding_ratio",
          code: "invalid_crop_policy_value",
          message: "crop_policy.padding_ratio must be in [0, 1]",
        })
      }
      if (
        cp.min_bbox_width_px !== undefined &&
        (typeof cp.min_bbox_width_px !== "number" ||
          !Number.isInteger(cp.min_bbox_width_px) ||
          cp.min_bbox_width_px < 1)
      ) {
        issues.push({
          file,
          path: "$.crop_policy.min_bbox_width_px",
          code: "invalid_crop_policy_value",
          message: "crop_policy.min_bbox_width_px must be an integer >= 1",
        })
      }
      if (
        cp.max_dimension !== undefined &&
        (typeof cp.max_dimension !== "number" ||
          !Number.isInteger(cp.max_dimension) ||
          cp.max_dimension < 1 ||
          cp.max_dimension > 640)
      ) {
        issues.push({
          file,
          path: "$.crop_policy.max_dimension",
          code: "invalid_crop_policy_value",
          message: "crop_policy.max_dimension must be an integer in [1, 640]",
        })
      }
      if (
        cp.max_bytes !== undefined &&
        (typeof cp.max_bytes !== "number" ||
          !Number.isInteger(cp.max_bytes) ||
          cp.max_bytes < 1 ||
          cp.max_bytes > 98304)
      ) {
        issues.push({
          file,
          path: "$.crop_policy.max_bytes",
          code: "invalid_crop_policy_value",
          message: "crop_policy.max_bytes must be an integer in [1, 98304]",
        })
      }
    }
  }

  if (doc.max_jobs_per_minute !== undefined && !isPackParamRef(doc.max_jobs_per_minute)) {
    if (
      typeof doc.max_jobs_per_minute !== "number" ||
      !Number.isInteger(doc.max_jobs_per_minute) ||
      doc.max_jobs_per_minute < 1
    ) {
      issues.push({
        file,
        path: "$.max_jobs_per_minute",
        code: "invalid_max_jobs_per_minute",
        message: "max_jobs_per_minute must be an integer >= 1",
      })
    }
  }

  if (doc.max_frames_per_track !== undefined && !isPackParamRef(doc.max_frames_per_track)) {
    if (
      typeof doc.max_frames_per_track !== "number" ||
      !Number.isInteger(doc.max_frames_per_track) ||
      doc.max_frames_per_track < 1 ||
      doc.max_frames_per_track > 32
    ) {
      issues.push({
        file,
        path: "$.max_frames_per_track",
        code: "invalid_max_frames_per_track",
        message: "max_frames_per_track must be an integer in [1, 32]",
      })
    }
  }

  if (
    doc.live_observation_retention_days !== undefined &&
    !isPackParamRef(doc.live_observation_retention_days)
  ) {
    if (
      typeof doc.live_observation_retention_days !== "number" ||
      !Number.isInteger(doc.live_observation_retention_days) ||
      doc.live_observation_retention_days < 1 ||
      doc.live_observation_retention_days > 3650
    ) {
      issues.push({
        file,
        path: "$.live_observation_retention_days",
        code: "invalid_live_observation_retention_days",
        message: "live_observation_retention_days must be an integer in [1, 3650]",
      })
    }
  }

  const schemaId = doc.signal_schema_id
  if (typeof schemaId !== "string" || schemaId.trim() === "") {
    issues.push({
      file,
      path: "$.signal_schema_id",
      code: "missing_signal_schema_id",
      message: "vantage pipeline requires a non-empty signal_schema_id",
    })
  } else {
    const matchedSchema = declaredSignalSchemaIds.get(schemaId)
    if (!matchedSchema) {
      issues.push({
        file,
        path: "$.signal_schema_id",
        code: "unknown_signal_schema_ref",
        message: `signal_schema_id "${schemaId}" is not declared in manifest.resources.signal_schemas`,
      })
    } else if (
      typeof doc.signal_schema_version === "string" &&
      matchedSchema.version &&
      doc.signal_schema_version !== matchedSchema.version
    ) {
      issues.push({
        file,
        path: "$.signal_schema_version",
        code: "signal_schema_version_mismatch",
        message: `signal_schema_version ${JSON.stringify(doc.signal_schema_version)} does not match declared signal schema version "${matchedSchema.version}"`,
      })
    }
  }

  if (typeof doc.signal_schema_version !== "string" || !SEMVER_REGEX.test(doc.signal_schema_version)) {
    issues.push({
      file,
      path: "$.signal_schema_version",
      code: "invalid_signal_schema_version",
      message: "signal_schema_version must be a valid SemVer string",
    })
  }

  if (typeof doc.display_contract_id !== "string" || doc.display_contract_id.trim() === "") {
    issues.push({
      file,
      path: "$.display_contract_id",
      code: "missing_display_contract_id",
      message: "vantage pipeline requires a non-empty display_contract_id",
    })
  } else if (
    displayContractIds.size > 0 &&
    !displayContractIds.has(doc.display_contract_id)
  ) {
    issues.push({
      file,
      path: "$.display_contract_id",
      code: "unknown_display_contract_ref",
      message: `display_contract_id "${doc.display_contract_id}" does not match any bundled signal_schemas display_file`,
    })
  }

  const usesVlm = runner === "camera_vlm" || fallbackRunner === "camera_vlm"
  if (doc.vlm_config !== undefined && doc.vlm_config !== null) {
    if (!isPlainObject(doc.vlm_config)) {
      issues.push({
        file,
        path: "$.vlm_config",
        code: "invalid_vlm_config",
        message: "vlm_config must be a JSON object",
      })
    } else {
      const vc = doc.vlm_config
      if (
        usesVlm &&
        !isPackParamRef(vc.prompt) &&
        (typeof vc.prompt !== "string" || vc.prompt.trim() === "")
      ) {
        issues.push({
          file,
          path: "$.vlm_config.prompt",
          code: "missing_vlm_prompt",
          message: "vlm_config.prompt is required when runner or fallback_runner is camera_vlm",
        })
      }
      if (vc.max_tokens !== undefined && !isPackParamRef(vc.max_tokens)) {
        if (
          typeof vc.max_tokens !== "number" ||
          !Number.isInteger(vc.max_tokens) ||
          vc.max_tokens < 1 ||
          vc.max_tokens > 4096
        ) {
          issues.push({
            file,
            path: "$.vlm_config.max_tokens",
            code: "invalid_vlm_max_tokens",
            message: "vlm_config.max_tokens must be an integer in [1, 4096]",
          })
        }
      }
      if (vc.temperature !== undefined && !isPackParamRef(vc.temperature)) {
        if (
          typeof vc.temperature !== "number" ||
          !Number.isFinite(vc.temperature) ||
          vc.temperature < 0 ||
          vc.temperature > 2
        ) {
          issues.push({
            file,
            path: "$.vlm_config.temperature",
            code: "invalid_vlm_temperature",
            message: "vlm_config.temperature must be a number in [0, 2]",
          })
        }
      }
    }
  } else if (usesVlm) {
    issues.push({
      file,
      path: "$.vlm_config",
      code: "missing_vlm_config",
      message: "vlm_config is required when runner or fallback_runner is camera_vlm",
    })
  }
}

function validateDashboardPackageEntry(
  files: Map<string, Buffer>,
  rootManifest: Record<string, unknown>,
  meta: {
    slug: string
    dir: string
    manifestFile: string
    rendererFile: string
    index: number
  },
  verifyHashes: boolean,
  issues: PackValidationIssue[],
): void {
  const manifestBuf = files.get(meta.manifestFile)
  if (!manifestBuf) {
    issues.push({
      file: "manifest.json",
      path: `$.resources.dashboard_packages[${meta.index}].manifest_file`,
      code: "missing_dashboard_package_manifest",
      message: `missing bundled dashboard package manifest "${meta.manifestFile}"`,
    })
    return
  }

  if (manifestBuf.length > MAX_DASHBOARD_MANIFEST_BYTES) {
    issues.push({
      file: meta.manifestFile,
      path: "$",
      code: "dashboard_manifest_too_large",
      message: `${meta.manifestFile} size ${manifestBuf.length} exceeds ${MAX_DASHBOARD_MANIFEST_BYTES} bytes`,
    })
  }

  let dm: unknown
  try {
    dm = JSON.parse(manifestBuf.toString("utf8"))
  } catch (err: any) {
    issues.push({
      file: meta.manifestFile,
      path: "$",
      code: "invalid_json",
      message: `invalid JSON in ${meta.manifestFile}: ${err?.message || String(err)}`,
    })
    return
  }
  if (!isPlainObject(dm)) {
    issues.push({
      file: meta.manifestFile,
      path: "$",
      code: "invalid_dashboard_manifest",
      message: `${meta.manifestFile} must be a JSON object`,
    })
    return
  }

  issues.push(...validateSecretFree(dm, meta.manifestFile))

  for (const key of Object.keys(dm)) {
    if (!ALLOWED_DASHBOARD_MANIFEST_KEYS.has(key)) {
      issues.push({
        file: meta.manifestFile,
        path: `$.${key}`,
        code: "unknown_dashboard_manifest_key",
        message: `unsupported key "${key}" in ${meta.manifestFile}`,
      })
    }
  }

  if (typeof dm.id !== "string" || !DASHBOARD_PACKAGE_ID_REGEX.test(dm.id)) {
    issues.push({
      file: meta.manifestFile,
      path: "$.id",
      code: "invalid_dashboard_id",
      message: `${meta.manifestFile} id must match ^[a-z0-9][a-z0-9._-]{1,127}$`,
    })
  }
  if (typeof dm.name !== "string" || dm.name.trim() === "") {
    issues.push({
      file: meta.manifestFile,
      path: "$.name",
      code: "missing_dashboard_name",
      message: `${meta.manifestFile} name must be a non-empty string`,
    })
  }
  if (typeof dm.version !== "string" || !SEMVER_REGEX.test(dm.version)) {
    issues.push({
      file: meta.manifestFile,
      path: "$.version",
      code: "invalid_dashboard_version",
      message: `${meta.manifestFile} version must be a valid SemVer string`,
    })
  }

  if (!Array.isArray(dm.data_frames) || dm.data_frames.length === 0) {
    issues.push({
      file: meta.manifestFile,
      path: "$.data_frames",
      code: "missing_dashboard_data_frames",
      message: `${meta.manifestFile} data_frames must be a non-empty array`,
    })
  } else {
    const seenFrameIds = new Set<string>()
    dm.data_frames.forEach((frame, idx) => {
      const fp = `$.data_frames[${idx}]`
      if (!isPlainObject(frame)) {
        issues.push({
          file: meta.manifestFile,
          path: fp,
          code: "invalid_data_frame",
          message: "data_frame entry must be an object",
        })
        return
      }
      for (const fk of Object.keys(frame)) {
        if (!ALLOWED_DATA_FRAME_KEYS.has(fk)) {
          issues.push({
            file: meta.manifestFile,
            path: `${fp}.${fk}`,
            code: "unknown_data_frame_key",
            message: `unsupported data_frame key "${fk}"`,
          })
        }
      }
      if (typeof frame.id !== "string" || frame.id.trim() === "") {
        issues.push({
          file: meta.manifestFile,
          path: `${fp}.id`,
          code: "missing_data_frame_id",
          message: "data_frame.id must be a non-empty string",
        })
      } else if (seenFrameIds.has(frame.id)) {
        issues.push({
          file: meta.manifestFile,
          path: `${fp}.id`,
          code: "duplicate_data_frame_id",
          message: `duplicate data_frame id "${frame.id}"`,
        })
      } else {
        seenFrameIds.add(frame.id)
      }
      if (typeof frame.query !== "string" || frame.query.trim() === "") {
        issues.push({
          file: meta.manifestFile,
          path: `${fp}.query`,
          code: "missing_data_frame_query",
          message: "data_frame.query must be a non-empty string",
        })
      }
      if (typeof frame.encoding !== "string" || !ALLOWED_DATA_FRAME_ENCODINGS.has(frame.encoding)) {
        issues.push({
          file: meta.manifestFile,
          path: `${fp}.encoding`,
          code: "invalid_data_frame_encoding",
          message: "data_frame.encoding must be json_rows or arrow_ipc",
        })
      }
    })
  }

  if (!Array.isArray(dm.capabilities) || dm.capabilities.length === 0) {
    issues.push({
      file: meta.manifestFile,
      path: "$.capabilities",
      code: "missing_dashboard_capabilities",
      message: `${meta.manifestFile} capabilities must be a non-empty array`,
    })
  } else {
    const seenCaps = new Set<string>()
    dm.capabilities.forEach((cap, idx) => {
      if (typeof cap !== "string" || !ALLOWED_DASHBOARD_CAPABILITIES.has(cap)) {
        issues.push({
          file: meta.manifestFile,
          path: `$.capabilities[${idx}]`,
          code: "invalid_dashboard_capability",
          message: `unsupported dashboard capability ${JSON.stringify(cap)}`,
        })
      } else if (seenCaps.has(cap)) {
        issues.push({
          file: meta.manifestFile,
          path: `$.capabilities[${idx}]`,
          code: "duplicate_dashboard_capability",
          message: `duplicate dashboard capability "${cap}"`,
        })
      } else {
        seenCaps.add(cap)
      }
    })
  }

  if (dm.settings_schema !== undefined && !isPlainObject(dm.settings_schema)) {
    issues.push({
      file: meta.manifestFile,
      path: "$.settings_schema",
      code: "invalid_dashboard_settings_schema",
      message: `${meta.manifestFile} settings_schema must be a JSON object`,
    })
  }

  let declaredSha256: string | null = null
  if (!isPlainObject(dm.renderer)) {
    issues.push({
      file: meta.manifestFile,
      path: "$.renderer",
      code: "missing_dashboard_renderer",
      message: `${meta.manifestFile} renderer must be a JSON object`,
    })
  } else {
    const r = dm.renderer
    for (const rk of Object.keys(r)) {
      if (!ALLOWED_DASHBOARD_RENDERER_KEYS.has(rk)) {
        issues.push({
          file: meta.manifestFile,
          path: `$.renderer.${rk}`,
          code: "unknown_dashboard_renderer_key",
          message: `unsupported renderer key "${rk}" in ${meta.manifestFile}`,
        })
      }
    }
    if (r.kind !== "browser_module") {
      issues.push({
        file: meta.manifestFile,
        path: "$.renderer.kind",
        code: "invalid_dashboard_renderer_kind",
        message: 'dashboard_packages renderer.kind must be "browser_module"',
      })
    }
    if (r.interface_version !== "dashboard-browser-module-v1") {
      issues.push({
        file: meta.manifestFile,
        path: "$.renderer.interface_version",
        code: "invalid_dashboard_interface_version",
        message: 'dashboard_packages renderer.interface_version must be "dashboard-browser-module-v1"',
      })
    }
    if (r.trust !== "trusted") {
      issues.push({
        file: meta.manifestFile,
        path: "$.renderer.trust",
        code: "untrusted_dashboard_renderer",
        message: 'dashboard_packages renderer.trust must be "trusted"',
      })
    }
    if (typeof r.artifact !== "string" || r.artifact !== "renderer.js") {
      issues.push({
        file: meta.manifestFile,
        path: "$.renderer.artifact",
        code: "invalid_dashboard_renderer_artifact",
        message: 'dashboard_packages renderer.artifact must be "renderer.js"',
      })
    }
    if (typeof r.sha256 !== "string" || !SHA256_HEX_REGEX.test(normalizeSha256Hex(r.sha256))) {
      issues.push({
        file: meta.manifestFile,
        path: "$.renderer.sha256",
        code: "invalid_dashboard_renderer_sha256",
        message: "dashboard_packages renderer.sha256 must be a 64-character SHA-256 hex digest",
      })
    } else {
      declaredSha256 = normalizeSha256Hex(r.sha256)
    }
  }

  const rendererBuf = files.get(meta.rendererFile)
  if (!rendererBuf) {
    issues.push({
      file: "manifest.json",
      path: `$.resources.dashboard_packages[${meta.index}].renderer_file`,
      code: "missing_dashboard_renderer_file",
      message: `missing bundled dashboard renderer "${meta.rendererFile}"`,
    })
    return
  }

  if (rendererBuf.length === 0) {
    issues.push({
      file: meta.rendererFile,
      path: "$",
      code: "empty_dashboard_renderer",
      message: `${meta.rendererFile} must not be empty`,
    })
  } else if (rendererBuf.length > MAX_DASHBOARD_RENDERER_BYTES) {
    issues.push({
      file: meta.rendererFile,
      path: "$",
      code: "renderer_too_large",
      message: `${meta.rendererFile} size ${rendererBuf.length} exceeds MAX_RENDERER_BYTES (${MAX_DASHBOARD_RENDERER_BYTES})`,
    })
  }

  issues.push(...scanJsBundleSecrets(rendererBuf.toString("utf8"), meta.rendererFile))

  const actualRendererSha = sha256Hex(rendererBuf)
  if (declaredSha256 && declaredSha256 !== actualRendererSha) {
    issues.push({
      file: meta.manifestFile,
      path: "$.renderer.sha256",
      code: "dashboard_renderer_digest_mismatch",
      message: `${meta.manifestFile} renderer.sha256 (${declaredSha256}) != actual renderer SHA-256 (${actualRendererSha})`,
    })
  }

  if (verifyHashes && isPlainObject(rootManifest.files)) {
    const listedShaRaw = rootManifest.files[meta.rendererFile]
    if (typeof listedShaRaw === "string") {
      const listedSha = normalizeSha256Hex(listedShaRaw)
      if (declaredSha256 && listedSha !== declaredSha256) {
        issues.push({
          file: meta.manifestFile,
          path: "$.renderer.sha256",
          code: "dashboard_renderer_digest_mismatch",
          message: `manifest.files[${JSON.stringify(meta.rendererFile)}] (${listedSha}) != ${meta.manifestFile} renderer.sha256 (${declaredSha256}) != actual renderer SHA-256 (${actualRendererSha})`,
        })
      }
    }
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
  const outcome = validatePackFiles(source.files, {
    verifyHashes: true,
    compressedBytes: source.compressedBytes,
  })

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

  const v2Extra =
    manifest.pack_format_version === 2
      ? `, ${resourceCounts.vantage_pipelines ?? 0} vantage_pipelines, ${resourceCounts.signal_schemas ?? 0} signal_schemas, ${resourceCounts.dashboard_packages ?? 0} dashboard_packages`
      : ""

  console.log(
    `Pack is valid: ${String(manifest.id)}@${String(manifest.version)} (${resourceCounts.checks} checks, ${resourceCounts.rules} rules, ${resourceCounts.dashboards} dashboards${v2Extra}, ${fileCount} files)`,
  )
}
