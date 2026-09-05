// Ensure the demo (or any instance) pages Kubernetes node NotReady through
// the existing notification platform: a route matching
// alert.metadata.incident_rule_name == k8s_node_not_ready, fanned out to an
// existing Discord channel. Does not create a second Discord path and never
// prints tokens.

import {resolveCredentialToken} from "../auth/index.js"
import {normalizeInstanceUrl} from "../auth/credentials.js"
import {formatFetchFailure} from "../tls_ca.js"

const JSON_API = "application/vnd.api+json"
const RULE_NAME = "k8s_node_not_ready"
const ROUTE_NAME = "k8s-node-not-ready"
const POLICY_NAME = "k8s-node-not-ready"
const MATCH = {
  field: "alert.metadata.incident_rule_name",
  equals: RULE_NAME,
}

interface JsonApiResource {
  id: string
  type: string
  attributes?: Record<string, unknown>
}

export async function ensureK8sAlertsCommand(options: Record<string, any>): Promise<void> {
  const instance = normalizeInstanceUrl(options.instance)
  if (!instance) {
    throw new Error("--instance is required (e.g. --instance https://demo.serviceradar.cloud)")
  }
  const credential = resolveCredentialToken(instance, {token: options.token})
  if (!credential) {
    throw new Error(
      `no token resolved for ${instance}\n→ run \`serviceradar-cli auth login --instance ${instance}\` first, or pass --token / set SERVICERADAR_TOKEN`,
    )
  }

  const channelName = String(options.channel || "demo-discord")
  const client = new JsonApiClient(instance, credential.token)

  const channels = await client.list("notification-channels")
  const channel = channels.find((row) => row.attributes?.name === channelName)
  if (!channel) {
    throw new Error(
      `channel ${channelName} not found. Create the Discord channel in ServiceRadar first; this command will not invent a webhook.`,
    )
  }

  const policies = await client.list("notification-escalation-policies")
  let policy = policies.find((row) => row.attributes?.name === POLICY_NAME)
  if (!policy) {
    policy = await client.create("notification-escalation-policies", "notification_escalation_policy", {
      name: POLICY_NAME,
      enabled: true,
      repeat_count: 0,
      resolve_notifies: true,
    })
  }

  const steps = await client.list("notification-escalation-steps")
  let step = steps.find((row) => row.attributes?.policy_id === policy.id && row.attributes?.step_number === 1)
  if (!step) {
    step = await client.create("notification-escalation-steps", "notification_escalation_step", {
      policy_id: policy.id,
      step_number: 1,
      delay_seconds: 0,
      condition: "always",
    })
  }

  await client.create("notification-escalation-step-channels", "notification_escalation_step_channel", {
    step_id: step.id,
    channel_id: channel.id,
  })

  const routes = await client.list("notification-routes")
  for (const route of routes) {
    const expr = route.attributes?.match_expression as {equals?: unknown} | undefined
    if (route.attributes?.name === "test" && expr && "equals" in expr && expr.equals === "") {
      await client.patch(`notification-routes/${route.id}/disable`, "notification_route", route.id, {})
      console.log(`Disabled empty-title route ${route.id}`)
    }
  }

  let route = routes.find((row) => row.attributes?.name === ROUTE_NAME)
  const routeAttrs = {
    name: ROUTE_NAME,
    enabled: true,
    priority: 10,
    continue: false,
    match_expression: MATCH,
    escalation_policy_id: policy.id,
  }
  if (route) {
    route = await client.patch(`notification-routes/${route.id}`, "notification_route", route.id, routeAttrs)
    console.log(`Updated route ${ROUTE_NAME}`)
  } else {
    route = await client.create("notification-routes", "notification_route", routeAttrs)
    console.log(`Created route ${ROUTE_NAME}`)
  }

  if (options.fireTest) {
    const alert = await client.create("alerts", "alert", {
      title: "Kubernetes worker node node-worker-1.example.com is NotReady",
      description: "Operator test-send for k8s_node_not_ready",
      severity: "critical",
      source_type: "system",
      metadata: {incident_rule_name: RULE_NAME},
    })
    console.log(`Fired test alert ${alert.id}`)
  }

  console.log(`✓ ${ROUTE_NAME} routes to ${channelName} on ${instance}`)
}

class JsonApiClient {
  constructor(
    private readonly instance: string,
    private readonly token: string,
  ) {}

  async list(path: string): Promise<JsonApiResource[]> {
    const payload = await this.request("GET", `/api/v2/${path}`)
    const data = payload.data
    if (Array.isArray(data)) return data as JsonApiResource[]
    return []
  }

  async create(path: string, type: string, attributes: Record<string, unknown>): Promise<JsonApiResource> {
    const payload = await this.request("POST", `/api/v2/${path}`, {data: {type, attributes}})
    return payload.data as JsonApiResource
  }

  async patch(path: string, type: string, id: string, attributes: Record<string, unknown>): Promise<JsonApiResource> {
    const payload = await this.request("PATCH", `/api/v2/${path}`, {data: {type, id, attributes}})
    return payload.data as JsonApiResource
  }

  private async request(method: string, path: string, body?: unknown): Promise<{data: unknown}> {
    let response: Response
    try {
      response = await fetch(`${this.instance}${path}`, {
        method,
        headers: {
          authorization: `Bearer ${this.token}`,
          accept: JSON_API,
          "content-type": JSON_API,
        },
        body: body ? JSON.stringify(body) : undefined,
      })
    } catch (error) {
      throw new Error(`${method} ${path} failed: ${formatFetchFailure(error)}`)
    }
    const text = await response.text()
    if (!response.ok) {
      throw new Error(`${method} ${path} -> ${response.status}: ${text.slice(0, 400)}`)
    }
    if (!text) return {data: {}}
    return JSON.parse(text)
  }
}
