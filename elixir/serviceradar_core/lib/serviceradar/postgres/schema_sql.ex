defmodule ServiceRadar.Postgres.SchemaSql do
  @moduledoc false

  # Extensions the application role may legitimately be unable to install.
  #
  # The authority is priv/repo/migrations/20260123111500_add_pg_stat_statements.exs, which
  # creates this one inside an `insufficient_privilege` handler rather than plainly. That is a
  # decision the project already made, and for good reasons: it is an observability extension,
  # nothing in the schema references it, and it is not a TRUSTED extension, so on a managed
  # cluster the application role cannot create it however the deployment is configured.
  #
  # Every other extension the baseline names IS required, so its CREATE stays unguarded: a
  # missing `vector` or `timescaledb` must fail here, naming the extension, rather than 700
  # statements later as `type "vector" does not exist`.
  @optional_extensions ~w(pg_stat_statements)

  @spec load_statements(Path.t(), keyword()) :: [String.t()]
  def load_statements(path, opts \\ []) do
    path
    |> File.read!()
    |> split()
    |> maybe_normalize_timescaledb_schema(opts)
    |> maybe_apply_extension_privilege_discipline(opts)
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

  # Restores the privilege discipline the migrations have and `pg_dump` does not.
  #
  # The baseline reproduces the SCHEMA the migration history builds, but it is produced by
  # `pg_dump --schema-only` running as the cluster SUPERUSER, and it re-emits the extension
  # layer the way that superuser would write it. The migrations never wrote it that way, and no
  # environment applies it that way:
  #
  #   * The fixture installs extensions from //rust/integration-db's `install_extensions`, on an
  #     ADMIN connection, before any migrator runs.
  #   * A CNPG deployment installs them from the cluster's `postInitApplicationSQL`, as the
  #     superuser, plus the extension-update job in //helm/serviceradar.
  #
  # In both, the role that then applies this baseline is the ordinary application role, and it
  # does not own the extensions. On 2026-09-05 that closed the whole fleet: `sr_core_template`
  # was empty, so every run -- trunk included -- fell through to the baseline and died on
  # statement twelve with `42501 must be owner of extension timescaledb`. The path had simply
  # never been exercised by a non-owner role, because the template had never been rebuilt from
  # empty.
  defp maybe_apply_extension_privilege_discipline(statements, opts) do
    if Keyword.get(opts, :apply_extension_privilege_discipline?, false) do
      statements
      |> Enum.reject(&comment_on_extension?/1)
      |> Enum.map(&guard_optional_extension/1)
    else
      statements
    end
  end

  # `COMMENT ON EXTENSION x IS '...'` requires ownership of x, and buys nothing.
  #
  # The text pg_dump emits is the extension's own control-file description, which PostgreSQL
  # already attached when the extension was created -- so the statement is a no-op whenever it
  # succeeds, and changes the outcome only by failing. The migration history contains no
  # COMMENT ON EXTENSION at all; these exist purely because the dump round-trips them.
  defp comment_on_extension?(statement) do
    Regex.match?(~r/\A\s*COMMENT\s+ON\s+EXTENSION\b/i, statement)
  end

  # Wraps an OPTIONAL extension's CREATE in the same handler its migration uses, so a role
  # without the privilege skips it with a notice instead of aborting the baseline.
  #
  # Deliberately the same shape as the migration rather than a cleverer one, because the two
  # have to mean the same thing: this runs INSTEAD of that migration on a baselined database.
  defp guard_optional_extension(statement) do
    case optional_extension_created_by(statement) do
      nil ->
        statement

      extension ->
        String.trim("""
        DO $serviceradar_optional_extension$
        BEGIN
          #{statement};
        EXCEPTION
          WHEN insufficient_privilege THEN
            RAISE NOTICE 'Skipping #{extension} extension creation (insufficient privileges)';
        END
        $serviceradar_optional_extension$
        """)
    end
  end

  defp optional_extension_created_by(statement) do
    if Regex.match?(~r/\A\s*CREATE\s+EXTENSION\b/i, statement) do
      Enum.find(@optional_extensions, fn extension ->
        Regex.match?(~r/\b#{Regex.escape(extension)}\b/i, statement)
      end)
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
