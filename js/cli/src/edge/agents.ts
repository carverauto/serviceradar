// `serviceradar-cli agent list` — the agents enrolled on an instance.
//
// Reads `GET /api/admin/agents` (`{data: [{uid, name, ...}]}`) and falls back
// to the Ash JSON:API `GET /api/v2/agents` (`{data: [{id, attributes}]}`) when
// the admin route is absent, so it works whichever route the server exposes to
// `edge.manage` tokens.

import {edgeHttpError, edgeRequestRaw, parseJson, requireEdgeSession} from "./http.js"
import {printJson, printTable, wantsJson} from "./output.js"

export interface AgentSummary {
  uid: string
  name: string
  gateway_id: string
  status: string
  last_seen: string
  version: string
  partition: string
}

export async function dispatchAgent(subcommand: string, options: Record<string, any>): Promise<void> {
  switch (subcommand) {
    case "list":
      return agentListCommand(options)
    case "help":
    case "--help":
    case "-h":
      printAgentHelp()
      return
    default:
      throw new Error(`unknown subcommand: agent ${subcommand}\n\nRun \`serviceradar-cli agent help\` for usage.`)
  }
}

export function printAgentHelp(): void {
  console.log(`Usage:
  serviceradar-cli agent list --instance <url> [--json]

Lists enrolled agents (uid, name, gateway, status, last seen, version, partition).
Needs a token carrying the edge.manage scope.`)
}

async function agentListCommand(options: Record<string, any>): Promise<void> {
  const session = requireEdgeSession(options)
  const agents = await fetchAgents(session)

  if (wantsJson(options)) {
    printJson(agents)
    return
  }
  printTable(agents, [
    {header: "UID", value: (a) => a.uid},
    {header: "NAME", value: (a) => a.name},
    {header: "GATEWAY", value: (a) => a.gateway_id},
    {header: "STATUS", value: (a) => a.status},
    {header: "LAST SEEN", value: (a) => a.last_seen},
    {header: "VERSION", value: (a) => a.version},
    {header: "PARTITION", value: (a) => a.partition},
  ], "No agents enrolled yet.")
}

async function fetchAgents(session: {instance: string; token: string}): Promise<AgentSummary[]> {
  const adminPath = "/api/admin/agents"
  const admin = await edgeRequestRaw(session, "GET", adminPath, undefined, "application/json")
  if (admin.status >= 200 && admin.status < 300) {
    return listOf(parseJson(admin.body)).map(normalizeAgent)
  }
  if (admin.status !== 404) {
    throw edgeHttpError(session.instance, "GET", adminPath, admin.status, parseJson(admin.body))
  }

  const jsonApiPath = "/api/v2/agents"
  const jsonApi = await edgeRequestRaw(session, "GET", jsonApiPath, undefined, "application/vnd.api+json")
  if (jsonApi.status < 200 || jsonApi.status >= 300) {
    throw edgeHttpError(session.instance, "GET", jsonApiPath, jsonApi.status, parseJson(jsonApi.body))
  }
  return listOf(parseJson(jsonApi.body)).map(normalizeAgent)
}

function listOf(payload: any): any[] {
  if (Array.isArray(payload)) return payload
  if (Array.isArray(payload?.data)) return payload.data
  return []
}

function normalizeAgent(entry: any): AgentSummary {
  // JSON:API rows nest fields under `attributes` with the primary key in `id`.
  const fields = entry?.attributes && typeof entry.attributes === "object"
    ? {...entry.attributes, uid: entry.attributes.uid ?? entry.id}
    : entry || {}
  return {
    uid: str(fields.uid ?? fields.id),
    name: str(fields.name),
    gateway_id: str(fields.gateway_id),
    status: str(fields.status),
    last_seen: str(fields.last_seen ?? fields.last_seen_time),
    version: str(fields.version),
    partition: str(fields.partition ?? fields.partition_id),
  }
}

function str(value: unknown): string {
  return value === null || value === undefined ? "" : String(value)
}
