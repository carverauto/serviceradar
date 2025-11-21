#!/usr/bin/env node

// Force webpack mode for Bazel runs to avoid Turbopack sandbox issues.
if (!process.env.NEXT_PRIVATE_SKIP_TURBOPACK) {
  process.env.NEXT_PRIVATE_SKIP_TURBOPACK = "1";
}
if (!process.env.TURBOPACK) {
  process.env.TURBOPACK = "0";
}
if (!process.argv.includes("--turbo") && !process.argv.includes("--no-turbo")) {
  // Insert --no-turbo after the script name (argv[1])
  process.argv.splice(2, 0, "--no-turbo");
}

require('./node_modules/next/dist/bin/next');
