defmodule ServiceRadar.Automation.Ansible.AwxInventorySyncReconciler do
  @moduledoc """
  Materializes AWX/AAP controllers into scheduled `awx-inventory-sync` plugin
  assignments.

  There is one enabled assignment per `(agent, awx-inventory-sync package)`.
  Each assignment carries every AWX controller reachable from that agent. This
  keeps the plugin assignment invariant intact while supporting multiple
  controllers per agent.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PolicyAssignmentReconciler
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query
  require Logger

  @plugin_id "awx-inventory-sync"
  @policy_id "ansible:awx-inventory-sync"
  @policy_version 1
  @default_timeout_ms 30_000

  @type reconcile_result :: PolicyAssignmentReconciler.reconcile_result()

  @doc "Reconcile inventory-sync assignments for all registered AWX controllers."
  @spec reconcile_all(keyword()) :: {:ok, reconcile_result()} | {:error, term()}
  def reconcile_all(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:awx_inventory_sync_reconciler))

    with {:ok, controllers} <- load_controllers(actor, opts) do
      reconcile_controllers(controllers, Keyword.put(opts, :actor, actor))
    end
  end

  @doc "Reconcile the inventory-sync assignment for one agent."
  @spec reconcile_agent(String.t(), keyword()) :: {:ok, reconcile_result()} | {:error, term()}
  def reconcile_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:awx_inventory_sync_reconciler))

    with {:ok, controllers} <- load_controllers_for_agent(agent_id, actor, opts) do
      reconcile_controllers(controllers, Keyword.put(opts, :actor, actor))
    end
  end

  @doc false
  @spec reconcile_controllers([map()], keyword()) :: {:ok, reconcile_result()} | {:error, term()}
  def reconcile_controllers(controllers, opts \\ []) when is_list(controllers) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:awx_inventory_sync_reconciler))

    with {:ok, package} <- approved_plugin_package(actor, opts),
         {:ok, rows} <- controller_rows(controllers, opts) do
      policy = %{
        policy_id: @policy_id,
        policy_version: @policy_version,
        plugin_package_id: string_value(package, [:id, "id"]),
        enabled: true
      }

      PolicyAssignmentReconciler.reconcile(policy, rows,
        actor: actor,
        resolver: __MODULE__.Resolver,
        planner: __MODULE__.Planner,
        store: Keyword.get(opts, :store, PolicyAssignmentReconciler.AshStore)
      )
    end
  end

  defmodule Resolver do
    @moduledoc false

    def resolve(rows, _opts), do: {:ok, rows}
  end

  defmodule Planner do
    @moduledoc false

    @policy_id "ansible:awx-inventory-sync"
    @default_interval_seconds 300
    @default_timeout_seconds 60
    @max_timeout_seconds 600

    @spec plan(map(), [map()], keyword()) ::
            {:ok, %{assignments: [map()], summary: map()}} | {:error, [String.t()]}
    def plan(policy, resolved_inputs, _opts \\ []) do
      with {:ok, package_id} <- required_string(policy, [:plugin_package_id, "plugin_package_id"]) do
        rows = Enum.flat_map(resolved_inputs, &rows_for_input/1)

        assignments =
          rows
          |> Enum.group_by(&Map.fetch!(&1, "agent_id"))
          |> Enum.sort_by(fn {agent_id, _rows} -> agent_id end)
          |> Enum.map(fn {agent_id, agent_rows} ->
            assignment_spec(package_id, agent_id, agent_rows)
          end)

        {:ok,
         %{
           assignments: assignments,
           summary: %{
             matched_rows: length(rows),
             agents: length(assignments),
             generated_assignments: length(assignments)
           }
         }}
      end
    end

    defp assignment_spec(package_id, agent_id, rows) do
      controllers =
        rows
        |> Enum.sort_by(&{Map.get(&1, "controller_name") || "", Map.get(&1, "controller_id")})
        |> Enum.map(&Map.fetch!(&1, "controller"))

      %{
        assignment_key: @policy_id <> ":" <> agent_id,
        agent_uid: agent_id,
        plugin_package_id: package_id,
        enabled: true,
        interval_seconds: interval_seconds(rows),
        timeout_seconds: timeout_seconds(rows),
        params: %{"controllers" => controllers},
        metadata: %{
          "source" => "policy",
          "policy_id" => @policy_id,
          "controller_count" => length(controllers)
        }
      }
    end

    defp rows_for_input(%{rows: rows}) when is_list(rows), do: rows
    defp rows_for_input(%{"rows" => rows}) when is_list(rows), do: rows
    defp rows_for_input(_), do: []

    defp interval_seconds(rows) do
      rows
      |> Enum.map(&(Map.get(&1, "interval_seconds") || @default_interval_seconds))
      |> Enum.filter(&is_integer/1)
      |> Enum.min(fn -> @default_interval_seconds end)
      |> max(30)
    end

    defp timeout_seconds(rows) do
      rows
      |> Enum.map(&(Map.get(&1, "timeout_seconds") || @default_timeout_seconds))
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> @default_timeout_seconds end)
      |> max(length(rows) * @default_timeout_seconds)
      |> min(@max_timeout_seconds)
    end

    defp required_string(map, keys) do
      keys
      |> Enum.find_value(&Map.get(map, &1))
      |> case do
        value when is_binary(value) and value != "" -> {:ok, value}
        _ -> {:error, ["missing required policy field: plugin_package_id"]}
      end
    end
  end

  defp load_controllers(actor, opts) do
    case Keyword.fetch(opts, :controllers) do
      {:ok, controllers} ->
        {:ok, controllers}

      :error ->
        Controller
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.read(actor: actor)
    end
  end

  defp load_controllers_for_agent(agent_id, actor, opts) do
    case Keyword.fetch(opts, :controllers) do
      {:ok, controllers} ->
        {:ok, Enum.filter(controllers, &(string_value(&1, [:agent_id, "agent_id"]) == agent_id))}

      :error ->
        Controller.list_by_agent(agent_id, actor: actor)
    end
  end

  defp approved_plugin_package(actor, opts) do
    case Keyword.fetch(opts, :plugin_package) do
      {:ok, package} ->
        {:ok, package}

      :error ->
        PluginPackage
        |> Ash.Query.for_read(:approved, %{}, actor: actor)
        |> Ash.Query.filter(plugin_id == ^@plugin_id)
        |> Ash.read(actor: actor)
        |> case do
          {:ok, packages} when packages != [] ->
            {:ok, Enum.max_by(packages, &package_sort_key/1)}

          {:ok, []} ->
            {:error, {:plugin_package_not_found, @plugin_id}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp controller_rows(controllers, opts) do
    controllers
    |> Enum.reject(&blank?(string_value(&1, [:agent_id, "agent_id"])))
    |> Enum.reduce_while({:ok, []}, fn controller, {:ok, acc} ->
      case controller_row(controller, opts) do
        {:ok, row} ->
          {:cont, {:ok, [row | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} ->
        {:ok,
         [
           %{
             name: "awx_controllers",
             entity: "ansible_controllers",
             query: "in:ansible_controllers",
             rows: Enum.reverse(rows)
           }
         ]}

      error ->
        error
    end
  end

  defp controller_row(controller, opts) do
    with {:ok, grant} <- grant_template(controller, opts),
         {:ok, controller_id} <- required_string(controller, [:id, "id"], "controller id"),
         {:ok, agent_id} <- required_string(controller, [:agent_id, "agent_id"], "agent_id"),
         {:ok, base_url} <- required_string(controller, [:base_url, "base_url"], "base_url"),
         {:ok, secret_id} <-
           required_string(
             controller,
             [:credential_secret_id, "credential_secret_id"],
             "credential_secret_id"
           ) do
      timeout_ms = metadata_int(controller, "timeout_ms", @default_timeout_ms)

      {:ok,
       %{
         "agent_id" => agent_id,
         "controller_id" => controller_id,
         "controller_name" => string_value(controller, [:name, "name"]) || controller_id,
         "interval_seconds" =>
           int_value(
             controller,
             [:inventory_sync_interval_seconds, "inventory_sync_interval_seconds"],
             300
           ),
         "timeout_seconds" => div(timeout_ms + 999, 1000),
         "controller" =>
           compact_map(%{
             "controller_id" => controller_id,
             "controller_name" => string_value(controller, [:name, "name"]) || controller_id,
             "base_url" => base_url,
             "api_token_secret_ref" => SecretRefs.network_credential_ref(secret_id),
             "credential_broker" => grant,
             "timeout_ms" => timeout_ms,
             "insecure_skip_verify" => metadata_bool(controller, "insecure_skip_verify", false)
           })
       }}
    end
  end

  defp grant_template(controller, opts) do
    issuer = Keyword.get(opts, :grant_template, &AwxClient.inventory_sync_grant_template/1)
    issuer.(controller)
  end

  defp package_sort_key(package) do
    {
      semver_sort_key(string_value(package, [:version, "version"])),
      timestamp_sort_key(raw_value(package, [:imported_at, "imported_at"])),
      timestamp_sort_key(raw_value(package, [:approved_at, "approved_at"])),
      timestamp_sort_key(raw_value(package, [:inserted_at, "inserted_at"]))
    }
  end

  defp semver_sort_key(version) when is_binary(version) do
    case Regex.run(~r/^v?(\d+)\.(\d+)\.(\d+)/, version) do
      [_match, major, minor, patch] ->
        {String.to_integer(major), String.to_integer(minor), String.to_integer(patch), version}

      _ ->
        {-1, -1, -1, version}
    end
  end

  defp semver_sort_key(_), do: {-1, -1, -1, ""}

  defp timestamp_sort_key(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)

  defp timestamp_sort_key(%NaiveDateTime{} = timestamp),
    do: NaiveDateTime.to_gregorian_seconds(timestamp)

  defp timestamp_sort_key(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> timestamp_sort_key(datetime)
      _ -> 0
    end
  end

  defp timestamp_sort_key(_), do: 0

  defp required_string(map, keys, label) do
    case string_value(map, keys) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_field, label}}
    end
  end

  defp metadata_int(map, key, default) do
    map
    |> metadata()
    |> ValueUtils.int_value([key, String.to_atom(key)], default)
  end

  defp metadata_bool(map, key, default) do
    case raw_value(metadata(map), [key, String.to_atom(key)]) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(String.trim(value)) in ~w(1 true yes on)
      _ -> default
    end
  end

  defp metadata(map), do: raw_value(map, [:metadata, "metadata"]) || %{}

  defp int_value(map, keys, default), do: ValueUtils.int_value(map, keys, default)

  defp string_value(map, keys) when is_map(map) do
    case raw_value(map, keys) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      nil ->
        nil

      value ->
        to_string(value)
    end
  end

  defp raw_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.get(map, key)
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end
end
