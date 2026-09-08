defmodule ServiceRadar.Edge.ProxmoxConsoleCompatibility do
  @moduledoc """
  Fail-closed compatibility gate for Proxmox console opens.

  Live evidence comes only from gateway-owned authenticated control-stream
  registry metadata. Persisted capability/config evidence comes from the
  canonical agent record. Both views must agree before a credential-bearing
  console frame can be sent.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent

  @required_capabilities [
    "plugin-host-authority:v1",
    "proxmox-semantic-connector:v1",
    "proxmox-identity:v3",
    "proxmox-console-policy-binding:v1"
  ]

  @doc false
  def required_capabilities, do: @required_capabilities

  def verify(session, policy_binding, control_evidence, opts \\ []) do
    agent_loader = Keyword.get(opts, :agent_loader, &load_agent/1)

    with {:ok, assignment_id} <- session_assignment_id(session),
         :ok <- require_control_identity(control_evidence, session.agent_id),
         :ok <- require_capabilities(control_evidence),
         :ok <- require_no_pending_config(control_evidence),
         {:ok, config_version} <- control_config_version(control_evidence),
         :ok <- require_exact_assignment_proof(control_evidence, assignment_id, policy_binding),
         {:ok, agent} <- agent_loader.(to_string(session.agent_id)),
         :ok <- require_agent_identity(agent, session.agent_id),
         :ok <- require_capabilities(agent),
         :ok <- require_config_ack(agent, config_version) do
      :ok
    else
      {:error, _reason} = error -> error
      _other -> {:error, :console_control_evidence_unavailable}
    end
  end

  defp load_agent(agent_id) do
    Agent.get_by_uid(agent_id,
      actor: SystemActor.system(:proxmox_console_compatibility)
    )
  end

  defp session_assignment_id(session) do
    case session |> map_value(:metadata) |> map_value("plugin_assignment_id") |> string_value() do
      nil -> {:error, :console_assignment_policy_binding_missing}
      assignment_id -> {:ok, assignment_id}
    end
  end

  defp require_capabilities(source) do
    capabilities =
      source
      |> map_value(:capabilities)
      |> List.wrap()
      |> Enum.flat_map(fn
        capability when is_binary(capability) ->
          case String.trim(capability) do
            "" -> []
            value -> [value]
          end

        _capability ->
          []
      end)
      |> MapSet.new()

    if Enum.all?(@required_capabilities, &MapSet.member?(capabilities, &1)) do
      :ok
    else
      {:error, :proxmox_console_upgrade_required}
    end
  end

  defp require_control_identity(control_evidence, expected_agent_id) do
    if control_evidence |> map_value(:agent_id) |> string_value() ==
         string_value(expected_agent_id) do
      :ok
    else
      {:error, :console_agent_identity_mismatch}
    end
  end

  defp require_no_pending_config(control_evidence) do
    pending = control_evidence |> map_value(:pending_config_version) |> string_value()

    case pending do
      nil -> :ok
      _version -> {:error, :console_config_ack_required}
    end
  end

  defp control_config_version(control_evidence) do
    version = control_evidence |> map_value(:config_version) |> string_value()

    case version do
      nil -> {:error, :console_config_ack_required}
      version -> {:ok, version}
    end
  end

  defp require_exact_assignment_proof(control_evidence, assignment_id, policy_binding) do
    expected_version = map_value(policy_binding, :version)
    expected_fingerprint = policy_binding |> map_value(:fingerprint) |> string_value()

    match? =
      control_evidence
      |> map_value(:applied_plugin_assignments)
      |> List.wrap()
      |> Enum.any?(fn proof ->
        string_value(map_value(proof, :assignment_id)) == assignment_id and
          string_value(map_value(proof, :plugin_id)) == "proxmox-console" and
          map_value(proof, :assignment_policy_version) == expected_version and
          string_value(map_value(proof, :assignment_policy_fingerprint)) ==
            expected_fingerprint
      end)

    if match?, do: :ok, else: {:error, :console_assignment_policy_binding_mismatch}
  end

  defp require_agent_identity(agent, expected_agent_id) do
    if string_value(map_value(agent, :uid)) == string_value(expected_agent_id) do
      :ok
    else
      {:error, :console_agent_identity_mismatch}
    end
  end

  defp require_config_ack(agent, config_version) do
    acked = agent |> map_value(:acked_config_version) |> string_value()
    pushed = agent |> map_value(:pushed_config_version) |> string_value()

    cond do
      acked != config_version ->
        {:error, :console_config_ack_required}

      pushed != config_version ->
        {:error, :console_config_ack_required}

      true ->
        :ok
    end
  end

  defp map_value(map, key) when is_map(map) do
    string_key = if is_atom(key), do: Atom.to_string(key), else: key
    atom_key = if is_binary(key), do: existing_atom(key), else: key

    Map.get(map, key) || Map.get(map, string_key) ||
      if(atom_key, do: Map.get(map, atom_key))
  end

  defp map_value(_map, _key), do: nil

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_value(nil), do: nil
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(_value), do: nil
end
