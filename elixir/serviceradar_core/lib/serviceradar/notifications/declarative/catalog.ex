defmodule ServiceRadar.Notifications.Declarative.Catalog do
  @moduledoc """
  The first-party seeded catalog of `:declarative` notification providers
  (tasks 2.4.1, 2.4.1a, 2.4.1b, 2.4.2).

  Design D2 claims that roughly 85% of notification destinations are "POST this
  JSON body to this URL with these headers", and that an operator adds one by
  uploading a document rather than by waiting for a release. This module is that
  claim shipped rather than promised: every entry below is a request-template
  document and nothing else. There is no Elixir module behind any of them, no
  entry in `ServiceRadar.Notifications.Transports.Registry`'s compile-time
  allowlist, and no `implementation_module` on any row. Delete this file and the
  platform loses nine destinations; it does not lose a line of delivery code.

  ## Reconciliation is the seeder's, not a second mechanism

  `ServiceRadar.Notifications.ProviderSeeder` reconciles these rows through the
  same `managed` / `template_version` / `template_fingerprint` path it uses for
  the `:native` catalog, in the same loop, with the same activation rule: a row
  is born `:draft`, is activated once, and is NEVER activated out of `:disabled`.
  So an operator who disables one catalog entry keeps it disabled across every
  future release (task 2.4.1a), and an operator who edits one keeps the edit
  (task 2.4.2), for exactly the reasons those properties hold for `slack`.

  The one difference is which fields the fingerprint covers:
  `ProviderSeeder.managed_fields/1` adds `:definition` for this tier, because
  the definition IS the provider here - a catalog entry whose document was not
  covered would be silently overwritten on upgrade, and a new document would
  never be applied. It is added for this tier only because adding a field to a
  fingerprint's field list changes every digest computed with it, and the
  `:native` rows already carry digests stamped by an earlier release. `definition`
  is structurally NULL on every non-declarative row anyway (the
  `notification_providers_declarative_definition` CHECK constraint says so), so
  its absence from that list loses nothing.

  ## Every entry is validated at COMPILE time

  `Definition.parse/1` runs over each document while this module is being
  compiled, and a document that fails takes the build down with the validator's
  own message. A first-party origin buys no relaxed validation path (the
  `notification-providers` spec is explicit about that), and a catalog entry that
  only fails at boot fails as a `Logger.warning` nobody reads, on the release
  that shipped it. The catalog-existence test (task 2.5.3a) asserts the same
  thing from the other side.

  ## What is in the catalog, and why each shape is what it is

  | Key | Endpoint | Auth | Success |
  | --- | --- | --- | --- |
  | `pagerduty` | `POST {events base}/v2/enqueue` | `routing_key` in the body | 202 |
  | `opsgenie` | `POST {api base}/v2/alerts` | `Authorization: GenieKey ...` | 202 |
  | `mattermost` | `POST <incoming webhook url>` | the URL is the credential | 200 |
  | `rocketchat` | `POST <incoming webhook url>` | the URL is the credential | 200 |
  | `googlechat` | `POST <space webhook url>` | the URL is the credential | 200 |
  | `teams` | `POST <workflow webhook url>` | the URL is the credential | 200, 202 |
  | `telegram` | `POST https://api.telegram.org/bot<token>/sendMessage` | token in the path | 200 |
  | `ntfy` | `POST {base}/` | `Authorization: Bearer ...` | 200 |
  | `gotify` | `POST {base}/message` | `X-Gotify-Key: ...` | 200 |

  PagerDuty Events API v2 is the entry that matters most: it closes the
  "integrate with real on-call rather than reimplement it" story, and it does so
  with a document. Its `dedup_key` is `alert.id`, so the ServiceRadar alert and
  the PagerDuty incident are one to one and repeated occurrences of the same
  alert do not open a second incident.

  ## Four things the document format cannot express, and how each is handled

  These are properties of the format, not oversights, and each shaped a decision
  below. They are worth knowing before authoring a tenth entry.

  **There is no value mapping.** The restricted engine substitutes and filters;
  it does not translate one vocabulary into another. ServiceRadar severities are
  `info | warning | critical | emergency`, and neither PagerDuty
  (`critical | error | warning | info`) nor Opsgenie (`P1`-`P5`) accepts that set
  - `emergency` would be rejected with a 400 on the one alert that mattered
  most. So the destination-side severity is pinned per channel as an enum
  `config` field, and the ServiceRadar severity travels in the summary and in the
  structured details. A channel per severity band is the operator-side answer.

  **A key cannot be omitted conditionally, and an unset `config` field is worse
  than blank.** An UNSET `{{ config.channel }}` does not render `""` - it is a
  gap, and `Transports.Declarative.check_gaps/1` turns any undefaulted
  `config.*` or `secrets.*` gap into a PERMANENT failure with no request sent at
  all, naming the field to edit. Only a field that is present but empty renders
  empty, and an empty string is still not the same as an absent key: Mattermost
  would look for a channel named "" rather than fall back to the webhook's own.

  So an optional destination field is not optional unless it is either dropped
  from the document entirely (letting the destination's own default apply, which
  is what an incoming webhook is for) or given a `default:` filter. Nothing here
  can render an empty required field.

  **A credential cannot be optional.** The same rule applied to an
  `Authorization` header would send the literal `Bearer ` and be rejected as
  malformed auth rather than treated as anonymous. That is why `ntfy` requires an
  access token instead of offering one: a document cannot say "send this header
  only when it has a value".

  ## What was deliberately left out

  `Zulip`, `Jira`, `ServiceNow`, and `Twilio` all authenticate with HTTP Basic,
  which needs `Base.encode64/1` of `user:token` - and `base64` is not one of
  `ServiceRadar.Notifications.Template.Syntax`'s seven filters. A document could
  only get there by asking the operator to paste a pre-encoded blob into a field
  labelled "password", which is a footgun, not a feature. They are wasm_plugin
  tier work, or a `base64` filter, or an `auth` block that reaches
  `Transports.HTTP`'s existing `{:basic, user, password}` support. Jira and
  ServiceNow additionally need per-instance field mapping (project key, issue
  type, Atlassian Document Format) that a fixed body template cannot carry.

  ## Purity

  Pure data. No database, no clock, no network, no process. Every test of it runs
  `async: true`.

  See `openspec/changes/add-notification-platform/design.md` (D2) and the
  `notification-providers` spec, "First-Party Declarative Catalog Ships and Is
  Operator-Disablable".
  """

  alias ServiceRadar.Notifications.Declarative.Definition

  # Bumped when a shipped document changes. `ProviderSeeder` applies a template
  # exactly when the stored version differs from this one, and only to a row whose
  # fingerprint still matches what the previous release wrote.
  # Bumped to "2" when PagerDuty's action links moved from payload.custom_details
  # to the top-level `links` array. A declarative entry's `definition` is a
  # seeder-managed field, so without a bump a deployed row keeps the old document
  # and the fix ships without taking effect. This version is independent of
  # `ProviderSeeder`'s: the two catalogs are reconciled separately, and sharing a
  # constant would reseed one on the other's unrelated change.
  @template_version "3"

  # The retry sets nearly every HTTP destination wants: a request timeout, a rate
  # limit, and a server-side fault are worth repeating; every other non-2xx is a
  # request this provider will keep getting wrong.
  @retryable_status [408, 429, "500-599"]

  @pagerduty %{
    "schema_version" => 1,
    "key" => "pagerduty",
    "display_name" => "PagerDuty",
    "description" =>
      "Trigger a PagerDuty incident through the Events API v2. The alert id is the " <>
        "dedup_key, so repeated occurrences of one ServiceRadar alert update a single " <>
        "PagerDuty incident instead of opening a new one, and resolving the alert " <>
        "resolves that incident.",
    "icon" => "pagerduty",
    "capabilities" => ["send", "test", "rich_payload"],
    "payload_formats" => ["plain"],
    "routes" => ["control_plane"],
    "config_schema" => %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "PagerDuty channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["routing_key"],
      "properties" => %{
        "routing_key" => %{
          "type" => "string",
          "title" => "Integration key",
          "description" =>
            "The Events API v2 integration key of the target PagerDuty service. Stored as a " <>
              "credential reference.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        },
        "severity" => %{
          "type" => "string",
          "title" => "PagerDuty severity",
          "description" =>
            "The severity every event from this channel carries. PagerDuty accepts only " <>
              "critical, error, warning, and info, which is not the ServiceRadar set - " <>
              "emergency has no PagerDuty equivalent and would be rejected - and a request " <>
              "template cannot map one vocabulary onto another. The ServiceRadar severity is " <>
              "in the summary and in custom_details. Use one channel per severity band to " <>
              "route them differently.",
          "enum" => ["critical", "error", "warning", "info"],
          "default" => "critical"
        },
        "api_base_url" => %{
          "type" => "string",
          "title" => "Events API base URL",
          "description" =>
            "Defaults to https://events.pagerduty.com. Set https://events.eu.pagerduty.com " <>
              "for an account in the EU service region.",
          "format" => "uri",
          "maxLength" => 2000
        }
      }
    },
    "request" => %{
      "method" => "POST",
      "url" => "{{ config.api_base_url | default: \"https://events.pagerduty.com\" }}/v2/enqueue",
      "body_format" => "json",
      "body" => %{
        "routing_key" => "{{ secrets.routing_key }}",
        # Derived from the routing lifecycle, NOT hardcoded (task 4.3.3b). With
        # "trigger" here a resolving ServiceRadar alert sent PagerDuty a trigger
        # on the dedup_key of the incident it should have closed, so the incident
        # was updated and stayed open until a human closed it by hand.
        # `default:` is load-bearing, not decoration. An unresolved variable
        # renders as "" and PagerDuty rejects an empty event_action outright, so
        # a context that somehow lacks the delivery namespace would turn a
        # working notification into a 400. Falling back to "trigger" restores
        # exactly the previous behaviour instead.
        "event_action" => "{{ delivery.event_action | default: \"trigger\" }}",
        "dedup_key" => "{{ alert.id }}",
        "client" => "{{ system.name | default: \"ServiceRadar\" }}",
        "payload" => %{
          "summary" =>
            "[{{ alert.severity | upper }}] {{ alert.title | truncate: 900 | default: \"ServiceRadar alert\" }}",
          "source" => "{{ device.hostname | default: \"serviceradar\" }}",
          "severity" => "{{ config.severity | default: \"critical\" }}",
          # `component` is one of the nine UI-code key names, but the validator
          # scopes that denylist to the document's own structure and exempts
          # `request.body`, where keys belong to the DESTINATION's API. PagerDuty
          # groups and dedupes on component, so omitting it degrades incident
          # grouping on the PagerDuty side.
          "component" => "{{ device.hostname | default: \"serviceradar\" }}",
          "group" => "{{ rule.category | default: \"serviceradar\" }}",
          "class" => "{{ alert.alert_class | default: \"alert\" }}",
          "custom_details" => %{
            "alert_id" => "{{ alert.id }}",
            "alert_status" => "{{ alert.status }}",
            "serviceradar_severity" => "{{ alert.severity }}",
            "message" => "{{ alert.message | truncate: 2000 }}",
            "rule" => "{{ rule.name }}",
            "occurrences" => "{{ alert.occurrence_count }}",
            "first_seen_at" => "{{ alert.first_seen_at | iso8601 }}",
            "last_seen_at" => "{{ alert.last_seen_at | iso8601 }}",
            "device" => "{{ device.name }}",
            "device_ip" => "{{ device.ip }}",
            "partition" => "{{ device.partition_id }}",
            "alert_url" => "{{ links.alert }}"
          }
        },
        # Top-level `links`, NOT payload.custom_details. PagerDuty renders
        # custom_details as a flat key/value blob, so an acknowledge URL placed
        # there arrives as inert text an on-call engineer has to select and
        # paste at 03:00. `links` is the field PagerDuty renders as actual
        # clickable links on the incident, which is the entire point of shipping
        # them.
        "links" => [
          %{"href" => "{{ links.alert }}", "text" => "Open in ServiceRadar"},
          %{"href" => "{{ links.acknowledge }}", "text" => "Acknowledge"},
          %{"href" => "{{ links.snooze }}", "text" => "Snooze 1h"},
          %{"href" => "{{ links.resolve }}", "text" => "Resolve"}
        ]
      }
    },
    "success" => %{"status" => [202]},
    "failure" => %{"retryable_status" => @retryable_status, "retry_after_header" => "retry-after"},
    "response" => %{"external_correlation_id" => %{"from" => "body", "path" => "dedup_key"}}
  }

  @opsgenie %{
    "schema_version" => 1,
    "key" => "opsgenie",
    "display_name" => "Opsgenie",
    "description" =>
      "Create an Opsgenie alert through the v2 Alert API. The alert id is the Opsgenie " <>
        "alias, so Opsgenie deduplicates on the same key ServiceRadar does.",
    "icon" => "opsgenie",
    "capabilities" => ["send", "test", "rich_payload"],
    "payload_formats" => ["plain"],
    "routes" => ["control_plane"],
    "config_schema" => %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Opsgenie channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["api_key"],
      "properties" => %{
        "api_key" => %{
          "type" => "string",
          "title" => "API key",
          "description" =>
            "The API key of an Opsgenie API integration. Routing and on-call scheduling " <>
              "belong to the team that owns the integration; this document sends the alert " <>
              "and does not choose responders. Stored as a credential reference.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        },
        "priority" => %{
          "type" => "string",
          "title" => "Opsgenie priority",
          "description" =>
            "The priority every alert from this channel carries. Opsgenie priorities are " <>
              "P1 to P5 and a request template cannot map ServiceRadar severities onto them; " <>
              "the ServiceRadar severity is in the message and in the details. Use one " <>
              "channel per severity band to raise or lower this.",
          "enum" => ["P1", "P2", "P3", "P4", "P5"],
          "default" => "P2"
        },
        "api_base_url" => %{
          "type" => "string",
          "title" => "API base URL",
          "description" =>
            "Defaults to https://api.opsgenie.com. Set https://api.eu.opsgenie.com for an " <>
              "account in the EU region.",
          "format" => "uri",
          "maxLength" => 2000
        }
      }
    },
    "request" => %{
      "method" => "POST",
      "url" => "{{ config.api_base_url | default: \"https://api.opsgenie.com\" }}/v2/alerts",
      "headers" => %{
        "Authorization" => "GenieKey {{ secrets.api_key }}"
      },
      "body_format" => "json",
      # `message` is capped at 130 characters by Opsgenie, and the severity
      # prefix is at most 12 of them.
      "body" => %{
        "message" =>
          "[{{ alert.severity | upper }}] {{ alert.title | truncate: 110 | default: \"ServiceRadar alert\" }}",
        "alias" => "{{ alert.id }}",
        "description" => "{{ alert.message | truncate: 5000 }}",
        "priority" => "{{ config.priority | default: \"P2\" }}",
        "source" => "{{ system.name | default: \"ServiceRadar\" }}",
        "entity" => "{{ device.name | default: \"serviceradar\" }}",
        "tags" => ["serviceradar"],
        "details" => %{
          "alert_id" => "{{ alert.id }}",
          "alert_status" => "{{ alert.status }}",
          "serviceradar_severity" => "{{ alert.severity }}",
          "alert_class" => "{{ alert.alert_class }}",
          "rule" => "{{ rule.name }}",
          "occurrences" => "{{ alert.occurrence_count }}",
          "first_seen_at" => "{{ alert.first_seen_at | iso8601 }}",
          "device_ip" => "{{ device.ip }}",
          "partition" => "{{ device.partition_id }}",
          "alert_url" => "{{ links.alert }}",
          "acknowledge_url" => "{{ links.acknowledge }}",
          "resolve_url" => "{{ links.resolve }}"
        }
      }
    },
    "success" => %{"status" => [202]},
    "failure" => %{"retryable_status" => @retryable_status, "retry_after_header" => "retry-after"},
    "response" => %{"external_correlation_id" => %{"from" => "body", "path" => "requestId"}}
  }

  @mattermost %{
    "schema_version" => 1,
    "key" => "mattermost",
    "display_name" => "Mattermost",
    "description" =>
      "Post an alert into a Mattermost channel through an incoming webhook. The channel " <>
        "is the one the webhook was created for, so no channel name is stored here.",
    "icon" => "mattermost",
    "capabilities" => ["send", "test"],
    "payload_formats" => ["markdown", "plain"],
    "routes" => ["control_plane"],
    "config_schema" => %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Mattermost channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["webhook_url"],
      "properties" => %{
        "webhook_url" => %{
          "type" => "string",
          "title" => "Incoming webhook URL",
          "description" =>
            "Stored as a credential reference: the webhook token is in the URL path and " <>
              "must never be saved as plain configuration.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        },
        "username" => %{
          "type" => "string",
          "title" => "Override username",
          "description" =>
            "The posting identity, when the Mattermost server allows webhooks to override " <>
              "it. Defaults to ServiceRadar.",
          "maxLength" => 200
        }
      }
    },
    "request" => %{
      "method" => "POST",
      "url" => "{{ secrets.webhook_url }}",
      "body_format" => "json",
      "body" => %{
        "username" => "{{ config.username | default: \"ServiceRadar\" }}",
        "text" =>
          "**{{ alert.severity | upper }}: {{ alert.title | default: \"ServiceRadar alert\" }}**\n" <>
            "{{ alert.message | truncate: 3000 }}\n\n" <>
            ~s[Device: {{ device.name | default: "n/a" }} ({{ device.ip | default: "n/a" }})\n] <>
            "Rule: {{ rule.name | default: \"n/a\" }}\n" <>
            "Occurrences: {{ alert.occurrence_count }}\n\n" <>
            "Open: {{ links.alert }}\nAcknowledge: {{ links.acknowledge }}"
      }
    },
    "success" => %{"status" => [200]},
    "failure" => %{"retryable_status" => @retryable_status, "retry_after_header" => "retry-after"}
  }

  @rocketchat %{
    "schema_version" => 1,
    "key" => "rocketchat",
    "display_name" => "Rocket.Chat",
    "description" =>
      "Post an alert into a Rocket.Chat channel through an incoming webhook. The channel " <>
        "is the one the integration was created for.",
    "icon" => "rocketchat",
    "capabilities" => ["send", "test"],
    "payload_formats" => ["markdown", "plain"],
    "routes" => ["control_plane"],
    "config_schema" => %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Rocket.Chat channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["webhook_url"],
      "properties" => %{
        "webhook_url" => %{
          "type" => "string",
          "title" => "Incoming webhook URL",
          "description" =>
            "Stored as a credential reference: the integration token is in the URL path.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        },
        "alias" => %{
          "type" => "string",
          "title" => "Posting alias",
          "description" => "The name the message is posted under. Defaults to ServiceRadar.",
          "maxLength" => 200
        }
      }
    },
    "request" => %{
      "method" => "POST",
      "url" => "{{ secrets.webhook_url }}",
      "body_format" => "json",
      "body" => %{
        "alias" => "{{ config.alias | default: \"ServiceRadar\" }}",
        "text" =>
          "*{{ alert.severity | upper }}: {{ alert.title | default: \"ServiceRadar alert\" }}*\n" <>
            "{{ alert.message | truncate: 3000 }}\n\n" <>
            ~s[Device: {{ device.name | default: "n/a" }} ({{ device.ip | default: "n/a" }})\n] <>
            "Rule: {{ rule.name | default: \"n/a\" }}\n\n" <>
            "Open: {{ links.alert }}\nAcknowledge: {{ links.acknowledge }}"
      }
    },
    "success" => %{"status" => [200]},
    "failure" => %{"retryable_status" => @retryable_status, "retry_after_header" => "retry-after"}
  }

  @googlechat %{
    "schema_version" => 1,
    "key" => "googlechat",
    "display_name" => "Google Chat",
    "description" =>
      "Post an alert into a Google Chat space through an incoming webhook. Google Chat " <>
        "takes *bold* rather than Markdown's double asterisk.",
    "icon" => "googlechat",
    "capabilities" => ["send", "test"],
    "payload_formats" => ["plain"],
    "routes" => ["control_plane"],
    "config_schema" => %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Google Chat channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["webhook_url"],
      "properties" => %{
        "webhook_url" => %{
          "type" => "string",
          "title" => "Space webhook URL",
          "description" =>
            "The full webhook URL Google Chat generates for the space, including its key " <>
              "and token query parameters. Stored as a credential reference.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        }
      }
    },
    "request" => %{
      "method" => "POST",
      "url" => "{{ secrets.webhook_url }}",
      "body_format" => "json",
      "body" => %{
        "text" =>
          "*{{ alert.severity | upper }}: {{ alert.title | default: \"ServiceRadar alert\" }}*\n" <>
            "{{ alert.message | truncate: 2000 }}\n\n" <>
            ~s[Device: {{ device.name | default: "n/a" }} ({{ device.ip | default: "n/a" }})\n] <>
            "Rule: {{ rule.name | default: \"n/a\" }}\n\n" <>
            "Open: {{ links.alert }}\nAcknowledge: {{ links.acknowledge }}"
      }
    },
    "success" => %{"status" => [200]},
    "failure" => %{"retryable_status" => @retryable_status, "retry_after_header" => "retry-after"},
    "response" => %{"external_correlation_id" => %{"from" => "body", "path" => "name"}}
  }

  @teams %{
    "schema_version" => 1,
    "key" => "teams",
    "display_name" => "Microsoft Teams",
    "description" =>
      "Post an Adaptive Card into a Microsoft Teams channel through a Workflows " <>
        "(Power Automate) webhook. The retired Office 365 connector accepted a different " <>
        "payload; this document is for the workflow webhook that replaced it.",
    "icon" => "teams",
    "capabilities" => ["send", "test", "rich_payload"],
    "payload_formats" => ["markdown", "plain"],
    "routes" => ["control_plane"],
    "config_schema" => %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Microsoft Teams channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["webhook_url"],
      "properties" => %{
        "webhook_url" => %{
          "type" => "string",
          "title" => "Workflow webhook URL",
          "description" =>
            "The URL of a Teams workflow using the \"When a Teams webhook request is " <>
              "received\" trigger. Stored as a credential reference: the URL carries its own " <>
              "signature.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        }
      }
    },
    "request" => %{
      "method" => "POST",
      "url" => "{{ secrets.webhook_url }}",
      "body_format" => "json",
      "body" => %{
        "type" => "message",
        "attachments" => [
          %{
            "contentType" => "application/vnd.microsoft.card.adaptive",
            "contentUrl" => nil,
            "content" => %{
              "$schema" => "http://adaptivecards.io/schemas/adaptive-card.json",
              "type" => "AdaptiveCard",
              "version" => "1.4",
              "body" => [
                %{
                  "type" => "TextBlock",
                  "size" => "Medium",
                  "weight" => "Bolder",
                  "wrap" => true,
                  "text" =>
                    "{{ alert.severity | upper }}: {{ alert.title | default: \"ServiceRadar alert\" }}"
                },
                %{
                  "type" => "TextBlock",
                  "wrap" => true,
                  "text" => "{{ alert.message | truncate: 2000 }}"
                },
                %{
                  "type" => "FactSet",
                  "facts" => [
                    %{"title" => "Device", "value" => "{{ device.name | default: \"n/a\" }}"},
                    %{"title" => "Address", "value" => "{{ device.ip | default: \"n/a\" }}"},
                    %{"title" => "Rule", "value" => "{{ rule.name | default: \"n/a\" }}"},
                    %{"title" => "Status", "value" => "{{ alert.status }}"},
                    %{"title" => "Occurrences", "value" => "{{ alert.occurrence_count }}"},
                    %{"title" => "First seen", "value" => "{{ alert.first_seen_at | iso8601 }}"}
                  ]
                },
                %{
                  "type" => "TextBlock",
                  "wrap" => true,
                  "text" =>
                    "[Open in ServiceRadar]({{ links.alert }}) | [Acknowledge]({{ links.acknowledge }})"
                }
              ]
            }
          }
        ]
      }
    },
    "success" => %{"status" => [200, 202]},
    "failure" => %{"retryable_status" => @retryable_status, "retry_after_header" => "retry-after"}
  }

  @telegram %{
    "schema_version" => 1,
    "key" => "telegram",
    "display_name" => "Telegram",
    "description" =>
      "Send an alert to a Telegram chat, group, or channel through the Bot API. The " <>
        "message is sent as plain text: Telegram's Markdown parser rejects a message whose " <>
        "punctuation it cannot parse, which an alert title would eventually contain.",
    "icon" => "telegram",
    "capabilities" => ["send", "test"],
    "payload_formats" => ["plain"],
    "routes" => ["control_plane"],
    "config_schema" => %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Telegram channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["bot_token", "chat_id"],
      "properties" => %{
        "bot_token" => %{
          "type" => "string",
          "title" => "Bot token",
          "description" =>
            "The token BotFather issued for the bot. Stored as a credential reference: it " <>
              "goes in the request path.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        },
        "chat_id" => %{
          "type" => "string",
          "title" => "Chat id",
          "description" =>
            "The numeric chat id, or an @channelusername for a public channel. A group id " <>
              "is negative, for example -1001234567890.",
          "minLength" => 1,
          "maxLength" => 200
        }
      }
    },
    "request" => %{
      "method" => "POST",
      "url" => "https://api.telegram.org/bot{{ secrets.bot_token }}/sendMessage",
      "body_format" => "json",
      "body" => %{
        "chat_id" => "{{ config.chat_id }}",
        "disable_web_page_preview" => true,
        "text" =>
          "{{ alert.severity | upper }}: {{ alert.title | default: \"ServiceRadar alert\" }}\n" <>
            "{{ alert.message | truncate: 2000 }}\n\n" <>
            ~s[Device: {{ device.name | default: "n/a" }} ({{ device.ip | default: "n/a" }})\n] <>
            "Rule: {{ rule.name | default: \"n/a\" }}\n\n" <>
            "Open: {{ links.alert }}\nAcknowledge: {{ links.acknowledge }}"
      }
    },
    "success" => %{"status" => [200]},
    "failure" => %{"retryable_status" => @retryable_status, "retry_after_header" => "retry-after"},
    "response" => %{
      "external_correlation_id" => %{"from" => "body", "path" => "result.message_id"}
    }
  }

  @ntfy %{
    "schema_version" => 1,
    "key" => "ntfy",
    "display_name" => "ntfy",
    "description" =>
      "Publish an alert to an ntfy topic. An access token is required rather than " <>
        "optional: a request template cannot omit an Authorization header when the value " <>
        "is missing, and an empty one is rejected as malformed rather than treated as " <>
        "anonymous.",
    "icon" => "ntfy",
    "capabilities" => ["send", "test"],
    "payload_formats" => ["markdown", "plain"],
    "routes" => ["control_plane"],
    "config_schema" => %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "ntfy channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["topic", "access_token"],
      "properties" => %{
        "topic" => %{
          "type" => "string",
          "title" => "Topic",
          "description" =>
            "The topic to publish to. Treat it as a secret on a public server: anyone who " <>
              "knows a topic name can subscribe to it.",
          "minLength" => 1,
          "maxLength" => 200
        },
        "access_token" => %{
          "type" => "string",
          "title" => "Access token",
          "description" =>
            "An ntfy access token (Account -> Access tokens on ntfy.sh, or a token issued " <>
              "by a self-hosted server). Stored as a credential reference.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        },
        "base_url" => %{
          "type" => "string",
          "title" => "Server URL",
          "description" => "Defaults to https://ntfy.sh. Set the URL of a self-hosted server.",
          "format" => "uri",
          "maxLength" => 2000,
          "default" => "https://ntfy.sh"
        }
      }
    },
    "request" => %{
      "method" => "POST",
      # Publishing as JSON posts to the server root; the topic is a body field.
      "url" => "{{ config.base_url | default: \"https://ntfy.sh\" }}/",
      "headers" => %{
        "Authorization" => "Bearer {{ secrets.access_token }}"
      },
      "body_format" => "json",
      "body" => %{
        "topic" => "{{ config.topic }}",
        "title" =>
          "{{ alert.severity | upper }}: {{ alert.title | truncate: 200 | default: \"ServiceRadar alert\" }}",
        "tags" => ["serviceradar"],
        "message" =>
          "{{ alert.message | truncate: 2000 }}\n\n" <>
            ~s[Device: {{ device.name | default: "n/a" }} ({{ device.ip | default: "n/a" }})\n] <>
            "Rule: {{ rule.name | default: \"n/a\" }}\n\n" <>
            "Open: {{ links.alert }}\nAcknowledge: {{ links.acknowledge }}"
      }
    },
    "success" => %{"status" => [200]},
    "failure" => %{"retryable_status" => @retryable_status, "retry_after_header" => "retry-after"},
    "response" => %{"external_correlation_id" => %{"from" => "body", "path" => "id"}}
  }

  @gotify %{
    "schema_version" => 1,
    "key" => "gotify",
    "display_name" => "Gotify",
    "description" =>
      "Send an alert to a self-hosted Gotify server as an application message. Priority " <>
        "is fixed at 5, which is what makes an Android client alert rather than sit " <>
        "silently in the tray.",
    "icon" => "gotify",
    "capabilities" => ["send", "test"],
    "payload_formats" => ["plain"],
    "routes" => ["control_plane"],
    "config_schema" => %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "title" => "Gotify channel configuration",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["base_url", "app_token"],
      "properties" => %{
        "base_url" => %{
          "type" => "string",
          "title" => "Server URL",
          "description" =>
            "The Gotify server, for example https://gotify.example.com. It must pass the " <>
              "outbound URL policy: HTTPS, and a host that resolves to a public address.",
          "format" => "uri",
          "maxLength" => 2000
        },
        "app_token" => %{
          "type" => "string",
          "title" => "Application token",
          "description" =>
            "The token of the Gotify application messages are posted as (not a client " <>
              "token). Stored as a credential reference.",
          "secretRef" => true,
          "credentialKind" => "api_token"
        }
      }
    },
    "request" => %{
      "method" => "POST",
      "url" => "{{ config.base_url }}/message",
      "headers" => %{
        "X-Gotify-Key" => "{{ secrets.app_token }}"
      },
      "body_format" => "json",
      "body" => %{
        "priority" => 5,
        "title" =>
          "{{ alert.severity | upper }}: {{ alert.title | truncate: 200 | default: \"ServiceRadar alert\" }}",
        "message" =>
          "{{ alert.message | truncate: 2000 }}\n\n" <>
            ~s[Device: {{ device.name | default: "n/a" }} ({{ device.ip | default: "n/a" }})\n] <>
            "Rule: {{ rule.name | default: \"n/a\" }}\n\n" <>
            "Open: {{ links.alert }}\nAcknowledge: {{ links.acknowledge }}"
      }
    },
    "success" => %{"status" => [200]},
    "failure" => %{"retryable_status" => @retryable_status, "retry_after_header" => "retry-after"},
    "response" => %{"external_correlation_id" => %{"from" => "body", "path" => "id"}}
  }

  @documents [
    @pagerduty,
    @opsgenie,
    @mattermost,
    @rocketchat,
    @googlechat,
    @teams,
    @telegram,
    @ntfy,
    @gotify
  ]

  # Compile-time validation. A malformed catalog entry fails the BUILD with the
  # validator's own message, rather than being skipped at boot by a warning
  # nobody reads. Same reasoning as `ProviderSeeder`'s transport-module map.
  @definitions (for document <- @documents do
                  case Definition.parse(document) do
                    {:ok, definition} ->
                      definition

                    {:error, errors} ->
                      raise ArgumentError,
                            "seeded declarative catalog entry " <>
                              inspect(Map.get(document, "key")) <>
                              " is not a valid provider definition: " <>
                              Definition.describe_errors(errors)
                  end
                end)

  @keys Enum.map(@definitions, & &1.key)

  if length(Enum.uniq(@keys)) != length(@keys) do
    raise ArgumentError,
          "the seeded declarative catalog declares a duplicate key: #{inspect(@keys)}"
  end

  @provider_attrs (for definition <- @definitions do
                     %{
                       provider_key: definition.key,
                       provider_type: :declarative,
                       display_name: definition.display_name,
                       description: definition.description,
                       icon: definition.icon,
                       implementation_module: nil,
                       capabilities: Enum.sort(definition.capabilities),
                       supported_routes: definition.routes,
                       payload_formats: definition.payload_formats,
                       config_schema: definition.config_schema,
                       definition: Definition.to_map(definition),
                       source: :first_party,
                       default_max_attempts: 3,
                       definition_version: 1,
                       managed: true,
                       template_version: @template_version
                     }
                   end)

  @doc """
  The catalog as parsed definitions.

  Every entry is already known to be valid: parsing happened while this module
  was compiled.
  """
  @spec definitions() :: [Definition.t()]
  def definitions, do: @definitions

  @doc """
  The catalog as canonical JSON-safe documents.

  This is `Definition.to_map/1` of each entry - the form stored in
  `NotificationProvider.definition`, and the form the docs and the upload UI can
  show as a worked example.
  """
  @spec documents() :: [map()]
  def documents, do: Enum.map(@provider_attrs, & &1.definition)

  @doc """
  The catalog as `NotificationProvider` attribute maps, for the seeder.

  `status` is deliberately absent: a provider is born `:draft` and is activated
  by the seeder exactly once, so an operator's disable is never overwritten.
  """
  @spec provider_attrs() :: [map()]
  def provider_attrs, do: @provider_attrs

  @doc "The provider keys this catalog ships, in catalog order."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "The template version every entry in this catalog currently ships at."
  @spec template_version() :: String.t()
  def template_version, do: @template_version
end
