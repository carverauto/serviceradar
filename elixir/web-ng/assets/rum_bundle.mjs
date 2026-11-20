import fs from "node:fs";
import path from "node:path";
import * as esbuild from "esbuild";

const outfile = process.argv[2] || "../priv/static/assets/rum/boomerang-sr.min.js";

const VENDOR_BOOMERANG_FILES = [
  "vendor/boomerang/boomerang.js",
  "vendor/boomerang/plugins/compression.js",
  "vendor/boomerang/plugins/continuity.js",
  "vendor/boomerang/plugins/auto-xhr.js",
  "vendor/boomerang/plugins/spa.js",
  "vendor/boomerang/plugins/history.js",
  "vendor/boomerang/plugins/rt.js",
  "vendor/boomerang/plugins/painttiming.js",
  "vendor/boomerang/plugins/eventtiming.js",
  "vendor/boomerang/plugins/navtiming.js",
  "vendor/boomerang/plugins/restiming.js",
  "vendor/boomerang/plugins/mobile.js",
  "vendor/boomerang/plugins/errors.js",
  "vendor/boomerang/plugins/bfcache.js",
  "vendor/boomerang/plugins/zzz-last-plugin.js",
];

function stripBoomerangDebug(source) {
  return source
    .replace(/\/\*\s*BEGIN_DEBUG\s*\*\/[\s\S]*?\/\*\s*END_DEBUG\s*\*\//g, "")
    .replace(/%boomerang_version%/g, "1.815.1");
}

const vendorBanner = VENDOR_BOOMERANG_FILES.map((relPath) => {
  const raw = fs.readFileSync(relPath, "utf8");
  return `/* ${relPath} */\n${stripBoomerangDebug(raw)}`;
}).join("\n;\n");

const integrationResult = await esbuild.build({
  entryPoints: ["js/rum/boomerang_init.js"],
  bundle: true,
  format: "iife",
  target: "es2020",
  write: false,
  minify: false,
});

const integrationJs = integrationResult.outputFiles[0].text;
const combined = `${vendorBanner}\n;\n${integrationJs}`;

const minified = await esbuild.transform(combined, {
  loader: "js",
  minify: true,
  target: "es2020",
  legalComments: "none",
});

const boomerangLicense = fs.readFileSync("vendor/boomerang/LICENSE", "utf8").trim();
const licenseBanner =
  "/*! ServiceRadar Boomerang RUM Bundle (akamai/boomerang BSD-3-Clause + ServiceRadarTrace)\n\n" +
  `${boomerangLicense}\n*/\n`;

fs.mkdirSync(path.dirname(outfile), { recursive: true });
fs.writeFileSync(outfile, `${licenseBanner}${minified.code}`, "utf8");
