defmodule ServiceRadar.PrefixTags.Changes.AdjustManualRecordCount do
  @moduledoc """
  Adjust `prefix_tag_snapshots.record_count` inside the same DB transaction as
  the PrefixTag create/destroy (via `after_action`).

  A post-commit ±1 races concurrent mutations and can permanently drift; keeping
  the counter update in the row transaction makes create/destroy+count atomic.
  """

  use Ash.Resource.Change

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  @impl true
  def change(changeset, opts, _context) do
    delta = Keyword.get(opts, :delta, 0)

    if delta == 0 do
      changeset
    else
      Ash.Changeset.after_action(changeset, fn _cs, record ->
        case adjust(record.snapshot_id, delta) do
          :ok -> {:ok, record}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    # Counter update uses raw SQL after the row write; run non-atomically.
    {:not_atomic, "record_count adjustment uses after_action SQL"}
  end

  defp adjust(snapshot_id, delta) when is_integer(delta) and delta != 0 do
    case SQL.query(
           Repo,
           """
           UPDATE platform.prefix_tag_snapshots
           SET record_count = GREATEST(0, COALESCE(record_count, 0) + $2),
               updated_at = NOW()
           WHERE id = $1
           """,
           [snapshot_id, delta]
         ) do
      {:ok, %{num_rows: n}} when is_integer(n) and n >= 1 -> :ok
      {:ok, _} -> {:error, :snapshot_not_found}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end
end
