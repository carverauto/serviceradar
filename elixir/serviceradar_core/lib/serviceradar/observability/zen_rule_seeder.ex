defmodule ServiceRadar.Observability.ZenRuleSeeder do
  @moduledoc """
  Seeds default Zen rules for each tenant.
  """

  use GenServer

  require Logger
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Observability.ZenRule

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
      # Tenant listing is cross-tenant, use platform actor
      actor = SystemActor.platform(:zen_rule_seeder)
      Tenant
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.select([:id, :slug])
      |> Ash.read(actor: actor)
      |> case do
        {:ok, tenants} ->
          Enum.each(tenants, &seed_for_tenant/1)

        {:error, reason} ->
          Logger.warning("Zen rule seed skipped: #{inspect(reason)}")
      end
    end
  end

  def seed_for_tenant(%Tenant{} = tenant) do
    schema = TenantSchemas.schema_for_tenant(tenant)
    actor = SystemActor.for_tenant(tenant.id, :zen_rule_seeder)

    ensure_defaults(default_zen_rules(), schema, actor)

    :ok
  end

  defp ensure_defaults(defaults, schema, actor) do
    query =
      ZenRule
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.select([
        :id,
        :name,
        :subject,
        :template,
        :builder_config,
        :format,
        :agent_id,
        :stream_name
      ])

    case Ash.read(query, actor: actor, tenant: schema) do
      {:ok, rules} ->
        existing =
          rules
          |> Enum.map(&{&1.name, &1.subject})
          |> MapSet.new()

        existing = rename_legacy_rules(rules, existing, schema, actor)

        Enum.each(defaults, fn attrs ->
          seed_rule_if_missing(existing, attrs, schema, actor)
        end)

      {:error, reason} ->
        Logger.warning("Failed to check Zen rule defaults for #{schema}: #{inspect(reason)}")
    end
  end

  defp rename_legacy_rules(rules, existing, schema, actor) do
    Enum.reduce(rules, existing, fn rule, acc ->
      rename_legacy_rule(rule, acc, schema, actor)
    end)
  end

  defp seed_rule_if_missing(existing, attrs, schema, actor) do
    key = {attrs[:name], attrs[:subject]}

    if MapSet.member?(existing, key) do
      :ok
    else
      create_rule(attrs, schema, actor)
    end
  end

  defp create_rule(attrs, schema, actor) do
    changeset =
      Ash.Changeset.for_create(ZenRule, :create, attrs,
        tenant: schema,
        actor: actor
      )

    case Ash.create(changeset, actor: actor) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning(
          "Failed to seed Zen rule #{attrs[:name]} for #{schema}: #{inspect(reason)}"
        )
    end
  end

  defp rename_legacy_rule(rule, acc, schema, actor) do
    case legacy_rule_name(rule.name) do
      nil -> acc
      new_name -> rename_rule_if_missing(rule, new_name, acc, schema, actor)
    end
  end

  defp rename_rule_if_missing(rule, new_name, existing, schema, actor) do
    key = {new_name, rule.subject}

    if MapSet.member?(existing, key) do
      existing
    else
      do_rename_rule(rule, new_name, key, existing, schema, actor)
    end
  end

  defp do_rename_rule(rule, new_name, key, existing, schema, actor) do
    changeset =
      Ash.Changeset.for_update(rule, :update, %{name: new_name},
        tenant: schema,
        actor: actor
      )

    case Ash.update(changeset, actor: actor) do
      {:ok, _} ->
        MapSet.put(existing, key)

      {:error, reason} ->
        Logger.warning(
          "Failed to rename Zen rule #{rule.name} for #{schema}: #{inspect(reason)}"
        )

        existing
    end
  end

  defp legacy_rule_name("syslog_passthrough"), do: "passthrough"
  defp legacy_rule_name("syslog_strip_full_message"), do: "strip_full_message"
  defp legacy_rule_name("syslog_cef_severity"), do: "cef_severity"
  defp legacy_rule_name(_), do: nil

  defp default_zen_rules do
    [
      %{
        name: "passthrough",
        description: "Default (passthrough) for syslog logs.",
        subject: "logs.syslog",
        template: :passthrough,
        builder_config: %{},
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
        builder_config: %{},
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
        builder_config: %{},
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
        builder_config: %{},
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
        builder_config: %{},
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
        builder_config: %{},
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
        builder_config: %{},
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
        builder_config: %{},
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
        builder_config: %{},
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
        builder_config: %{},
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
        builder_config: %{},
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
        builder_config: %{},
        order: 110,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      }
    ]
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end
end
