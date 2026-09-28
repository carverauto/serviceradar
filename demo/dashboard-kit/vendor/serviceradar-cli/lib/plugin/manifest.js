// Reads and checks a Wasm plugin project: `plugin.yaml` plus the built
// `plugin.wasm`. Shared by `plugin validate` and `plugin publish` so the two
// agree on what a valid project is — publish runs the same checks rather than a
// looser subset, which is what keeps "validate passed but publish 422'd" from
// happening.
import { existsSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { parse as parseYaml } from "yaml";
export const DEFAULT_MANIFEST_FILE = "plugin.yaml";
export const DEFAULT_WASM_ARTIFACT = "plugin.wasm";
// Mirrors the server's manifest contract exactly -- `ServiceRadar.Plugins.Manifest`
// enforces id/name/version/entrypoint/outputs as strings plus capabilities as a
// non-empty string list and resources as a map (`manifest.ex:300-306`).
// `runtime` is deliberately absent: the resource attribute is nullable and the
// SDK's own tcp-check example ships without it.
const REQUIRED_FIELDS = ["id", "name", "version", "entrypoint", "outputs"];
const PLUGIN_ID_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
export function manifestPath(projectDir, options = {}) {
    return resolve(projectDir, String(options.manifest || DEFAULT_MANIFEST_FILE));
}
export function wasmPath(projectDir, options = {}) {
    return resolve(projectDir, String(options.wasm || DEFAULT_WASM_ARTIFACT));
}
export function loadManifest(projectDir, options = {}) {
    const manifestFile = manifestPath(projectDir, options);
    if (!existsSync(manifestFile)) {
        throw new Error(`${DEFAULT_MANIFEST_FILE} does not exist: ${manifestFile}\n→ run \`serviceradar-cli plugin init <name>\` to scaffold one, or pass --manifest <path>`);
    }
    let raw;
    try {
        raw = parseYaml(readFileSync(manifestFile, "utf8"));
    }
    catch (error) {
        throw new Error(`${manifestFile} is not valid YAML: ${error?.message || error}`);
    }
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
        throw new Error(`${manifestFile} must be a YAML mapping`);
    }
    const record = raw;
    const errors = manifestErrors(record);
    if (errors.length > 0) {
        throw new Error(`${manifestFile} is invalid:\n${errors.map((line) => `  - ${line}`).join("\n")}`);
    }
    return {
        projectDir,
        manifestPath: manifestFile,
        wasmPath: wasmPath(projectDir, options),
        manifest: record,
        raw: record,
    };
}
export function manifestErrors(manifest) {
    const errors = [];
    for (const field of REQUIRED_FIELDS) {
        const value = manifest[field];
        if (typeof value !== "string" || value.trim() === "") {
            errors.push(`${field} is required and must be a non-empty string`);
        }
    }
    const id = manifest.id;
    if (typeof id === "string" && id !== "" && !PLUGIN_ID_PATTERN.test(id)) {
        errors.push(`id "${id}" must be lowercase alphanumeric segments separated by single hyphens`);
    }
    const capabilities = manifest.capabilities;
    if (!Array.isArray(capabilities) || capabilities.length === 0) {
        errors.push("capabilities is required and must be a non-empty list of strings");
    }
    else if (capabilities.some((entry) => typeof entry !== "string")) {
        errors.push("capabilities must contain only strings");
    }
    const resources = manifest.resources;
    if (typeof resources !== "object" || resources === null || Array.isArray(resources)) {
        errors.push("resources is required and must be a mapping");
    }
    const permissions = manifest.permissions;
    if (permissions !== undefined && (typeof permissions !== "object" || permissions === null || Array.isArray(permissions))) {
        errors.push("permissions must be a mapping when present");
    }
    const runtime = manifest.runtime;
    if (runtime !== undefined && (typeof runtime !== "string" || runtime.trim() === "")) {
        errors.push("runtime must be a non-empty string when present");
    }
    return errors;
}
export function readWasm(project) {
    if (!existsSync(project.wasmPath)) {
        throw new Error(`${DEFAULT_WASM_ARTIFACT} does not exist: ${project.wasmPath}\n→ build the plugin first (\`tinygo build -target=wasi -o plugin.wasm ./\` for Go, \`cargo build --target wasm32-wasip1 --release\` for Rust), or pass --wasm <path>`);
    }
    const bytes = readFileSync(project.wasmPath);
    // A wasm binary starts with \0asm. Catching this here turns "the server
    // rejected your upload" into "you uploaded the wrong file", which is the
    // difference between a one-second fix and a support thread.
    if (bytes.length < 4 || bytes[0] !== 0x00 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
        throw new Error(`${project.wasmPath} is not a WebAssembly binary (missing the \\0asm preamble)`);
    }
    return bytes;
}
export function sha256(bytes) {
    return createHash("sha256").update(bytes).digest("hex");
}
//# sourceMappingURL=manifest.js.map