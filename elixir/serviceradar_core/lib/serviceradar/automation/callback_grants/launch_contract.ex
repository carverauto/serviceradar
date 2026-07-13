defmodule ServiceRadar.Automation.CallbackGrants.LaunchContract do
  @moduledoc """
  Validates the immutable, reviewed callback contract pinned to an AWX binding.

  Callback launch metadata is never accepted from a survey, ordinary launch
  input, or browser-selected extra variable. It lives in the immutable
  `review_metadata` of a versioned `AwxTemplateBinding` and is intersected with
  the source-controlled action registry before a grant can be prepared.

  The shape is intentionally action-neutral. The first registered action uses
  the common phase/operation/state request envelope, while future actions must
  first be added to the source-controlled registry and then pin their exact
  schemas and deployment maximum here.
  """

  alias ServiceRadar.Automation.CallbackGrants.ActionContract

  @schema "serviceradar.automation_callback_launch_contract/v1"
  @callback_slot "ssh_ca_callback"
  @sha256_hex ~r/\A[0-9a-f]{64}\z/
  @contract_keys MapSet.new([
                   "schema",
                   "action",
                   "action_version",
                   "request_schema",
                   "response_schema",
                   "manifest_sha256",
                   "phase",
                   "operation",
                   "state",
                   "policy_version",
                   "ttl_seconds"
                 ])

  @type t :: %{
          action: String.t(),
          action_version: String.t(),
          request_schema: String.t(),
          response_schema: String.t(),
          manifest_sha256: String.t(),
          phase: String.t(),
          operation: String.t(),
          state: String.t(),
          policy_version: String.t(),
          ttl_seconds: pos_integer()
        }

  @doc "Returns the exact reviewed callback contract for one immutable binding."
  @spec from_binding(map() | struct()) :: {:ok, t()} | {:error, term()}
  def from_binding(binding) when is_map(binding) do
    review_metadata = value(binding, :review_metadata)
    callback_actions = List.wrap(value(binding, :callback_actions))

    with {:ok, raw_contract} <- reviewed_contract(review_metadata),
         {:ok, contract} <- exact_string_map(raw_contract),
         true <- contract["schema"] == @schema || {:error, :invalid_callback_contract_schema},
         {:ok, action_contract} <- ActionContract.fetch(contract["action"]),
         :ok <- exact_action_version(contract, action_contract),
         :ok <- exact_schemas(contract, action_contract),
         :ok <- exact_binding_action(callback_actions, action_contract.action),
         :ok <- exact_credential_prompt(binding),
         :ok <- exact_credential_slot(binding),
         :ok <- valid_manifest(contract["manifest_sha256"]),
         :ok <- exact_policy_version(review_metadata, contract["policy_version"]),
         :ok <- bounded_ttl(contract["ttl_seconds"], action_contract.max_ttl_seconds),
         :ok <- deployment_maximum(contract, action_contract) do
      {:ok,
       %{
         action: action_contract.action,
         action_version: action_contract.version,
         request_schema: contract["request_schema"],
         response_schema: contract["response_schema"],
         manifest_sha256: contract["manifest_sha256"],
         phase: contract["phase"],
         operation: contract["operation"],
         state: contract["state"],
         policy_version: contract["policy_version"],
         ttl_seconds: contract["ttl_seconds"]
       }}
    else
      false -> {:error, :invalid_callback_launch_contract}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_callback_launch_contract}
    end
  end

  def from_binding(_binding), do: {:error, :callback_launch_contract_required}

  defp reviewed_contract(metadata) when is_map(metadata) do
    case value(metadata, :callback_contract) do
      contract when is_map(contract) -> {:ok, contract}
      _ -> {:error, :callback_launch_contract_required}
    end
  end

  defp reviewed_contract(_metadata), do: {:error, :callback_launch_contract_required}

  defp exact_string_map(map) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not is_binary(key) ->
          {:halt, {:error, :invalid_callback_contract_field}}

        Map.has_key?(normalized, key) ->
          {:halt, {:error, {:duplicate_callback_contract_field, key}}}

        true ->
          {:cont, {:ok, Map.put(normalized, key, value)}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        if MapSet.new(Map.keys(normalized)) == @contract_keys,
          do: {:ok, normalized},
          else: {:error, :unexpected_callback_contract_field}

      error ->
        error
    end
  end

  defp exact_string_map(_map), do: {:error, :callback_launch_contract_required}

  defp exact_action_version(contract, action_contract) do
    if contract["action_version"] == action_contract.version,
      do: :ok,
      else: {:error, :callback_action_version_mismatch}
  end

  defp exact_schemas(contract, action_contract) do
    expected_request = value(action_contract.request_schema, :"$id")
    expected_response = value(action_contract.response_schema, :"$id")

    if contract["request_schema"] == expected_request and
         contract["response_schema"] == expected_response,
       do: :ok,
       else: {:error, :callback_schema_mismatch}
  end

  defp exact_binding_action([action], action), do: :ok
  defp exact_binding_action(_actions, _action), do: {:error, :callback_action_binding_mismatch}

  defp exact_credential_prompt(binding) do
    if value(binding, :ask_credential_on_launch) == true,
      do: :ok,
      else: {:error, :callback_credential_prompt_not_enabled}
  end

  defp exact_credential_slot(binding) do
    if value(binding, :callback_credential_slot) == @callback_slot,
      do: :ok,
      else: {:error, :callback_credential_slot_mismatch}
  end

  defp valid_manifest(value) when is_binary(value) do
    if Regex.match?(@sha256_hex, value),
      do: :ok,
      else: {:error, :invalid_callback_manifest_digest}
  end

  defp valid_manifest(_value), do: {:error, :invalid_callback_manifest_digest}

  defp exact_policy_version(metadata, policy_version)
       when is_map(metadata) and is_binary(policy_version) and policy_version != "" do
    if to_string(value(metadata, :policy_version)) == policy_version,
      do: :ok,
      else: {:error, :callback_policy_version_mismatch}
  end

  defp exact_policy_version(_metadata, _policy_version),
    do: {:error, :callback_policy_version_required}

  defp bounded_ttl(ttl, maximum) when is_integer(ttl) and ttl > 0 and ttl <= maximum, do: :ok
  defp bounded_ttl(_ttl, _maximum), do: {:error, :callback_ttl_outside_deployment_maximum}

  defp deployment_maximum(contract, action_contract) do
    ActionContract.validate_deployment(action_contract, %{
      operation: contract["operation"],
      phase: contract["phase"],
      state: contract["state"],
      targets: [%{}]
    })
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, result} -> result
      :error -> Map.get(map, to_string(key))
    end
  end

  defp value(_map, _key), do: nil
end
