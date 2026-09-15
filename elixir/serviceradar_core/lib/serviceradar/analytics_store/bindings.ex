defmodule ServiceRadar.AnalyticsStore.Bindings do
  @moduledoc """
  Render analytics parameters before pg_duckdb plans a query.

  pg_duckdb prepares its deparsed SQL before binding values. Parameters inside
  expressions or table-function arguments can consequently have UNKNOWN types,
  even with PostgreSQL custom plans. This adapter is only for the analytics head;
  callers execute the returned SQL with an empty parameter list.

  Values use a closed set of typed literals. SQL strings, quoted identifiers and
  comments are never interpolated. Callers must not log the resulting SQL.
  """

  @placeholder ~r/(?<![\w$])\$[0-9]+(?![\w$])/u
  @dollar_quote ~r/\A\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/
  @types %{
    "text" => :text,
    "bool" => :boolean,
    "int" => :bigint,
    "float" => :float8,
    "date" => :date,
    "timestamptz" => :timestamptz,
    "uuid" => :uuid,
    "text_array" => {:array, :text},
    "int_array" => {:array, :bigint}
  }

  @spec bind(String.t(), [term()], keyword()) :: {:ok, String.t()} | {:error, atom()}
  def bind(sql, params, opts \\ []) when is_binary(sql) and is_list(params) do
    types = Keyword.get(opts, :types, [])

    with {:ok, literals} <- parameter_literals(params, types) do
      map_sql(sql, &replace_parameters(&1, literals))
    end
  end

  @doc "Transform SQL code chunks while preserving quoted text and comments."
  @spec map_sql(String.t(), (String.t() -> {:ok, String.t()} | {:error, term()}), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def map_sql(sql, fun, opts \\ []) when is_binary(sql) and is_function(fun, 1) do
    identifiers = Keyword.get(opts, :quoted_identifiers, :protected)

    with {:ok, tokens} <- tokenize(sql, [], [], identifiers) do
      tokens
      |> Enum.reduce_while({:ok, []}, fn
        {:protected, text}, {:ok, acc} ->
          {:cont, {:ok, [text | acc]}}

        {:code, text}, {:ok, acc} ->
          case fun.(text) do
            {:ok, rewritten} -> {:cont, {:ok, [rewritten | acc]}}
            {:error, _} = error -> {:halt, error}
          end
      end)
      |> finish()
    end
  end

  defp parameter_literals(params, types) when is_list(types) do
    if types == [] or length(types) == length(params) do
      params
      |> Enum.zip(if(types == [], do: List.duplicate(nil, length(params)), else: types))
      |> Enum.reduce_while({:ok, []}, fn {value, hint}, {:ok, acc} ->
        with {:ok, type} <- parameter_type(value, hint),
             {:ok, literal} <- literal(value, type) do
          {:cont, {:ok, [literal | acc]}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, literals} -> {:ok, literals |> Enum.reverse() |> List.to_tuple()}
        error -> error
      end
    else
      {:error, :invalid_analytics_parameter}
    end
  end

  defp parameter_literals(_params, _types), do: {:error, :invalid_analytics_parameter}

  defp parameter_type(value, nil), do: infer_type(value)

  defp parameter_type(_value, hint) do
    case Map.fetch(@types, hint) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :invalid_analytics_parameter}
    end
  end

  defp infer_type(nil), do: {:ok, :null}
  defp infer_type(value) when is_binary(value), do: {:ok, :text}
  defp infer_type(value) when is_boolean(value), do: {:ok, :boolean}
  defp infer_type(value) when is_integer(value), do: {:ok, :bigint}
  defp infer_type(value) when is_float(value), do: {:ok, :float8}
  defp infer_type(%Date{}), do: {:ok, :date}
  defp infer_type(%DateTime{}), do: {:ok, :timestamptz}
  defp infer_type(%NaiveDateTime{}), do: {:ok, :timestamp}
  defp infer_type(%Decimal{}), do: {:ok, :numeric}
  defp infer_type([]), do: {:ok, {:array, :text}}

  defp infer_type(values) when is_list(values) do
    case values |> Enum.find(&(not is_nil(&1))) |> infer_type() do
      {:ok, {:array, _}} -> {:error, :invalid_analytics_parameter}
      {:ok, :null} -> {:ok, {:array, :text}}
      {:ok, type} -> {:ok, {:array, type}}
      error -> error
    end
  end

  defp infer_type(_), do: {:error, :invalid_analytics_parameter}

  defp literal(nil, :null), do: {:ok, "NULL"}
  defp literal(nil, type), do: {:ok, "CAST(NULL AS #{sql_type(type)})"}

  defp literal(value, :text) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      {:ok, "CAST(#{quote_text(value)} AS text)"}
    else
      {:error, :invalid_analytics_parameter}
    end
  end

  defp literal(value, :boolean) when is_boolean(value),
    do: {:ok, if(value, do: "TRUE", else: "FALSE")}

  defp literal(value, :bigint) when is_integer(value), do: {:ok, "CAST(#{value} AS bigint)"}
  defp literal(value, :float8) when is_number(value), do: {:ok, "CAST(#{value} AS float8)"}
  defp literal(%Date{} = value, :date), do: {:ok, "DATE '#{Date.to_iso8601(value)}'"}

  defp literal(%DateTime{} = value, :timestamptz),
    do: {:ok, "TIMESTAMPTZ '#{DateTime.to_iso8601(value)}'"}

  defp literal(%NaiveDateTime{} = value, :timestamp),
    do: {:ok, "TIMESTAMP '#{NaiveDateTime.to_iso8601(value)}'"}

  defp literal(%Decimal{} = value, :numeric) do
    if Decimal.nan?(value) or Decimal.inf?(value) do
      {:error, :invalid_analytics_parameter}
    else
      {:ok, "CAST('#{Decimal.to_string(value)}' AS numeric)"}
    end
  end

  defp literal(value, :uuid) when is_binary(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> {:ok, "CAST('#{uuid}' AS uuid)"}
      :error -> {:error, :invalid_analytics_parameter}
    end
  end

  defp literal(values, {:array, type}) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case literal(value, type) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} ->
        items = items |> Enum.reverse() |> Enum.join(", ")
        {:ok, "CAST(ARRAY[#{items}] AS #{sql_type(type)}[])"}

      error ->
        error
    end
  end

  defp literal(_value, _type), do: {:error, :invalid_analytics_parameter}

  defp sql_type({:array, type}), do: "#{sql_type(type)}[]"
  defp sql_type(type), do: Atom.to_string(type)

  defp quote_text(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("'", "''")
    "E'#{escaped}'"
  end

  defp replace_parameters(sql, literals) do
    @placeholder
    |> Regex.split(sql, include_captures: true)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case part do
        <<"$", digits::binary>> ->
          replace_parameter(part, digits, literals, acc)

        _ ->
          {:cont, {:ok, [part | acc]}}
      end
    end)
    |> finish()
  end

  defp replace_parameter(part, digits, literals, acc) do
    case Integer.parse(digits) do
      {index, ""} when index > 0 and index <= tuple_size(literals) ->
        {:cont, {:ok, [elem(literals, index - 1) | acc]}}

      {_index, ""} ->
        {:halt, {:error, :invalid_analytics_placeholder}}

      _ ->
        {:cont, {:ok, [part | acc]}}
    end
  end

  defp tokenize("", code, tokens, _identifiers), do: {:ok, Enum.reverse(flush_code(code, tokens))}

  defp tokenize(sql, code, tokens, identifiers) do
    case protected(sql) do
      {:identifier, text, rest} when identifiers == :code ->
        tokenize(rest, [text | code], tokens, identifiers)

      {kind, text, rest} when kind in [:ok, :identifier] ->
        tokenize(rest, [], [{:protected, text} | flush_code(code, tokens)], identifiers)

      :code ->
        <<byte, rest::binary>> = sql
        tokenize(rest, [<<byte>> | code], tokens, identifiers)

      {:error, _} = error ->
        error
    end
  end

  defp protected(<<prefix, "'", rest::binary>>) when prefix in [?E, ?e],
    do: quoted(rest, ?', true, [<<prefix, ?'>>])

  defp protected(<<"'", rest::binary>>), do: quoted(rest, ?', false, ["'"])

  defp protected(<<"\"", rest::binary>>) do
    case quoted(rest, ?", false, ["\""]) do
      {:ok, text, tail} -> {:identifier, text, tail}
      error -> error
    end
  end

  defp protected(<<"--", rest::binary>>) do
    case :binary.match(rest, "\n") do
      {index, 1} ->
        <<line::binary-size(index + 1), tail::binary>> = rest
        {:ok, "--" <> line, tail}

      :nomatch ->
        {:ok, "--" <> rest, ""}
    end
  end

  defp protected(<<"/*", rest::binary>>), do: block_comment(rest, 1, ["/*"])

  defp protected(<<"$", _::binary>> = sql) do
    case Regex.run(@dollar_quote, sql) do
      [delimiter] -> dollar_quoted(sql, delimiter)
      nil -> :code
    end
  end

  defp protected(_), do: :code

  defp quoted("", _quote, _escaped, _acc), do: {:error, :invalid_analytics_sql}

  defp quoted(<<quote, quote, rest::binary>>, quote, escaped, acc),
    do: quoted(rest, quote, escaped, [<<quote, quote>> | acc])

  defp quoted(<<quote, rest::binary>>, quote, _escaped, acc),
    do: {:ok, join([<<quote>> | acc]), rest}

  defp quoted(<<"\\", byte, rest::binary>>, quote, true, acc),
    do: quoted(rest, quote, true, [<<"\\", byte>> | acc])

  defp quoted(<<byte, rest::binary>>, quote, escaped, acc),
    do: quoted(rest, quote, escaped, [<<byte>> | acc])

  defp block_comment("", _depth, _acc), do: {:error, :invalid_analytics_sql}
  defp block_comment(<<"*/", rest::binary>>, 1, acc), do: {:ok, join(["*/" | acc]), rest}

  defp block_comment(<<"*/", rest::binary>>, depth, acc),
    do: block_comment(rest, depth - 1, ["*/" | acc])

  defp block_comment(<<"/*", rest::binary>>, depth, acc),
    do: block_comment(rest, depth + 1, ["/*" | acc])

  defp block_comment(<<byte, rest::binary>>, depth, acc),
    do: block_comment(rest, depth, [<<byte>> | acc])

  defp dollar_quoted(sql, delimiter) do
    size = byte_size(delimiter)
    <<_::binary-size(size), rest::binary>> = sql

    case :binary.match(rest, delimiter) do
      {index, ^size} ->
        <<body::binary-size(index + size), tail::binary>> = rest
        {:ok, delimiter <> body, tail}

      :nomatch ->
        {:error, :invalid_analytics_sql}
    end
  end

  defp flush_code([], tokens), do: tokens
  defp flush_code(code, tokens), do: [{:code, join(code)} | tokens]
  defp join(reversed), do: reversed |> Enum.reverse() |> IO.iodata_to_binary()
  defp finish({:ok, acc}), do: {:ok, join(acc)}
  defp finish({:error, _} = error), do: error
end
