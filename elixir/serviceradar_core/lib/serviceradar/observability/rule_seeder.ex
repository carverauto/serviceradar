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
  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Identity.Tenant
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
      # Tenant listing is cross-tenant, use platform actor
      actor = SystemActor.platform(:rule_seeder)
      Tenant
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.select([:id, :slug])
      |> Ash.read(actor: actor)
      |> case do
        {:ok, tenants} ->
          Enum.each(tenants, &seed_for_tenant/1)

        {:error, reason} ->
          Logger.warning("Rule seed skipped: #{inspect(reason)}")
      end
    end
  end

  def seed_for_tenant(%Tenant{} = tenant) do
    schema = TenantSchemas.schema_for_tenant(tenant)
    actor = SystemActor.for_tenant(tenant.id, :rule_seeder)

    ensure_promotion_rules(schema, actor)
    ensure_stateful_rules(schema, actor)

    :ok
  end

  defp ensure_promotion_rules(schema, actor) do
    ensure_defaults(LogPromotionRule, default_promotion_rules(), schema, actor)
  end

  defp ensure_stateful_rules(schema, actor) do
    ensure_defaults(StatefulAlertRule, default_stateful_rules(), schema, actor)
  end

  defp ensure_defaults(resource, defaults, schema, actor) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.select([:name])

    case Ash.read(query, actor: actor, tenant: schema) do
      {:ok, rules} ->
        existing =
          rules
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

            case Ash.create(changeset, actor: actor) do
              {:ok, _} ->
                Logger.info("Seeded rule: #{attrs[:name]} for #{schema}")

              {:error, reason} ->
                Logger.warning(
                  "Failed to seed #{resource} rule #{attrs[:name]} for #{schema}: #{inspect(reason)}"
                )
            end
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to check rule defaults for #{resource} in #{schema}: #{inspect(reason)}")
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
