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
    ensure_defaults(StatefulAlertRule, default_stateful_rules(), opts)
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
      # Reserved for future default event rules.
    ]
  end

  defp default_stateful_rules do
    [
      # Reserved for future default stateful alert rules.
    ]
  end
end
