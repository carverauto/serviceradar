// `dashboard init`: scaffold a new dashboard package from a template.
// Copies the chosen template, swizzles project name + identifier, optionally
// runs `npm install`, and prints next steps. Templates live at
// `templates/{react-blank,react-map,react-table}` in the published tarball.

import {existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync} from "node:fs"
import {join, resolve} from "node:path"

import {TEMPLATES_DIR} from "../paths.js"
import {relativePath, runCommand} from "../utils.js"

const ALLOWED_TEMPLATES = ["react-blank", "react-map", "react-table"]

type Replacements = Record<string, string>

export async function initCommand(options: Record<string, any>): Promise<void> {
  const positional = (options._ || []).filter(Boolean)
  const targetName: string = positional[0] || options.name || "serviceradar-dashboard"
  const template: string = options.template || "react-map"
  if (!ALLOWED_TEMPLATES.includes(template)) {
    throw new Error(`unknown template: ${template}\n→ choose one of: ${ALLOWED_TEMPLATES.join(", ")}`)
  }

  const templateDir = join(TEMPLATES_DIR, template)
  if (!existsSync(templateDir)) {
    throw new Error(`template "${template}" is missing in this SDK build at ${templateDir}`)
  }

  const targetDir = resolve(process.cwd(), targetName)
  if (existsSync(targetDir) && !options.force) {
    const entries = readdirSync(targetDir)
    if (entries.length > 0) {
      throw new Error(`target directory already exists and is not empty: ${targetDir}\n→ pick another name, remove the directory, or pass --force to overwrite`)
    }
  }

  const packageId: string = options.packageId || `com.example.${slugify(targetName)}`
  const dashboardTitle: string = options.title || humanizeName(targetName)
  const replacements: Replacements = {
    __PACKAGE_ID__: packageId,
    __PACKAGE_NAME__: slugify(targetName),
    __DASHBOARD_TITLE__: dashboardTitle,
  }

  console.log(`Scaffolding ${targetName} from template "${template}"…`)
  mkdirSync(targetDir, {recursive: true})
  copyTemplateTree(templateDir, targetDir, replacements)
  console.log(`Wrote ${relativePath(process.cwd(), targetDir)}/`)

  if (options.install === false) {
    printNextSteps(targetName, {installed: false, template})
    return
  }

  try {
    console.log("Installing dependencies (npm install)…")
    await runCommand("npm install --no-audit --no-fund", targetDir)
  } catch (error: any) {
    console.warn(`\nDependencies did not install cleanly: ${error?.message || error}`)
    console.warn("→ run `npm install` in the project directory once the issue is resolved.")
    printNextSteps(targetName, {installed: false, template})
    return
  }
  printNextSteps(targetName, {installed: true, template})
}

function copyTemplateTree(sourceDir: string, destDir: string, replacements: Replacements): void {
  const entries = readdirSync(sourceDir, {withFileTypes: true})
  for (const entry of entries) {
    const source = join(sourceDir, entry.name)
    const dest = join(destDir, entry.name)
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
  return /\.(json|mjs|js|jsx|ts|tsx|css|md|html|txt|yml|yaml|gitignore)$/.test(name) || name === ".gitignore"
}

function slugify(value: unknown): string {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-")
    || "dashboard"
}

function humanizeName(value: unknown): string {
  return String(value || "")
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ") || "Dashboard"
}

function printNextSteps(targetName: string, {installed, template}: {installed: boolean; template: string}): void {
  const cd = `cd ${targetName}`
  console.log("")
  console.log("Next:")
  console.log(`  ${cd}`)
  if (!installed) console.log("  npm install")
  console.log("  npm run dev      # SDK harness with HMR")
  console.log("  npm run validate # static check before building")
  console.log("  npm run build    # write dist/ for publish")
  console.log("")
  console.log(`Template: ${template}. Reference docs:`)
  console.log("  https://developer.serviceradar.cloud/docs/v2/dashboard-sdk")
}
