defmodule ServiceRadar.PrefixTags.Changes.BroadcastManualInvalidation do
  @moduledoc """
  Post-commit trie invalidation for manual prefix-tag mutations.

  Runs in `after_transaction` so peer loaders see the committed row (not the
  pre-commit snapshot that `after_action` can observe). Safe for atomic and
  non-atomic actions: `atomic/3` returns `:ok` so create/update/destroy are not
  blocked, while `change/3` attaches the post-commit hook.
  """

  use Ash.Resource.Change

  alias ServiceRadar.PrefixTags.Loader

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

      true ->
        case Ash.Changeset.get_argument(changeset, :source) do
          src when is_binary(src) and src != "" -> src
          _ -> "manual"
        end
    end
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
