defmodule ServiceRadar.Inventory.Changes.MergeDeviceFacts do
  @moduledoc """
  Merges externally supplied scalar facts into device metadata and stamps
  per-key provenance.

  The plain value is written at its own key so every existing metadata consumer
  sees it unchanged. Provenance is written alongside under `__fact_provenance`,
  which is what lets a composite check enforce a maximum age without asking the
  caller to send timestamps — and, because it is server-stamped, prevents a
  caller from back-dating a compliance signal.

  Any invalid fact rejects the whole request. A partial write would leave the
  caller believing every fact landed.
  """

  use Ash.Resource.Change

  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata

  @key_pattern ~r/^[a-z][a-z0-9_]{0,63}$/
  @reserved_keys ~w(passive_fingerprint identity_state identity_source)
  @max_facts 32

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @impl true
  def change(changeset, _opts, context) do
    facts = Ash.Changeset.get_argument(changeset, :facts) || %{}
    existing = Ash.Changeset.get_data(changeset, :metadata) || %{}

    with :ok <- validate_facts(facts),
         :ok <- validate_cap(existing, facts) do
      Ash.Changeset.force_change_attribute(
        changeset,
        :metadata,
        merge(existing, facts, source(context))
      )
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :facts, message: message)
    end
  end

  defp validate_facts(facts) when is_map(facts) and map_size(facts) > 0 do
    Enum.reduce_while(facts, :ok, fn {key, value}, :ok ->
      case validate_fact(to_string(key), value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_facts(_facts), do: {:error, "at least one fact is required"}

  defp validate_fact(key, value) do
    cond do
      key == DeviceMetadata.provenance_key() ->
        {:error, "#{key} is reserved and cannot be written as a fact"}

      key in @reserved_keys ->
        {:error, "#{key} is reserved for internal enrichment"}

      not Regex.match?(@key_pattern, key) ->
        {:error, "#{key} is not a valid fact key (lowercase letters, digits, underscores)"}

      not scalar?(value) ->
        {:error, "#{key} must be a scalar value (boolean, number, or string)"}

      true ->
        :ok
    end
  end

  defp validate_cap(existing, facts) do
    written = existing |> Map.get(DeviceMetadata.provenance_key(), %{}) |> Map.keys()

    total =
      written
      |> MapSet.new()
      |> MapSet.union(facts |> Map.keys() |> MapSet.new(&to_string/1))
      |> MapSet.size()

    if total > @max_facts do
      {:error, "writing these facts would exceed the per-device cap of #{@max_facts}"}
    else
      :ok
    end
  end

  defp merge(existing, facts, source) do
    stamped_at = DateTime.to_iso8601(DateTime.utc_now())
    provenance_key = DeviceMetadata.provenance_key()

    Enum.reduce(facts, existing, fn {key, value}, acc ->
      key = to_string(key)
      provenance = Map.get(acc, provenance_key, %{})

      acc
      |> Map.put(key, value)
      |> Map.put(
        provenance_key,
        Map.put(provenance, key, %{"source" => source, "updated_at" => stamped_at})
      )
    end)
  end

  defp scalar?(value), do: is_boolean(value) or is_number(value) or is_binary(value)

  defp source(context) do
    case context do
      %{actor: %{name: name}} when is_binary(name) and name != "" -> name
      %{actor: %{email: email}} when is_binary(email) and email != "" -> email
      %{actor: %{id: id}} when not is_nil(id) -> to_string(id)
      _ -> "unknown"
    end
  end

  @doc false
  def max_facts, do: @max_facts

  @doc false
  def reserved_keys, do: @reserved_keys
end
