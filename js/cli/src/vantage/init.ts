// `serviceradar vantage init <name> --template vlm|rust-worker|python-worker [--with-dashboard]`

import {existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync} from "node:fs"
import {basename, join, resolve} from "node:path"
import {collectPackDirectoryFiles, isVantageDevAuthoringPath} from "../pack/archive.js"
import {sha256Hex, writeCanonicalJsonPretty} from "../pack/canonical.js"
import {computePackFileDigests} from "../pack/validate.js"
import {TEMPLATES_DIR} from "../paths.js"
import {relativePath} from "../utils.js"
import {validateVantageProject} from "./validate.js"

const ALLOWED_TEMPLATES = ["vlm", "rust-worker", "python-worker"] as const
type VantageTemplate = (typeof ALLOWED_TEMPLATES)[number]

const REVERSE_DNS_ID_REGEX = /^[a-z0-9]+(?:-[a-z0-9]+)*(?:\.[a-z0-9]+(?:-[a-z0-9]+)*)+$/
const PIPELINE_ID_REGEX = /^[a-z][a-z0-9-]*(?:\.[a-z0-9][a-z0-9._-]*)+$/
const DASHBOARD_SLUG_REGEX = /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/

export async function initCommand(options: Record<string, unknown>): Promise<void> {
  const positional = ((options._ as string[] | undefined) || []).filter(Boolean)
  const targetName = positional[0] || (typeof options.name === "string" ? options.name : "")
  if (!targetName || targetName.trim() === "") {
    throw new Error(
      "vantage init requires a project name: `serviceradar-cli vantage init <name> --template vlm|rust-worker|python-worker`",
    )
  }

  const template = (typeof options.template === "string" ? options.template : "vlm").trim()
  if (!ALLOWED_TEMPLATES.includes(template as VantageTemplate)) {
    throw new Error(
      `unknown vantage template "${template}"\n→ choose one of: ${ALLOWED_TEMPLATES.join(", ")}`,
    )
  }

  const templateDir = join(TEMPLATES_DIR, `vantage-${template}`)
  if (!existsSync(templateDir)) {
    throw new Error(`template "vantage-${template}" is missing in this CLI build at ${templateDir}`)
  }

  const targetDir = resolve(process.cwd(), targetName)
  if (existsSync(targetDir) && !options.force) {
    const entries = readdirSync(targetDir)
    if (entries.length > 0) {
      throw new Error(
        `target directory already exists and is not empty: ${targetDir}\n→ pick another name, remove the directory, or pass --force to overwrite`,
      )
    }
  }

  const packSlug = slugify(basename(targetName))
  const packageId =
    typeof options.packageId === "string" && options.packageId.trim() !== ""
      ? options.packageId.trim()
      : `io.serviceradar.vantage.${packSlug}`

  if (!REVERSE_DNS_ID_REGEX.test(packageId)) {
    throw new Error(
      `invalid --package-id "${packageId}": must be reverse-DNS lowercase alphanumeric (e.g. io.serviceradar.vantage.demo)`,
    )
  }

  const packName = humanizeName(basename(targetName))
  const pipelineSlug = `${packSlug}-pipeline`
  const pipelineId = `${packageId}.pipeline`
  const schemaId = `${packSlug.replace(/-/g, "_")}_signal`
  const capability = `vantage.${packSlug.replace(/-/g, "_")}.v1`
  const crateName = `${packSlug.replace(/-/g, "_")}_worker`
  const dashboardBaseSlug = /^[a-z]/.test(packSlug) ? packSlug : `v-${packSlug}`
  const dashboardSlug = `${dashboardBaseSlug}-console`
  const dashboardPackageId = `${packageId}-console`
  const withDashboard = Boolean(options.withDashboard)

  if (!PIPELINE_ID_REGEX.test(pipelineId)) {
    throw new Error(
      `invalid derived pipeline_id "${pipelineId}": --package-id must start with a lowercase letter (e.g. io.serviceradar.vantage.demo)`,
    )
  }
  if (withDashboard && !DASHBOARD_SLUG_REGEX.test(dashboardSlug)) {
    throw new Error(
      `invalid derived dashboard slug "${dashboardSlug}": must match lowercase kebab-case starting with a letter`,
    )
  }

  const replacements: Record<string, string> = {
    __PACK_ID__: packageId,
    __PACK_SLUG__: packSlug,
    __PACK_NAME__: packName,
    __PIPELINE_ID__: pipelineId,
    __PIPELINE_SLUG__: pipelineSlug,
    __SCHEMA_ID__: schemaId,
    __CAPABILITY__: capability,
    __CRATE_NAME__: crateName,
    __DASHBOARD_SLUG__: dashboardSlug,
    __DASHBOARD_PACKAGE_ID__: dashboardPackageId,
  }

  mkdirSync(targetDir, {recursive: true})
  copyTemplateTree(templateDir, targetDir, replacements)

  if (withDashboard) {
    const dashTemplateDir = join(TEMPLATES_DIR, "vantage-dashboard")
    if (!existsSync(dashTemplateDir)) {
      throw new Error(`dashboard template "vantage-dashboard" is missing at ${dashTemplateDir}`)
    }
    const dashDestDir = join(targetDir, "dashboard_packages", dashboardSlug)
    mkdirSync(dashDestDir, {recursive: true})
    copyTemplateTree(dashTemplateDir, dashDestDir, replacements)

    // Stamp exact SHA-256 of renderer.js into dashboard_packages/<slug>/manifest.json
    const rendererPath = join(dashDestDir, "renderer.js")
    const dashManifestPath = join(dashDestDir, "manifest.json")
    const rendererDigest = sha256Hex(readFileSync(rendererPath))
    const dashManifest = JSON.parse(readFileSync(dashManifestPath, "utf8")) as Record<string, any>
    dashManifest.renderer = {
      ...(dashManifest.renderer || {}),
      sha256: rendererDigest,
    }
    writeFileSync(dashManifestPath, writeCanonicalJsonPretty(dashManifest), "utf8")

    // Register bundled dashboard_packages entry in root manifest.json
    const rootManifestPath = join(targetDir, "manifest.json")
    const rootManifest = JSON.parse(readFileSync(rootManifestPath, "utf8")) as Record<string, any>
    rootManifest.resources = {
      ...(rootManifest.resources || {}),
      dashboard_packages: [
        {
          slug: dashboardSlug,
          dir: `dashboard_packages/${dashboardSlug}`,
          manifest_file: `dashboard_packages/${dashboardSlug}/manifest.json`,
          renderer_file: `dashboard_packages/${dashboardSlug}/renderer.js`,
        },
      ],
    }
    writeFileSync(rootManifestPath, writeCanonicalJsonPretty(rootManifest), "utf8")
  }

  // Stamp root manifest.files SHA-256 digests over all pack runtime files.
  const packFiles = collectPackDirectoryFiles(targetDir, {
    excludePath: isVantageDevAuthoringPath,
  })
  const digests = computePackFileDigests(packFiles)
  const rootManifestPath = join(targetDir, "manifest.json")
  const rootManifest = JSON.parse(readFileSync(rootManifestPath, "utf8")) as Record<string, any>
  rootManifest.files = digests
  writeFileSync(rootManifestPath, writeCanonicalJsonPretty(rootManifest), "utf8")

  // Self-validate scaffolded project before reporting success.
  const validated = validateVantageProject(targetDir)

  if (options.json) {
    console.log(
      JSON.stringify(
        {
          created: true,
          path: validated.resolvedDir,
          template,
          with_dashboard: withDashboard,
          id: packageId,
          slug: packSlug,
          version: validated.manifest.version,
          pipeline_id: pipelineId,
          signal_schema_id: schemaId,
          resource_counts: validated.resourceCounts,
        },
        null,
        2,
      ),
    )
    return
  }

  console.log(`Scaffolding ${targetName} from template "vantage-${template}"…`)
  console.log(`Wrote ${relativePath(process.cwd(), targetDir)}/`)
  console.log("")
  console.log("Next:")
  console.log(`  cd ${targetName}`)
  console.log("  serviceradar-cli vantage validate")
  console.log("  serviceradar-cli vantage dev --fixture fixtures/synthetic_frame.json --json")
  console.log("  serviceradar-cli pack build .")
}

function copyTemplateTree(
  sourceDir: string,
  destDir: string,
  replacements: Record<string, string>,
): void {
  for (const entry of readdirSync(sourceDir, {withFileTypes: true})) {
    const source = join(sourceDir, entry.name)
    const replacedName = applyReplacements(entry.name === "gitignore" ? ".gitignore" : entry.name, replacements)
    const dest = join(destDir, replacedName)

    if (entry.isDirectory()) {
      mkdirSync(dest, {recursive: true})
      copyTemplateTree(source, dest, replacements)
      continue
    }

    if (entry.isFile()) {
      const raw = readFileSync(source)
      if (looksLikeText(entry.name)) {
        writeFileSync(dest, applyReplacements(raw.toString("utf8"), replacements), "utf8")
      } else {
        writeFileSync(dest, raw)
      }
    }
  }
}

function applyReplacements(content: string, replacements: Record<string, string>): string {
  let result = content
  for (const [token, value] of Object.entries(replacements)) {
    result = result.split(token).join(value)
  }
  return result
}

function looksLikeText(name: string): boolean {
  return (
    /\.(py|rs|toml|js|jsx|mjs|json|md|txt|yml|yaml|gitignore)$/.test(name) ||
    name === "gitignore" ||
    name === ".gitignore"
  )
}

function slugify(value: string): string {
  return (
    value
      .toLowerCase()
      .replace(/[^a-z0-9-]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .replace(/-{2,}/g, "-") || "vantage-pack"
  )
}

function humanizeName(value: string): string {
  return (
    value
      .split(/[-_\s]+/)
      .filter(Boolean)
      .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
      .join(" ") || "Vantage Pack"
  )
}
