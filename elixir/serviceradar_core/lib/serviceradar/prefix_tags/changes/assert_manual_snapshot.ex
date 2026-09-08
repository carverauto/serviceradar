defmodule ServiceRadar.PrefixTags.Changes.AssertManualSnapshot do
  @moduledoc """
  Reject create/update/destroy actions intended for operators when the prefix
  tag does not belong to the `manual` snapshot source. Imported rows (netbox,
  custom, …) are read-only.
  """

  use Ash.Resource.Change

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  @source "manual"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      case snapshot_source(cs) do
        @source ->
          cs

        other when is_binary(other) ->
          Ash.Changeset.add_error(cs,
            field: :snapshot_id,
            message:
              "only manual prefix tags may be created, updated, or destroyed (source=#{other})"
          )

        :error ->
          Ash.Changeset.add_error(cs,
            field: :snapshot_id,
            message: "snapshot not found for prefix tag"
          )
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "manual-source guard loads snapshot source"}
  end

  defp snapshot_source(changeset) do
    record = changeset.data

    cond do
      match?(%{snapshot: %{source: src}} when is_binary(src), record) ->
        record.snapshot.source

      is_map(record) and not is_nil(Map.get(record, :snapshot_id)) ->
        query_source(record.snapshot_id)

      snapshot_id = Ash.Changeset.get_attribute(changeset, :snapshot_id) ->
        query_source(snapshot_id)

      true ->
        :error
    end
  end

  defp query_source(snapshot_id) do
    case Ecto.UUID.dump(snapshot_id) do
      {:ok, dumped_snapshot_id} ->
        case SQL.query(
               Repo,
               "SELECT source FROM platform.prefix_tag_snapshots WHERE id = $1",
               [dumped_snapshot_id]
             ) do
          {:ok, %{rows: [[source]]}} when is_binary(source) -> source
          {:ok, %{rows: []}} -> :error
          _ -> :error
        end

      :error ->
        :error
    end
  rescue
    _ -> :error
  end
end
