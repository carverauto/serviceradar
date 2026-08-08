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

  require Logger

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

  @doc false
  @spec source_for_invalidation(Ash.Changeset.t(), map() | nil) :: String.t() | nil
  def source_for_invalidation(changeset, record) do
    source_from_record(record) ||
      source_from_record(changeset.data) ||
      source_from_snapshot_id(Ash.Changeset.get_attribute(changeset, :snapshot_id)) ||
      source_from_argument(changeset)
  end

  defp source_from_record(%{snapshot: %{source: source}}) when is_binary(source) and source != "",
    do: source

  defp source_from_record(record) when is_map(record) do
    case Map.get(record, :source) do
      source when is_binary(source) and source != "" ->
        source

      _ ->
        record
        |> Map.get(:snapshot_id)
        |> source_from_snapshot_id()
    end
  end

  defp source_from_record(_record), do: nil

  defp source_from_snapshot_id(nil), do: nil
  defp source_from_snapshot_id(snapshot_id), do: query_snapshot_source(snapshot_id)

  defp source_from_argument(changeset) do
    case Ash.Changeset.get_argument(changeset, :source) do
      source when is_binary(source) and source != "" -> source
      _ -> nil
    end
  end

  defp query_snapshot_source(snapshot_id) do
    case Ecto.UUID.dump(snapshot_id) do
      {:ok, dumped_snapshot_id} ->
        case Ecto.Adapters.SQL.query(
               ServiceRadar.Repo,
               "SELECT source FROM platform.prefix_tag_snapshots WHERE id = $1",
               [dumped_snapshot_id]
             ) do
          {:ok, %{rows: [[source]]}} when is_binary(source) -> source
          _ -> nil
        end

      :error ->
        nil
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

  defp invalidate_source(nil) do
    Logger.warning(
      "PrefixTags invalidation skipped because snapshot source could not be resolved"
    )

    :ok
  end
end
