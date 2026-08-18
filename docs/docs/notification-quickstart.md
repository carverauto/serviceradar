---
title: Notifications Quickstart
---

# Notifications Quickstart

This page gets a working page out of ServiceRadar in about fifteen minutes,
then explains the pieces you just created. For the full object model,
suppression reasons, escalation, and the delivery firehose, see
[How Notifications Work](./notifications.md).

You need an **Admin** role. Channel edit and test-send are admin-only.

## How it works

An **alert** is not a page. A page is a **delivery** that a **route** decided
to send to a **channel**.

```
Alert fires (Rule Builder)
        |
        v
   Matching Route          (which alerts, which policy)
        |
        v
 Escalation Policy         (who is told, and in what order)
        |
        v
     Channel               (one configured destination: Discord #ops)
        |
        v
    Delivery Log           (every attempt, including withheld ones)
```

Four objects, always:

| Object | What it is | Example |
| --- | --- | --- |
| **Provider** | A *kind* of destination. Seeded for you. | `discord`, `slack`, `email` |
| **Channel** | One *configured* destination. | `farm-discord` webhook |
| **Escalation policy** | The ladder. One step with your channel is enough. | `page-ops` |
| **Route** | Which alerts use that policy. Empty match = every alert. | `all-alerts` |

Everything lives at **Settings → Notifications** (`/settings/notifications`).

A delivery that is deliberately not sent still writes a Delivery Log row with a
`suppression_reason`. Nothing is dropped silently. That is how you answer
"why was I not paged?"

## Before you start

### 1. Public URL (so pages are clickable)

Notification messages include an **Open in ServiceRadar** link to
`/alerts/<id>`. That link needs the deployment's public origin.

On Helm, set `webNg.publicUrl` to the HTTPS origin operators actually open
(for example `https://demo.serviceradar.cloud`). Recent charts copy that value
to `SERVICERADAR_NOTIFICATION_ACTION_BASE_URL` on `web-ng` and `core`. If
links are missing after a send, check that env on both deployments.

```yaml
webNg:
  publicUrl: "https://serviceradar.example.com"
```

Without a base URL, the page still goes out. It just has no way back into
ServiceRadar.

### 2. Egress (Kubernetes)

Control-plane webhooks leave from the **web-ng** (and sometimes **core**)
pods. If NetworkPolicy is enabled, HTTPS to the destination must be
allowlisted. Kubernetes NetworkPolicy cannot match DNS names, so you pin
CIDRs.

| Destination | Typical cause of `timeout contacting <host>` |
| --- | --- |
| Discord | `discord.com` is Cloudflare. Pin `162.159.128.0/18` (resolved 2026-08-13) and re-resolve if it moves. |
| Slack | Slack / AWS edge IPs. Pin the current `hooks.slack.com` CIDR the same way. |
| Email | Does not use this path. See [Outbound Mail](./outbound-mail.md). |

See [Helm NetworkPolicy](./helm-configuration.md#kubernetes-networkpolicy-recommended).

### 3. You need an alert source

A channel with no route never fires. After the walkthrough, either:

- leave the route match empty so **every** alert pages, or
- write a [stateful alert rule](./rule-builder.md) and match on that rule.

A test-send does **not** create an alert. It only proves the webhook works.

## 15-minute Discord walkthrough

This is the path we recommend first. Slack is the same shape; the only
difference is the webhook URL.

### 1. Create a Discord incoming webhook

In Discord: Server settings → Integrations → Webhooks → New webhook.
Copy the URL. It looks like
`https://discord.com/api/webhooks/<id>/<token>`.

That token lives in the **path**. ServiceRadar stores it as a credential
reference, never as plain channel config.

### 2. Create the channel

1. Open **Settings → Notifications → Channels**.
2. **New channel**.
3. Provider: `discord`.
4. Name it something you will recognize later (`ops-discord`).
5. Leave **execution route** on **Control plane**.
6. Paste the webhook URL into **Webhook URL**.
7. Click **Send test** *before* you leave the editor.

You should see either:

- **The destination accepted the test notification**, or
- a specific refusal (`timeout contacting discord.com`, `host is not allowed`,
  `webhook_url is required`).

A timeout on Kubernetes is almost always NetworkPolicy (step 2 above). A
"host is not allowed" error means the URL is not public HTTPS (loopback and
RFC1918 are refused on purpose).

8. **Save channel**. Confirm it shows **Enabled**.

The test delivery is flagged `is_test`. It never counts toward an alert and
never drives escalation.

### 3. Create a one-step escalation policy

1. Open **Routes and Escalation**.
2. **New policy**. Name it `page-ops`.
3. Add **step 1**:
   - `delay_seconds`: `0` (page immediately)
   - fan-out: your `ops-discord` channel
4. Save.

A single-step policy is a valid "just tell me once" configuration. Add more
steps later if you want a second channel after N seconds of no ack.

### 4. Create a route

1. Still on **Routes and Escalation**, **New route**.
2. Name it `all-alerts`.
3. Bind the `page-ops` policy.
4. Leave the match expression **empty** to match every alert. Narrow it later
   (severity, rule name, partition).
5. Enable the route and save.

Priority matters only when two routes match. Lower number wins.

### 5. Prove a real page

Either wait for an existing alert to fire, or create a narrow
[stateful alert rule](./rule-builder.md) you can trip on purpose.

Then open **Delivery Log**, not Discord, first:

| What you see | Meaning |
| --- | --- |
| `sent` | The destination accepted it. Check Discord. |
| `failed` / `retryable` | Transport error. Read `error_class` and the message. |
| `suppressed` | The platform decided not to send. Read `suppression_reason`. |

A successful Discord embed has an **Open in ServiceRadar** field pointing at
`/alerts/<id>`. If that field is missing, the public URL env is unset.

## Slack

Same four objects. Differences:

1. Create an **Incoming Webhook** in Slack (or use a bot token - the channel
   form shows which fields the `slack` provider expects).
2. Pick provider `slack` instead of `discord`.
3. Test-send before save.
4. Reuse the same escalation policy and route, or add the Slack channel to
   the same step's fan-out so Discord and Slack fire together.

## Email

Email does **not** use a webhook URL. It uses the deployment's single
outbound mailer (the same path as password-reset mail).

1. Configure SMTP under Helm `core.mailer` or **Settings → Mail**. Until a
   relay is configured, an email channel will not validate. See
   [Outbound Mail](./outbound-mail.md).
2. Create a channel on the `email` provider with the destination address.
3. Policy + route as above.

Do not point the mailer at a "test" adapter in production. That adapter
reports success without delivering.

## Connecting a rule

Alerts come from **Settings → Rules → Alerts** (stateful alert rules), plus
a few built-in sources such as the seeded Falco incident rule.

Useful knobs on the rule, not on the notification channel:

| Rule field | Effect on paging |
| --- | --- |
| `group_by` | Which fields keep events inside one incident |
| `cooldown_seconds` | Floor between *new* incidents for the same group |
| `renotify_seconds` | How often a still-open incident pages again |

If you are paged too often, raise `renotify_seconds` on the rule. If you are
paged too rarely, check silences, the route match, and the Delivery Log
suppression reason before touching the channel.

## "Why was I not paged?"

Work the Delivery Log top-down. Common `suppression_reason` values:

| Reason | What to do |
| --- | --- |
| `channel_disabled` | Enable the channel. |
| `route_disabled` / no matching route | Enable the route, or widen the match. |
| `silence` | A silence is covering this alert. Check the Silences tab. |
| `device_out_of_service` | The subject device is marked inactive. |
| `rate_limited` | The channel hit `rate_limit_per_minute`. |
| `duplicate` / cooldown | The rule's cooldown or dedupe swallowed a repeat. |

Retry, failover, and escalation are three different things. The full
explanation is in
[How Notifications Work](./notifications.md#retry-failover-and-escalation-are-three-different-things).

## What not to do

- **Do not** put a Discord or Slack webhook URL in Git, values.yaml, or a
  non-secret ConfigMap. The token is in the URL path.
- **Do not** set `execution_route` to **edge agent** unless the destination
  is only reachable from inside a site network. Discord and Slack should stay
  on the control plane. Discord cannot run on the edge route at all (the
  token is in the URL path and no credential-injection mode rewrites a path).
- **Do not** treat a green test-send as proof that *alerts* will page. You
  still need an enabled route and policy.
- **Do not** debug from the destination first. Debug from the Delivery Log.

## Next

- [How Notifications Work](./notifications.md) - object model, suppression,
  silences, schedules, action links, RBAC.
- [Declarative Providers](./notification-providers.md) - PagerDuty, Teams,
  ntfy, and destinations you describe as YAML.
- [Notification Plugins (Wasm)](./notification-plugin-authoring.md) - signed
  packages for request signing, OAuth, or on-prem destinations.
- [Rule Builder](./rule-builder.md) - the alerts that feed this system.
- [Roles & Permissions](./rbac-and-roles.md) - who can edit channels vs who
  can only read the Delivery Log.
