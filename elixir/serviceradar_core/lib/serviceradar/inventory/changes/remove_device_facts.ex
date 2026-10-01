defmodule ServiceRadar.Inventory.Changes.RemoveDeviceFacts do
  @moduledoc """
  Removes externally supplied fact keys from device metadata and their
  corresponding provenance entries.

  Guard rules:

  - Only keys present in `__fact_provenance` may be removed (non-fact
    metadata written by integrations such as Armis is never touched).
  - The caller may only remove facts whose provenance source matches the
    caller's own source identity; attempting to remove another caller's
    fact is rejected with a validation error.
  - The `__fact_provenance` key itself is reserved and is always rejected.
  - Removing a key that is not in provenance is a no-op (idempotent).

  Atomicity guarantee: both the value key and its provenance entry are
  removed in one SQL statement inside the action's transaction, matching
  the approach used by `MergeDeviceFacts`.
  """

  use Ash.Resource.Change

  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata
  alias ServiceRadar.Repo

  @key_pattern ~r/^[a-z][a-z0-9_]{0,63}$/

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @impl true
  def change(changeset, _opts, context) do
    keys = Ash.Changeset.get_argument(changeset, :keys) || []
    metadata = Ash.Changeset.get_data(changeset, :metadata) || %{}
    provenance = Map.get(metadata, DeviceMetadata.provenance_key(), %{})
    caller_source = source(context)

    with :ok <- validate_keys(keys),
         {:ok, keys_to_remove} <- classify_keys(keys, provenance, caller_source) do
      if keys_to_remove == [] do
        changeset
      else
        Ash.Changeset.after_action(changeset, fn _changeset, record ->
          remove(record, keys_to_remove)
        end)
      end
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :keys, message: message)
    end
  end

  defp validate_keys([]), do: {:error, "at least one key is required"}

  defp validate_keys(keys) when is_list(keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      key_str = to_string(key)

      cond do
        key_str == DeviceMetadata.provenance_key() ->
          {:halt, {:error, "#{key_str} is reserved and cannot be removed"}}

        not Regex.match?(@key_pattern, key_str) ->
          {:halt,
           {:error, "#{key_str} is not a valid fact key (lowercase letters, digits, underscores)"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_keys(_), do: {:error, "keys must be a list"}

  # Returns {:ok, keys_to_remove} or {:error, message}.
  # A key absent from provenance is a no-op (already removed or never written).
  # A key present in provenance but owned by a different source is rejected.
  defp classify_keys(keys, provenance, caller_source) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      key_str = to_string(key)

      case Map.get(provenance, key_str) do
        nil ->
          {:cont, {:ok, acc}}

        entry ->
          stored_source = Map.get(entry, "source")

          if stored_source == caller_source do
            {:cont, {:ok, [key_str | acc]}}
          else
            {:halt,
             {:error, "#{key_str} was written by a different source and cannot be removed"}}
          end
      end
    end)
  end

  # Removes the specified keys from both the top-level metadata map and
  # from the __fact_provenance sub-object in one atomic UPDATE.
  #
  # The jsonb `-` operator applied to an array removes all named keys from
  # the object. Overlaying with the updated provenance object replaces the
  # prior provenance in-place without touching any other metadata key.
  defp remove(record, keys) do
    provenance_key = DeviceMetadata.provenance_key()

    case Repo.query(
           """
           UPDATE platform.ocsf_devices
           SET metadata =
             (COALESCE(metadata, '{}'::jsonb) - CAST($2 AS text[]))
             || jsonb_build_object(
                  CAST($3 AS text),
                  COALESCE(metadata -> CAST($3 AS text), '{}'::jsonb) - CAST($2 AS text[])
                )
           WHERE uid = $1
           RETURNING metadata
           """,
           [record.uid, keys, provenance_key]
         ) do
      {:ok, %{rows: [[merged]]}} ->
        {:ok, %{record | metadata: merged}}

      {:ok, %{rows: []}} ->
        {:ok, record}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp source(context) do
    case context do
      %{actor: %{name: name}} when is_binary(name) and name != "" -> name
      %{actor: %{email: email}} when is_binary(email) and email != "" -> email
      %{actor: %{id: id}} when not is_nil(id) -> to_string(id)
      _ -> "unknown"
    end
  end
end
