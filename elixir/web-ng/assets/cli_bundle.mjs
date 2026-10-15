// Bundle the real CLI entry point for the hosted plugin-config acceptance lane.
// YAML is a declared, lock-pinned input; dashboard build dependencies are lazy
// imports and are intentionally outside this admin-only runtime.
import {build} from "esbuild";

await build({
  entryPoints: ["../../../js/cli/src/cli.ts"],
  outfile: "plugin_config_cli.mjs",
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node20",
  external: ["vite", "@vitejs/plugin-react", "ajv/*"],
  // yaml's CJS build calls require("process"). esbuild's ESM __require helper
  // uses that binding, which Node ESM does not provide. One createRequire
  // covers every bundled Node builtin require, including process.
  banner: {
    js: `import {createRequire as createBundleRequire} from "node:module";\nconst require = createBundleRequire(import.meta.url);`,
  },
});
