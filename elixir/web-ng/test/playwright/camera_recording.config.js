import {resolve} from "node:path"

const outputDir = process.env.TEST_UNDECLARED_OUTPUTS_DIR
if (!outputDir) throw new Error("TEST_UNDECLARED_OUTPUTS_DIR is required")

process.env.PLAYWRIGHT_BROWSERS_PATH = resolve(
  process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE, process.env.PLAYWRIGHT_BROWSERS_PATH,
)

export default {
  testDir: ".",
  testMatch: "camera_recording.playwright.js",
  outputDir,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: "line",
  timeout: 30_000,
  use: {browserName: "chromium", headless: true, trace: "retain-on-failure"},
}
