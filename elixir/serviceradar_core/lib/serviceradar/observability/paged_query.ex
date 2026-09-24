defmodule ServiceRadar.Observability.PagedQuery do
  @moduledoc false

  @spec fetch(
          module(),
          term(),
          keyword(),
          keyword(),
          term(),
          (term(), list() -> term()),
          (term() -> term()),
          (pos_integer() -> term()),
          (term() -> term())
        ) :: {:ok, term()} | {:error, term()}
  def fetch(
        runner,
        query,
        runner_opts,
        opts,
        acc,
        fold_fun,
        finish_fun,
        exhausted_fun,
        unexpected_fun
      )
      when is_function(fold_fun, 2) and is_function(finish_fun, 1) and
             is_function(exhausted_fun, 1) and
             is_function(unexpected_fun, 1) do
    max_pages = positive_integer(Keyword.get(opts, :max_history_pages), 100)

    fetch_page(
      runner,
      query,
      runner_opts,
      nil,
      acc,
      0,
      max_pages,
      fold_fun,
      finish_fun,
      exhausted_fun,
      unexpected_fun
    )
  end

  defp fetch_page(
         _runner,
         _query,
         _runner_opts,
         _cursor,
         _acc,
         page_count,
         max_pages,
         _fold_fun,
         _finish_fun,
         exhausted_fun,
         _unexpected_fun
       )
       when page_count >= max_pages, do: {:error, exhausted_fun.(max_pages)}

  defp fetch_page(
         runner,
         query,
         runner_opts,
         cursor,
         acc,
         page_count,
         max_pages,
         fold_fun,
         finish_fun,
         exhausted_fun,
         unexpected_fun
       ) do
    page_opts =
      if is_binary(cursor), do: Keyword.put(runner_opts, :cursor, cursor), else: runner_opts

    case runner.query_page(query, page_opts) do
      {:ok, %{rows: rows, next_cursor: next_cursor}} when is_list(rows) ->
        acc = fold_fun.(acc, rows)

        if is_binary(next_cursor) and next_cursor != "" do
          fetch_page(
            runner,
            query,
            runner_opts,
            next_cursor,
            acc,
            page_count + 1,
            max_pages,
            fold_fun,
            finish_fun,
            exhausted_fun,
            unexpected_fun
          )
        else
          {:ok, finish_fun.(acc)}
        end

      {:ok, %{rows: rows}} when is_list(rows) ->
        acc = fold_fun.(acc, rows)
        {:ok, finish_fun.(acc)}

      {:ok, other} ->
        {:error, unexpected_fun.(other)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  @doc false
  # Follow `next_cursor` until the query is exhausted. `max_pages` is a
  # runaway guard that fails the read; it is not a successful partial result.
  @spec collect(module(), String.t(), keyword(), pos_integer()) ::
          {:ok, [term()]} | {:error, term()}
  def collect(runner, query, opts \\ [], max_pages \\ 100_000)
      when is_binary(query) and is_integer(max_pages) and max_pages > 0 do
    do_collect(runner, query, opts, nil, [], 0, max_pages)
  end

  defp do_collect(_runner, _query, _opts, _cursor, _acc, page_count, max_pages)
       when page_count >= max_pages do
    {:error, {:pages_exhausted, max_pages}}
  end

  defp do_collect(runner, query, opts, cursor, acc, page_count, max_pages) do
    page_opts =
      if is_binary(cursor) and cursor != "", do: Keyword.put(opts, :cursor, cursor), else: opts

    case runner.query_page(query, page_opts) do
      {:ok, %{rows: rows, next_cursor: next_cursor}} when is_list(rows) ->
        acc = [rows | acc]

        if is_binary(next_cursor) and next_cursor != "" do
          do_collect(runner, query, opts, next_cursor, acc, page_count + 1, max_pages)
        else
          {:ok, acc |> Enum.reverse() |> List.flatten()}
        end

      {:ok, %{rows: rows}} when is_list(rows) ->
        {:ok, acc |> Enum.reverse() |> List.flatten() |> Kernel.++(rows)}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_page, other}}
    end
  end
end
