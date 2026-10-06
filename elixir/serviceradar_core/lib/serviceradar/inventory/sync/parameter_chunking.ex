defmodule ServiceRadar.Inventory.Sync.ParameterChunking do
  @moduledoc """
  Chunks bulk `insert_all` writes so one statement never exceeds Postgres's
  wire-protocol bound-parameter limit.

  Ecto binds one parameter per header column per row, and the header is the
  UNION of every row's keys -- a batch whose rows carry different keys binds
  more per row than any single row is wide, so a chunk size derived from one
  row's width (or even from the widest row) can still overflow the limit.
  Nothing else is generated behind the rows' backs: `insert_all` never
  autogenerates timestamps, and the Ash resources written here carry
  `autogenerate_id: nil` (their uuid primary keys default database-side and
  are simply absent from the header when the rows omit them), so the rows'
  own keys are the whole count.

  Values pinned into an `on_conflict` query (`^param` inside an update
  expression) are bound once per statement on top of the rows; pass their
  count as `:extra_parameters`.
  """

  # Postgres's wire protocol hard limit (int16) on bound parameters in one query.
  @max_bound_parameters 65_535

  @doc """
  Splits `rows` (field- or column-keyed maps) into chunks that each stay
  within the bound-parameter limit of one `insert_all` statement.

  The concatenation of the returned chunks is `rows` in order.

  Options:

    * `:extra_parameters` -- additional fixed parameters the statement binds
      outside the rows. Defaults to `0`.
  """
  @spec insert_all_chunks([map()], keyword()) :: [[map()]]
  def insert_all_chunks(rows, opts \\ [])

  def insert_all_chunks([], _opts), do: []

  def insert_all_chunks(rows, opts) do
    column_count =
      rows
      |> Enum.reduce(MapSet.new(), fn row, columns ->
        MapSet.union(MapSet.new(Map.keys(row)), columns)
      end)
      |> MapSet.size()

    budget = @max_bound_parameters - Keyword.get(opts, :extra_parameters, 0)

    Enum.chunk_every(rows, max(div(budget, column_count), 1))
  end
end
