defmodule ServiceRadar.Automation.CallbackGrants.Audit do
  @moduledoc """
  Builds an allowlisted, secret-free callback lifecycle audit record.
  """

  @safe_metadata_keys MapSet.new([
                        :reason,
                        :policy_version,
                        :response_digest,
                        :request_digest,
                        :job_id,
                        :cleanup_status,
                        :cancel_status,
                        :credential_status,
                        :retryable,
                        :outcome
                      ])

  @forbidden_fragments ~w(token bearer verifier secret authorization_header response_body body)

  @spec attrs(binary() | atom(), map(), map()) :: {:ok, map()} | {:error, term()}
  def attrs(event, grant, metadata \\ %{})

  def attrs(event, grant, metadata) when is_map(grant) and is_map(metadata) do
    with :ok <- validate_metadata(metadata) do
      base = %{
        event: to_string(event),
        grant_id: value(grant, :id),
        tenant_id: value(grant, :tenant_id),
        parent_run_id: value(grant, :parent_run_id),
        execution_id: value(grant, :execution_id),
        principal_type: value(grant, :principal_type),
        principal_id: value(grant, :principal_id),
        action: value(grant, :action),
        state: value(grant, :state)
      }

      {:ok, Map.merge(base, metadata)}
    end
  end

  def attrs(_event, _grant, _metadata), do: {:error, :invalid_audit_attributes}

  @spec safe_grant(map()) :: map()
  def safe_grant(grant) when is_map(grant) do
    Map.drop(grant, [
      :verifier_digest,
      "verifier_digest",
      :verifier_key_id,
      "verifier_key_id",
      :token_verifier,
      "token_verifier",
      :token_pepper_version,
      "token_pepper_version",
      :idempotency_key_verifier,
      "idempotency_key_verifier",
      :idempotency_pepper_version,
      "idempotency_pepper_version",
      :idempotency_verifier_digest,
      "idempotency_verifier_digest",
      :idempotency_verifier_key_id,
      "idempotency_verifier_key_id",
      :launch_envelope_ref,
      "launch_envelope_ref",
      :response_bytes,
      "response_bytes",
      :response_reference,
      "response_reference",
      :response_ref,
      "response_ref",
      :committed_response_bytes,
      "committed_response_bytes",
      :committed_response_reference,
      "committed_response_reference",
      :body,
      "body",
      :policy_snapshot,
      "policy_snapshot",
      :response_snapshot,
      "response_snapshot"
    ])
  end

  @doc false
  @spec authorization_grant(map()) :: map()
  def authorization_grant(grant) when is_map(grant) do
    grant
    |> safe_grant()
    |> Map.put(:policy_snapshot, value(grant, :policy_snapshot))
  end

  defp validate_metadata(metadata) do
    Enum.reduce_while(metadata, :ok, fn {key, value}, :ok ->
      normalized_key = normalize_key(key)

      cond do
        not MapSet.member?(@safe_metadata_keys, normalized_key) ->
          {:halt, {:error, {:unsafe_audit_key, key}}}

        contains_forbidden_key?(value) ->
          {:halt, {:error, {:unsafe_audit_value, key}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp contains_forbidden_key?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      forbidden_key?(key) or contains_forbidden_key?(nested)
    end)
  end

  defp contains_forbidden_key?(value) when is_list(value),
    do: Enum.any?(value, &contains_forbidden_key?/1)

  defp contains_forbidden_key?(_value), do: false

  defp forbidden_key?(key) do
    normalized = key |> to_string() |> String.downcase()
    Enum.any?(@forbidden_fragments, &String.contains?(normalized, &1))
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@safe_metadata_keys, &(Atom.to_string(&1) == key)) || :unknown
  end

  defp normalize_key(_key), do: :unknown

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
