defmodule ServiceRadar.CompositeChecks.Scope do
  @moduledoc """
  Resolves a composite check's SRQL scope into device UIDs, one page at a time.

  A scope can select a very large device population, so callers stream pages
  rather than collecting every UID. `page_limit` bounds both the SRQL page and
  the per-page input queries the evaluation pass issues against it.
  """

  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLQuery

  @default_page_limit 1_000

  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, :scope_must_target_devices}
  def normalize(query) when is_binary(query) do
    normalized = SRQLQuery.ensure_target(query, :devices)

    if SRQLAst.entity(normalized) == "devices" do
      {:ok, normalized}
    else
      {:error, :scope_must_target_devices}
    end
  end

  @doc """
  Streams device UIDs for a scope, one list per page.

  Raises on a runner error rather than yielding a partial stream. A caller that
  silently treated a failed page as "no devices here" would conclude those
  devices had left the scope and delete their verdicts.
  """
  @spec stream_uids(String.t(), keyword()) :: Enumerable.t()
  def stream_uids(query, opts \\ []) do
    runner = Keyword.get(opts, :runner, SRQLRunner)
    page_limit = Keyword.get(opts, :page_limit, @default_page_limit)

    Stream.resource(
      fn -> {:start, nil} end,
      fn
        :done ->
          {:halt, :done}

        {step, cursor} ->
          query_opts = page_opts(page_limit, step, cursor)

          case runner.query_page(query, query_opts) do
            {:ok, %{rows: rows, next_cursor: next_cursor}} ->
              uids = Enum.flat_map(rows, &extract_uid/1)
              next = if blank?(next_cursor), do: :done, else: {:more, next_cursor}
              {[uids], next}

            {:error, reason} ->
              raise "composite check scope query failed: #{inspect(reason)}"
          end
      end,
      fn _ -> :ok end
    )
  end

  @spec count(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(query, opts \\ []) do
    total =
      query
      |> stream_uids(opts)
      |> Enum.reduce(0, fn page, acc -> acc + length(page) end)

    {:ok, total}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp page_opts(page_limit, :start, _cursor), do: [limit: page_limit]
  defp page_opts(page_limit, _step, cursor), do: [limit: page_limit, cursor: cursor]

  defp extract_uid(row) when is_map(row) do
    case Map.get(row, "uid") || Map.get(row, :uid) || Map.get(row, "id") || Map.get(row, :id) do
      uid when is_binary(uid) and uid != "" -> [uid]
      _ -> []
    end
  end

  defp extract_uid(_row), do: []

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  @doc false
  def default_page_limit, do: @default_page_limit
end
