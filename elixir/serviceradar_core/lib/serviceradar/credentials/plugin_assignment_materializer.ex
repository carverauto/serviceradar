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
  @proxmox_inventory_plugin_id "proxmox-inventory"
  @proxmox_console_plugin_id "proxmox-console"
  @inventory_purpose :inventory_enrichment
  @console_purpose :console_access

  @doc """
  Reconciles enabled Proxmox inventory credential rules that are in scope for an agent.
  """
  @spec reconcile_proxmox_inventory_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_proxmox_inventory_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    reconcile_proxmox_for_agent(agent_id, @inventory_purpose, @proxmox_inventory_plugin_id, opts)
  end

  @doc """
  Reconciles enabled Proxmox console credential rules that are in scope for an agent.
  """
  @spec reconcile_proxmox_console_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_proxmox_console_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    reconcile_proxmox_for_agent(agent_id, @console_purpose, @proxmox_console_plugin_id, opts)
  end

  defp reconcile_proxmox_for_agent(agent_id, purpose, plugin_id, opts) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:proxmox_credential_materializer))

    with {:ok, rules} <- rules_for_agent_scope(agent_id, purpose, actor, opts) do
      case rules do
        [] ->
          {:ok, empty_summary()}

        _ ->
          with {:ok, package} <- approved_plugin_package(plugin_id, actor, opts) do
            opts =
              opts
              |> Keyword.put(:actor, actor)
              |> Keyword.put(:purpose, purpose)

            reconcile_rules(rules, agent_id, package, opts)
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
    purpose = Keyword.get(opts, :purpose, @inventory_purpose)

    with {:ok, selected_rules} <- selected_rules_for_agent(rules, agent_id, purpose) do
      Enum.reduce_while(selected_rules, {:ok, empty_summary()}, fn rule, {:ok, acc} ->
        case reconcile_rule(rule, agent_id, package, purpose, actor, reconciler, opts) do
          {:ok, result} ->
            {:cont, {:ok, merge_summary(acc, result)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp reconcile_rule(rule, agent_id, package, purpose, actor, reconciler, opts) do
    with {:ok, policy} <- policy_for_rule(rule, package, purpose),
         {:ok, input_defs} <- input_defs_for_rule(rule, purpose) do
      reconcile_opts =
        opts
        |> Keyword.put(:actor, actor)
        |> Keyword.put(:chunk_size, metadata_int(rule, "chunk_size", 100))
        |> Keyword.put(:target_agent_uid, agent_id)

      reconciler.reconcile(policy, input_defs, reconcile_opts)
    end
  end

  defp policy_for_rule(rule, package, purpose) do
    with {:ok, rule_id} <- required_string(rule, [:id, "id"], "id"),
         {:ok, secret_id} <- required_string(rule, [:secret_id, "secret_id"], "secret_id"),
         {:ok, package_id} <- required_string(package, [:id, "id"], "plugin package id") do
      {:ok,
       %{
         policy_id: policy_id_for_rule(rule_id, purpose),
         policy_version: rule_version(rule),
         plugin_package_id: package_id,
         params_template: proxmox_params_template(rule, secret_id, purpose),
         enabled: rule_enabled?(rule),
         interval_seconds: metadata_int(rule, "interval_seconds", 300),
         timeout_seconds: metadata_int(rule, "timeout_seconds", 30)
       }}
    end
  end

  defp input_defs_for_rule(rule, _purpose) do
    with {:ok, query} <- required_string(rule, [:target_query, "target_query"], "target_query") do
      {:ok, [%{name: "targets", entity: "devices", query: query}]}
    end
  end

  defp proxmox_params_template(rule, secret_id, @inventory_purpose) do
    %{
      "credential_broker" => proxmox_inventory_credential_broker_grant(rule, secret_id),
      "api_token_secret_ref" => SecretRefs.network_credential_ref(secret_id),
      "include_guests" => metadata_bool(rule, "include_guests", true),
      "timeout_ms" => metadata_int(rule, "timeout_ms", 30_000),
      "insecure_skip_verify" => tls_policy(rule) == :skip_verify,
      "auto_discovery_enabled" => metadata_bool(rule, "auto_discovery_enabled", false),
      "credential_rule_id" => value_string(rule, [:id, "id"])
    }
  end

  defp proxmox_params_template(rule, secret_id, @console_purpose) do
    params = %{
      "credential_broker" => proxmox_console_credential_broker_grant(rule, secret_id),
      "timeout_ms" => metadata_int(rule, "timeout_ms", 30_000),
      "insecure_skip_verify" => tls_policy(rule) == :skip_verify,
      "ssh_host_key_policy" => ssh_host_key_policy(rule),
      "credential_rule_id" => value_string(rule, [:id, "id"])
    }

    if auth_method(rule) == "proxmox_api_token" do
      Map.put(params, "api_token_secret_ref", SecretRefs.network_credential_ref(secret_id))
    else
      Map.put(params, "credential_secret", SecretRefs.network_credential_ref(secret_id))
    end
  end

  defp proxmox_params_template(rule, secret_id, _purpose),
    do: proxmox_params_template(rule, secret_id, @inventory_purpose)

  defp proxmox_inventory_credential_broker_grant(rule, secret_id) do
    %{
      "schema" => "serviceradar.edge_credential_broker_grant.v1",
      "grant_type" => "proxmox_api_token",
      "credential_secret_ref" => SecretRefs.network_credential_ref(secret_id),
      "credential_rule_id" => value_string(rule, [:id, "id"]),
      "inject" => %{
        "header" => "Authorization",
        "scheme" => "PVEAPIToken"
      },
      "allow" => %{
        "methods" => ["GET"],
        "paths" => [
          "/api2/json/version",
          "/api2/json/cluster/status",
          "/api2/json/nodes",
          "/api2/json/nodes/*",
          "/api2/json/cluster/resources"
        ]
      },
      "ttl_seconds" => metadata_int(rule, "credential_broker_ttl_seconds", 300)
    }
  end

  defp proxmox_console_credential_broker_grant(rule, secret_id) do
    %{
      "schema" => "serviceradar.edge_credential_broker_grant.v1",
      "grant_type" => "proxmox_console",
      "auth_method" => auth_method(rule),
      "credential_secret_ref" => SecretRefs.network_credential_ref(secret_id),
      "credential_rule_id" => value_string(rule, [:id, "id"]),
      "ttl_seconds" => metadata_int(rule, "credential_broker_ttl_seconds", 300)
    }
  end

  defp rules_for_agent_scope(agent_id, purpose, actor, opts) do
    case Keyword.fetch(opts, :rules) do
      {:ok, rules} ->
        {:ok, Enum.filter(rules, &rule_has_purpose?(&1, purpose))}

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
            {:ok, rules} ->
              {:cont, {:ok, acc ++ Enum.filter(rules, &rule_has_purpose?(&1, purpose))}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, rules} -> {:ok, Enum.uniq_by(rules, &value_string(&1, [:id, "id"]))}
          error -> error
        end
    end
  end

  defp selected_rules_for_agent(rules, agent_id, purpose) do
    rules
    |> Enum.filter(
      &(rule_has_purpose?(&1, purpose) and rule_enabled?(&1) and scope_allows_agent?(&1, agent_id))
    )
    |> Enum.sort_by(&{rule_priority(&1), value_string(&1, [:inserted_at, "inserted_at"]) || ""})
    |> collapse_by_target_query()
  end

  defp collapse_by_target_query(rules) do
    rules
    |> Enum.group_by(&value_string(&1, [:target_query, "target_query"]))
    |> Enum.reduce_while({:ok, []}, fn
      {nil, grouped}, {:ok, acc} ->
        {:cont, {:ok, acc ++ grouped}}

      {query, grouped}, {:ok, acc} ->
        case selected_rule_for_query(query, grouped) do
          {:ok, rule} -> {:cont, {:ok, acc ++ [rule]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp selected_rule_for_query(query, [winner | _] = rules) do
    priority = rule_priority(winner)
    equal_priority = Enum.filter(rules, &(rule_priority(&1) == priority))

    if length(equal_priority) > 1 do
      {:error, {:equal_priority_credential_rule_conflict, query, priority}}
    else
      {:ok, winner}
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
        |> Ash.read(actor: actor)
        |> case do
          {:ok, packages} when is_list(packages) and packages != [] ->
            package = Enum.max_by(packages, &package_sort_key/1)
            {:ok, package}

          {:ok, []} ->
            {:error, {:plugin_package_not_found, plugin_id}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp package_sort_key(package) do
    {
      semver_sort_key(value_string(package, [:version, "version"])),
      timestamp_sort_key(ValueUtils.raw_value(package, [:imported_at, "imported_at"])),
      timestamp_sort_key(ValueUtils.raw_value(package, [:approved_at, "approved_at"])),
      timestamp_sort_key(ValueUtils.raw_value(package, [:inserted_at, "inserted_at"]))
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

  defp semver_sort_key(_version), do: {-1, -1, -1, ""}

  defp timestamp_sort_key(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)
  defp timestamp_sort_key(%NaiveDateTime{} = timestamp), do: NaiveDateTime.to_gregorian_seconds(timestamp)

  defp timestamp_sort_key(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> timestamp_sort_key(datetime)
      _ -> 0
    end
  end

  defp timestamp_sort_key(_timestamp), do: 0

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

  defp rule_purpose(rule) do
    case value_string(rule, [:purpose, "purpose"]) do
      "inventory_enrichment" -> :inventory_enrichment
      "discovery" -> :discovery
      "console_access" -> :console_access
      "generic" -> :generic
      _ -> @inventory_purpose
    end
  end

  defp rule_has_purpose?(rule, purpose) do
    purpose_string = Atom.to_string(purpose)

    rule
    |> rule_purposes()
    |> Enum.member?(purpose_string)
    |> case do
      true ->
        true

      false ->
        purpose == @console_purpose and rule_purpose(rule) == @inventory_purpose and
          auth_method(rule) == "proxmox_api_token"
    end
  end

  defp rule_purposes(rule) do
    metadata_purposes =
      rule
      |> metadata()
      |> ValueUtils.list_value(["purposes", :purposes])
      |> nil_to_empty_list()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    if metadata_purposes == [] do
      [Atom.to_string(rule_purpose(rule))]
    else
      metadata_purposes
    end
  end

  defp nil_to_empty_list(nil), do: []
  defp nil_to_empty_list(value), do: value

  defp policy_id_for_rule(rule_id, @inventory_purpose), do: "network-credential-rule:#{rule_id}"
  defp policy_id_for_rule(rule_id, purpose), do: "network-credential-rule:#{rule_id}:#{purpose}"

  defp auth_method(rule) do
    case value_string(rule, [:auth_method, "auth_method"]) do
      "ssh_private_key" -> "ssh_private_key"
      "username_password" -> "username_password"
      "certificate" -> "certificate"
      "opaque" -> "opaque"
      _ -> "proxmox_api_token"
    end
  end

  defp ssh_host_key_policy(rule) do
    case value_string(rule, [:ssh_host_key_policy, "ssh_host_key_policy"]) do
      "trust_on_first_use" -> "trust_on_first_use"
      "skip_verify" -> "skip_verify"
      _ -> "known_hosts"
    end
  end

  defp rule_enabled?(rule) do
    case raw_rule_value(rule, [:enabled, "enabled"]) do
      value when is_boolean(value) -> value
      _ -> true
    end
  end

  defp scope_allows_agent?(rule, agent_id) do
    case {raw_rule_value(rule, [:scope_type, "scope_type"]),
          value_string(rule, [:scope_value, "scope_value"])} do
      {scope, value} when scope in [:agent, "agent"] -> value in [nil, "", agent_id]
      _ -> true
    end
  end

  defp rule_priority(rule) do
    ValueUtils.int_value(rule, [:priority, "priority"], 100)
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
  defp metadata_atom_key("auto_discovery_enabled"), do: :auto_discovery_enabled
  defp metadata_atom_key("gateway_id"), do: :gateway_id
  defp metadata_atom_key("include_guests"), do: :include_guests
  defp metadata_atom_key("interval_seconds"), do: :interval_seconds
  defp metadata_atom_key("partition_id"), do: :partition_id
  defp metadata_atom_key("credential_broker_ttl_seconds"), do: :credential_broker_ttl_seconds
  defp metadata_atom_key("timeout_ms"), do: :timeout_ms
  defp metadata_atom_key("timeout_seconds"), do: :timeout_seconds

  defp value_string(map, keys), do: ValueUtils.string_value(map, keys)

  defp raw_rule_value(map, keys) when is_map(map) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      if Map.has_key?(map, key) do
        {:halt, Map.get(map, key)}
      else
        {:cont, nil}
      end
    end)
  end

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
