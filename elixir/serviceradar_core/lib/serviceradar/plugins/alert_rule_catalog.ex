defmodule ServiceRadar.Plugins.AlertRuleCatalog do
  @moduledoc """
  Materializes package-declared alert rules as operator-owned rule rows.

  A plugin **proposes** rules; it never activates them. Rows are created with
  `enabled: false` and the manifest cannot express otherwise — `enabled` is not
  an accepted key. Turning a rule on is a human action taken in the UI, because
  a rule that fires pages someone, and a plugin update should never be able to
  change who gets woken up.

  Two properties this shares with `ProducerScheduleCatalog`, both deliberate:

    * **Sync runs on APPROVE, not on import.** A staged package's manifest has
      not been reviewed by anyone, so materializing at import would let unread
      content reach the database.

    * **Re-sync cannot touch operator fields.** The update branch takes only the
      rule's *definition* — what it watches and what it says. `enabled`,
      `threshold`, `window_seconds`, `bucket_seconds`, `cooldown_seconds`,
      `renotify_seconds` and `priority` are structurally excluded, so upgrading
      a plugin can never re-arm a rule an operator disabled, nor undo a
      threshold they tuned. This mirrors `RuleSeeder`'s `@managed_fields`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query
  require Logger

  # What a plugin owns. Everything else on the row belongs to the operator.
  @definition_fields [:description, :signal, :match, :group_by, :event, :alert]

  # Tuning the manifest may seed but never subsequently overwrite. These are
  # applied on CREATE only, so a plugin can ship sensible starting values while
  # an operator's later edit is permanent.
  @seed_only_fields [
    :threshold,
    :window_seconds,
    :bucket_seconds,
    :cooldown_seconds,
    :renotify_seconds
  ]

  @spec sync_package(PluginPackage.t(), keyword()) :: :ok | {:error, term()}
  def sync_package(package, opts \\ [])

  def sync_package(%PluginPackage{} = package, opts) do
    sync_rules(package, package.alert_rules || [], opts)
  end

  def sync_package(_package, _opts), do: :ok

  @doc """
  Disable every rule a package contributed.

  Used when a package is denied, revoked or restaged. The rows are kept rather
  than deleted so an operator can still see what a since-revoked plugin was
  watching, and so re-approving does not silently lose their tuning.
  """
  @spec disable_package_rules(PluginPackage.t(), keyword()) :: :ok | {:error, term()}
  def disable_package_rules(%PluginPackage{} = package, opts) do
    _opts = opts
    actor = SystemActor.system(:alert_rule_catalog)

    case package_rules(package.id, actor) do
      {:ok, rules} ->
        Enum.reduce_while(rules, :ok, fn rule, :ok ->
          case update_rule(rule, %{enabled: false}, actor) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def disable_package_rules(_package, _opts), do: :ok

  defp sync_rules(package, rules, opts) when is_list(rules) do
    _opts = opts
    actor = SystemActor.system(:alert_rule_catalog)

    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case sync_rule(package, normalize_rule(rule), actor) do
        {:ok, _rule} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sync_rules(_package, _rules, _opts), do: :ok

  defp sync_rule(package, rule, actor) do
    name = qualified_name(package, map_get(rule, "name"))

    definition = %{
      description: map_get(rule, "description"),
      signal: signal(map_get(rule, "signal")),
      match: map_get(rule, "match") || %{},
      group_by: map_get(rule, "group_by"),
      event: map_get(rule, "event") || %{},
      alert: map_get(rule, "alert") || %{}
    }

    case find_existing(package.id, name, actor) do
      {:ok, nil} ->
        attrs =
          definition
          |> Map.merge(seed_tuning(rule))
          |> Map.merge(%{
            name: name,
            plugin_package_id: package.id,
            # Never true. A plugin cannot arm its own rule.
            enabled: false
          })
          |> drop_nils()

        StatefulAlertRule
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create(actor: actor)

      {:ok, rule_row} ->
        update_rule(rule_row, drop_nils(Map.take(definition, @definition_fields)), actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_rule(rule_row, attrs, actor) do
    rule_row
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: actor)
  end

  # Rule names are namespaced by package.
  #
  # RuleSeeder.ensure_managed_defaults/3 keys the whole table by name and will
  # adopt an unmanaged row whose name matches one of its built-in defaults. A
  # package shipping a rule called `sweep_device_unavailable` would otherwise
  # collide with a core-managed rule. The prefix makes that impossible rather
  # than unlikely.
  defp qualified_name(package, name), do: "plugin:#{package.name}:#{name}"

  defp seed_tuning(rule) do
    Enum.reduce(@seed_only_fields, %{}, fn field, acc ->
      case map_get(rule, to_string(field)) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp find_existing(package_id, name, actor) do
    StatefulAlertRule
    |> Ash.Query.filter(plugin_package_id == ^package_id and name == ^name)
    |> Ash.Query.limit(1)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [rule | _]} -> {:ok, rule}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp package_rules(package_id, actor) do
    StatefulAlertRule
    |> Ash.Query.filter(plugin_package_id == ^package_id)
    |> Ash.read(actor: actor)
  end

  defp signal(value) when is_binary(value) do
    case value do
      "log" -> :log
      "event" -> :event
      _ -> :metric
    end
  end

  defp signal(_value), do: :metric

  defp normalize_rule(rule) when is_map(rule) do
    Map.new(rule, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_rule(_rule), do: %{}

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp map_get(_map, _key), do: nil

  defp drop_nils(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
