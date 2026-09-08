// Generic helpers used across the CLI. Kept dependency-free so any module
// can pull from here without creating import cycles.

import {spawn} from "node:child_process"
import {relative, sep} from "node:path"

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function errorStack(error: unknown): string {
  return error instanceof Error && error.stack ? error.stack : errorMessage(error)
}

export function errorCode(error: unknown): string {
  if (!error || typeof error !== "object" || !("code" in error)) return ""
  const code = (error as {code?: unknown}).code
  return typeof code === "string" ? code : ""
}

export function codedError(message: string, code: string): Error & {code: string} {
  const error = new Error(message) as Error & {code: string}
  error.code = code
  return error
}

export function relativePath(from: string, to: string): string {
  if (!from) return to
  return relative(from, to) || "."
}

/**
 * URL-form path relative to projectDir. Always uses forward slashes so
 * derived hrefs (`/project/<path>`) work on Windows too.
 */
export function relativeUrl(projectDir: string, path: string): string {
  return relative(projectDir, path).split(sep).join("/")
}

export function basenameWithoutExt(file: string): string {
  return file.replace(/\.[^.]+$/, "")
}

export async function runCommand(
  command: string,
  cwd: string,
  extraEnv: Record<string, string> = {},
): Promise<void> {
  await new Promise<void>((resolveRun, rejectRun) => {
    const child = spawn(command, {
      cwd,
      env: {...process.env, ...extraEnv},
      shell: true,
      stdio: "inherit",
    })
    child.on("error", rejectRun)
    child.on("exit", (code) => {
      if (code === 0) resolveRun()
      else rejectRun(new Error(`command failed with exit code ${code}: ${command}`))
    })
  })
}

/**
 * Single-line stdin reader for interactive prompts. Resolves with the line
 * (sans trailing newline) once the user hits enter.
 */
export function readLineFromStdin(prompt: string): Promise<string> {
  return new Promise((res, rej) => {
    process.stdout.write(prompt)
    let chunks = ""
    const onData = (chunk: Buffer | string) => {
      chunks += chunk.toString()
      const newline = chunks.indexOf("\n")
      if (newline === -1) return
      process.stdin.removeListener("data", onData)
      process.stdin.pause()
      res(chunks.slice(0, newline).replace(/\r$/, ""))
    }
    process.stdin.on("data", onData)
    process.stdin.on("error", rej)
    process.stdin.resume()
  })
}

export async function openBrowser(url: string): Promise<void> {
  const command = process.platform === "darwin" ? "open"
    : process.platform === "win32" ? "start \"\""
    : "xdg-open"
  try {
    await runCommand(`${command} ${JSON.stringify(url)}`, process.cwd())
  } catch (_) {
    // Best-effort. If the platform doesn't have an opener, the user opens
    // the URL by hand from the printed log line.
  }
}
