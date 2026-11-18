// Vite / Rollup plugins for self-contained dashboard CSS bundling,
// mount-scoped `<style>` lifecycle, CSP safety enforcement, and single-chunk
// output in `dashboard build` and `dashboard dev`.

import {randomUUID} from "node:crypto"
import {existsSync, realpathSync} from "node:fs"
import {resolve} from "node:path"

import {relativeUrl} from "../utils.js"
import {
  assertCspSafeCss,
  assertNoSvgFontRefs,
  buildEntryProxyCode,
  collectTransitiveExportNamesFromRollup,
  collectTransitiveExportNamesFromVite,
} from "./css.js"

const VIRTUAL_ENTRY_ID = "\0serviceradar:entry"
const VIRTUAL_RUNTIME_ID = "\0serviceradar:style-runtime"
const DEV_ENTRY_URL = "/@serviceradar/entry"
const DEV_RUNTIME_URL = "/@serviceradar/style-runtime"

const CSS_LANGS_RE = /\.(?:css|less|sass|scss|styl|stylus|pcss|postcss|sss)(?:$|\?)/i
const EXCLUDED_CSS_QUERY_RE = /[?&](?:raw|url|html-proxy|commonjs-proxy)\b/
const NON_STYLE_INJECTION_QUERY_RE = /[?&](?:inline|raw|url|direct|html-proxy|commonjs-proxy)\b/
const VITE_STYLE_IMPORT_RE =
  /import\s*\{\s*updateStyle\s+as\s+__vite__updateStyle\s*,\s*removeStyle\s+as\s+__vite__removeStyle\s*\}\s*from\s*["']\/@vite\/client["']/

export interface CssBuildPluginOptions {
  projectDir: string
  entry: string
  artifact: string
}

export interface CssDevPluginOptions {
  projectDir: string
  entryPath: string
  getViteServer: () => any
}

export function renderStyleRuntimeCode(options: {bundleNonce?: string} = {}): string {
  const bundleLine = options.bundleNonce
    ? `stylesMap.set("__bundle__", ${JSON.stringify(options.bundleNonce)});\n`
    : ""

  return `const stylesMap = new Map();
const wrappedByFn = new WeakMap();
const activeMountsByRoot = new WeakMap();
const latestTokenByRoot = new WeakMap();
const activeMounts = new Set();

${bundleLine}function hasStyles() {
  for (const css of stylesMap.values()) {
    if (css) return true;
  }
  return false;
}

function combinedCss() {
  const parts = [];
  for (const css of stylesMap.values()) {
    if (css) parts.push(css);
  }
  return parts.join("\\n");
}

function removeNode(node) {
  if (!node) return;
  if (typeof node.remove === "function") {
    node.remove();
    return;
  }
  node.parentNode?.removeChild?.(node);
}

function prependNode(parent, child) {
  if (typeof parent.prepend === "function") {
    parent.prepend(child);
    return;
  }
  if (typeof parent.insertBefore === "function") {
    parent.insertBefore(child, parent.firstChild || null);
    return;
  }
  parent.appendChild?.(child);
}

function syncActiveMount(record) {
  const css = combinedCss();
  if (!css) {
    if (record.styleEl) {
      removeNode(record.styleEl);
      record.styleEl = null;
    }
    return;
  }
  if (!record.styleEl) {
    const doc = record.root?.ownerDocument;
    if (!doc?.createElement) return;
    const el = doc.createElement("style");
    el.setAttribute("data-sr-dashboard-styles", "true");
    prependNode(record.root, el);
    record.styleEl = el;
  }
  record.styleEl.textContent = css;
}

export function registerStyle(id, css) {
  stylesMap.set(id, typeof css === "string" ? css : "");
  for (const record of activeMounts) {
    syncActiveMount(record);
  }
}

export function removeStyle(id) {
  if (!stylesMap.delete(id)) return;
  for (const record of activeMounts) {
    syncActiveMount(record);
  }
}

function clearStaleNodes(root) {
  if (!root?.children) return;
  for (const child of Array.from(root.children)) {
    if (
      child?.hasAttribute?.("data-sr-dashboard-styles")
      || child?.hasAttribute?.("data-sr-dashboard-mount")
    ) {
      removeNode(child);
    }
  }
}

function destroyMounted(mounted) {
  if (typeof mounted === "function") {
    mounted();
  } else {
    mounted?.destroy?.();
  }
}

export function wrapMount(fn) {
  if (typeof fn !== "function") return fn;
  const existing = wrappedByFn.get(fn);
  if (existing) return existing;

  const wrapped = function mountDashboardWithStyles(root, host, api) {
    if (!root || typeof root.ownerDocument?.createElement !== "function") {
      return fn(root, host, api);
    }

    const previous = activeMountsByRoot.get(root);
    if (previous) {
      previous.destroy();
    }
    clearStaleNodes(root);

    const token = Symbol("sr-dashboard-mount");
    latestTokenByRoot.set(root, token);

    const doc = root.ownerDocument;
    const cssActive = hasStyles();
    let styleEl = null;
    let mountNode = null;
    let targetRoot = root;

    if (cssActive) {
      styleEl = doc.createElement("style");
      styleEl.setAttribute("data-sr-dashboard-styles", "true");
      styleEl.textContent = combinedCss();
      root.appendChild(styleEl);

      mountNode = doc.createElement("div");
      mountNode.setAttribute("data-sr-dashboard-mount", "true");
      if (mountNode.style) {
        mountNode.style.cssText = "width:100%;height:100%;min-height:inherit";
      }
      root.appendChild(mountNode);
      targetRoot = mountNode;
    }

    const record = {root, styleEl};
    activeMounts.add(record);

    let settled = false;
    let destroyed = false;

    const cleanupDom = () => {
      activeMounts.delete(record);
      removeNode(mountNode);
      removeNode(record.styleEl);
      record.styleEl = null;
      styleEl = null;
      mountNode = null;
    };

    const finishMount = (mounted) => {
      if (latestTokenByRoot.get(root) !== token) {
        try {
          destroyMounted(mounted);
        } finally {
          cleanupDom();
        }
        return {destroy() {}};
      }

      settled = true;
      const destroy = () => {
        if (destroyed) return;
        destroyed = true;
        if (activeMountsByRoot.get(root) === handle) {
          activeMountsByRoot.delete(root);
        }
        try {
          destroyMounted(mounted);
        } finally {
          cleanupDom();
        }
      };

      const handle = mounted && typeof mounted === "object"
        ? {...mounted, destroy}
        : {destroy};

      activeMountsByRoot.set(root, handle);
      return handle;
    };

    const onError = (error) => {
      if (!settled) cleanupDom();
      throw error;
    };

    try {
      const result = fn(targetRoot, host, api);
      if (result && typeof result.then === "function") {
        return result.then(finishMount, onError);
      }
      return finishMount(result);
    } catch (error) {
      onError(error);
    }
  };

  wrappedByFn.set(fn, wrapped);
  return wrapped;
}
`
}

function isCssModuleTransform(id: string): boolean {
  return CSS_LANGS_RE.test(id) && !EXCLUDED_CSS_QUERY_RE.test(id)
}

function isCssPostRewriteCandidate(id: string): boolean {
  return CSS_LANGS_RE.test(id) && !NON_STYLE_INJECTION_QUERY_RE.test(id)
}

function safeJsStringLiteral(value: string): string {
  return JSON.stringify(value)
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029")
}

export function dashboardCssBuildPlugins(options: CssBuildPluginOptions): any[] {
  const {projectDir, entry, artifact} = options
  const resolvedEntryPath = resolve(entry)
  const entryRealPath = existsSync(resolvedEntryPath) ? realpathSync(resolvedEntryPath) : resolvedEntryPath
  const nonceToken = `__SR_BUNDLE_CSS_${randomUUID().replace(/-/g, "")}__`

  const prePlugin = {
    name: "serviceradar-dashboard-css-pre",
    enforce: "pre" as const,
    async resolveId(this: any, source: string, importer: string | undefined, resolveOpts: any) {
      if (source === VIRTUAL_RUNTIME_ID) return VIRTUAL_RUNTIME_ID
      if (source === VIRTUAL_ENTRY_ID) return VIRTUAL_ENTRY_ID
      if (resolveOpts?.isEntry) {
        const directResolved = resolve(projectDir, source)
        if (directResolved === resolvedEntryPath || directResolved === entryRealPath) {
          return VIRTUAL_ENTRY_ID
        }
        const resolved = await this.resolve(source, importer, {skipSelf: true})
        if (resolved?.id) {
          const clean = resolved.id.split("?")[0]
          if (clean === resolvedEntryPath || clean === entryRealPath) {
            return VIRTUAL_ENTRY_ID
          }
        }
      }
      return null
    },
    async load(this: any, id: string) {
      if (id === VIRTUAL_RUNTIME_ID) {
        return renderStyleRuntimeCode({bundleNonce: nonceToken})
      }
      if (id === VIRTUAL_ENTRY_ID) {
        const resolved = await this.resolve(resolvedEntryPath, undefined, {skipSelf: true})
        const targetId = resolved?.id || resolvedEntryPath
        const exportsInfo = await collectTransitiveExportNamesFromRollup(this, targetId)
        return buildEntryProxyCode(targetId, VIRTUAL_RUNTIME_ID, exportsInfo)
      }
      return null
    },
    transform(code: string, id: string) {
      if (isCssModuleTransform(id)) {
        assertNoSvgFontRefs(code, id)
      }
      return null
    },
  }

  const normalPlugin = {
    name: "serviceradar-dashboard-css-csp",
    transform(code: string, id: string) {
      if (isCssModuleTransform(id)) {
        assertCspSafeCss(code, id, {mode: "build", projectDir})
      }
      return null
    },
  }

  const postPlugin = {
    name: "serviceradar-dashboard-css-inline",
    enforce: "post" as const,
    generateBundle(_outputOptions: any, bundle: Record<string, any>) {
      const cssParts: string[] = []
      const toDelete: string[] = []

      for (const [fileName, entryItem] of Object.entries(bundle)) {
        if (entryItem?.type !== "asset") continue
        if (fileName.endsWith(".css")) {
          const source = typeof entryItem.source === "string"
            ? entryItem.source
            : Buffer.from(entryItem.source).toString("utf8")
          if (source) cssParts.push(source)
          toDelete.push(fileName)
        } else if (fileName.endsWith(".css.map")) {
          toDelete.push(fileName)
        }
      }

      for (const fileName of toDelete) {
        delete bundle[fileName]
      }

      const combinedCss = cssParts.join("\n")
      if (combinedCss) {
        assertCspSafeCss(combinedCss, "bundled.css", {mode: "build", projectDir})
      }

      const chunks: any[] = []
      for (const [fileName, entryItem] of Object.entries(bundle)) {
        if (entryItem?.type === "chunk") {
          chunks.push(entryItem)
          continue
        }
        if (entryItem?.type === "asset" && fileName !== `${artifact}.map`) {
          throw new Error(
            `unexpected sidecar asset "${fileName}" emitted during dashboard build\n` +
              `→ dashboard renderers must be self-contained in ${artifact} (inline small assets or remove external asset references)`,
          )
        }
      }

      if (chunks.length !== 1) {
        throw new Error(
          `dashboard build emitted ${chunks.length} JS chunks instead of 1 single-file ${artifact}\n` +
            `→ keep rollupOptions.output.inlineDynamicImports enabled so modular imports do not split chunks`,
        )
      }

      const entryChunk = chunks[0]
      const tokenRe = new RegExp(`(["'\`])${nonceToken}\\1`, "g")
      let replaced = false
      entryChunk.code = entryChunk.code.replace(tokenRe, () => {
        replaced = true
        return safeJsStringLiteral(combinedCss)
      })

      if (combinedCss && !replaced) {
        throw new Error(
          `internal error: bundled CSS runtime placeholder was not found in ${entryChunk.fileName}`,
        )
      }
    },
  }

  return [prePlugin, normalPlugin, postPlugin]
}

export function dashboardCssDevPlugins(options: CssDevPluginOptions): any[] {
  const {projectDir, entryPath, getViteServer} = options
  const resolvedEntryPath = resolve(entryPath)

  const prePlugin = {
    name: "serviceradar-dashboard-css-dev-pre",
    enforce: "pre" as const,
    resolveId(id: string) {
      const clean = id.split("?")[0]
      if (clean === DEV_ENTRY_URL) return VIRTUAL_ENTRY_ID
      if (clean === DEV_RUNTIME_URL) return VIRTUAL_RUNTIME_ID
      return null
    },
    async load(this: any, id: string) {
      if (id === VIRTUAL_RUNTIME_ID) {
        return renderStyleRuntimeCode({})
      }
      if (id === VIRTUAL_ENTRY_ID) {
        this.addWatchFile(resolvedEntryPath)
        const entryUrl = "/" + relativeUrl(projectDir, resolvedEntryPath)
        const viteServer = getViteServer()
        const exportsInfo = await collectTransitiveExportNamesFromVite(
          this,
          viteServer,
          entryUrl,
          resolvedEntryPath,
        )
        return buildEntryProxyCode(entryUrl, DEV_RUNTIME_URL, exportsInfo)
      }
      return null
    },
    handleHotUpdate({file, server}: {file: string; server: any}) {
      if (resolve(file) === resolvedEntryPath) {
        const mod = server?.moduleGraph?.getModuleById(VIRTUAL_ENTRY_ID)
        if (mod) server.moduleGraph.invalidateModule(mod)
      }
    },
    transform(code: string, id: string) {
      if (isCssModuleTransform(id)) {
        assertNoSvgFontRefs(code, id)
      }
      return null
    },
  }

  const normalPlugin = {
    name: "serviceradar-dashboard-css-dev-csp",
    transform(code: string, id: string) {
      if (isCssModuleTransform(id)) {
        assertCspSafeCss(code, id, {mode: "dev", projectDir})
      }
      return null
    },
  }

  const postPlugin = {
    name: "serviceradar-dashboard-css-dev-post",
    enforce: "post" as const,
    transform(code: string, id: string) {
      if (!isCssPostRewriteCandidate(id)) return null
      if (!VITE_STYLE_IMPORT_RE.test(code)) return null

      // Keep the harness's own mapbox-gl.css import in document.head when no
      // renderer module imports it, so zero-CSS dashboards keep `root` unwrapped
      // in dev just as they do in build.
      if (id.split("?")[0].replace(/\\/g, "/").endsWith("/mapbox-gl/dist/mapbox-gl.css")) {
        const mod = getViteServer()?.moduleGraph?.getModuleById(id)
        const importers = mod ? Array.from(mod.importers as Iterable<any>) : []
        if (importers.length > 0 && importers.every((imp: any) => String(imp?.id || "").startsWith("/@harness/"))) {
          return null
        }
      }

      const rewritten = code.replace(
        VITE_STYLE_IMPORT_RE,
        `import { registerStyle as __vite__updateStyle, removeStyle as __vite__removeStyle } from ${JSON.stringify(DEV_RUNTIME_URL)}`,
      )
      return {code: rewritten, map: null}
    },
  }

  return [prePlugin, normalPlugin, postPlugin]
}

export const DASHBOARD_DEV_ENTRY_URL = DEV_ENTRY_URL
export const DASHBOARD_DEV_RUNTIME_URL = DEV_RUNTIME_URL
