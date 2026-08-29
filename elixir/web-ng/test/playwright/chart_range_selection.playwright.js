// Keep the browser test beside the assets importer so strict Bazel node module
// resolution uses that importer's declared @playwright/test package.
import "../../assets/chart_range_selection_acceptance.playwright.js"
