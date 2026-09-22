import assert from "node:assert/strict"
import {test} from "node:test"
import {ensureK8sAlertsCommand} from "../dist/notifications/ensure_k8s_alerts.js"

for (const [flag, endpoint] of [["fireTest", "k8s-node-not-ready-test"], ["clearTest", "k8s-node-ready-test"]]) {
  test(`${flag} sends generic action arguments while preserving resource envelopes`, async (t) => {
    const requests = []
    t.mock.method(globalThis, "fetch", async (url, options) => {
      const path = new URL(url).pathname
      const body = options.body ? JSON.parse(options.body) : undefined
      requests.push({path, method: options.method, body})
      let data = {id: "created"}
      if (options.method === "GET") {
        data = path.endsWith("notification-channels")
          ? [{id: "channel", attributes: {name: "example-discord", enabled: true}}]
          : []
      }
      return new Response(JSON.stringify({data}), {status: 200})
    })
    t.mock.method(console, "log", () => {})

    await ensureK8sAlertsCommand({
      instance: "https://monitor.example.com", token: "synthetic-token",
      channel: "example-discord", cluster: "cluster-example", [flag]: true,
    })

    const probe = requests.find((request) => request.path === `/api/v2/alerts/${endpoint}`)
    assert.deepEqual(probe, {
      path: `/api/v2/alerts/${endpoint}`, method: "POST",
      body: {data: {cluster_id: "cluster-example", node: "node-worker-1.example.com", role: "worker"}},
    })
    const route = requests.find((request) => request.path === "/api/v2/notification-routes" && request.method === "POST")
    assert.equal(route.body.data.type, "notification_route")
    assert.equal(route.body.data.attributes.name, "k8s-node-not-ready")
  })
}
