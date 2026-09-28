// `plugin assignments|secrets|rules|controllers` — JSON admin API wrappers.
import { adminRequest, requireAdminSession } from "../api.js";
const RESOURCES = {
    assignments: {
        name: "plugin assignment",
        collection: "/api/admin/plugin-assignments",
        item: (id) => `/api/admin/plugin-assignments/${encodeURIComponent(id)}`,
    },
    secrets: {
        name: "credential secret",
        collection: "/api/admin/network-credential-secrets",
        item: (id) => `/api/admin/network-credential-secrets/${encodeURIComponent(id)}`,
    },
    rules: {
        name: "credential rule",
        collection: "/api/admin/network-credential-rules",
        item: (id) => `/api/admin/network-credential-rules/${encodeURIComponent(id)}`,
    },
    controllers: {
        name: "Ansible controller",
        collection: "/api/admin/ansible-controllers",
        item: (id) => `/api/admin/ansible-controllers/${encodeURIComponent(id)}`,
    },
};
export async function dispatchPluginConfig(resourceName, options) {
    const resource = RESOURCES[resourceName];
    if (!resource) {
        throw new Error(`unknown plugin config resource: ${resourceName}`);
    }
    const action = String(options._?.[0] || "list");
    const rest = Array.isArray(options._) ? options._.slice(1) : [];
    switch (action) {
        case "list":
            return listCommand(resource, options);
        case "get":
            return getCommand(resource, options, rest);
        case "create":
            return writeCommand(resource, "POST", resource.collection, options, 201);
        case "update":
            return updateCommand(resource, options, rest);
        case "enable":
        case "disable":
            return toggleCommand(resource, action, options, rest);
        case "rotate":
            return rotateCommand(resource, options, rest);
        default:
            throw new Error(`unknown subcommand: plugin ${resourceName} ${action}\n\nRun \`serviceradar-cli help\` for usage.`);
    }
}
async function listCommand(resource, options) {
    const session = await requireAdminSession(options);
    const query = new URLSearchParams();
    for (const key of ["provider", "name", "plugin_id", "agent_uid", "agent_id", "scope_value", "enabled"]) {
        const value = options[camel(key)] ?? options[key];
        if (value !== undefined && value !== "")
            query.set(key, String(value));
    }
    const suffix = query.toString() ? `?${query}` : "";
    const { payload } = await adminRequest(session, "GET", `${resource.collection}${suffix}`);
    printPayload(payload, options);
}
async function getCommand(resource, options, rest) {
    const id = String(options.id || rest[0] || "").trim();
    if (!id)
        throw new Error("--id is required");
    const session = await requireAdminSession(options);
    const { payload } = await adminRequest(session, "GET", resource.item(id));
    printPayload(payload, options);
}
async function writeCommand(resource, method, path, options, expectedStatus) {
    const session = await requireAdminSession(options);
    const body = parseBody(options);
    const { status, payload } = await adminRequest(session, method, path, body);
    if (status !== expectedStatus && status !== 200) {
        throw new Error(`${resource.name} write returned HTTP ${status}`);
    }
    printPayload(payload, options);
}
async function updateCommand(resource, options, rest) {
    const id = String(options.id || rest[0] || "").trim();
    if (!id)
        throw new Error("--id is required");
    await writeCommand(resource, "PATCH", resource.item(id), options, 200);
}
async function toggleCommand(resource, action, options, rest) {
    if (resource.name === "plugin assignment") {
        throw new Error("assignments are enabled with plugin assignments update --body '{\"enabled\":true}'");
    }
    const id = String(options.id || rest[0] || "").trim();
    if (!id)
        throw new Error("--id is required");
    const session = await requireAdminSession(options);
    const { payload } = await adminRequest(session, "POST", `${resource.item(id)}/${action}`);
    printPayload(payload, options);
}
async function rotateCommand(resource, options, rest) {
    if (resource.name !== "credential secret") {
        throw new Error("rotate is only valid for plugin secrets");
    }
    const id = String(options.id || rest[0] || "").trim();
    if (!id)
        throw new Error("--id is required");
    const session = await requireAdminSession(options);
    const body = parseBody(options);
    const { payload } = await adminRequest(session, "POST", `${resource.item(id)}/rotate`, body);
    printPayload(payload, options);
}
function parseBody(options) {
    if (typeof options.body === "string" && options.body.trim() !== "") {
        try {
            return JSON.parse(options.body);
        }
        catch (error) {
            throw new Error(`--body is not valid JSON: ${error.message}`);
        }
    }
    throw new Error("--body '<json>' is required for create/update/rotate");
}
function printPayload(payload, options) {
    if (options.json) {
        console.log(JSON.stringify(payload, null, 2));
        return;
    }
    if (Array.isArray(payload)) {
        for (const item of payload)
            printOne(item);
        if (payload.length === 0)
            console.log("(none)");
        return;
    }
    printOne(payload);
}
function printOne(item) {
    if (!item || typeof item !== "object") {
        console.log(String(item));
        return;
    }
    const id = item.id || item.plugin_id || "";
    const name = item.name || item.plugin_id || item.agent_uid || id;
    const extra = [
        item.provider,
        item.plugin_id,
        item.enabled === undefined ? "" : item.enabled ? "enabled" : "disabled",
    ]
        .filter(Boolean)
        .join(" ");
    console.log(`${name}${id && id !== name ? `  ${id}` : ""}${extra ? `  ${extra}` : ""}`);
}
function camel(value) {
    return value.replace(/_([a-z])/g, (_, letter) => letter.toUpperCase());
}
//# sourceMappingURL=config.js.map