defmodule ServiceRadar.Observability.RuleSeeder do
  @moduledoc """
  Seeds default EventRules and StatefulAlertRules on startup.

  These rules are created by default so the instance has working rules for
  common use cases like missed sweep detection out of the box.

  In single-deployment architecture, the DB connection's
  search_path determines which schema rules are seeded into.
  """

  use ServiceRadar.DelayedSeeder, delay_ms: 6_000, callback: :seed_all

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.StatefulAlertRule

  require Ash.Query
  require Logger

  def seed_all do
    if repo_enabled?() do
      # DB connection's search_path determines the schema
      seed_rules()
    end
  end

  defp seed_rules do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:rule_seeder)
    opts = [actor: actor]

    ensure_event_rules(opts)
    ensure_stateful_rules(opts)

    :ok
  end

  defp ensure_event_rules(opts) do
    ensure_defaults(EventRule, default_event_rules(), opts)
  end

  defp ensure_stateful_rules(opts) do
    retire_legacy_causal_prediction_rule(opts)
    ensure_defaults(StatefulAlertRule, default_stateful_rules(), opts)
  end

  defp retire_legacy_causal_prediction_rule(opts) do
    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(name == "causal_prediction_health_finding")

    case Ash.read(query, opts) do
      {:ok, rules} ->
        Enum.each(rules, fn rule ->
          rule
          |> Ash.Changeset.for_update(:update, %{enabled: false}, opts)
          |> Ash.update()
          |> case do
            {:ok, _} ->
              Logger.info("Retired legacy rule: causal_prediction_health_finding")

            {:error, reason} ->
              Logger.warning("Failed to retire legacy causal prediction rule: #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to check legacy causal prediction rule: #{inspect(reason)}")
    end
  end

  defp ensure_defaults(resource, defaults, opts) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.select([:name])

    case Ash.read(query, opts) do
      {:ok, rules} ->
        existing = MapSet.new(rules, & &1.name)

        Enum.each(defaults, fn attrs ->
          seed_rule_if_missing(existing, attrs, resource, opts)
        end)

      {:error, reason} ->
        schema = Keyword.get(opts, :schema, "unknown")

        Logger.warning(
          "Failed to check rule defaults for #{resource} in #{schema}: #{inspect(reason)}"
        )
    end
  end

  defp seed_rule_if_missing(existing, attrs, resource, opts) do
    if MapSet.member?(existing, attrs[:name]) do
      :ok
    else
      create_rule(resource, attrs, opts)
    end
  end

  defp create_rule(resource, attrs, opts) do
    changeset = Ash.Changeset.for_create(resource, :create, attrs, opts)
    schema = Keyword.get(opts, :schema, "unknown")

    case Ash.create(changeset) do
      {:ok, _} ->
        Logger.info("Seeded rule: #{attrs[:name]} for #{schema}")

      {:error, reason} ->
        Logger.warning(
          "Failed to seed #{resource} rule #{attrs[:name]} for #{schema}: #{inspect(reason)}"
        )
    end
  end

  defp default_event_rules do
    [
      %{
        name: "waf_findings_to_security_events",
        enabled: true,
        priority: 60,
        source_type: :log,
        source: %{},
        match: %{
          "subject_prefix" => "logs.",
          "event_type" => "waf.finding"
        },
        event: %{
          "log_name" => "security.waf.finding",
          "alert" => false
        }
      },
      %{
        name: "copyfail_falco_logs_to_security_events",
        enabled: true,
        priority: 35,
        source_type: :log,
        source: %{},
        match: %{
          "subject_prefix" => "falco.",
          "service_name" => "falco",
          "attribute_equals" => %{
            "falco.rule" => "Copy Fail AF_ALG Socket Created In Container"
          }
        },
        event: %{
          "log_name" => "falco.copyfail.af_alg",
          "severity" => "critical",
          "status" => "Failure",
          "status_code" => "cve_2026_31431_af_alg_socket",
          "status_detail" => "Falco detected AF_ALG socket creation in a container",
          "alert" => false
        }
      }
    ]
  end

  defp default_stateful_rules do
    [
      %{
        name: "endpoint_inventory_vulnerability",
        description:
          "Raise one active vulnerability incident per canonical endpoint device from endpoint inventory findings.",
        priority: 45,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "signals.causal.inventory",
          "attribute_equals" => %{"signal_type" => "inventory"}
        },
        group_by: ["device"],
        threshold: 1,
        window_seconds: 300,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 21_600,
        event: %{
          "log_name" => "alert.security.endpoint_inventory.vulnerability",
          "message" => "Endpoint inventory vulnerability detected"
        },
        alert: %{
          "title" => "Endpoint Inventory Vulnerability",
          "severity" => "critical"
        }
      },
      %{
        name: "causal_prediction_anomaly_finding",
        description:
          "Raise one active health incident per canonical anomaly finding and resolve it on clear.",
        priority: 44,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "signals.causal.predictions",
          "resource_attribute_equals" => %{
            "signal_type" => "causal",
            "event_type" => "anomaly"
          },
          "attribute_equals" => %{
            "status" => ["open", "breach"]
          },
          "attribute_not_equals" => %{
            "anomaly.state" => "pending_anomaly"
          },
          "reset_when" => [
            %{
              "subject_prefix" => "signals.causal.predictions",
              "resource_attribute_equals" => %{
                "signal_type" => "causal",
                "event_type" => "anomaly"
              },
              "attribute_equals" => %{
                "status" => ["cleared", "closed", "resolved", "inactive", "clear"]
              }
            },
            %{
              "subject_prefix" => "signals.causal.predictions",
              "resource_attribute_equals" => %{
                "signal_type" => "causal",
                "event_type" => "anomaly",
                "detection_finding.state" => ["clean", "normal"]
              }
            }
          ]
        },
        group_by: ["finding_info.uid"],
        threshold: 1,
        window_seconds: 300,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 21_600,
        event: %{
          "log_name" => "alert.health.anomaly_detection",
          "message" => "Anomaly detection finding detected"
        },
        alert: %{
          "title" => "Anomaly Detection Finding"
        }
      },
      %{
        name: "causal_prediction_capacity_exhaustion",
        description:
          "Raise one active health incident per capacity forecast that crosses the warning horizon.",
        priority: 44,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "signals.causal.predictions",
          "resource_attribute_equals" => %{
            "signal_type" => "causal",
            "event_type" => "capacity_forecast"
          },
          "attribute_equals" => %{"status" => "projected"},
          "reset_when" => %{
            "subject_prefix" => "signals.causal.predictions",
            "resource_attribute_equals" => %{
              "signal_type" => "causal",
              "event_type" => "capacity_forecast"
            },
            "attribute_equals" => %{
              "status" => ["inactive", "resolved", "closed", "skipped"]
            }
          }
        },
        group_by: ["finding_info.uid"],
        threshold: 1,
        window_seconds: 300,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 21_600,
        event: %{
          "log_name" => "alert.health.capacity_forecast",
          "message" => "Capacity forecast warning horizon crossed"
        },
        alert: %{
          "title" => "Capacity Forecast Warning"
        }
      },
      %{
        name: "falco_critical_incident",
        description:
          "Collapse repeated Falco critical detections into one active incident per rule and host.",
        priority: 40,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "falco.",
          "severity_number_min" => 5
        },
        group_by: ["rule", "hostname"],
        threshold: 1,
        window_seconds: 300,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 21_600,
        event: %{
          "log_name" => "alert.security.falco.incident",
          "message" => "Falco security incident detected"
        },
        alert: %{
          "title" => "Falco Security Incident",
          "severity" => "critical"
        }
      }
    ]
  end
end
