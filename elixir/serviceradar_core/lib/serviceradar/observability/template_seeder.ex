defmodule ServiceRadar.Observability.TemplateSeeder do
  @moduledoc """
  Seeds default rule templates for each tenant.
  """

  use GenServer

  require Logger
  require Ash.Query

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Observability.{
    LogPromotionRuleTemplate,
    StatefulAlertRuleTemplate,
    ZenRuleTemplate
  }

  @seed_delay_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :seed, @seed_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:seed, state) do
    seed_all()
    {:noreply, state}
  end

  def seed_all do
    if repo_enabled?() do
      Tenant
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.select([:id, :slug])
      |> Ash.read(authorize?: false)
      |> case do
        {:ok, tenants} ->
          Enum.each(tenants, &seed_for_tenant/1)

        {:error, reason} ->
          Logger.warning("Template seed skipped: #{inspect(reason)}")
      end
    end
  end

  def seed_for_tenant(%Tenant{} = tenant) do
    schema = TenantSchemas.schema_for_tenant(tenant)
    actor = %{tenant_id: to_string(tenant.id), role: :admin}

    ensure_zen_defaults(schema, actor)
    ensure_defaults(LogPromotionRuleTemplate, default_promotion_templates(), schema, actor)
    ensure_defaults(StatefulAlertRuleTemplate, default_stateful_templates(), schema, actor)

    :ok
  end

  defp ensure_defaults(resource, defaults, schema, actor) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.select([:name])

    case Ash.read(query, authorize?: false, tenant: schema) do
      {:ok, templates} ->
        existing =
          templates
          |> Enum.map(& &1.name)
          |> MapSet.new()

        Enum.each(defaults, fn attrs ->
          if MapSet.member?(existing, attrs[:name]) do
            :ok
          else
            changeset =
              Ash.Changeset.for_create(resource, :create, attrs,
                tenant: schema,
                actor: actor
              )

            case Ash.create(changeset, authorize?: false) do
              {:ok, _} -> :ok
              {:error, reason} ->
                Logger.warning("Failed to seed #{resource}: #{inspect(reason)}")
            end
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to check template defaults for #{resource}: #{inspect(reason)}")
    end
  end

  defp ensure_zen_defaults(schema, actor) do
    query =
      ZenRuleTemplate
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.select([:id, :name, :subject])

    case Ash.read(query, authorize?: false, tenant: schema) do
      {:ok, templates} ->
        existing =
          templates
          |> Enum.map(&{&1.name, &1.subject})
          |> MapSet.new()

        existing = rename_legacy_templates(templates, existing, schema, actor)

        Enum.each(default_zen_templates(), fn attrs ->
          key = {attrs[:name], attrs[:subject]}

          if MapSet.member?(existing, key) do
            :ok
          else
            changeset =
              Ash.Changeset.for_create(ZenRuleTemplate, :create, attrs,
                tenant: schema,
                actor: actor
              )

            case Ash.create(changeset, authorize?: false) do
              {:ok, _} -> :ok
              {:error, reason} ->
                Logger.warning("Failed to seed #{ZenRuleTemplate}: #{inspect(reason)}")
            end
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to check template defaults for #{ZenRuleTemplate}: #{inspect(reason)}")
    end
  end

  defp rename_legacy_templates(templates, existing, schema, actor) do
    Enum.reduce(templates, existing, fn template, acc ->
      case legacy_template_name(template.name) do
        nil ->
          acc

        new_name ->
          key = {new_name, template.subject}

          if MapSet.member?(acc, key) do
            acc
          else
            changeset =
              Ash.Changeset.for_update(template, :update, %{name: new_name},
                tenant: schema,
                actor: actor
              )

            case Ash.update(changeset, authorize?: false) do
              {:ok, _} ->
                MapSet.put(acc, key)

              {:error, reason} ->
                Logger.warning(
                  "Failed to rename Zen template #{template.name} for #{schema}: #{inspect(reason)}"
                )

                acc
            end
          end
      end
    end)
  end

  defp legacy_template_name("syslog_passthrough"), do: "passthrough"
  defp legacy_template_name("syslog_strip_full_message"), do: "strip_full_message"
  defp legacy_template_name("syslog_cef_severity"), do: "cef_severity"
  defp legacy_template_name(_), do: nil

  defp default_zen_templates do
    [
      %{
        name: "passthrough",
        description: "Default (passthrough) for syslog logs.",
        subject: "logs.syslog",
        template: :passthrough,
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for SNMP logs.",
        subject: "logs.snmp",
        template: :passthrough,
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for OTEL logs.",
        subject: "logs.otel",
        template: :passthrough,
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for OTEL metrics.",
        subject: "otel.metrics.raw",
        template: :passthrough,
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for internal health logs.",
        subject: "logs.internal.health",
        template: :passthrough,
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for internal jobs logs.",
        subject: "logs.internal.jobs",
        template: :passthrough,
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for internal onboarding logs.",
        subject: "logs.internal.onboarding",
        template: :passthrough,
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for internal audit logs.",
        subject: "logs.internal.audit",
        template: :passthrough,
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for internal sweep logs.",
        subject: "logs.internal.sweep",
        template: :passthrough,
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "strip_full_message",
        description: "Remove full_message from syslog payloads.",
        subject: "logs.syslog",
        template: :strip_full_message,
        order: 110,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "cef_severity",
        description: "Map CEF severity values into normalized severity.",
        subject: "logs.syslog",
        template: :cef_severity,
        order: 120,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "snmp_severity",
        description: "Normalize SNMP trap severity fields.",
        subject: "logs.snmp",
        template: :snmp_severity,
        order: 110,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      }
    ]
  end

  defp default_promotion_templates do
    [
      %{
        name: "promote_errors",
        description: "Promote error logs into events.",
        priority: 50,
        enabled: true,
        match: %{
          "severity_text" => "error"
        },
        event: %{
          "message" => "Promoted error log"
        }
      },
      %{
        name: "promote_warnings",
        description: "Promote warning logs into events.",
        priority: 75,
        enabled: true,
        match: %{
          "severity_text" => "warning"
        },
        event: %{
          "message" => "Promoted warning log"
        }
      },
      %{
        name: "promote_missed_sweeps",
        description: "Promote missed sweep logs into events for alert processing.",
        priority: 25,
        enabled: true,
        match: %{
          "event_type" => "sweep.missed"
        },
        event: %{
          "message" => "Network sweep missed expected execution",
          "category_name" => "System Activity",
          "class_name" => "Scheduled Job Activity",
          "severity_id" => 3,
          "type_id" => 6006
        }
      }
    ]
  end

  defp default_stateful_templates do
    [
      %{
        name: "burst_errors",
        description: "Alert on repeated errors in a short window.",
        priority: 50,
        enabled: true,
        signal: :log,
        threshold: 5,
        window_seconds: 600,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 21_600,
        match: %{
          "severity_text" => "error"
        },
        event: %{},
        alert: %{}
      },
      %{
        name: "repeated_missed_sweeps",
        description: "Alert when a sweep group misses 2 or more consecutive sweeps.",
        priority: 25,
        enabled: true,
        signal: :event,
        threshold: 2,
        window_seconds: 3600,
        bucket_seconds: 300,
        cooldown_seconds: 1800,
        renotify_seconds: 21_600,
        group_by: ["sweep_group_id"],
        match: %{
          "type_id" => 6006,
          "class_name" => "Scheduled Job Activity"
        },
        event: %{},
        alert: %{
          "severity" => "high",
          "title" => "Network Sweep Repeatedly Missed",
          "description" => "A network sweep group has missed multiple scheduled executions"
        }
      }
    ]
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end
end
