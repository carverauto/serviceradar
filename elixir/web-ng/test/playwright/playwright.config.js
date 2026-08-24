import {resolve} from "node:path"

const runfilesRoot = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE)
process.env.PLAYWRIGHT_BROWSERS_PATH = resolve(runfilesRoot, process.env.PLAYWRIGHT_BROWSERS_PATH)

export default {
  testDir: ".",
  testMatch: "god_view_elk_scene.playwright.js",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: "line",
  timeout: 180_000,
  use: {
    headless: true,
  },
}
