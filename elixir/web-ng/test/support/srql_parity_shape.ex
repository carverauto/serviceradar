defmodule ServiceRadarWebNG.SRQLParityShape do
  @moduledoc """
  The SRQL query SHAPE the StarRocks-vs-CNPG parity inventory is matched by, ported from
  `integration_tests/srql_parity/src/shape.rs`, which defines it (read its module docs for the
  rules and why each one exists).

  A shape is the canonical warehouse entity, the translation-selecting clauses (`bucket`,
  `agg`, `series`, `value_field`, `stats`, `rollup_stats`, `other`) and the `sort`/`limit`
  modifiers. Filters and windows are not part of it; the `bucket:` width and a CIDR group
  field's prefix length are wildcarded.

  The port exists because the builder-coverage test drives Elixir query builders. It cannot
  drift from the Rust definition unnoticed: `integration_tests/srql_parity/shape_examples.json`
  holds worked examples that the Rust unit tier and
  `ServiceRadarWebNGWeb.SRQL.WarehouseQueryInventoryTest` both assert.
  """

  @wildcard "*"
  @clause_keys ~w(bucket agg series value_field stats rollup_stats other)
  @modifier_keys ~w(sort limit)
  @chart_keys ~w(bucket agg series stats rollup_stats)

  @type t :: %{entity: String.t() | nil, clauses: %{String.t() => String.t()}, modifiers: MapSet.t()}

  # The canonical entity for every spelling the warehouse serves, as `warehouse_entity/1` in
  # `integration_tests/srql_parity/src/coverage.rs` lists them.
  @canonical %{
    "flows" => ~w(flows flow network_activity),
    "attributed_flows" => ~w(attributed_flows attributed_flow flow_attributions flow_attribution),
    "timeseries_metrics" => ~w(timeseries_metrics timeseries),
    "snmp_metrics" => ~w(snmp_metrics snmp),
    "rperf_metrics" => ~w(rperf_metrics rperf),
    "logs" => ~w(logs),
    "events" => ~w(events activity),
    "security_findings" => ~w(security_findings security_finding findings finding),
    "scan_activity" => ~w(scan_activity scan_activities security_scans scanner_activity),
    "dns_activity" => ~w(dns_activity dns_activities dns_security_activity powerdns pdns),
    "mtr_traces" => ~w(mtr_traces),
    "mtr_hops" => ~w(mtr_hops mtr_hop_stats),
    "otel_metrics" => ~w(otel_metrics metrics),
    "otel_metric_points" => ~w(otel_metric_points metric_points)
  }
  @spellings for {canonical, spellings} <- @canonical, spelling <- spellings, into: %{}, do: {spelling, canonical}

  @doc "The canonical warehouse entity for a spelling, or nil when the warehouse does not serve it."
  @spec canonical_entity(String.t()) :: String.t() | nil
  def canonical_entity(entity) when is_binary(entity) do
    key = entity |> String.replace(~r/\A["']+|["']+\z/, "") |> String.downcase(:ascii)
    Map.get(@spellings, key)
  end

  @doc "The shape of one SRQL text. `entity` is the raw `in:` value; see `canonical_entity/1`."
  @spec shape_of(String.t()) :: t()
  def shape_of(text) when is_binary(text) do
    tokens = tokenize(text)

    entity =
      Enum.reduce(tokens, nil, fn
        {"in", value}, _acc -> value
        _token, acc -> acc
      end)

    stats = for {"stats", value} <- tokens, do: value

    clauses =
      tokens
      |> Enum.reduce(%{}, fn
        {"bucket", _value}, acc -> Map.put(acc, "bucket", @wildcard)
        {key, value}, acc when key in @clause_keys and key != "stats" -> Map.put(acc, key, value)
        _token, acc -> acc
      end)
      |> then(fn acc -> if stats == [], do: acc, else: Map.put(acc, "stats", stats_signature(stats)) end)

    modifiers = for {key, _value} <- tokens, key in @modifier_keys, into: MapSet.new(), do: key

    %{entity: entity, clauses: clauses, modifiers: modifiers}
  end

  @doc "Whether the shape is a chart/aggregate query rather than a row listing."
  @spec chart?(t()) :: boolean()
  def chart?(%{clauses: clauses}), do: Enum.any?(Map.keys(clauses), &(&1 in @chart_keys))

  @doc """
  Whether `inventory` accounts for `shape`: the same clauses with the same values, and no more
  modifiers. Entities are compared by the caller, canonically.
  """
  @spec covered_by?(t(), t()) :: boolean()
  def covered_by?(shape, inventory) do
    shape.clauses == inventory.clauses and MapSet.subset?(shape.modifiers, inventory.modifiers)
  end

  @doc "One line describing a shape, for failure messages."
  @spec describe(t()) :: String.t()
  def describe(%{entity: entity, clauses: clauses, modifiers: modifiers}) do
    clause_parts = clauses |> Enum.sort() |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    modifier_parts = modifiers |> Enum.sort() |> Enum.map(&"+#{&1}")
    Enum.join(["in:#{entity}" | clause_parts ++ modifier_parts], " ")
  end

  # `key:value` tokens, with a quoted value kept whole and a bare `stats:` value running on
  # until the next key that is not one of its group fields (`by addr,time:1h`).
  defp tokenize(text) do
    {tokens, _bare_stats_open?, _previous} = Enum.reduce(split_words(text), {[], false, ""}, &token_step/2)
    Enum.reverse(tokens)
  end

  defp token_step(word, {tokens, open?, previous}) do
    continues_group? = open? and (String.downcase(previous, :ascii) == "by" or String.ends_with?(previous, ","))

    case {if(continues_group?, do: nil, else: split_key(word)), tokens} do
      {{key, value}, tokens} ->
        open? = key == "stats" and not String.starts_with?(value, "\"")
        {[{key, String.trim(value, "\"")} | tokens], open?, word}

      {nil, [{key, value} | rest]} when open? ->
        {[{key, value <> " " <> word} | rest], open?, word}

      {nil, tokens} ->
        {tokens, open?, word}
    end
  end

  defp split_key(word) do
    case String.split(word, ":", parts: 2) do
      [key, value] when key != "" and value != "" -> if key =~ ~r/\A[a-z0-9_.]+\z/, do: {key, value}
      _ -> nil
    end
  end

  # Whitespace separates words except inside double quotes, which stay part of the word.
  defp split_words(text) do
    {words, current, _quoted?} = Enum.reduce(String.graphemes(text), {[], "", false}, &word_step/2)
    words |> push_word(current) |> Enum.reverse()
  end

  defp word_step("\"", {words, current, quoted?}), do: {words, current <> "\"", not quoted?}
  defp word_step(char, {words, current, true}), do: {words, current <> char, true}

  defp word_step(char, {words, current, false}) do
    if String.trim(char) == "", do: {push_word(words, current), "", false}, else: {words, current <> char, false}
  end

  defp push_word(words, ""), do: words
  defp push_word(words, word), do: [word | words]

  # `sum(bytes_total) as b, count(*) as n by src_ip, dst_ip` -> `count(*),sum(bytes_total)|by:src_ip,dst_ip`
  defp stats_signature(values) do
    {functions, group_by} =
      Enum.reduce(values, {MapSet.new(), []}, fn value, {functions, group_by} ->
        {aggregates, by} = split_by(value)

        functions =
          aggregates
          |> split_top_level()
          |> Enum.map(&aggregate_expression/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.into(functions)

        {functions, group_by ++ group_fields(by)}
      end)

    functions = functions |> Enum.sort() |> Enum.join(",")
    if group_by == [], do: functions, else: "#{functions}|by:#{Enum.join(group_by, ",")}"
  end

  defp aggregate_expression(item) do
    expr = String.trim(item)

    expr =
      case :binary.match(String.downcase(expr, :ascii), " as ") do
        {at, _length} -> expr |> binary_part(0, at) |> String.trim()
        :nomatch -> expr
      end

    case String.replace(expr, " ", "") do
      "count()" -> "count(*)"
      other -> other
    end
  end

  defp split_by(value) do
    case :binary.match(String.downcase(value, :ascii), " by ") do
      {at, _length} -> {binary_part(value, 0, at), binary_part(value, at + 4, byte_size(value) - at - 4)}
      :nomatch -> {value, nil}
    end
  end

  # Commas between aggregates, not the ones inside an aggregate's arguments.
  defp split_top_level(list) do
    {items, current, _depth} = Enum.reduce(String.graphemes(list), {[], "", 0}, &top_level_step/2)
    Enum.reverse([current | items])
  end

  defp top_level_step("(", {items, current, depth}), do: {items, current <> "(", depth + 1}
  defp top_level_step(")", {items, current, depth}), do: {items, current <> ")", max(depth - 1, 0)}
  defp top_level_step(",", {items, current, 0}), do: {[current | items], "", 0}
  defp top_level_step(char, {items, current, depth}), do: {items, current <> char, depth}

  defp group_fields(nil), do: []

  defp group_fields(by) do
    by
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&group_field/1)
  end

  defp group_field(field) do
    case String.split(field, ":", parts: 2) do
      [name, length] ->
        if String.ends_with?(name, "_cidr") and length =~ ~r/\A[0-9]+\z/, do: "#{name}:#{@wildcard}", else: field

      _ ->
        field
    end
  end
end
