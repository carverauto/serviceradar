defmodule ServiceRadarWebNG.Dashboards.Authored.Preview do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      alias ServiceRadarWebNG.Dashboards.Authored.Visuals

      require Ash.Query

      @spec preview_query(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
      def preview_query(scope, srql_query, opts \\ [])

      def preview_query(scope, srql_query, opts) when is_binary(srql_query) do
        query = String.trim(srql_query)
        max_limit = opts |> Keyword.get(:max_limit, 200) |> normalize_limit(10_000)
        limit = opts |> Keyword.get(:limit, 100) |> normalize_limit(max_limit)
        srql_module = Keyword.get(opts, :srql_module, srql_module())

        if query == "" do
          {:error, :empty_query}
        else
          bounded_query = bound_authored_query(query, limit)

          case srql_module.query(bounded_query, %{scope: scope, limit: limit}) do
            {:ok, %{"results" => results} = response} ->
              rows = Visuals.normalize_rows(results)
              fields = Visuals.infer_fields(rows, Map.get(response, "viz"))

              {:ok,
               %{
                 query: bounded_query,
                 rows: rows,
                 row_count: length(rows),
                 fields: fields,
                 compatible_visuals: Visuals.compatible_visuals(rows, fields),
                 viz: Map.get(response, "viz"),
                 pagination: Map.get(response, "pagination")
               }}

            {:ok, response} ->
              {:ok,
               %{
                 query: bounded_query,
                 rows: [],
                 row_count: 0,
                 fields: [],
                 compatible_visuals: [:table],
                 raw: response
               }}

            {:error, reason} ->
              {:error, reason}
          end
        end
      end

      def preview_query(_scope, _srql_query, _opts), do: {:error, :empty_query}

      defp bound_authored_query(query, limit) when is_binary(query) do
        tokens = split_srql_tokens(query)
        has_time? = Enum.any?(tokens, &time_token?/1)

        tokens
        |> Enum.reject(&limit_token?/1)
        |> maybe_append_default_time(has_time?)
        |> Kernel.++(["limit:#{limit}"])
        |> Enum.join(" ")
      end

      defp split_srql_tokens(query) do
        {tokens, current, _quote, _escaped?} =
          query
          |> String.graphemes()
          |> Enum.reduce({[], "", nil, false}, &split_srql_token/2)

        tokens =
          if current == "" do
            tokens
          else
            [current | tokens]
          end

        Enum.reverse(tokens)
      end

      defp split_srql_token(char, {tokens, current, quote, true}) do
        {tokens, current <> char, quote, false}
      end

      defp split_srql_token("\\", {tokens, current, quote, false}) when not is_nil(quote) do
        {tokens, current <> "\\", quote, true}
      end

      defp split_srql_token(char, {tokens, current, quote, false}) when char == quote and not is_nil(quote) do
        {tokens, current <> char, nil, false}
      end

      defp split_srql_token(char, {tokens, current, quote, false}) when not is_nil(quote) do
        {tokens, current <> char, quote, false}
      end

      defp split_srql_token(char, {tokens, current, nil, false}) when char in ["\"", "'"] do
        {tokens, current <> char, char, false}
      end

      defp split_srql_token(char, {tokens, current, nil, false}) when char in [" ", "\n", "\r", "\t"] do
        if current == "" do
          {tokens, "", nil, false}
        else
          {[current | tokens], "", nil, false}
        end
      end

      defp split_srql_token(char, {tokens, current, quote, escaped?}) do
        {tokens, current <> char, quote, escaped?}
      end

      defp maybe_append_default_time(tokens, true), do: tokens
      defp maybe_append_default_time(tokens, false), do: tokens ++ ["time:#{"last_24h"}"]

      defp time_token?(token) do
        key =
          token
          |> String.downcase()
          |> String.split(":", parts: 2)
          |> List.first()

        key in ["time", "timeframe", "first_seen", "first_seen_time"]
      end

      defp limit_token?(token), do: token |> String.downcase() |> String.starts_with?("limit:")
    end
  end
end
