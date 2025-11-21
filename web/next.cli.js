#!/usr/bin/env node

// Force webpack mode for Bazel runs to avoid Turbopack sandbox issues.
if (!process.env.NEXT_PRIVATE_SKIP_TURBOPACK) {
  process.env.NEXT_PRIVATE_SKIP_TURBOPACK = "1";
}
if (!process.env.TURBOPACK) {
  process.env.TURBOPACK = "0";
}

require('./node_modules/next/dist/bin/next');
