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

  The merge runs in the database, in one statement inside the action's
  transaction, and stamps each fact's provenance `updated_at` with the
  database `now()` there. Two reasons:

    * `metadata` has many independent writers. Writing a whole map computed in
      Elixir would be a read-modify-write that silently reverts keys other
      writers committed in between (see `MergeDeviceMetadata`).
    * composite checks select devices whose provenance `updated_at` is later
      than a mark they take with the database `now()`, less a fixed slack. That
      only holds when the timestamp is the database clock at the writing
      statement; an application timestamp taken before the transaction opened
      could fall behind the mark and the change would never be selected.
  """

  use Ash.Resource.Change

  alias ServiceRadar.CompositeChecks.Resolvers.DeviceMetadata
  alias ServiceRadar.Repo

  @key_pattern ~r/^[a-z][a-z0-9_]{0,63}$/

  # Keys the platform writes from its own enrichment and from source evidence. A caller's fact
  # at one of them would read as evidence no source reported: the identity state and source
  # mark a provisional topology sighting, a source id, integration id, MAC, address or hostname
  # is identity evidence, and a switch-port attachment is a source fact with its own provenance
  # (`ServiceRadar.Inventory.SourceFacts`).
  @reserved_keys ~w(
    passive_fingerprint
    identity_state
    identity_source
    armis_device_id
    integration_id
    mac
    ip
    hostname
    switch_port_attachment
    sync_service_id
    agent_id
    source_agent_id
    discovered_by_agent_id
  )
  @max_facts 32

  # `{:ok, change(...)}`, not a bare `:ok`: the change registers an after_action
  # hook, and Ash rebuilds atomic updates from a second changeset -- returning
  # `:ok` would drop the hook and silently write nothing.
  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @impl true
  def change(changeset, _opts, context) do
    facts = Ash.Changeset.get_argument(changeset, :facts) || %{}
    existing = Ash.Changeset.get_data(changeset, :metadata) || %{}

    with :ok <- validate_facts(facts),
         :ok <- validate_cap(existing, facts) do
      values = Map.new(facts, fn {key, value} -> {to_string(key), value} end)
      sources = Map.new(values, fn {key, _value} -> {key, source(context)} end)

      # An after_action, not a changed attribute: Ash.Type.Map has no atomic
      # expression support, so routing this through the attribute would write a
      # literal map computed here, which is the read-modify-write above.
      Ash.Changeset.after_action(changeset, fn _changeset, record ->
        merge(record, values, sources)
      end)
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

  # The maps go in at jsonb-cast placeholders so Postgrex encodes them once; a
  # pre-encoded binary would land as a jsonb string scalar.
  defp merge(record, values, sources) do
    case Repo.query(
           """
           UPDATE platform.ocsf_devices
           SET metadata =
             (COALESCE(metadata, '{}'::jsonb) || CAST($2 AS jsonb))
             || jsonb_build_object(
                  CAST($3 AS text),
                  COALESCE(metadata -> CAST($3 AS text), '{}'::jsonb)
                  || (
                    SELECT jsonb_object_agg(
                      e.key,
                      jsonb_build_object('source', e.value, 'updated_at', to_jsonb(now()))
                    )
                    FROM jsonb_each_text(CAST($4 AS jsonb)) AS e
                  )
                )
           WHERE uid = $1
           RETURNING metadata
           """,
           [record.uid, values, DeviceMetadata.provenance_key(), sources]
         ) do
      {:ok, %{rows: [[merged]]}} ->
        {:ok, %{record | metadata: merged}}

      {:ok, %{rows: []}} ->
        # Removed between the read and here. Nothing to merge into, and
        # inventing a row would resurrect it.
        {:ok, record}

      {:error, reason} ->
        {:error, reason}
    end
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
