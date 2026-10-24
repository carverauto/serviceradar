import config from "./camera_recording.config.js"

export default {
  ...config,
  testMatch: "camera_codec_capability.playwright.js",
  use: {...config.use, launchOptions: {args: ["--autoplay-policy=no-user-gesture-required"]}},
}
