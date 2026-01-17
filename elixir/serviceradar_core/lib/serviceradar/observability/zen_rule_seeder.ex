defmodule ServiceRadar.Observability.ZenRuleSeeder do
  @moduledoc """
  Seeds default Zen rules for each tenant.
  """

  use GenServer

  require Logger
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
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
      # DB connection's search_path determines the schema
      # Seed rules for the current tenant schema
      seed_for_current_tenant()
    end
  end

  def seed_for_tenant(_tenant) do
    # DB connection's search_path determines the schema
    seed_for_current_tenant()
  end

  defp seed_for_current_tenant do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:zen_rule_seeder)
    opts = [actor: actor]

    ensure_defaults(default_zen_rules(), opts)

    :ok
  end

  defp ensure_defaults(defaults, opts) do
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

    case Ash.read(query, opts) do
      {:ok, rules} ->
        existing =
          rules
          |> Enum.map(&{&1.name, &1.subject})
          |> MapSet.new()

        existing = rename_legacy_rules(rules, existing, opts)

        Enum.each(defaults, fn attrs ->
          seed_rule_if_missing(existing, attrs, opts)
        end)

      {:error, reason} ->
        schema = Keyword.get(opts, :tenant, "unknown")
        Logger.warning("Failed to check Zen rule defaults for #{schema}: #{inspect(reason)}")
    end
  end

  defp rename_legacy_rules(rules, existing, opts) do
    Enum.reduce(rules, existing, fn rule, acc ->
      rename_legacy_rule(rule, acc, opts)
    end)
  end

  defp seed_rule_if_missing(existing, attrs, opts) do
    key = {attrs[:name], attrs[:subject]}

    if MapSet.member?(existing, key) do
      :ok
    else
      create_rule(attrs, opts)
    end
  end

  defp create_rule(attrs, opts) do
    changeset = Ash.Changeset.for_create(ZenRule, :create, attrs, opts)
    schema = Keyword.get(opts, :tenant, "unknown")

    case Ash.create(changeset) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning(
          "Failed to seed Zen rule #{attrs[:name]} for #{schema}: #{inspect(reason)}"
        )
    end
  end

  defp rename_legacy_rule(rule, acc, opts) do
    case legacy_rule_name(rule.name) do
      nil -> acc
      new_name -> rename_rule_if_missing(rule, new_name, acc, opts)
    end
  end

  defp rename_rule_if_missing(rule, new_name, existing, opts) do
    key = {new_name, rule.subject}

    if MapSet.member?(existing, key) do
      existing
    else
      do_rename_rule(rule, new_name, key, existing, opts)
    end
  end

  defp do_rename_rule(rule, new_name, key, existing, opts) do
    changeset = Ash.Changeset.for_update(rule, :update, %{name: new_name}, opts)
    schema = Keyword.get(opts, :tenant, "unknown")

    case Ash.update(changeset) do
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
