defmodule ServiceRadar.Inventory.ProxmoxSourceScopeResolver do
  @moduledoc """
  Resolves Proxmox inventory identity scope from authenticated control-plane state.

  Result-owned target metadata is never used as provenance. The only accepted
  chain is an assignment id stamped by the agent runtime, an enabled policy
  assignment for the exact Proxmox inventory package, and the immutable source
  UUIDs on the referenced network credential rule.
  """

  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.RuleAccessors
  alias ServiceRadar.Plugins.PluginAssignment

  require Ash.Query

  @plugin_id "proxmox-inventory"
  @policy_prefix "network-credential-rule:"
  @required_delivery_capabilities [
    "plugin-host-authority:v1",
    "proxmox-semantic-connector:v1",
    "proxmox-identity:v3"
  ]

  @spec resolve(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(payload, status, opts) when is_map(payload) and is_map(status) do
    actor = Keyword.fetch!(opts, :actor)
    assignment_loader = Keyword.get(opts, :assignment_loader, &load_assignment/2)
    rule_loader = Keyword.get(opts, :rule_loader, &load_rule/2)

    with {:ok, assignment_id} <- trusted_assignment_id(payload, status),
         {:ok, agent_id} <- authenticated_agent_id(status),
         {:ok, partition_id} <- authenticated_partition_id(status),
         :ok <- validate_delivery_capabilities(status),
         :ok <- validate_reported_plugin(payload, status),
         {:ok, assignment} <- assignment_loader.(assignment_id, actor) do
      resolve_assignment(assignment,
        actor: actor,
        agent_id: agent_id,
        partition_id: partition_id,
        assignment_id: assignment_id,
        plugin_id: @plugin_id,
        rule_loader: rule_loader
      )
    end
  end

  def resolve(_payload, _status, _opts), do: {:error, :invalid_proxmox_result_envelope}

  @doc """
  Resolve source scope from a loaded/current Proxmox inventory assignment.

  Callers must supply the agent identity they are generating configuration for.
  Package, policy, enabled-state, rule purpose, and immutable UUID checks are
  identical to result ingestion, while transport capability checks remain in
  `resolve/3`.
  """
  @spec resolve_assignment(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_assignment(assignment, opts) when is_map(assignment) and is_list(opts) do
    actor = Keyword.fetch!(opts, :actor)
    agent_id = Keyword.fetch!(opts, :agent_id)
    partition_id = Keyword.fetch!(opts, :partition_id)
    assignment_id = Keyword.get(opts, :assignment_id, field(assignment, :id))
    expected_plugin_id = Keyword.get(opts, :plugin_id, field(assignment, :plugin_id))
    rule_loader = Keyword.get(opts, :rule_loader, &load_rule/2)

    with {:ok, assignment_id} <- canonical_uuid(assignment_id),
         {:ok, contract} <- assignment_contract(expected_plugin_id, field(assignment, :policy_id)),
         :ok <-
           validate_assignment(
             assignment,
             assignment_id,
             agent_id,
             partition_id,
             contract.plugin_id
           ),
         rule_id = contract.rule_id,
         {:ok, rule} <- rule_loader.(rule_id, actor),
         :ok <- validate_rule(rule, rule_id, contract.purpose),
         {:ok, integration_id} <- canonical_uuid(field(rule, :integration_id)),
         {:ok, controller_id} <- canonical_uuid(field(rule, :controller_id)) do
      {:ok,
       %{
         integration_id: integration_id,
         controller_id: controller_id,
         partition_id: partition_id,
         assignment_id: assignment_id,
         credential_rule_id: rule_id
       }}
    end
  end

  def resolve_assignment(_assignment, _opts), do: {:error, :invalid_plugin_assignment}

  defp trusted_assignment_id(payload, status) do
    candidates =
      [
        field(status, :assignment_id),
        status |> labels() |> field(:assignment_id),
        payload |> labels() |> field(:assignment_id)
      ]
      |> Enum.filter(&present?/1)
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    case candidates do
      [assignment_id] -> canonical_uuid(assignment_id)
      [] -> {:error, :missing_trusted_assignment_id}
      _ -> {:error, :conflicting_trusted_assignment_ids}
    end
  end

  defp authenticated_agent_id(status) do
    case field(status, :agent_id) do
      agent_id when is_binary(agent_id) and agent_id != "" -> {:ok, String.trim(agent_id)}
      _ -> {:error, :missing_authenticated_agent_id}
    end
  end

  defp authenticated_partition_id(status) do
    case field(status, :partition) || field(status, :partition_id) do
      partition_id when is_binary(partition_id) and partition_id != "" ->
        {:ok, String.trim(partition_id)}

      _ ->
        {:error, :missing_authenticated_partition_id}
    end
  end

  defp validate_reported_plugin(payload, status) do
    reported =
      [
        field(status, :plugin_id),
        status |> labels() |> field(:plugin_id),
        payload |> labels() |> field(:plugin_id)
      ]
      |> Enum.filter(&present?/1)
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    case reported do
      [@plugin_id] -> :ok
      _ -> {:error, :proxmox_inventory_plugin_mismatch}
    end
  end

  defp validate_delivery_capabilities(status) do
    delivered =
      status
      |> field(:delivery_capabilities)
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    missing = Enum.reject(@required_delivery_capabilities, &MapSet.member?(delivered, &1))

    case missing do
      [] -> :ok
      missing -> {:error, {:missing_proxmox_identity_delivery_capabilities, missing}}
    end
  end

  defp validate_assignment(assignment, assignment_id, agent_id, partition_id, expected_plugin_id)
       when is_map(assignment) do
    package = field(assignment, :plugin_package)

    cond do
      canonical_uuid_value(field(assignment, :id)) != assignment_id ->
        {:error, :plugin_assignment_id_mismatch}

      field(assignment, :enabled) != true ->
        {:error, :plugin_assignment_disabled}

      field(assignment, :source) not in [:policy, "policy"] ->
        {:error, :plugin_assignment_not_policy_managed}

      field(assignment, :agent_uid) != agent_id ->
        {:error, :plugin_assignment_agent_mismatch}

      field(assignment, :partition_id) != partition_id ->
        {:error, :plugin_assignment_partition_mismatch}

      field(assignment, :plugin_id) != expected_plugin_id ->
        {:error, :plugin_assignment_plugin_mismatch}

      not is_map(package) ->
        {:error, :plugin_assignment_package_not_loaded}

      field(package, :plugin_id) != expected_plugin_id ->
        {:error, :plugin_assignment_package_mismatch}

      field(package, :status) not in [:approved, "approved"] ->
        {:error, :plugin_assignment_package_not_approved}

      assignment_policy_mismatch?(assignment) ->
        {:error, :plugin_assignment_policy_mismatch}

      true ->
        :ok
    end
  end

  defp validate_assignment(
         _assignment,
         _assignment_id,
         _agent_id,
         _partition_id,
         _expected_plugin_id
       ),
       do: {:error, :plugin_assignment_not_found}

  defp assignment_policy_mismatch?(assignment) do
    policy_id = field(assignment, :policy_id)

    case field(assignment, :params) do
      params when is_map(params) -> field(params, :policy_id) != policy_id
      _ -> true
    end
  end

  defp assignment_contract("proxmox-inventory", @policy_prefix <> rule_id) do
    with false <- String.contains?(rule_id, ":"),
         {:ok, rule_id} <- canonical_uuid(rule_id) do
      {:ok, %{plugin_id: "proxmox-inventory", purpose: :inventory_enrichment, rule_id: rule_id}}
    else
      _ -> {:error, :invalid_proxmox_inventory_policy_id}
    end
  end

  defp assignment_contract("proxmox-console", @policy_prefix <> policy_suffix) do
    with [rule_id, "console_access"] <- String.split(policy_suffix, ":"),
         {:ok, rule_id} <- canonical_uuid(rule_id) do
      {:ok, %{plugin_id: "proxmox-console", purpose: :console_access, rule_id: rule_id}}
    else
      _ -> {:error, :invalid_proxmox_console_policy_id}
    end
  end

  defp assignment_contract("proxmox-inventory", _policy_id),
    do: {:error, :invalid_proxmox_inventory_policy_id}

  defp assignment_contract("proxmox-console", _policy_id),
    do: {:error, :invalid_proxmox_console_policy_id}

  defp assignment_contract(_plugin_id, _policy_id),
    do: {:error, :unsupported_proxmox_assignment_plugin}

  defp validate_rule(rule, rule_id, purpose) when is_map(rule) do
    cond do
      canonical_uuid_value(field(rule, :id)) != rule_id ->
        {:error, :credential_rule_id_mismatch}

      field(rule, :enabled) != true ->
        {:error, :credential_rule_disabled}

      field(rule, :provider) != "proxmox" ->
        {:error, :credential_rule_provider_mismatch}

      Atom.to_string(purpose) not in RuleAccessors.rule_purposes(rule) ->
        {:error, :credential_rule_purpose_mismatch}

      true ->
        validate_rule_transport(rule, purpose)
    end
  end

  defp validate_rule(_rule, _rule_id, _purpose), do: {:error, :credential_rule_not_found}

  defp validate_rule_transport(rule, :inventory_enrichment) do
    case {field_string(rule, :auth_method), field_string(rule, :tls_policy)} do
      {"proxmox_api_token", "verify"} -> :ok
      {"proxmox_api_token", _tls_policy} -> {:error, :proxmox_tls_verification_required}
      {_auth_method, _tls_policy} -> {:error, :unsupported_proxmox_inventory_auth_method}
    end
  end

  defp validate_rule_transport(rule, :console_access) do
    case {
      field_string(rule, :auth_method),
      field_string(rule, :tls_policy),
      field_string(rule, :ssh_host_key_policy)
    } do
      {"proxmox_api_token", "verify", _ssh_policy} ->
        :ok

      {"proxmox_api_token", _tls_policy, _ssh_policy} ->
        {:error, :proxmox_tls_verification_required}

      {"ssh_private_key", _tls_policy, ssh_policy}
      when ssh_policy in ["known_hosts", "trust_on_first_use"] ->
        :ok

      {"ssh_private_key", _tls_policy, _ssh_policy} ->
        {:error, :proxmox_ssh_host_key_verification_required}

      {_auth_method, _tls_policy, _ssh_policy} ->
        {:error, :unsupported_proxmox_console_auth_method}
    end
  end

  defp validate_rule_transport(_rule, _purpose), do: {:error, :unsupported_proxmox_rule_purpose}

  defp load_assignment(assignment_id, actor) do
    PluginAssignment
    |> Ash.Query.filter(id == ^assignment_id)
    |> Ash.read_one(actor: actor, domain: ServiceRadar.Plugins)
    |> case do
      {:ok, %PluginAssignment{} = assignment} ->
        Ash.load(assignment, :plugin_package, actor: actor)

      {:ok, nil} ->
        {:error, :plugin_assignment_not_found}

      {:error, reason} ->
        {:error, {:plugin_assignment_lookup_failed, reason}}
    end
  end

  defp load_rule(rule_id, actor) do
    case NetworkCredentialRule.get_by_id(rule_id, actor: actor) do
      {:ok, %NetworkCredentialRule{} = rule} -> {:ok, rule}
      {:ok, nil} -> {:error, :credential_rule_not_found}
      {:error, reason} -> {:error, {:credential_rule_lookup_failed, reason}}
    end
  end

  defp labels(map) when is_map(map), do: field(map, :labels) || field(map, :label) || %{}
  defp labels(_map), do: %{}

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_map, _key), do: nil

  defp field_string(map, key) do
    case field(map, key) do
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) -> String.trim(value)
      _value -> nil
    end
  end

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid_uuid}

  defp canonical_uuid_value(value) do
    case canonical_uuid(value) do
      {:ok, uuid} -> uuid
      {:error, _reason} -> nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
