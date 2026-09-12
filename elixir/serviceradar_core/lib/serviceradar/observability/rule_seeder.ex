defmodule ServiceRadar.Observability.RuleSeeder do
  @moduledoc """
  Seeds default EventRules and StatefulAlertRules on startup.

  These rules are created by default so the instance has working rules for
  common use cases like missed sweep detection out of the box.

  Stateful alert rule templates are versioned. Rules the seeder creates carry
  `managed: true`, the current `template_version`, and a fingerprint of the
  seeder-owned fields. On boot, managed rules whose stored version is behind
  the current template are reconciled to the current template as long as the
  seeder-owned fields still match what the seeder last wrote. Rules whose
  seeder-owned fields were modified by an operator are skipped and logged.

  Exactly two rules — the prediction-contract rules
  `causal_prediction_health_finding` and `causal_capacity_health_finding`,
  which the contract-repair migration stamps managed at version 0 with no
  fingerprint — get a one-time template adoption on the first boot after
  upgrade; operator knobs (enabled, priority, threshold, window/bucket/
  cooldown/renotify, description) are preserved as before. All other seeded
  rules are never content-modified unless their content already matches the
  shipped template: an unmanaged seeded-name rule whose seeder-owned fields
  equal the current template is adopted (stamped managed at the current
  version, no content change); anything else is skipped and logged. Clearing
  `managed` detaches a customized rule from the seeder. Operator-tunable
  knobs (enabled, priority, thresholds, windows, description) are never
  reconciled.

  In single-deployment architecture, the DB connection's
  search_path determines which schema rules are seeded into.
  """

  use ServiceRadar.DelayedSeeder, delay_ms: 6_000, callback: :seed_all

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.StatefulAlertRule

  require Ash.Query
  require Logger

  # Fields owned by the stateful rule templates: reconciled on template version
  # bumps and covered by the divergence fingerprint. Everything else on the
  # rule is operator-tunable and never touched by reconciliation.
  @managed_fields [:signal, :match, :group_by, :event, :alert]

  # The two producer-contract rules the 20260712110000 contract-repair
  # migration rewrites and stamps managed at version 0 with no fingerprint.
  # Only these names get the one-time nil-fingerprint reconcile below.
  @contract_repair_rules [
    "causal_prediction_health_finding",
    "causal_capacity_health_finding"
  ]

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
    ensure_managed_defaults(StatefulAlertRule, default_stateful_rules(), opts)
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

  defp ensure_managed_defaults(resource, defaults, opts) do
    query = Ash.Query.for_read(resource, :read, %{})

    case Ash.read(query, opts) do
      {:ok, rules} ->
        existing = Map.new(rules, &{&1.name, &1})

        Enum.each(defaults, fn attrs ->
          reconcile_or_create_rule(existing, attrs, resource, opts)
        end)

      {:error, reason} ->
        schema = Keyword.get(opts, :schema, "unknown")

        Logger.warning(
          "Failed to check rule defaults for #{resource} in #{schema}: #{inspect(reason)}"
        )
    end
  end

  defp reconcile_or_create_rule(existing, attrs, resource, opts) do
    case Map.get(existing, attrs[:name]) do
      nil ->
        create_rule(resource, Map.put(attrs, :template_fingerprint, fingerprint(attrs)), opts)

      rule ->
        reconcile_rule(rule, attrs, resource, opts)
    end
  end

  defp reconcile_rule(rule, attrs, resource, opts) do
    cond do
      not rule.managed ->
        maybe_adopt_unmanaged_rule(rule, attrs, resource, opts)

      (rule.template_version || 0) >= attrs[:template_version] ->
        :ok

      diverged_from_last_template?(rule) ->
        Logger.info(
          "Skipping managed rule #{rule.name}: operator-modified fields diverge from " <>
            "template v#{rule.template_version}"
        )

      true ->
        update_managed_rule(rule, attrs, resource, opts)
    end
  end

  # A seeded-name rule without the managed marker is adopted only when its
  # seeder-owned fields already match the current template exactly: the stamp
  # adds the marker without any content change. Anything else is
  # operator-owned and left alone.
  defp maybe_adopt_unmanaged_rule(rule, attrs, resource, opts) do
    if fingerprint(rule) == fingerprint(attrs) do
      adopt_pristine_rule(rule, attrs, resource, opts)
    else
      Logger.info("Skipping unmanaged seeded rule #{rule.name}: not owned by the seeder")
    end
  end

  defp adopt_pristine_rule(rule, attrs, resource, opts) do
    stamp_attrs = %{
      managed: true,
      template_version: attrs[:template_version],
      template_fingerprint: fingerprint(attrs)
    }

    changeset = Ash.Changeset.for_update(rule, :update, stamp_attrs, opts)
    schema = Keyword.get(opts, :schema, "unknown")

    case Ash.update(changeset) do
      {:ok, _} ->
        Logger.info(
          "Adopted pristine seeded rule #{rule.name} at template v#{attrs[:template_version]}"
        )

      {:error, reason} ->
        Logger.warning(
          "Failed to adopt #{resource} rule #{rule.name} for #{schema}: #{inspect(reason)}"
        )
    end
  end

  # Only the two contract-repair rules stamped managed at version 0 by the
  # 20260712110000 migration predate the fingerprint; they are reconciled
  # exactly once on the next boot. Any other managed rule with no fingerprint
  # is treated as diverged and left alone.
  defp diverged_from_last_template?(%{template_fingerprint: nil, name: name})
       when name in @contract_repair_rules,
       do: false

  defp diverged_from_last_template?(%{template_fingerprint: nil}), do: true
  defp diverged_from_last_template?(rule), do: fingerprint(rule) != rule.template_fingerprint

  defp update_managed_rule(rule, attrs, resource, opts) do
    update_attrs =
      attrs
      |> Map.take([:managed, :template_version | @managed_fields])
      |> Map.put(:template_fingerprint, fingerprint(attrs))

    changeset = Ash.Changeset.for_update(rule, :update, update_attrs, opts)
    schema = Keyword.get(opts, :schema, "unknown")

    case Ash.update(changeset) do
      {:ok, _} ->
        Logger.info(
          "Reconciled managed rule #{rule.name} from template " <>
            "v#{rule.template_version || 0} to v#{attrs[:template_version]}"
        )

      {:error, reason} ->
        Logger.warning(
          "Failed to reconcile #{resource} rule #{rule.name} for #{schema}: #{inspect(reason)}"
        )
    end
  end

  defp fingerprint(rule_or_attrs) do
    digest =
      @managed_fields
      |> Map.new(fn field -> {field, Map.get(rule_or_attrs, field)} end)
      |> canonical_term()
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    Base.encode16(digest, case: :lower)
  end

  # Canonical form for fingerprinting: sorted key/value pairs with atoms
  # stringified, so template maps hash identically to their jsonb round-trip.
  defp canonical_term(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort()
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)
  defp canonical_term(value) when is_boolean(value) or is_nil(value), do: value
  defp canonical_term(value) when is_atom(value), do: to_string(value)
  defp canonical_term(value), do: value

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

  @doc false
  def default_event_rules do
    [
      # Core health checks (the anomaly tripwires and the seasonal-baseline
      # producer heartbeat) record `core` health transitions. Promote them into
      # events so the stateful rule below can page on them; the seasonal
      # baseline freshness check sat unhealthy for eight weeks with no alert.
      %{
        name: "core_health_state_change_events",
        enabled: true,
        priority: 50,
        source_type: :log,
        source: %{},
        match: %{
          "subject_prefix" => "logs.internal.health",
          "attribute_equals" => %{"health.entity_type" => "core"}
        },
        event: %{
          "log_name" => "health.core.state_change",
          "alert" => false
        }
      },
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
        name: "sweep_device_availability_events",
        enabled: true,
        priority: 50,
        source_type: :log,
        source: %{},
        match: %{
          "subject_prefix" => "logs.internal.sweep",
          "event_type" => ["device.unavailable", "device.available"]
        },
        event: %{
          "log_name" => "sweep.device.availability",
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
      },
      %{
        name: "k8s_node_readiness_events",
        enabled: true,
        priority: 52,
        source_type: :log,
        source: %{},
        match: %{
          "subject_prefix" => "logs.internal.k8s",
          "event_type" => ["node.not_ready", "node.ready"]
        },
        event: %{
          "log_name" => "k8s.node.readiness",
          "alert" => false
        }
      }
    ]
  end

  @doc false
  def default_stateful_rules do
    [
      %{
        name: "core_health_check_unhealthy",
        managed: true,
        template_version: 1,
        description:
          "Open one critical incident per core health check (the anomaly tripwires and the seasonal-baseline producer) when it goes unhealthy, and clear it when the check recovers.",
        priority: 30,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "health.core.state_change",
          "attribute_equals" => %{"health.new_state" => "unhealthy"},
          "recovery" => %{
            "subject_prefix" => "health.core.state_change",
            "attribute_equals" => %{"health.new_state" => "healthy"}
          }
        },
        group_by: ["health.entity_id"],
        threshold: 1,
        window_seconds: 300,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 21_600,
        event: %{
          "log_name" => "alert.health.core_check",
          "message" => "Core health check {health.entity_id} is unhealthy ({health.reason})"
        },
        alert: %{
          "title" => "Anomaly pipeline check unhealthy",
          "severity" => "critical"
        }
      },
      %{
        name: "sweep_device_unavailable",
        managed: true,
        template_version: 1,
        description:
          "Open one availability incident per device when sweep marks it unreachable, and clear it when the device recovers.",
        priority: 55,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "sweep.device.availability",
          "attribute_equals" => %{"event_type" => "device.unavailable"},
          "recovery" => %{
            "subject_prefix" => "sweep.device.availability",
            "attribute_equals" => %{"event_type" => "device.available"}
          }
        },
        group_by: ["device"],
        threshold: 1,
        window_seconds: 300,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 21_600,
        event: %{
          "log_name" => "alert.availability.sweep.device",
          "message" => "Device is unreachable from sweep checks"
        },
        alert: %{
          "title" => "Device Unreachable",
          "severity" => "warning"
        }
      },
      %{
        name: "k8s_node_not_ready",
        managed: true,
        template_version: 2,
        description:
          "Open one incident per Kubernetes node when Ready becomes False, and clear it when Ready returns True. Control-plane vs worker is taken from node.role, which names the node in the alert title without joining the incident identity.",
        priority: 20,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "k8s.node.readiness",
          "attribute_equals" => %{"event_type" => "node.not_ready"},
          "recovery" => %{
            "subject_prefix" => "k8s.node.readiness",
            "attribute_equals" => %{"event_type" => "node.ready"}
          }
        },
        group_by: ["cluster_id", "node"],
        threshold: 1,
        window_seconds: 300,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 21_600,
        event: %{
          "log_name" => "alert.availability.k8s.node",
          "message" => "Kubernetes {node.role} node {node} is NotReady in cluster {cluster_id}"
        },
        alert: %{
          "severity" => "critical"
        }
      },
      %{
        name: "endpoint_inventory_vulnerability",
        managed: true,
        template_version: 2,
        description:
          "Raise one active vulnerability incident per endpoint package and CVE only when distro-aware adjudication confirms the installed package is affected, and clear it when that assessment resolves.",
        priority: 45,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "signals.analytics.inventory.vulnerability_assessment",
          "attribute_equals" => %{
            "signal_type" => "inventory",
            "event_type" => "vulnerability_assessment",
            "assessment_status" => "active",
            "assessment" => "confirmed",
            "disposition" => "affected",
            "finding_status" => "open"
          },
          "recovery" => %{
            "subject_prefix" => "signals.analytics.inventory.vulnerability_assessment",
            "attribute_equals" => %{
              "signal_type" => "inventory",
              "event_type" => "vulnerability_assessment",
              "finding_status" => "resolved"
            }
          }
        },
        group_by: ["device", "package.identity_key", "cve_id"],
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
        name: "causal_prediction_health_finding",
        managed: true,
        template_version: 2,
        description:
          "Raise one active health incident per canonical anomaly series from confirmed causal anomaly transitions.",
        priority: 44,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "signals.analytics.predictions",
          "attribute_equals" => %{
            "signal_type" => "prediction",
            "event_type" => ["anomaly", "anomaly_detection"],
            "anomaly.state" => [
              "anomaly_open",
              "anomaly_update",
              "anomaly_drift_open",
              "anomaly_drift_update",
              "open",
              "anomalous"
            ]
          },
          "recovery" => %{
            "subject_prefix" => "signals.analytics.predictions",
            "attribute_equals" => %{
              "signal_type" => "prediction",
              "event_type" => ["anomaly", "anomaly_detection"],
              "anomaly.state" => [
                "anomaly_clear",
                "anomaly_drift_clear",
                "clear",
                "cleared",
                "inactive"
              ]
            }
          }
        },
        group_by: ["device", "anomaly.series_key"],
        threshold: 1,
        window_seconds: 300,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 21_600,
        event: %{
          "log_name" => "alert.health.causal_prediction",
          "message" => "Causal prediction finding detected"
        },
        alert: %{
          "title" => "Anomaly Finding",
          "severity_from" => "source"
        }
      },
      %{
        name: "causal_capacity_health_finding",
        managed: true,
        template_version: 1,
        description:
          "Raise one active health incident per canonical capacity forecast resource inside the warning horizon.",
        priority: 43,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "signals.analytics.predictions",
          "attribute_equals" => %{
            "signal_type" => "prediction",
            "event_type" => "capacity_forecast",
            "capacity_forecast.status" => "projected"
          },
          "recovery" => %{
            "subject_prefix" => "signals.analytics.predictions",
            "attribute_equals" => %{
              "signal_type" => "prediction",
              "event_type" => "capacity_forecast",
              "capacity_forecast.status" => ["inactive", "skipped"]
            }
          }
        },
        group_by: ["device", "capacity_forecast.resource_key"],
        threshold: 1,
        window_seconds: 300,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 21_600,
        event: %{
          "log_name" => "alert.health.capacity_forecast",
          "message" => "Capacity forecast warning-horizon finding detected"
        },
        alert: %{
          "title" => "Capacity Forecast Finding",
          "severity_from" => "source"
        }
      },
      %{
        name: "falco_critical_incident",
        managed: true,
        template_version: 1,
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
