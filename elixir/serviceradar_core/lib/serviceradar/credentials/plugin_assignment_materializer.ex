defmodule ServiceRadar.Credentials.PluginAssignmentMaterializer do
  @moduledoc """
  Materializes network credential rules into policy-derived plugin assignments.

  Credential rules own the API-key and scope decisions. This module translates
  matching rules into the existing SRQL plugin targeting path so edge agents get
  normal `serviceradar.plugin_inputs.v1` assignments without plugin-specific
  host lists.

  The module is parameterized over a
  `ServiceRadar.Credentials.CredentialProviderProfile`, which supplies the
  provider-specific constants (provider string, plugin ids, purposes), the
  credential-broker grant spec, and the stored params template. Proxmox flows
  through `ProxmoxProfile` via thin shims so its output stays byte-identical to
  the previous Proxmox-only implementation; camera providers (unifi-protect,
  axis) flow through the same generic path.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialProviderProfile
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.ProviderProfiles.ProxmoxProfile
  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.PolicyAssignmentReconciler
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @inventory_purpose :inventory_enrichment

  @doc """
  Reconciles enabled Proxmox inventory credential rules that are in scope for an agent.
  """
  @spec reconcile_proxmox_inventory_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_proxmox_inventory_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    reconcile_provider_for_agent(ProxmoxProfile, agent_id, :inventory_enrichment, opts)
  end

  @doc """
  Reconciles enabled Proxmox console credential rules that are in scope for an agent.
  """
  @spec reconcile_proxmox_console_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_proxmox_console_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    reconcile_provider_for_agent(ProxmoxProfile, agent_id, :console_access, opts)
  end

  @doc """
  Reconciles enabled camera inventory credential rules (unifi-protect + axis) in scope for an agent.
  """
  @spec reconcile_camera_inventory_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_camera_inventory_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    reconcile_camera_for_agent(agent_id, :camera_inventory, opts)
  end

  @doc """
  Reconciles enabled camera stream credential rules (unifi-protect + axis) in scope for an agent.
  """
  @spec reconcile_camera_stream_for_agent(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_camera_stream_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    reconcile_camera_for_agent(agent_id, :camera_stream, opts)
  end

  defp reconcile_camera_for_agent(agent_id, purpose, opts) do
    Enum.reduce_while(
      CredentialProviderProfile.camera_profiles(),
      {:ok, empty_summary()},
      fn profile, {:ok, acc} ->
        case reconcile_provider_for_agent(profile, agent_id, purpose, opts) do
          {:ok, summary} -> {:cont, {:ok, add_summaries(acc, summary)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  @doc """
  Reconciles enabled credential rules for a provider profile + purpose in scope for an agent.
  """
  @spec reconcile_provider_for_agent(module(), String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_provider_for_agent(profile, agent_id, purpose, opts \\ [])
      when is_atom(profile) and is_binary(agent_id) and is_atom(purpose) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:credential_materializer))

    with {:ok, rules} <- rules_for_agent_scope(profile, agent_id, purpose, actor, opts) do
      case rules do
        [] ->
          {:ok, empty_summary()}

        _ ->
          with {:ok, package} <-
                 approved_plugin_package(profile.plugin_id(purpose), actor, opts) do
            opts =
              opts
              |> Keyword.put(:actor, actor)
              |> Keyword.put(:purpose, purpose)
              |> Keyword.put(:profile, profile)

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
    profile = Keyword.get(opts, :profile, ProxmoxProfile)
    purpose = Keyword.get(opts, :purpose, @inventory_purpose)

    with {:ok, selected_rules} <- selected_rules_for_agent(profile, rules, agent_id, purpose) do
      Enum.reduce_while(selected_rules, {:ok, empty_summary()}, fn rule, {:ok, acc} ->
        case reconcile_rule(profile, rule, agent_id, package, purpose, actor, reconciler, opts) do
          {:ok, result} ->
            {:cont, {:ok, merge_summary(acc, result)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp reconcile_rule(profile, rule, agent_id, package, purpose, actor, reconciler, opts) do
    with {:ok, policy} <- policy_for_rule(profile, rule, package, purpose, agent_id, actor, opts),
         {:ok, input_defs} <- input_defs_for_rule(rule, purpose) do
      reconcile_opts =
        opts
        |> Keyword.put(:actor, actor)
        |> Keyword.put(:chunk_size, metadata_int(rule, "chunk_size", 100))
        |> Keyword.put(:target_agent_uid, agent_id)

      reconciler.reconcile(policy, input_defs, reconcile_opts)
    end
  end

  defp policy_for_rule(profile, rule, package, purpose, agent_id, actor, opts) do
    with {:ok, rule_id} <- required_string(rule, [:id, "id"], "id"),
         {:ok, secret_id} <- required_string(rule, [:secret_id, "secret_id"], "secret_id"),
         {:ok, package_id} <- required_string(package, [:id, "id"], "plugin package id"),
         {:ok, params_template} <-
           build_params_template(profile, rule, secret_id, purpose, agent_id, actor, opts) do
      {:ok,
       %{
         policy_id: policy_id_for_rule(rule_id, purpose),
         policy_version: rule_version(rule),
         plugin_package_id: package_id,
         params_template: params_template,
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

  # Issues the credential-broker grant for the profile/purpose, resolves the
  # public (non-secret) username when the profile requires it, then delegates to
  # the profile to build the stored params template embedding the grant payload.
  defp build_params_template(profile, rule, secret_id, purpose, agent_id, actor, opts) do
    {grant_attrs, extras} = profile.grant_spec(purpose, rule, secret_id, agent_id)

    with {:ok, grant} <- issue_grant(grant_attrs, actor, opts, extras),
         {:ok, username} <-
           maybe_resolve_username(profile, purpose, rule, secret_id, actor, opts) do
      ctx = %{
        grant: grant,
        secret_ref: SecretRefs.network_credential_ref(secret_id),
        username: username
      }

      profile.params_template(purpose, rule, secret_id, ctx)
    end
  end

  defp maybe_resolve_username(profile, purpose, rule, secret_id, actor, opts) do
    if profile.resolve_username?(purpose, rule) do
      resolver = Keyword.get(opts, :username_resolver, &default_username_resolver/2)
      resolver.(secret_id, actor)
    else
      {:ok, nil}
    end
  end

  defp default_username_resolver(secret_id, actor) do
    case NetworkCredentialSecret.get_by_id(secret_id, actor: actor) do
      {:ok, nil} -> {:ok, nil}
      {:ok, secret} -> {:ok, value_string(secret, [:username, "username"])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_grant(attrs, actor, opts, extras) do
    issuer = Keyword.get(opts, :grant_issuer, default_grant_issuer(actor))

    case issuer.(attrs) do
      {:ok, %{} = grant} -> {:ok, CredentialBrokerGrant.to_payload(grant, extras)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_credential_broker_grant_issuer_result, other}}
    end
  end

  defp default_grant_issuer(actor) do
    if SystemActor.system_actor?(actor) do
      &issue_persisted_grant(&1, actor)
    else
      &issue_ephemeral_test_grant/1
    end
  end

  defp issue_persisted_grant(attrs, actor) do
    attrs
    |> CredentialBrokerGrant.issue_attrs()
    |> CredentialBrokerGrant.issue_grant(actor: actor)
  end

  defp issue_ephemeral_test_grant(attrs) do
    grant =
      attrs
      |> CredentialBrokerGrant.issue_attrs()
      |> Map.put(:id, "test-grant-#{System.unique_integer([:positive])}")

    {:ok, grant}
  end

  defp rules_for_agent_scope(profile, agent_id, purpose, actor, opts) do
    case Keyword.fetch(opts, :rules) do
      {:ok, rules} ->
        {:ok, Enum.filter(rules, &profile.rule_has_purpose?(&1, purpose))}

      :error ->
        scopes = agent_scopes(agent_id, actor)

        scopes
        |> Enum.reduce_while({:ok, []}, fn {scope_type, scope_value}, {:ok, acc} ->
          case NetworkCredentialRule.list_enabled_for_scope(
                 profile.provider(),
                 scope_type,
                 scope_value,
                 actor: actor
               ) do
            {:ok, rules} ->
              {:cont, {:ok, acc ++ Enum.filter(rules, &profile.rule_has_purpose?(&1, purpose))}}

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

  defp selected_rules_for_agent(profile, rules, agent_id, purpose) do
    rules
    |> Enum.filter(
      &(profile.rule_has_purpose?(&1, purpose) and rule_enabled?(&1) and
          scope_allows_agent?(&1, agent_id))
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

  defp timestamp_sort_key(%NaiveDateTime{} = timestamp),
    do: NaiveDateTime.to_gregorian_seconds(timestamp)

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

  defp policy_id_for_rule(rule_id, @inventory_purpose), do: "network-credential-rule:#{rule_id}"
  defp policy_id_for_rule(rule_id, purpose), do: "network-credential-rule:#{rule_id}:#{purpose}"

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

  defp metadata_int(rule, key, default) do
    RuleAccessors.metadata_int(rule, key, default)
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

  defp metadata_atom_key("gateway_id"), do: :gateway_id
  defp metadata_atom_key("partition_id"), do: :partition_id

  defp value_string(map, keys), do: RuleAccessors.value_string(map, keys)

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

  defp add_summaries(acc, summary) do
    %{
      rules: acc.rules + Map.get(summary, :rules, 0),
      resolved_inputs: acc.resolved_inputs + Map.get(summary, :resolved_inputs, 0),
      desired_assignments: acc.desired_assignments + Map.get(summary, :desired_assignments, 0),
      upserted: acc.upserted + Map.get(summary, :upserted, 0),
      unchanged: acc.unchanged + Map.get(summary, :unchanged, 0),
      disabled: acc.disabled + Map.get(summary, :disabled, 0)
    }
  end
end
