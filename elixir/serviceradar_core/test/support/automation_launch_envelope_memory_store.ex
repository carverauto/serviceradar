defmodule ServiceRadar.TestSupport.AutomationLaunchEnvelopeMemoryStore do
  @moduledoc false

  @behaviour ServiceRadar.Automation.LaunchEnvelopes.Store

  alias ServiceRadar.Automation.LaunchEnvelopes.Context

  def start_link(opts \\ []) do
    Agent.start_link(fn ->
      %{records: %{}, fail_create?: Keyword.get(opts, :fail_create?, false)}
    end)
  end

  def records(pid), do: Agent.get(pid, &Map.values(&1.records))

  @impl true
  def transaction(fun, pid) when is_function(fun, 0) and is_pid(pid) do
    snapshot = Agent.get(pid, & &1)
    Process.put(transaction_key(pid), snapshot)

    result = fun.()

    case result do
      {:ok, value} ->
        staged = Process.get(transaction_key(pid))
        Agent.update(pid, fn _current -> staged end)
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  after
    Process.delete(transaction_key(pid))
  end

  @impl true
  def create_sealed(attrs, pid) when is_map(attrs) and is_pid(pid) do
    state = Process.get(transaction_key(pid)) || Agent.get(pid, & &1)

    cond do
      state.fail_create? ->
        {:error, :forced_seal_failure}

      Map.has_key?(state.records, attrs.reference_verifier) ->
        {:error, :duplicate_reference}

      true ->
        record = Map.merge(attrs, %{id: Ecto.UUID.generate(), state: :sealed})
        updated = put_in(state, [:records, attrs.reference_verifier], record)

        if Process.get(transaction_key(pid)) do
          Process.put(transaction_key(pid), updated)
        else
          Agent.update(pid, fn _current -> updated end)
        end

        {:ok, record}
    end
  end

  @impl true
  def consume(reference_verifier, request, now, cipher, decrypt, pid) do
    Agent.get_and_update(pid, fn state ->
      case Map.get(state.records, reference_verifier) do
        nil ->
          {{:error, :launch_envelope_denied}, state}

        record ->
          consume_record(record, reference_verifier, request, now, cipher, decrypt, state)
      end
    end)
  end

  defp consume_record(record, reference_verifier, request, now, cipher, decrypt, state) do
    with true <- record.state == :sealed,
         {:ok, context} <- Context.from_record(record),
         false <- Context.expired?(context, now),
         true <- Context.request_matches?(context, request),
         true <- secure_equal?(Context.digest(context), record.context_digest),
         true <- record.cipher_version == cipher.cipher_version,
         true <- record.cipher_key_id == cipher.cipher_key_id,
         {:ok, material} <- decrypt_record(record, context, decrypt) do
      resolved =
        record
        |> Map.put(:state, :resolved)
        |> Map.put(:resolved_at, now)

      result = %{
        id: resolved.id,
        material: material,
        context: context,
        expires_at: resolved.expires_at
      }

      {{:ok, result}, put_in(state, [:records, reference_verifier], resolved)}
    else
      {:error, :launch_envelope_decrypt_failed} = error -> {error, state}
      _ -> {{:error, :launch_envelope_denied}, state}
    end
  end

  defp decrypt_record(record, context, decrypt) do
    case decrypt.(%{
           ciphertext: record.ciphertext,
           cipher_version: record.cipher_version,
           context: context,
           expires_at: record.expires_at
         }) do
      {:ok, material} when is_map(material) -> {:ok, material}
      _ -> {:error, :launch_envelope_decrypt_failed}
    end
  rescue
    _ -> {:error, :launch_envelope_decrypt_failed}
  catch
    _, _ -> {:error, :launch_envelope_decrypt_failed}
  end

  defp transaction_key(pid), do: {__MODULE__, pid}

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
