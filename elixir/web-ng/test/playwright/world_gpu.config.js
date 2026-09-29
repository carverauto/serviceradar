import base from "./playwright.config.js"

export default {...base, testMatch: "god_view_world_gpu.playwright.js", timeout: 60000}
