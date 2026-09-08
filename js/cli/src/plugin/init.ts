// `plugin init`: scaffold a Wasm plugin project from a template. Templates live
// at `templates/plugin-{go,rust}` in the published tarball and depend on the
// language SDKs -- this is how `serviceradar-sdk-go` and `serviceradar-sdk-rust`
// participate in publishing without either of them growing a CLI of its own.

import {existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync} from "node:fs"
import {join, resolve} from "node:path"

import {TEMPLATES_DIR} from "../paths.js"
import {relativePath} from "../utils.js"

const ALLOWED_TEMPLATES = ["go", "rust"] as const

type Replacements = Record<string, string>

export async function initCommand(options: Record<string, any>): Promise<void> {
  const positional = (options._ || []).filter(Boolean)
  const targetName: string = positional[0] || options.name || "serviceradar-plugin"
  const template: string = options.template || "go"

  if (!ALLOWED_TEMPLATES.includes(template as (typeof ALLOWED_TEMPLATES)[number])) {
    throw new Error(`unknown template: ${template}\n→ choose one of: ${ALLOWED_TEMPLATES.join(", ")}`)
  }

  const templateDir = join(TEMPLATES_DIR, `plugin-${template}`)
  if (!existsSync(templateDir)) {
    throw new Error(`template "plugin-${template}" is missing in this CLI build at ${templateDir}`)
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

  const pluginId: string = options.pluginId || slugify(targetName)
  const replacements: Replacements = {
    __PLUGIN_ID__: pluginId,
    __PLUGIN_NAME__: options.title || humanizeName(targetName),
    __MODULE_NAME__: slugify(targetName),
    __CRATE_NAME__: slugify(targetName).replace(/-/g, "_"),
  }

  console.log(`Scaffolding ${targetName} from template "plugin-${template}"…`)
  mkdirSync(targetDir, {recursive: true})
  copyTemplateTree(templateDir, targetDir, replacements)
  console.log(`Wrote ${relativePath(process.cwd(), targetDir)}/`)

  printNextSteps(targetName, template)
}

function copyTemplateTree(sourceDir: string, destDir: string, replacements: Replacements): void {
  for (const entry of readdirSync(sourceDir, {withFileTypes: true})) {
    const source = join(sourceDir, entry.name)
    // npm refuses to publish a directory containing a literal `.gitignore`, so
    // templates ship it as `gitignore` and it is renamed on the way out. The
    // dashboard templates hit the same thing.
    const destName = entry.name === "gitignore" ? ".gitignore" : entry.name
    const dest = join(destDir, destName)

    if (entry.isDirectory()) {
      mkdirSync(dest, {recursive: true})
      copyTemplateTree(source, dest, replacements)
      continue
    }

    if (entry.isFile()) {
      const raw = readFileSync(source)
      if (looksLikeText(entry.name)) {
        writeFileSync(dest, applyReplacements(raw.toString("utf8"), replacements))
      } else {
        writeFileSync(dest, raw)
      }
    }
  }
}

function applyReplacements(content: string, replacements: Replacements): string {
  let result = content
  for (const [token, value] of Object.entries(replacements)) {
    result = result.split(token).join(value)
  }
  return result
}

function looksLikeText(name: string): boolean {
  return (
    /\.(go|rs|toml|mod|sum|json|md|txt|yml|yaml|gitignore)$/.test(name) ||
    name === "gitignore" ||
    name === ".gitignore"
  )
}

function slugify(value: unknown): string {
  return (
    String(value || "")
      .toLowerCase()
      .replace(/[^a-z0-9-]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .replace(/-{2,}/g, "-") || "serviceradar-plugin"
  )
}

function humanizeName(value: unknown): string {
  return (
    String(value || "")
      .split(/[-_\s]+/)
      .filter(Boolean)
      .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
      .join(" ") || "ServiceRadar Plugin"
  )
}

function printNextSteps(targetName: string, template: string): void {
  const build =
    template === "go"
      ? "tinygo build -target=wasi -no-debug -o plugin.wasm ./"
      : "cargo build --target wasm32-wasip1 --release && cp target/wasm32-wasip1/release/*.wasm plugin.wasm"

  console.log("")
  console.log("Next:")
  console.log(`  cd ${targetName}`)
  console.log(`  ${build}`)
  console.log("  serviceradar-cli plugin validate")
  console.log("  serviceradar-cli auth login --instance https://<your-instance> --scope plugin.publish")
  console.log("  serviceradar-cli plugin publish --instance https://<your-instance>")
  console.log("")
  console.log("The published package is staged; an administrator approves it in")
  console.log("Settings → Agents → Plugins, where the capabilities your manifest")
  console.log("requests are reviewed before anything runs.")
}
