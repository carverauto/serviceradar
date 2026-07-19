defmodule ServiceRadar.PrefixTags.Changes.BroadcastManualInvalidation do
  @moduledoc """
  Post-commit trie invalidation for manual prefix-tag mutations.

  Runs in `after_transaction` so peer loaders see the committed row (not the
  pre-commit snapshot that `after_action` can observe). When Loader is down
  (or disabled), falls back to a local Store rebuild so this node does not
  keep serving a stale manual trie indefinitely.
  """

  use Ash.Resource.Change

  alias ServiceRadar.PrefixTags.Loader
  alias ServiceRadar.PrefixTags.Manual

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn cs, result ->
      case result do
        {:ok, record} ->
          source = source_for_invalidation(cs, record)
          invalidate_source(source)
          {:ok, record}

        :ok ->
          source = source_for_invalidation(cs, nil)
          invalidate_source(source)
          :ok

        other ->
          other
      end
    end)
  end

  # Notification-only change: allow atomic actions; hooks attach via change/3
  # when the action runs non-atomically. Manual update/destroy set
  # require_atomic? false so change/3 always runs for those paths.
  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp source_for_invalidation(changeset, record) do
    cond do
      is_map(record) and match?(%{snapshot: %{source: src}} when is_binary(src), record) ->
        record.snapshot.source

      is_map(record) and is_binary(Map.get(record, :source)) ->
        record.source

      is_map(record) and not is_nil(Map.get(record, :snapshot_id)) ->
        case query_snapshot_source(record.snapshot_id) do
          src when is_binary(src) -> src
          _ -> "manual"
        end

      true ->
        case Ash.Changeset.get_argument(changeset, :source) do
          src when is_binary(src) and src != "" -> src
          _ -> "manual"
        end
    end
  end

  defp query_snapshot_source(snapshot_id) do
    case Ecto.Adapters.SQL.query(
           ServiceRadar.Repo,
           "SELECT source FROM platform.prefix_tag_snapshots WHERE id = $1",
           [snapshot_id]
         ) do
      {:ok, %{rows: [[source]]}} when is_binary(source) -> source
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp invalidate_source("manual") do
    # Full path: Loader.reload with local Store rebuild fallback + broadcast.
    Manual.invalidate!()
  end

  defp invalidate_source(source) when is_binary(source) do
    _ =
      try do
        Loader.reload(source)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

    _ = Loader.broadcast_invalidation(%{source: source})
    :ok
  end
end
