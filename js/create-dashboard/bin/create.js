#!/usr/bin/env node
// `npm create @serviceradar/dashboard <name>` lands here. We forward straight
// through to the canonical CLI implementation so there is exactly one place
// that knows how to scaffold a project.
//
// npm rewrites `npm create @serviceradar/dashboard <args>` to
// `npx @serviceradar/create-dashboard <args>`, then invokes this `create`
// bin. No explicit subcommand is on argv; we prepend `init` so the user
// experience matches `serviceradar-cli dashboard init <name>`.

import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

let cliPath;
try {
  cliPath = require.resolve("@serviceradar/cli/bin/serviceradar-cli.js");
} catch (err) {
  console.error(
    "create-dashboard: cannot resolve @serviceradar/cli. Is it installed alongside this package?",
  );
  console.error(err?.message || err);
  process.exit(1);
}

process.argv = [process.argv[0], cliPath, "dashboard", "init", ...process.argv.slice(2)];

await import(cliPath);
