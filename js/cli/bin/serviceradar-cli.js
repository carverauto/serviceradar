#!/usr/bin/env node
// Thin shebang shim. The real CLI implementation lives at `src/cli.js`,
// compiled (allowJs passthrough) into `dist/cli.js` by `npm run build`.
// Importing the compiled file triggers the top-level `main()` invocation.
import "../dist/cli.js"
