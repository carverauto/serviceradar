import {resolve} from "node:path"

const runfilesRoot = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE)
process.env.PLAYWRIGHT_BROWSERS_PATH = resolve(runfilesRoot, process.env.PLAYWRIGHT_BROWSERS_PATH)
const outputDir = process.env.TEST_UNDECLARED_OUTPUTS_DIR
if (!outputDir) throw new Error("TEST_UNDECLARED_OUTPUTS_DIR is required")

export default {
  testDir: ".",
  testMatch: "god_view_elk_scene.playwright.js",
  outputDir,
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: "line",
  // Bound each independent browser contract inside Bazel's large-test allowance.
  //
  // Six phases of real WebGL rendering, and each managed fit now measures whether its
  // visual density actually holds at the scale the scene fits into rather than assuming
  // it. That costs a label-free probe per candidate density on scenes that must step down.
  // The gate used to put both contracts under one 600-second timer and reached that
  // exact limit under ordinary RBE variance. Two 300-second inner bounds leave another
  // 300 seconds inside Bazel's 900-second outer bound for startup and failure-trace flushes.
  timeout: 300_000,
  use: {
    headless: true,
    trace: "retain-on-failure",
  },
}
