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
  // Stay below Bazel's 300-second medium budget while allowing cold RBE
  // Chromium and trace persistence to complete without an inner timeout.
  timeout: 240_000,
  use: {
    headless: true,
  },
}
