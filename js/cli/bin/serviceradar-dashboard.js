#!/usr/bin/env node
// Transitional alias for the canonical `serviceradar-cli` bin.
// Kept for one minor version so scripts that already invoke
// `serviceradar-dashboard build` (or any prior subcommand) keep working.
// Removal is announced in the changelog and lands in the release after.

import {pathToFileURL} from "node:url"
import {resolve} from "node:path"
import {fileURLToPath} from "node:url"

const here = fileURLToPath(new URL(".", import.meta.url))
const cliPath = resolve(here, "serviceradar-cli.js")

const args = process.argv.slice(2)

// If the first argument is one of the legacy top-level subcommands,
// keep it where it is (the new dispatch still accepts these as a
// backward-compatible alias for `dashboard <subcommand>`). Otherwise
// the user passed a `dashboard` group invocation directly; pass through.
console.warn("[serviceradar-dashboard] deprecated: invoke `serviceradar-cli dashboard <subcommand>` (or `npx serviceradar-cli`) instead. This bin will be removed in the release after next.")

process.argv = [process.argv[0], cliPath, ...args]
await import(pathToFileURL(cliPath).href)
