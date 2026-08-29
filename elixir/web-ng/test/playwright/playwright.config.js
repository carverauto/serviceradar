import {resolve} from "node:path"

const runfilesRoot = resolve(process.env.TEST_SRCDIR, process.env.TEST_WORKSPACE)
process.env.PLAYWRIGHT_BROWSERS_PATH = resolve(runfilesRoot, process.env.PLAYWRIGHT_BROWSERS_PATH)

export default {
  testDir: ".",
  testMatch: process.env.PLAYWRIGHT_TEST_MATCH || "god_view_elk_scene.playwright.js",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: "line",
  // Bound the browser work independently of Bazel's large-test allowance while
  // leaving room for cold RBE Chromium startup and the final trace flush.
  //
  // Six phases of real WebGL rendering, and each managed fit now measures whether its
  // visual density actually holds at the scale the scene fits into rather than assuming
  // it. That costs a label-free probe per candidate density on scenes that must step down.
  // Measured ~426s here against the previous 420s bound, which had left ~10% over the
  // then-380s suite. Raised to keep a real margin over run-to-run RBE variance (~20s
  // observed) instead of sitting on the edge, and still well inside the 900s Bazel allows
  // a large test, so Bazel's timeout stays the outer bound.
  timeout: 600_000,
  use: {
    headless: true,
  },
}
