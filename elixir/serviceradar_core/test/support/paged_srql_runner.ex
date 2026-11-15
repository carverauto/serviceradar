defmodule ServiceRadar.TestSupport.PagedSRQLRunner do
  @moduledoc """
  An SRQL runner that serves rows the way `SRQLRunner.query_page/2` does: one
  page of at most `:limit` rows (100 when the request omits it, as SRQL
  defaults) and a cursor after every full page, until the next offset would
  pass the cursor window (SRQL's `max_cursor_offset`). `query/2` returns the
  first page, as `SRQLRunner.query/2` does, so a caller that reads one page
  sees exactly the cut a real deployment would.

  State lives in the calling process's dictionary: `serving/2` sets the rows
  and returns the module to pass as `runner:`. Every query received is
  recorded and returned by `queries/0`.
  """

  @default_limit 100

  @doc "Serves `rows` (a list for any query, or a map of query => rows)."
  def serving(rows, opts \\ []) do
    Process.put(__MODULE__, rows)
    Process.put({__MODULE__, :cursor_window}, Keyword.get(opts, :cursor_window, :infinity))
    Process.put({__MODULE__, :queries}, [])
    __MODULE__
  end

  def queries, do: {__MODULE__, :queries} |> Process.get([]) |> Enum.reverse()

  def query(query, opts) do
    with {:ok, %{rows: rows}} <- query_page(query, opts), do: {:ok, rows}
  end

  def query_page(query, opts) do
    Process.put({__MODULE__, :queries}, [query | Process.get({__MODULE__, :queries}, [])])

    rows =
      case Process.get(__MODULE__) do
        by_query when is_map(by_query) -> Map.fetch!(by_query, query)
        rows when is_list(rows) -> rows
      end

    limit = Keyword.get(opts, :limit) || @default_limit
    offset = opts |> Keyword.get(:cursor, "0") |> String.to_integer()
    page = rows |> Enum.drop(offset) |> Enum.take(limit)
    window = Process.get({__MODULE__, :cursor_window}, :infinity)

    next =
      if length(page) >= limit and offset + limit <= window,
        do: Integer.to_string(offset + limit)

    {:ok, %{rows: page, next_cursor: next}}
  end
end
