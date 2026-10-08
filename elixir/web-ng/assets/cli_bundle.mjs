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
});
