defmodule ServiceRadarWebNG.JsonbParamFenceTest do
  @moduledoc """
  A pre-encoded JSON binary must never be bound to a `$n::jsonb` placeholder.

  Postgres types the parameter in `$11::jsonb` as `jsonb` (`$11::text::jsonb`
  and `($11::text)::jsonb` type it as `text`), and Postgrex encodes every value
  it sends for a `jsonb` parameter through `Jason.encode_to_iodata!/1`. Hand it
  an already-encoded binary and it encodes a second time, storing a jsonb
  **string scalar** instead of an object.

  `||` on a scalar does not merge -- it builds an array:

      '{"a":1}'::jsonb || '"{\\"b\\":2}"'::jsonb  ->  [{"a": 1}, "{\\"b\\":2}"]

  so the column stops being an object and reads raise
  `ArgumentError: cannot load [...] as type :map`.

  This shipped in `field_survey_session_metadata.ex`, whose upsert pre-encoded
  the metadata map into `$11::jsonb` and then merged with
  `metadata || EXCLUDED.metadata`. The same defect in
  `serviceradar_core`'s `SourceIdentityDrift` corrupted `ocsf_devices.metadata`
  and took the whole Armis discovery sync down.

  The tag matters: `//elixir/web-ng:unit_tests` runs only `:db_free` tests, so
  an untagged fence would never execute in CI.

  This is the sibling of `ServiceRadar.Repo.JsonbParamFenceTest` in
  `serviceradar_core`; the two scan their own `lib/` trees because a Bazel test
  target only stages its own package's sources. Keep them in step.
  """

  use ExUnit.Case, async: true

  @moduletag :db_free

  @lib_dir Path.expand("../../lib", __DIR__)

  @query_fns [:query, :query!, :query_many, :query_many!]
  @encoders [:encode!, :encode_to_iodata!]

  # `$1::text::jsonb` / `($1::text)::jsonb` put `::text` between the
  # placeholder and the cast, so they never match and are correctly safe.
  @bare_jsonb_placeholder ~r/\$\d+::jsonb/

  test "no pre-encoded JSON binary is bound to a $n::jsonb placeholder" do
    files = Path.wildcard(Path.join(@lib_dir, "**/*.ex"))

    assert length(files) > 100,
           "expected to scan the web-ng lib tree, found #{length(files)} file(s) under " <>
             "#{@lib_dir} -- the fence is not looking at anything"

    results = Enum.map(files, &analyze/1)

    unparseable = for {:unparseable, path, reason} <- results, do: {path, reason}

    assert unparseable == [],
           "these files could not be parsed, so the fence could not inspect them:\n" <>
             Enum.map_join(unparseable, "\n", fn {p, r} -> "  #{rel(p)}: #{inspect(r)}" end)

    queries = for {:ok, _path, qs} <- results, q <- qs, do: q

    # Anti-vacuity: if every bare `$n::jsonb` placeholder ever legitimately
    # disappears from web-ng, this fence guards nothing -- relax it
    # deliberately rather than letting it pass on an empty scan.
    assert Enum.any?(queries, & &1.bare_jsonb?),
           "no `$n::jsonb` placeholder found anywhere in #{@lib_dir}; the fence is vacuous"

    violations = Enum.filter(queries, &(&1.bare_jsonb? and &1.pre_encoded?))

    assert violations == [], """
    Pre-encoded JSON bound to a `$n::jsonb` placeholder:

    #{Enum.map_join(violations, "\n", fn v -> "  #{rel(v.path)}:#{v.line}" end)}

    Postgrex encodes values for a jsonb parameter itself, so this stores a JSON
    *string scalar*, and `object || string` builds an ARRAY instead of merging.

    Fix it either way:
      - pass the map and drop the `Jason.encode!`, or
      - keep the encode and cast through text: `($n::text)::jsonb`.
    """
  end

  defp analyze(path) do
    source = File.read!(path)

    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        ast = expand_pipes(ast)
        attrs = collect_string_attributes(ast)
        encoded_vars = collect_pre_encoded_vars(ast)

        queries =
          for {sql_ast, params_ast, line} <- collect_query_calls(ast) do
            sql = resolve_sql(sql_ast, attrs)

            %{
              path: path,
              line: line,
              bare_jsonb?: is_binary(sql) and Regex.match?(@bare_jsonb_placeholder, sql),
              pre_encoded?: pre_encoded?(params_ast, encoded_vars)
            }
          end

        {:ok, path, queries}

      {:error, reason} ->
        {:unparseable, path, reason}
    end
  end

  # `sql |> Repo.query(params)` -> `Repo.query(sql, params)`.
  defp expand_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [lhs, {call, meta, args}]} when is_list(args) -> {call, meta, [lhs | args]}
      other -> other
    end)
  end

  defp collect_string_attributes(ast) do
    {_, attrs} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) and is_binary(value) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    attrs
  end

  # The encoded value often reaches the parameter list through a variable.
  defp collect_pre_encoded_vars(ast) do
    {_, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:=, _, [{name, _, ctx}, rhs]} = node, acc when is_atom(name) and is_atom(ctx) ->
          if encoder_call?(rhs), do: {node, MapSet.put(acc, name)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  defp collect_query_calls(ast) do
    {_, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_mod, fun]}, meta, [sql, params | _]} = node, acc when fun in @query_fns ->
          {node, [{sql, params, Keyword.get(meta, :line, 0)} | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp resolve_sql(sql, _attrs) when is_binary(sql), do: sql

  defp resolve_sql({:@, _, [{name, _, ctx}]}, attrs) when is_atom(name) and is_atom(ctx), do: Map.get(attrs, name)

  defp resolve_sql(_, _), do: nil

  defp pre_encoded?(params_ast, encoded_vars) do
    {_, found?} =
      Macro.prewalk(params_ast, false, fn
        node, true ->
          {node, true}

        {{:., _, [{:__aliases__, _, [:Jason]}, fun]}, _, _} = node, _ when fun in @encoders ->
          {node, true}

        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, acc or MapSet.member?(encoded_vars, name)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp encoder_call?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Jason]}, fun]}, _, _} = node, _ when fun in @encoders ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp rel(path), do: Path.relative_to(path, Path.expand("../../..", @lib_dir))
end
