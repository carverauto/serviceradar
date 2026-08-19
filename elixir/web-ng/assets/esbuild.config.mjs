// esbuild entry point for the Bazel build (//elixir/web-ng/assets:js_bundle).
//
// Why a config file rather than rules_js's generated `bin.esbuild`: the npm esbuild
// package's `bin/esbuild` is the platform-native executable (an ELF binary on the Linux
// RBE executors), and rules_js runs a package bin through node, which fails with
// "SyntaxError: Invalid or unexpected token" on the ELF header. Going through the JS API
// is the supported path -- the module locates and spawns that same native binary itself.
//
// Keep the options here in sync with the `build:js:minify` script in package.json, which
// is what a developer runs outside Bazel.
import fs from "node:fs";
import path from "node:path";
import * as esbuild from "esbuild";

const outdir = process.argv[2];

if (!outdir) {
  console.error("usage: esbuild.config.mjs <outdir>");
  process.exit(1);
}

await esbuild.build({
  entryPoints: ["js/app.js", "js/theme_init.js"],
  bundle: true,
  target: "es2022",
  outdir,
  publicPath: "/assets/js",
  // Served by Phoenix from priv/static, so they must not be resolved at bundle time.
  external: ["/fonts/*", "/images/*"],
  alias: {
    "@": ".",
    react: "./node_modules/react",
    "react-dom": "./node_modules/react-dom",
    stream: "stream-browserify",
    // Hex phoenix_live_view is 1.2.9; the npm package is still 1.1.27 and
    // 1.2.9's published npm dep is a GitHub morphdom pin that Bazel cannot
    // fetch. Vendor the self-contained Hex ESM so the client matches the
    // server. Keep this path in sync with the package.json esbuild scripts.
    phoenix_live_view: "./vendor/phoenix_live_view.esm.js",
  },
  // `file` emits a content-hashed copy and rewrites the reference. The hashed names are
  // why the Bazel target declares out_dirs rather than individual outs.
  loader: {
    ".ttf": "file",
    ".woff": "file",
    ".woff2": "file",
    ".wasm": "file",
  },
  minify: true,
});

// IIFE bundles cannot resolve `import.meta.url`, so God View fetches this
// stable path instead of an esbuild file-loader rewrite. Keep the filename
// in sync with WasmAssetController and god_view_exec_runtime.js.
fs.copyFileSync(
  path.join("js", "wasm", "god_view_exec.wasm"),
  path.join(outdir, "god_view_exec.wasm"),
);
