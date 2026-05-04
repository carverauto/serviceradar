// Centralized package-root + ship-dir paths. Defining them here (rather than
// in each consumer) keeps the `new URL("..", import.meta.url)` walk anchored
// at a single known depth: this file lives at `src/paths.ts` (compiled to
// `dist/paths.js`), so `..` always resolves to the package root.

import {join, resolve} from "node:path"
import {fileURLToPath} from "node:url"

export const CLI_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)))
export const HARNESS_DIR = join(CLI_ROOT, "harness")
export const TEMPLATES_DIR = join(CLI_ROOT, "templates")
export const SCHEMAS_DIR = join(CLI_ROOT, "schemas")
