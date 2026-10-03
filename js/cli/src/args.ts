// Parses CLI argv into a typed-ish options object. Boolean flags listed in
// BOOLEAN_FLAGS are recognized as true on presence (or false for `--no-*`
// aliases); everything else consumes the next argv as its value. Positional
// args land in `options._`.

export const BOOLEAN_FLAGS: Set<string> = new Set([
  "no-build",
  "no-hmr",
  "no-install",
  "no-browser",
  "open",
  "force",
  "yes",
  "json",
  "dry-run",
  // Switches `auth login` from the device-code flow (default) to the
  // PKCE-with-localhost-callback browser flow (RFC 7636 + RFC 8252).
  "web",
  "fire-test",
  "clear-test",
  // `edge site bundle --wait` polls until the site's leaf server is ready.
  "wait",
])

// Single-letter aliases. Only `-o` is recognised: download commands take
// `-o <file>` the way curl and wget do.
const SHORT_FLAGS: Record<string, string> = {
  "-o": "output",
}

export interface ParsedArgs {
  _: string[]
  [key: string]: unknown
}

export function parseArgs(args: string[]): ParsedArgs {
  const options: ParsedArgs = {_: []}
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]
    if (SHORT_FLAGS[arg]) {
      options[SHORT_FLAGS[arg]] = args[index + 1]
      index += 1
      continue
    }
    if (!arg.startsWith("--")) {
      options._.push(arg)
      continue
    }
    const key = arg.slice(2)
    if (BOOLEAN_FLAGS.has(key)) {
      if (key === "no-build") options.build = false
      else if (key === "no-hmr") options.hmr = false
      else if (key === "no-install") options.install = false
      else if (key === "no-browser") options.browser = false
      else options[toCamel(key)] = true
      continue
    }
    options[toCamel(key)] = args[index + 1]
    index += 1
  }
  return options
}

export function toCamel(value: string): string {
  return value.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())
}
