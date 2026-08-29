import {resolve} from "node:path"
import {startVitest} from "vitest/node"

const runfilesRoot = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE)
const filters = process.argv.slice(2).map((filter) => resolve(runfilesRoot, filter))
const context = await startVitest("test", filters, {
  root: process.cwd(),
  run: true,
  watch: false,
})

await context.exit()
