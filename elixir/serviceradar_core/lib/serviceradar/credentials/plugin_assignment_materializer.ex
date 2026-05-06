defmodule ServiceRadar.Credentials.PluginAssignmentMaterializer do
  @moduledoc """
  Materializes network credential rules into policy-derived plugin assignments.

  Credential rules own the API-key and scope decisions. This module translates
  matching rules into the existing SRQL plugin targeting path so edge agents get
  normal `serviceradar.plugin_inputs.v1` assignments without plugin-specific
  host lists.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PolicyAssignmentReconciler
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @proxmox_provider "proxmox"
  @proxmox_plugin_id "proxmox-inventory"
  @inventory_purpose :inventory_enrichment

  @doc """
  Reconciles enabled Proxmox inventory credential rules that are in scope for an agent.
  """
  @spec reconcile_proxmox_inventory_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_proxmox_inventory_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:proxmox_credential_materializer))

    with {:ok, rules} <- rules_for_agent_scope(agent_id, actor, opts) do
      case rules do
        [] ->
          {:ok, empty_summary()}

        _ ->
          with {:ok, package} <- approved_plugin_package(@proxmox_plugin_id, actor, opts) do
            reconcile_rules(rules, agent_id, package, Keyword.put(opts, :actor, actor))
          end
      end
    end
  end

  @doc """
  Reconciles already-loaded credential rules.

  This is public so workers/tests can inject a package and avoid a database round
  trip when the surrounding orchestration already has the records loaded.
  """
  @spec reconcile_rules([map()], String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_rules(rules, agent_id, package, opts \\ [])
      when is_list(rules) and is_binary(agent_id) and is_map(package) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_rule_reconcile))
    reconciler = Keyword.get(opts, :reconciler, PolicyAssignmentReconciler)

    Enum.reduce_while(rules, {:ok, empty_summary()}, fn rule, {:ok, acc} ->
      case reconcile_rule(rule, agent_id, package, actor, reconciler, opts) do
        {:ok, result} ->
          {:cont, {:ok, merge_summary(acc, result)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_rule(rule, _agent_id, package, actor, reconciler, opts) do
    with {:ok, policy} <- policy_for_rule(rule, package),
         {:ok, input_defs} <- input_defs_for_rule(rule) do
      reconcile_opts =
        opts
        |> Keyword.put(:actor, actor)
        |> Keyword.put(:chunk_size, metadata_int(rule, "chunk_size", 100))

      reconciler.reconcile(policy, input_defs, reconcile_opts)
    end
  end

  defp policy_for_rule(rule, package) do
    with {:ok, rule_id} <- required_string(rule, [:id, "id"], "id"),
         {:ok, secret_id} <- required_string(rule, [:secret_id, "secret_id"], "secret_id"),
         {:ok, package_id} <- required_string(package, [:id, "id"], "plugin package id") do
      {:ok,
       %{
         policy_id: "network-credential-rule:#{rule_id}",
         policy_version: rule_version(rule),
         plugin_package_id: package_id,
         params_template: proxmox_params_template(rule, secret_id),
         enabled: rule_enabled?(rule),
         interval_seconds: metadata_int(rule, "interval_seconds", 300),
         timeout_seconds: metadata_int(rule, "timeout_seconds", 30)
       }}
    end
  end

  defp input_defs_for_rule(rule) do
    with {:ok, query} <- required_string(rule, [:target_query, "target_query"], "target_query") do
      {:ok, [%{name: "targets", entity: "devices", query: query}]}
    end
  end

  defp proxmox_params_template(rule, secret_id) do
    %{
      "api_token_secret_ref" => SecretRefs.network_credential_ref(secret_id),
      "include_guests" => metadata_bool(rule, "include_guests", true),
      "timeout_ms" => metadata_int(rule, "timeout_ms", 30_000),
      "insecure_skip_verify" => tls_policy(rule) == :skip_verify,
      "credential_rule_id" => value_string(rule, [:id, "id"]),
      "credential_secret_id" => secret_id
    }
  end

  defp rules_for_agent_scope(agent_id, actor, opts) do
    case Keyword.fetch(opts, :rules) do
      {:ok, rules} ->
        {:ok, rules}

      :error ->
        scopes = agent_scopes(agent_id, actor)

        scopes
        |> Enum.reduce_while({:ok, []}, fn {scope_type, scope_value}, {:ok, acc} ->
          case NetworkCredentialRule.list_enabled_for_scope(
                 @proxmox_provider,
                 scope_type,
                 scope_value,
                 actor: actor
               ) do
            {:ok, rules} -> {:cont, {:ok, acc ++ Enum.filter(rules, &inventory_rule?/1)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, rules} -> {:ok, Enum.uniq_by(rules, &value_string(&1, [:id, "id"]))}
          error -> error
        end
    end
  end

  defp approved_plugin_package(plugin_id, actor, opts) do
    case Keyword.fetch(opts, :plugin_package) do
      {:ok, package} ->
        {:ok, package}

      :error ->
        PluginPackage
        |> Ash.Query.for_read(:approved, %{}, actor: actor)
        |> Ash.Query.filter(plugin_id == ^plugin_id)
        |> Ash.Query.sort(approved_at: :desc, inserted_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read_one(actor: actor)
        |> case do
          {:ok, %PluginPackage{} = package} ->
            {:ok, package}

          {:ok, nil} ->
            {:error, {:plugin_package_not_found, plugin_id}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp agent_scopes(agent_id, actor) do
    agent = load_agent(agent_id, actor)

    [
      {:agent, agent_id},
      {:gateway, agent && value_string(agent, [:gateway_id, "gateway_id"])},
      {:partition, agent_partition(agent_id, agent)}
    ]
    |> Enum.reject(fn {_type, value} -> ValueUtils.blank_string?(value) end)
    |> Enum.uniq()
  end

  defp load_agent(agent_id, actor) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %Agent{} = agent} -> agent
      _ -> nil
    end
  end

  defp agent_partition(agent_id, agent) do
    registry_partition(agent_id) || metadata_value(agent, "partition_id")
  end

  defp registry_partition(agent_id) do
    agent_id
    |> AgentRegistry.lookup()
    |> Enum.find_value(fn {_pid, metadata} -> metadata_value(metadata, "partition_id") end)
  end

  defp inventory_rule?(rule), do: rule_purpose(rule) == @inventory_purpose

  defp rule_purpose(rule) do
    case value_string(rule, [:purpose, "purpose"]) do
      "inventory_enrichment" -> :inventory_enrichment
      "discovery" -> :discovery
      "console_access" -> :console_access
      "generic" -> :generic
      _ -> @inventory_purpose
    end
  end

  defp rule_enabled?(rule) do
    case ValueUtils.raw_value(rule, [:enabled, "enabled"]) do
      value when is_boolean(value) -> value
      _ -> true
    end
  end

  defp rule_version(rule) do
    timestamp =
      ValueUtils.raw_value(rule, [:updated_at, "updated_at"]) ||
        ValueUtils.raw_value(rule, [:inserted_at, "inserted_at"])

    case timestamp do
      %DateTime{} -> max(DateTime.to_unix(timestamp, :second), 1)
      _ -> 1
    end
  end

  defp tls_policy(rule) do
    case value_string(rule, [:tls_policy, "tls_policy"]) do
      "skip_verify" -> :skip_verify
      _ -> :verify
    end
  end

  defp metadata_int(rule, key, default) do
    rule
    |> metadata()
    |> ValueUtils.int_value([key, metadata_atom_key(key)], default)
  end

  defp metadata_bool(rule, key, default) do
    metadata = metadata(rule)

    cond do
      is_boolean(Map.get(metadata, key)) ->
        Map.get(metadata, key)

      is_boolean(Map.get(metadata, metadata_atom_key(key))) ->
        Map.get(metadata, metadata_atom_key(key))

      true ->
        default
    end
  end

  defp metadata(rule) do
    ValueUtils.map_value(rule, [:metadata, "metadata"], stringify_keys: true) || %{}
  end

  defp metadata_value(nil, _key), do: nil

  defp metadata_value(map, key) when is_map(map) do
    map
    |> ValueUtils.raw_value([key, metadata_atom_key(key)])
    |> case do
      nil -> nil
      value when is_binary(value) -> String.trim(value)
      value -> to_string(value)
    end
  end

  defp metadata_atom_key("chunk_size"), do: :chunk_size
  defp metadata_atom_key("gateway_id"), do: :gateway_id
  defp metadata_atom_key("include_guests"), do: :include_guests
  defp metadata_atom_key("interval_seconds"), do: :interval_seconds
  defp metadata_atom_key("partition_id"), do: :partition_id
  defp metadata_atom_key("timeout_ms"), do: :timeout_ms
  defp metadata_atom_key("timeout_seconds"), do: :timeout_seconds

  defp value_string(map, keys), do: ValueUtils.string_value(map, keys)

  defp required_string(map, keys, label) do
    case value_string(map, keys) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_field, label}}
    end
  end

  defp empty_summary do
    %{
      rules: 0,
      resolved_inputs: 0,
      desired_assignments: 0,
      upserted: 0,
      unchanged: 0,
      disabled: 0
    }
  end

  defp merge_summary(acc, result) do
    %{
      rules: acc.rules + 1,
      resolved_inputs: acc.resolved_inputs + Map.get(result, :resolved_inputs, 0),
      desired_assignments: acc.desired_assignments + Map.get(result, :desired_assignments, 0),
      upserted: acc.upserted + Map.get(result, :upserted, 0),
      unchanged: acc.unchanged + Map.get(result, :unchanged, 0),
      disabled: acc.disabled + Map.get(result, :disabled, 0)
    }
  end
end
