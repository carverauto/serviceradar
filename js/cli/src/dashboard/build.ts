// `dashboard build` — bundle the renderer via Vite (or a custom command),
// stamp the manifest digest, copy sample fixtures into `dist/`. Runs the
// validate path pre-flight so authors see config / manifest / sample-data
// problems before bundling, and refuses to write `dist/` on failure.

import {existsSync, writeFileSync} from "node:fs"
import {copyFile} from "node:fs/promises"
import {join, resolve} from "node:path"

import {loadConfig} from "../config.js"
import {DEFAULT_RENDERER_ENTRY, outputDir, rendererArtifact, sampleTarget} from "../manifest.js"
import {basenameWithoutExt, relativePath, runCommand} from "../utils.js"
import {formatValidationFailures, validateProject} from "../validation.js"
import {manifestCommand} from "./manifest.js"

export async function buildCommand(options: Record<string, any>): Promise<void> {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = options.configObject || await loadConfig(projectDir, options.config)

  const validation = await validateProject(projectDir, config, {skipDigestCheck: true})
  if (validation.failures.length > 0) {
    throw new Error(formatValidationFailures(validation.failures))
  }

  if (config.build?.command) {
    await runCommand(config.build.command, projectDir)
  } else {
    await buildRenderer(projectDir, config, options)
  }

  await manifestCommand({...options, cwd: projectDir, configObject: config})
  await writeSamples(projectDir, config, options)
}

async function buildRenderer(
  projectDir: string,
  config: Record<string, any>,
  options: Record<string, any>,
): Promise<void> {
  const {build} = await import("vite")
  const react = (await import("@vitejs/plugin-react")).default
  const outDir = outputDir(projectDir, config, options)
  const artifact = rendererArtifact(config, options)
  const entry = resolve(projectDir, config.renderer?.entry || config.entry || DEFAULT_RENDERER_ENTRY)

  if (!existsSync(entry)) throw new Error(`renderer entry does not exist: ${entry}`)

  await build({
    root: projectDir,
    configFile: false,
    plugins: [react()],
    define: {
      "process.env.NODE_ENV": JSON.stringify("production"),
      ...(config.vite?.define || {}),
    },
    resolve: {
      alias: {
        react: join(projectDir, "node_modules/react"),
        "react-dom/client": join(projectDir, "node_modules/react-dom/client"),
        ...(config.vite?.resolve?.alias || {}),
      },
      ...(config.vite?.resolve || {}),
    },
    build: {
      outDir,
      emptyOutDir: false,
      sourcemap: Boolean(config.renderer?.sourcemap || config.build?.sourcemap),
      minify: config.renderer?.minify ?? config.build?.minify ?? false,
      lib: {
        entry,
        formats: ["es"],
        fileName: () => artifact,
      },
      rollupOptions: {
        output: {
          entryFileNames: artifact,
          chunkFileNames: basenameWithoutExt(artifact) + "-[hash].js",
          assetFileNames: basenameWithoutExt(artifact) + "-[hash][extname]",
        },
        ...(config.vite?.build?.rollupOptions || {}),
      },
      ...(config.vite?.build || {}),
    },
  })
}

async function writeSamples(
  projectDir: string,
  config: Record<string, any>,
  options: Record<string, any>,
): Promise<void> {
  const outDir = outputDir(projectDir, config, options)
  const context = {
    projectDir,
    outDir,
    env: process.env,
    copyFile: (from: string, to: string) => copyFile(resolve(projectDir, from), resolve(outDir, to)),
    writeJson: (to: string, value: unknown) => writeFileSync(resolve(outDir, to), `${JSON.stringify(value, null, 2)}\n`),
  }

  if (typeof config.afterBuild === "function") {
    await config.afterBuild(context)
    return
  }

  await copySample(projectDir, outDir, config.samples?.frames, "sample-frames.json")
  await copySample(projectDir, outDir, config.samples?.settings, "sample-settings.json")
}

async function copySample(
  projectDir: string,
  outDir: string,
  spec: string | {source?: string; target?: string} | undefined,
  defaultTarget: string,
): Promise<void> {
  if (!spec) return
  const source = typeof spec === "string" ? spec : spec.source
  const target = sampleTarget(spec, defaultTarget)
  if (!source || !existsSync(resolve(projectDir, source))) return
  await copyFile(resolve(projectDir, source), resolve(outDir, target))
  console.log(`Wrote ${relativePath(projectDir, resolve(outDir, target))}`)
}
