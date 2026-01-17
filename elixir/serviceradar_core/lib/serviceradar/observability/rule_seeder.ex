defmodule ServiceRadar.Observability.RuleSeeder do
  @moduledoc """
  Seeds default LogPromotionRules and StatefulAlertRules for each tenant.

  These rules are created by default so tenants have working rules for
  common use cases like missed sweep detection out of the box.
  """

  use GenServer

  require Logger
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.LogPromotionRule
  alias ServiceRadar.Observability.StatefulAlertRule

  @seed_delay_ms 6_000

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
    actor = SystemActor.system(:rule_seeder)
    opts = [actor: actor]

    ensure_promotion_rules(opts)
    ensure_stateful_rules(opts)

    :ok
  end

  defp ensure_promotion_rules(opts) do
    ensure_defaults(LogPromotionRule, default_promotion_rules(), opts)
  end

  defp ensure_stateful_rules(opts) do
    ensure_defaults(StatefulAlertRule, default_stateful_rules(), opts)
  end

  defp ensure_defaults(resource, defaults, opts) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.select([:name])

    case Ash.read(query, opts) do
      {:ok, rules} ->
        existing =
          rules
          |> Enum.map(& &1.name)
          |> MapSet.new()

        Enum.each(defaults, fn attrs ->
          seed_rule_if_missing(existing, attrs, resource, opts)
        end)

      {:error, reason} ->
        schema = Keyword.get(opts, :tenant, "unknown")
        Logger.warning("Failed to check rule defaults for #{resource} in #{schema}: #{inspect(reason)}")
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
    schema = Keyword.get(opts, :tenant, "unknown")

    case Ash.create(changeset) do
      {:ok, _} ->
        Logger.info("Seeded rule: #{attrs[:name]} for #{schema}")

      {:error, reason} ->
        Logger.warning(
          "Failed to seed #{resource} rule #{attrs[:name]} for #{schema}: #{inspect(reason)}"
        )
    end
  end

  defp default_promotion_rules do
    [
      %{
        name: "promote_missed_sweeps",
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

  defp default_stateful_rules do
    [
      %{
        name: "repeated_missed_sweeps",
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
