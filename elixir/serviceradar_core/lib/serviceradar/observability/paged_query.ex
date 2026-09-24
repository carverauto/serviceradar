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
end
