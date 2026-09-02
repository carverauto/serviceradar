import {startVitest} from "vitest/node"
import {resolve} from "node:path"

const runfilesRoot = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE)
const filters = process.argv.slice(2).map((filter) => resolve(runfilesRoot, filter))
const context = await startVitest("test", filters, {
  root: process.cwd(),
  run: true,
  server: {
    deps: {
      inline: [/@deck\.gl/, /@luma\.gl/, /wgsl_reflect/],
    },
  },
  watch: false,
}, {
  resolve: {
    alias: {
      wgsl_reflect: resolve(process.cwd(), "node_modules/wgsl_reflect/wgsl_reflect.module.js"),
    },
  },
  ssr: {
    noExternal: [/^(?:@deck\.gl|@luma\.gl|wgsl_reflect)/],
  },
})

await context.exit()
