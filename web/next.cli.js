#!/usr/bin/env node

// Force webpack mode for Bazel runs to avoid Turbopack sandbox issues.
const fs = require("fs");
const path = require("path");

// Clear any turbopack toggles that may be set in the environment. Next treats
// a truthy string (even "0") as enabling Turbopack, so leave it unset.
delete process.env.TURBOPACK;
process.env.NEXT_PRIVATE_SKIP_TURBOPACK = process.env.NEXT_PRIVATE_SKIP_TURBOPACK || "1";
process.env.NEXT_SKIP_TURBO = process.env.NEXT_SKIP_TURBO || "1";

// Force webpack unless a turbo flag is explicitly passed through.
const hasTurboFlag = process.argv.some((arg) => arg === "--turbo" || arg === "--turbopack");
const hasWebpackFlag = process.argv.includes("--webpack");
if (!hasTurboFlag && !hasWebpackFlag) {
  const buildIdx = process.argv.indexOf("build");
  const insertAt = buildIdx >= 0 ? buildIdx + 1 : process.argv.length;
  process.argv.splice(insertAt, 0, "--webpack");
}

// Next's sandbox check rejects package.json symlinks pointing outside the
// filesystem root. Materialize package.json into the cwd if it is a symlink.
(() => {
  const pkgPath = path.join(process.cwd(), "package.json");
  try {
    const stat = fs.lstatSync(pkgPath);
    if (stat.isSymbolicLink()) {
      const target = fs.realpathSync(pkgPath);
      if (!target.startsWith(process.cwd())) {
        const contents = fs.readFileSync(target);
        fs.unlinkSync(pkgPath);
        fs.writeFileSync(pkgPath, contents);
      }
    }
  } catch (err) {
    if (err.code !== "ENOENT") {
      throw err;
    }
  }
})();

require('./node_modules/next/dist/bin/next');
