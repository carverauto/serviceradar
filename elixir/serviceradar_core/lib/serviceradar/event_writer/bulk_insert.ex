defmodule ServiceRadar.EventWriter.BulkInsert do
  @moduledoc """
  Shared bulk insert boundary for event-writer processors.

  Event-writer batches are transport batches: one NATS message may expand into
  many database rows. This module keeps PostgreSQL statement sizing owned by
  the database write boundary instead of each processor guessing how many rows
  are safe for `insert_all/3`.
  """

  require Logger

  @postgres_bind_parameter_limit 65_535
  @insert_bind_parameter_headroom 1_024
  @max_insert_bind_parameters @postgres_bind_parameter_limit - @insert_bind_parameter_headroom

  @type table :: atom() | binary() | {binary(), module()}
  @type rows :: [map()]
  @type repo :: module()

  @doc """
  Inserts rows using `ServiceRadar.Repo`, splitting oversized statements by the
  PostgreSQL bind-parameter budget.
  """
  @spec insert_all(table(), rows(), Keyword.t()) :: {non_neg_integer(), term()}
  def insert_all(table, rows, opts \\ []) do
    insert_all(ServiceRadar.Repo, table, rows, opts)
  end

  @doc """
  Inserts rows using the supplied repo module.

  This exists for tests and for call sites that need an alternate repo while
  still sharing the same statement-sizing behavior.
  """
  @spec insert_all(repo(), table(), rows(), Keyword.t()) :: {non_neg_integer(), term()}
  def insert_all(_repo, _table, [], opts), do: {0, empty_return(opts)}

  def insert_all(repo, table, rows, opts) when is_list(rows) do
    chunk_size = max_rows_per_statement(rows)

    if length(rows) > chunk_size do
      Logger.debug(
        "Chunking #{inspect(table)} insert into #{chunk_size}-row statements for #{length(rows)} rows"
      )
    end

    rows
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce({0, empty_return(opts)}, fn chunk, {total_count, total_returned} ->
      {chunk_count, chunk_returned} = repo.insert_all(table, chunk, opts)

      {
        total_count + chunk_count,
        merge_returned(total_returned, chunk_returned, opts)
      }
    end)
  end

  @doc false
  @spec max_rows_per_statement(rows()) :: pos_integer()
  def max_rows_per_statement(rows) when is_list(rows) and rows != [] do
    rows
    |> bound_column_count()
    |> then(&max(1, div(@max_insert_bind_parameters, &1)))
  end

  @doc false
  @spec max_bind_parameters() :: pos_integer()
  def max_bind_parameters, do: @max_insert_bind_parameters

  defp bound_column_count(rows) do
    rows
    |> Enum.reduce(MapSet.new(), fn row, columns ->
      row
      |> Map.keys()
      |> Enum.reject(&placeholder_column?(Map.fetch!(row, &1)))
      |> Enum.reduce(columns, &MapSet.put(&2, &1))
    end)
    |> MapSet.size()
    |> max(1)
  end

  defp placeholder_column?({:placeholder, _name}), do: true
  defp placeholder_column?(_value), do: false

  defp empty_return(opts) do
    if returns_rows?(opts), do: []
  end

  defp merge_returned(total_returned, chunk_returned, opts) do
    if returns_rows?(opts), do: total_returned ++ List.wrap(chunk_returned)
  end

  defp returns_rows?(opts), do: Keyword.get(opts, :returning, false) not in [false, nil]
end
