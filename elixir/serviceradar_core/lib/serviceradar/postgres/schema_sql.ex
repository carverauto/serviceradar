defmodule ServiceRadar.Postgres.SchemaSql do
  @moduledoc false

  @spec load_statements(Path.t(), keyword()) :: [String.t()]
  def load_statements(path, opts \\ []) do
    path
    |> File.read!()
    |> split()
    |> maybe_normalize_timescaledb_schema(opts)
  end

  @spec split(String.t()) :: [String.t()]
  def split(sql) when is_binary(sql) do
    sql
    |> strip_psql_meta_commands()
    |> do_split([], [])
    |> Enum.reverse()
  end

  defp strip_psql_meta_commands(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim_leading(line)
      String.starts_with?(trimmed, "\\restrict ") or String.starts_with?(trimmed, "\\unrestrict ")
    end)
    |> Enum.join("\n")
  end

  defp do_split(<<>>, current, statements) do
    push_statement(current, statements)
  end

  defp do_split(<<"--", rest::binary>>, current, statements) do
    {_comment, rest} = take_until_newline(rest, [])
    do_split(rest, current, statements)
  end

  defp do_split(<<"/*", rest::binary>>, current, statements) do
    do_split(skip_block_comment(rest), current, statements)
  end

  defp do_split(<<"'", rest::binary>>, current, statements) do
    {quoted, rest} = take_single_quoted(rest, ["'"])
    do_split(rest, [quoted | current], statements)
  end

  defp do_split(<<"\"", rest::binary>>, current, statements) do
    {quoted, rest} = take_double_quoted(rest, ["\""])
    do_split(rest, [quoted | current], statements)
  end

  defp do_split(<<"$", _rest::binary>> = sql, current, statements) do
    case dollar_quote_tag(sql) do
      nil ->
        <<char::binary-size(1), rest::binary>> = sql
        do_split(rest, [char | current], statements)

      tag ->
        <<^tag::binary-size(byte_size(tag)), rest::binary>> = sql
        {quoted, rest} = take_dollar_quoted(rest, tag, [tag])
        do_split(rest, [quoted | current], statements)
    end
  end

  defp do_split(<<";", rest::binary>>, current, statements) do
    do_split(rest, [], push_statement(current, statements))
  end

  defp do_split(<<char::binary-size(1), rest::binary>>, current, statements) do
    do_split(rest, [char | current], statements)
  end

  defp push_statement([], statements), do: statements

  defp push_statement(current, statements) do
    statement = current |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()

    if statement == "" do
      statements
    else
      [statement | statements]
    end
  end

  defp take_until_newline(<<"\n", rest::binary>>, acc), do: {acc, <<"\n", rest::binary>>}
  defp take_until_newline(<<>>, acc), do: {acc, ""}

  defp take_until_newline(<<char::binary-size(1), rest::binary>>, acc) do
    take_until_newline(rest, [char | acc])
  end

  defp skip_block_comment(<<"*/", rest::binary>>), do: rest
  defp skip_block_comment(<<_char::binary-size(1), rest::binary>>), do: skip_block_comment(rest)
  defp skip_block_comment(<<>>), do: ""

  defp take_single_quoted(<<"''", rest::binary>>, acc) do
    take_single_quoted(rest, ["''" | acc])
  end

  defp take_single_quoted(<<"'", rest::binary>>, acc) do
    {IO.iodata_to_binary(Enum.reverse(["'" | acc])), rest}
  end

  defp take_single_quoted(<<char::binary-size(1), rest::binary>>, acc) do
    take_single_quoted(rest, [char | acc])
  end

  defp take_single_quoted(<<>>, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), ""}

  defp take_double_quoted(<<"\"\"", rest::binary>>, acc) do
    take_double_quoted(rest, ["\"\"" | acc])
  end

  defp take_double_quoted(<<"\"", rest::binary>>, acc) do
    {IO.iodata_to_binary(Enum.reverse(["\"" | acc])), rest}
  end

  defp take_double_quoted(<<char::binary-size(1), rest::binary>>, acc) do
    take_double_quoted(rest, [char | acc])
  end

  defp take_double_quoted(<<>>, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), ""}

  defp take_dollar_quoted(sql, tag, acc) do
    if String.starts_with?(sql, tag) do
      <<^tag::binary-size(byte_size(tag)), rest::binary>> = sql
      {IO.iodata_to_binary(Enum.reverse([tag | acc])), rest}
    else
      case sql do
        <<char::binary-size(1), rest::binary>> -> take_dollar_quoted(rest, tag, [char | acc])
        <<>> -> {IO.iodata_to_binary(Enum.reverse(acc)), ""}
      end
    end
  end

  defp dollar_quote_tag(sql) do
    case Regex.run(~r/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/, sql) do
      [tag] -> tag
      _ -> nil
    end
  end

  defp maybe_normalize_timescaledb_schema(statements, opts) do
    if Keyword.get(opts, :normalize_timescaledb_schema?, false) do
      search_path = Keyword.get(opts, :timescaledb_search_path, "platform, public, ag_catalog")

      Enum.map(statements, fn statement ->
        statement
        |> normalize_extension_owned_references()
        |> String.replace(
          "SELECT pg_catalog.set_config('search_path', '', false)",
          "SELECT pg_catalog.set_config('search_path', '#{search_path}', false)"
        )
      end)
    else
      statements
    end
  end

  defp normalize_extension_owned_references(statement) do
    statement
    |> String.replace("platform.time_bucket(", "time_bucket(")
    |> String.replace("platform.geometry(", "geometry(")
    |> String.replace("platform.geography(", "geography(")
    |> String.replace("::platform.geography", "::geography")
    |> String.replace("platform.st_setsrid(", "st_setsrid(")
    |> String.replace("platform.st_makepoint(", "st_makepoint(")
    |> String.replace("platform.vector(", "vector(")
    |> String.replace(" platform.vector_cosine_ops", " vector_cosine_ops")
  end
end
