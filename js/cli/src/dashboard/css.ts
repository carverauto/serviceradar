// CSS CSP validation, comment stripping, and transitive export collection
// shared between `dashboard build` and `dashboard dev`. Kept free of external
// npm dependencies so `src/cli.ts` bundles cleanly under Bazel RBE.

import {existsSync} from "node:fs"
import {isAbsolute, relative, resolve} from "node:path"

const FONT_EXT_RE = /\.(?:woff2|woff|ttf|otf|eot)$/i
const EXTERNAL_URL_RE = /^(?:https?:)?\/\//i
const IMPORT_STMT_RE = /(^|[;{}\n\r])\s*@import\s+(?:url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]+))\s*\)|"([^"]*)"|'([^']*)')/gi
const IDENT_RE = /^[A-Za-z_$][A-Za-z0-9_$]*$/

export interface CspCheckOptions {
  mode: "build" | "dev"
  projectDir?: string
}

export interface CollectedExports {
  names: Set<string>
  hasDefault: boolean
}

/**
 * Strips CSS block comments (`/* ... *\/`) while preserving string literals
 * (`'...'`, `"..."`) and backslash escapes inside strings.
 */
export function stripCssComments(css: string): string {
  let out = ""
  let i = 0
  let quote: string | null = null

  while (i < css.length) {
    const ch = css[i]
    if (quote) {
      out += ch
      if (ch === "\\" && i + 1 < css.length) {
        out += css[i + 1]
        i += 2
        continue
      }
      if (ch === quote) quote = null
      i += 1
      continue
    }

    if (ch === "'" || ch === "\"") {
      quote = ch
      out += ch
      i += 1
      continue
    }

    if (ch === "/" && css[i + 1] === "*") {
      const end = css.indexOf("*/", i + 2)
      if (end === -1) break
      // Preserve a space so adjacent tokens cannot merge across stripped comments.
      out += " "
      i = end + 2
      continue
    }

    out += ch
    i += 1
  }

  return out
}

interface UrlOccurrence {
  url: string
  inFontFace: boolean
}

function extractCssUrls(strippedCss: string): UrlOccurrence[] {
  const occurrences: UrlOccurrence[] = []
  const blockStack: boolean[] = []
  let fontFaceDepth = 0
  let pendingAtRule = ""
  let readingAtHeader = false
  let quote: string | null = null
  let i = 0

  while (i < strippedCss.length) {
    const ch = strippedCss[i]

    if (quote) {
      if (ch === "\\" && i + 1 < strippedCss.length) {
        i += 2
        continue
      }
      if (ch === quote) quote = null
      i += 1
      continue
    }

    if (ch === "'" || ch === "\"") {
      if (readingAtHeader) pendingAtRule += ch
      quote = ch
      i += 1
      continue
    }

    if (ch === "@") {
      readingAtHeader = true
      pendingAtRule = "@"
      i += 1
      continue
    }

    if (readingAtHeader) {
      if (ch === "{") {
        const isFontFace = /^@font-face(?:\s|$)/i.test(pendingAtRule.trim())
        blockStack.push(isFontFace)
        if (isFontFace) fontFaceDepth += 1
        readingAtHeader = false
        pendingAtRule = ""
        i += 1
        continue
      }
      if (ch === ";") {
        readingAtHeader = false
        pendingAtRule = ""
        i += 1
        continue
      }
      pendingAtRule += ch
    } else if (ch === "{") {
      blockStack.push(false)
      i += 1
      continue
    } else if (ch === "}") {
      const wasFontFace = blockStack.pop()
      if (wasFontFace) fontFaceDepth = Math.max(0, fontFaceDepth - 1)
      i += 1
      continue
    }

    // Match `url(` when not preceded by an identifier character (e.g. `my-url(`).
    if (
      (ch === "u" || ch === "U")
      && strippedCss.slice(i, i + 4).toLowerCase() === "url("
      && (i === 0 || !/[A-Za-z0-9_-]/.test(strippedCss[i - 1]))
    ) {
      const parsed = readCssUrlArgument(strippedCss, i + 4)
      if (parsed) {
        occurrences.push({
          url: parsed.url,
          inFontFace: fontFaceDepth > 0,
        })
        i = parsed.nextIndex
        continue
      }
    }

    i += 1
  }

  return occurrences
}

function readCssUrlArgument(css: string, start: number): {url: string; nextIndex: number} | null {
  let i = start
  while (i < css.length && /\s/.test(css[i])) i += 1
  if (i >= css.length) return null

  const first = css[i]
  if (first === "'" || first === "\"") {
    const quote = first
    i += 1
    let value = ""
    while (i < css.length) {
      const ch = css[i]
      if (ch === "\\" && i + 1 < css.length) {
        value += css[i + 1]
        i += 2
        continue
      }
      if (ch === quote) {
        i += 1
        break
      }
      value += ch
      i += 1
    }
    while (i < css.length && /\s/.test(css[i])) i += 1
    if (css[i] === ")") i += 1
    return {url: value.trim(), nextIndex: i}
  }

  let value = ""
  while (i < css.length) {
    const ch = css[i]
    if (ch === "\\" && i + 1 < css.length) {
      value += css[i + 1]
      i += 2
      continue
    }
    if (ch === ")") {
      i += 1
      break
    }
    value += ch
    i += 1
  }
  return {url: value.trim(), nextIndex: i}
}

function cleanUrlPath(rawUrl: string): string {
  const hashIndex = rawUrl.indexOf("#")
  const noHash = hashIndex === -1 ? rawUrl : rawUrl.slice(0, hashIndex)
  const queryIndex = noHash.indexOf("?")
  return queryIndex === -1 ? noHash : noHash.slice(0, queryIndex)
}

function isSvgFragmentUrl(rawUrl: string): boolean {
  const hashIndex = rawUrl.indexOf("#")
  if (hashIndex === -1) return false
  return cleanUrlPath(rawUrl).toLowerCase().endsWith(".svg")
}

function isLocalFileInProject(rawUrl: string, projectDir?: string): boolean {
  if (!projectDir) return false
  const clean = cleanUrlPath(rawUrl)
  if (!clean) return false

  let candidate: string | null = null
  if (clean.startsWith("/@fs/")) {
    candidate = decodeURIComponent(clean.slice("/@fs".length))
  } else if (clean.startsWith("/")) {
    candidate = resolve(projectDir, clean.slice(1))
  }

  if (!candidate || !existsSync(candidate)) return false

  // Files served from Vite's `public/` directory are NOT inlined in `build` mode;
  // reject them in `dev` as well so CSP failures surface before `dashboard build`.
  const publicDir = resolve(projectDir, "public")
  const relPublic = relative(publicDir, candidate)
  if (relPublic && !relPublic.startsWith("..") && !isAbsolute(relPublic)) {
    return false
  }
  return true
}

/**
 * Validates that CSS contains only CSP-safe, self-contained references:
 * - Rejects external `http://`, `https://`, and `//` `@import` statements.
 * - Rejects external font URLs, non-inlineable `.svg#...` font references
 *   (such as `@blueprintjs/icons/lib/css/blueprint-icons.css`), and unresolved
 *   or public-dir font URLs.
 * - Permits `data:` URIs and small local inlineable assets.
 */
export function assertCspSafeCss(css: string, sourceId: string, options: CspCheckOptions): void {
  const stripped = stripCssComments(css)

  IMPORT_STMT_RE.lastIndex = 0
  let importMatch: RegExpExecArray | null
  while ((importMatch = IMPORT_STMT_RE.exec(stripped)) !== null) {
    const rawTarget = (
      importMatch[2]
      ?? importMatch[3]
      ?? importMatch[4]
      ?? importMatch[5]
      ?? importMatch[6]
      ?? ""
    ).trim()
    if (EXTERNAL_URL_RE.test(rawTarget)) {
      throw new Error(
        `CSP-unsafe external CSS @import in ${sourceId}: "${rawTarget}"\n` +
          `→ dashboard renderers must be self-contained without external stylesheet requests`,
      )
    }
  }

  for (const {url, inFontFace} of extractCssUrls(stripped)) {
    if (!url || url.startsWith("#")) continue
    if (/^data:/i.test(url)) continue

    const cleanPath = cleanUrlPath(url)
    const isFontExt = FONT_EXT_RE.test(cleanPath)
    const isSvgFrag = isSvgFragmentUrl(url)

    if (EXTERNAL_URL_RE.test(url)) {
      if (inFontFace || isFontExt) {
        throw new Error(
          `CSP-unsafe external font URL in ${sourceId}: "${url}"\n` +
            `→ ServiceRadar CSP forbids external font requests (use data: URIs or modular SVG components)`,
        )
      }
      continue
    }

    if (inFontFace && isSvgFrag) {
      throw new Error(
        `non-inlineable SVG font reference in ${sourceId}: "${url}"\n` +
          `→ import modular SVG components (e.g. from "@blueprintjs/icons") instead of icon-font CSS`,
      )
    }

    if (!inFontFace && !isFontExt) continue

    if (options.mode === "build") {
      throw new Error(
        `non-inlineable font asset in ${sourceId}: "${url}"\n` +
          `→ dashboard CSS must inline all font assets as data: URIs or omit @font-face rules`,
      )
    }

    if (!isLocalFileInProject(url, options.projectDir)) {
      throw new Error(
        `non-inlineable font asset in ${sourceId}: "${url}"\n` +
          `→ font references must resolve to inlineable local assets (not public/ or missing paths)`,
      )
    }
  }
}

/**
 * Checks raw pre-processed CSS for font references that are always non-inlineable
 * (such as `.svg#...` inside `@font-face`), even if a bundler later attempts to
 * rewrite or inline the SVG differently.
 */
export function assertNoSvgFontRefs(css: string, sourceId: string): void {
  const stripped = stripCssComments(css)
  for (const {url, inFontFace} of extractCssUrls(stripped)) {
    if (!url || /^data:/i.test(url)) continue
    if (inFontFace && isSvgFragmentUrl(url)) {
      throw new Error(
        `non-inlineable SVG font reference in ${sourceId}: "${url}"\n` +
          `→ import modular SVG components (e.g. from "@blueprintjs/icons") instead of icon-font CSS`,
      )
    }
  }
}

/**
 * Collects exported binding names from a Rollup module graph (following
 * `export * from ...` chains via `exportedBindings`).
 */
export async function collectTransitiveExportNamesFromRollup(
  ctx: {
    load: (options: {id: string; resolveDependencies?: boolean}) => Promise<any>
    resolve: (source: string, importer?: string, options?: {skipSelf?: boolean}) => Promise<{id: string} | null>
  },
  id: string,
  seen = new Set<string>(),
): Promise<CollectedExports> {
  const names = new Set<string>()
  let hasDefault = false
  if (seen.has(id)) return {names, hasDefault}
  seen.add(id)

  const info = await ctx.load({id, resolveDependencies: true})
  const directExports: string[] = Array.isArray(info?.exports) ? info.exports : []
  for (const exp of directExports) {
    if (exp === "default") {
      hasDefault = true
    } else if (exp !== "*") {
      names.add(exp)
    }
  }

  const exportedBindings: Record<string, string[]> | null | undefined = info?.exportedBindings
  if (exportedBindings && typeof exportedBindings === "object") {
    for (const [source, bindings] of Object.entries(exportedBindings)) {
      if (!source || source === "." || !Array.isArray(bindings)) continue
      if (bindings.includes("*")) {
        const resolved = await ctx.resolve(source, id, {skipSelf: true})
        if (resolved?.id) {
          const nested = await collectTransitiveExportNamesFromRollup(ctx, resolved.id, seen)
          for (const name of nested.names) names.add(name)
          // `export * from "..."` in ESM does not re-export `default`.
        }
      }
    }
  }

  return {names, hasDefault}
}

/**
 * Collects exported binding names from Vite's dev module transform + Rollup AST
 * parser (following `export * from ...` recursively).
 */
export async function collectTransitiveExportNamesFromVite(
  ctx: {
    parse: (code: string) => any
    resolve: (source: string, importer?: string, options?: {skipSelf?: boolean}) => Promise<{id: string} | null>
  },
  viteServer: {transformRequest: (url: string) => Promise<{code?: string} | null> | null} | null | undefined,
  urlOrId: string,
  importer?: string,
  seen = new Set<string>(),
  isRoot = true,
): Promise<CollectedExports> {
  const names = new Set<string>()
  let hasDefault = false
  if (!viteServer || seen.has(urlOrId)) return {names, hasDefault}
  seen.add(urlOrId)

  const transformed = await viteServer.transformRequest(urlOrId)
  if (!transformed?.code) return {names, hasDefault}

  let ast: any
  try {
    ast = ctx.parse(transformed.code)
  } catch {
    return {names, hasDefault}
  }

  for (const node of ast?.body || []) {
    if (node.type === "ExportDefaultDeclaration") {
      if (isRoot) hasDefault = true
      continue
    }

    if (node.type === "ExportNamedDeclaration") {
      if (node.declaration) {
        for (const idName of extractDeclaredIdentifiers(node.declaration)) {
          if (idName === "default") {
            if (isRoot) hasDefault = true
          } else {
            names.add(idName)
          }
        }
      }
      for (const spec of node.specifiers || []) {
        const exportedName = spec.exported?.name ?? spec.exported?.value
        if (exportedName === "default") {
          if (isRoot) hasDefault = true
        } else if (typeof exportedName === "string") {
          names.add(exportedName)
        }
      }
      continue
    }

    if (node.type === "ExportAllDeclaration") {
      if (node.exported) {
        const exportedName = node.exported.name ?? node.exported.value
        if (exportedName === "default") {
          if (isRoot) hasDefault = true
        } else if (typeof exportedName === "string") {
          names.add(exportedName)
        }
        continue
      }
      const sourceValue = node.source?.value
      if (typeof sourceValue === "string" && sourceValue) {
        const resolved = await ctx.resolve(sourceValue, importer || urlOrId, {skipSelf: true})
        if (resolved?.id) {
          const nested = await collectTransitiveExportNamesFromVite(
            ctx,
            viteServer,
            resolved.id,
            resolved.id,
            seen,
            false,
          )
          for (const name of nested.names) names.add(name)
        }
      }
    }
  }

  return {names, hasDefault}
}

function extractDeclaredIdentifiers(decl: any): string[] {
  if (!decl) return []
  if (decl.id?.name) return [decl.id.name]
  if (Array.isArray(decl.declarations)) {
    const ids: string[] = []
    for (const item of decl.declarations) {
      collectBindingNames(item?.id, ids)
    }
    return ids
  }
  return []
}

function collectBindingNames(pattern: any, out: string[]): void {
  if (!pattern) return
  switch (pattern.type) {
    case "Identifier":
      out.push(pattern.name)
      break
    case "ObjectPattern":
      for (const prop of pattern.properties || []) {
        collectBindingNames(prop.type === "RestElement" ? prop.argument : prop.value, out)
      }
      break
    case "ArrayPattern":
      for (const elem of pattern.elements || []) {
        if (elem) collectBindingNames(elem, out)
      }
      break
    case "AssignmentPattern":
      collectBindingNames(pattern.left, out)
      break
    case "RestElement":
      collectBindingNames(pattern.argument, out)
      break
  }
}

/**
 * Generates an ESM proxy module wrapping `mountDashboard` and `default` with
 * the mount-scoped style runtime while forwarding all other exports verbatim.
 */
export function buildEntryProxyCode(
  entrySpecifier: string,
  runtimeSpecifier: string,
  exportsInfo: CollectedExports,
): string {
  const lines: string[] = [
    `import * as __srEntry from ${JSON.stringify(entrySpecifier)};`,
    `import { wrapMount as __srWrapMount } from ${JSON.stringify(runtimeSpecifier)};`,
  ]

  let tempIndex = 0
  for (const name of exportsInfo.names) {
    if (name === "default" || name === "mountDashboard") continue
    if (IDENT_RE.test(name)) {
      lines.push(`export const ${name} = __srEntry.${name};`)
    } else {
      const tmp = `__srExp_${tempIndex++}`
      lines.push(`const ${tmp} = __srEntry[${JSON.stringify(name)}];`)
      lines.push(`export { ${tmp} as ${JSON.stringify(name)} };`)
    }
  }

  if (exportsInfo.names.has("mountDashboard")) {
    lines.push("export const mountDashboard = __srWrapMount(__srEntry.mountDashboard);")
  }
  if (exportsInfo.hasDefault) {
    lines.push("export default __srWrapMount(__srEntry.default);")
  }

  return lines.join("\n") + "\n"
}
