defmodule ServiceRadar.Inventory.Changes.MergeDeviceMetadata do
  @moduledoc """
  Merges a patch into a device's `metadata` as a database expression.

  `metadata` is a jsonb column with many independent writers -- sweep promotion,
  rDNS, the mapper ingestor, identity promotion, ingest -- each owning its own
  disjoint set of keys. The obvious way to add a key is to read the map, `Map.put`
  into it and write the whole map back. That is a read-modify-write, and it loses
  every change another writer committed in between, because the new value is a
  literal parameter rather than something derived from the column. Postgres' row
  lock does not help: it serializes the writes, and the second one still carries a
  stale snapshot of every key it does not own.

  The lost write is silent. There is no conflict, no error and no log line -- the
  key simply reappears, or disappears, depending on which writer ran last.

  This was not theoretical. A remediation pass that removes a metadata key was
  found to be silently revertible by the sweep -> mapper promotion path, which runs
  regularly against the same devices. The pass would have reported success and
  changed nothing.

  So the merge happens in the database: `COALESCE(metadata, '{}') || patch`. Only
  the patch's own keys move, and every other writer's keys survive regardless of
  interleaving.

  MERGE ONLY -- this cannot REMOVE a key, by construction. jsonb `||` overwrites
  and inserts; it has no delete. A caller that must remove a key needs `- 'key'`
  and should say so explicitly in its own action rather than reaching for this one.
  Setting a key to `nil` writes a JSON `null`, which is what the whole-map writers
  this replaced already did.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Repo

  @impl true
  def change(changeset, opts, context) do
    patch = changeset |> patch(opts, context) |> stringify()

    if patch == %{} do
      changeset
    else
      # An after_action, not a changed attribute. Ash cannot express this
      # atomically -- `Ash.Type.Map` has no atomic expression support, so anything
      # routed through the attribute becomes a literal map and is a
      # read-modify-write again. One targeted UPDATE is atomic in the database,
      # which is where it has to hold.
      Ash.Changeset.after_action(changeset, fn _changeset, record ->
        merge(record, patch)
      end)
    end
  end

  # `{:ok, change(...)}`, not a bare `:ok`: the change registers an after_action
  # hook, and Ash rebuilds atomic updates from a second changeset -- returning
  # `:ok` would drop the hook and silently write nothing.
  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end

  defp merge(record, patch) do
    case Repo.query(
           """
           UPDATE platform.ocsf_devices
           SET metadata = COALESCE(metadata, '{}'::jsonb) || $2::jsonb
           WHERE uid = $1
           RETURNING metadata
           """,
           # The MAP goes in at a `$n::jsonb` placeholder so Postgrex encodes it
           # once. A pre-encoded binary here is encoded AGAIN and lands as a jsonb
           # STRING scalar, and `object || string` in Postgres builds an array
           # rather than merging -- after which metadata is no longer an object.
           [record.uid, patch]
         ) do
      {:ok, %{rows: [[merged]]}} ->
        {:ok, %{record | metadata: merged}}

      {:ok, %{rows: []}} ->
        # Soft-deleted or removed between the read and here. Nothing to merge
        # into, and inventing a row would resurrect it.
        {:ok, record}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Read from the argument, not from the attribute: the attribute is what we are
  # computing, and reading a proposed attribute value here is exactly the
  # read-modify-write this module exists to avoid.
  defp patch(changeset, _opts, _context) do
    Ash.Changeset.get_argument(changeset, :metadata_patch) || %{}
  end

  # jsonb keys are strings. An atom-keyed patch would merge as a DIFFERENT key
  # from the string one already stored, leaving both.
  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify(_), do: %{}
end
