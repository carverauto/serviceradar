defmodule ServiceRadar.DeclarativeChecks.NodeEvaluators do
  @moduledoc """
  Pure, deterministic evaluators for `extract_field`, `threshold_assert`,
  `decision_table`, `alert_output`, and safe template variable interpolation (`2.1`).

  Zero I/O, zero database access, zero arbitrary code execution, and bounded
  linear-time regex / non-recursive JSONPath evaluation shared across scheduled
  Core passes and interactive Test Runs.
  """

  @max_regex_pattern_bytes 512
  @max_regex_subject_bytes 65_536
  @max_jsonpath_depth 16
  @template_exact_regex ~r/\A\{\{\s*(inputs|target)\.([a-zA-Z0-9._-]+)\s*\}\}\z/
  @template_inline_regex ~r/\{\{\s*(inputs|target)\.([a-zA-Z0-9._-]+)\s*\}\}/
  @unsafe_host_chars ["\r", "\n", <<0>>, " ", "\t", "@", "/", "\\", "?", "#"]

  @doc """
  Computes effective input parameters by merging declared `inputs` defaults with
  operator `parameter_overrides`.
  """
  @spec resolve_effective_inputs([map()], map() | nil) :: map()
  def resolve_effective_inputs(inputs, overrides \\ %{}) when is_list(inputs) do
    defaults =
      Enum.reduce(inputs, %{}, fn item, acc ->
        key = Map.get(item, "key") || Map.get(item, :key)
        default = Map.get(item, "default", Map.get(item, :default))
        if is_binary(key), do: Map.put(acc, key, default), else: acc
      end)

    override_map =
      case overrides do
        m when is_map(m) -> Map.new(m, fn {k, v} -> {to_string(k), v} end)
        _ -> %{}
      end

    Map.merge(defaults, override_map)
  end

  @doc """
  Interpolates `{{inputs.<key>}}` and `{{target.<field>}}` placeholders across a
  node configuration map or value, preserving scalar types on exact placeholder
  matches and validating interpolated URLs/hosts against injection.
  """
  @spec interpolate(term(), map(), map()) :: {:ok, term()} | {:error, String.t()}
  def interpolate(value, effective_inputs, target_ctx \\ %{})

  def interpolate(map, effective_inputs, target_ctx) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      key_str = to_string(k)

      with {:ok, interpolated} <- interpolate(v, effective_inputs, target_ctx),
           :ok <- validate_interpolated_field(key_str, interpolated) do
        {:cont, {:ok, Map.put(acc, key_str, interpolated)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  def interpolate(list, effective_inputs, target_ctx) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case interpolate(item, effective_inputs, target_ctx) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      {:error, _} = err -> err
    end
  end

  def interpolate(str, effective_inputs, target_ctx) when is_binary(str) do
    case Regex.run(@template_exact_regex, str) do
      [_, scope, path] ->
        lookup_template_var(scope, path, effective_inputs, target_ctx)

      nil ->
        if String.contains?(str, "{{") do
          interpolate_inline_string(str, effective_inputs, target_ctx)
        else
          {:ok, str}
        end
    end
  end

  def interpolate(other, _effective_inputs, _target_ctx), do: {:ok, other}

  defp interpolate_inline_string(str, effective_inputs, target_ctx) do
    matches = Regex.scan(@template_inline_regex, str)

    Enum.reduce_while(matches, {:ok, str}, fn [full, scope, path], {:ok, acc} ->
      case lookup_template_var(scope, path, effective_inputs, target_ctx) do
        {:ok, val} when not is_nil(val) ->
          rendered = to_string(val)

          if String.contains?(rendered, ["\r", "\n", <<0>>]) do
            {:halt,
             {:error, "interpolated value for #{scope}.#{path} contains control characters"}}
          else
            {:cont, {:ok, String.replace(acc, full, rendered, global: false)}}
          end

        {:ok, nil} ->
          {:halt, {:error, "missing template value for #{scope}.#{path}"}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp lookup_template_var("inputs", key, effective_inputs, _target_ctx) do
    case Map.fetch(effective_inputs, key) do
      {:ok, val} -> {:ok, val}
      :error -> {:error, "undeclared input '#{key}'"}
    end
  end

  defp lookup_template_var("target", "tags." <> tag_key, _effective_inputs, target_ctx) do
    tags = Map.get(target_ctx, "tags") || Map.get(target_ctx, :tags) || %{}

    val =
      if is_map(tags), do: Map.get(tags, tag_key) || Map.get(tags, safe_existing_atom(tag_key))

    {:ok, val}
  end

  defp lookup_template_var("target", field, _effective_inputs, target_ctx)
       when field in ~w(uid ip hostname url host port id name) do
    val = Map.get(target_ctx, field) || Map.get(target_ctx, safe_existing_atom(field))
    {:ok, val}
  end

  defp lookup_template_var("target", field, _effective_inputs, _target_ctx) do
    {:error, "unsupported target template field 'target.#{field}'"}
  end

  defp validate_interpolated_field("url", url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "interpolated url must use http or https scheme"}

      not is_binary(uri.host) or String.trim(uri.host) == "" ->
        {:error, "interpolated url must include a valid host"}

      not is_nil(uri.userinfo) ->
        {:error, "interpolated url must not embed userinfo credentials"}

      String.contains?(uri.host, @unsafe_host_chars) ->
        {:error, "interpolated url host contains invalid characters"}

      true ->
        :ok
    end
  end

  defp validate_interpolated_field(key, host)
       when key in ["host", "hostname"] and is_binary(host) do
    if String.trim(host) != "" and not String.contains?(host, @unsafe_host_chars) do
      :ok
    else
      {:error, "interpolated #{key} contains invalid host characters"}
    end
  end

  defp validate_interpolated_field(_key, _val), do: :ok

  ## 1. extract_field

  @doc """
  Evaluates an `extract_field` node against `upstream` signal output.
  """
  @spec evaluate_extract_field(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def evaluate_extract_field(config, upstream) when is_map(config) and is_map(upstream) do
    source_type = Map.get(config, "source_type", "field")
    output_key = Map.get(config, "output_key", "value")
    default = Map.get(config, "default")
    cast_type = Map.get(config, "cast")

    expr =
      Map.get(config, "expression") ||
        Map.get(config, "path") ||
        Map.get(config, "header") ||
        Map.get(config, "pattern") ||
        Map.get(config, "field")

    payload = unwrap_payload(upstream)

    with {:ok, raw_val} <- do_extract(source_type, expr, config, payload),
         resolved = if(is_nil(raw_val), do: default, else: raw_val),
         {:ok, casted} <- cast_extracted(resolved, cast_type) do
      status = if is_nil(casted), do: :unknown, else: :healthy

      {:ok,
       %{
         status: status,
         value: casted,
         output_key: output_key,
         payload: %{output_key => casted, "value" => casted}
       }}
    end
  end

  defp do_extract("jsonpath", expr, _config, payload) when is_binary(expr) do
    subject =
      case Map.get(payload, "body") do
        json_str when is_binary(json_str) ->
          case Jason.decode(json_str) do
            {:ok, decoded} -> decoded
            _ -> payload
          end

        body_map when is_map(body_map) or is_list(body_map) ->
          body_map

        _ ->
          payload
      end

    eval_bounded_jsonpath(expr, subject)
  end

  defp do_extract("header", header_name, _config, payload) when is_binary(header_name) do
    headers = Map.get(payload, "headers") || Map.get(payload, :headers) || payload
    target = String.downcase(String.trim(header_name))

    found =
      if is_map(headers) do
        Enum.find_value(headers, fn {k, v} ->
          if String.downcase(to_string(k)) == target do
            case v do
              [first | _] -> first
              scalar -> scalar
            end
          end
        end)
      end

    {:ok, found}
  end

  defp do_extract("regex", pattern, config, payload) when is_binary(pattern) do
    subject =
      cond do
        is_binary(Map.get(payload, "body")) -> Map.get(payload, "body")
        is_binary(Map.get(payload, "value")) -> Map.get(payload, "value")
        is_binary(Map.get(payload, "raw")) -> Map.get(payload, "raw")
        true -> ""
      end

    cond do
      byte_size(pattern) > @max_regex_pattern_bytes ->
        {:error, "regex pattern exceeds #{@max_regex_pattern_bytes} bytes"}

      byte_size(subject) > @max_regex_subject_bytes ->
        {:error, "regex subject exceeds #{@max_regex_subject_bytes} bytes"}

      Regex.match?(~r/\\[1-9]/, pattern) or
          String.contains?(pattern, ["(?=", "(?!", "(?<=", "(?<!"]) ->
        {:error, "unsafe regex construct forbidden"}

      true ->
        with {:ok, regex} <- compile_regex(pattern) do
          case Regex.run(regex, subject) do
            nil ->
              {:ok, nil}

            matches ->
              group_idx =
                case Map.get(config, "group") do
                  i when is_integer(i) and i >= 0 -> i
                  _ -> if(length(matches) > 1, do: 1, else: 0)
                end

              {:ok, Enum.at(matches, group_idx)}
          end
        end
    end
  end

  defp do_extract(kind, field_path, _config, payload)
       when kind in ["srql_field", "field"] and is_binary(field_path) do
    target_map =
      cond do
        is_map(Map.get(payload, "first_row")) ->
          Map.get(payload, "first_row")

        match?([first | _] when is_map(first), Map.get(payload, "rows")) ->
          hd(Map.get(payload, "rows"))

        true ->
          payload
      end

    {:ok, lookup_dotted_path(target_map, String.split(field_path, ".", trim: true))}
  end

  defp do_extract(kind, _expr, _config, _payload) do
    {:error, "unsupported extract_field source_type #{inspect(kind)}"}
  end

  @doc """
  Evaluates a deterministic, non-recursive JSONPath selector (`max_depth <= 16`,
  zero `..` recursive descent, zero `?(...)` script filters).
  """
  @spec eval_bounded_jsonpath(String.t(), term()) :: {:ok, term()} | {:error, String.t()}
  def eval_bounded_jsonpath(expr, data) when is_binary(expr) do
    trimmed = String.trim(expr)

    cond do
      not String.starts_with?(trimmed, "$") ->
        {:error, "JSONPath must start with '$'"}

      String.contains?(trimmed, "..") ->
        {:error, "recursive JSONPath '..' is forbidden"}

      String.contains?(trimmed, "(") ->
        {:error, "script/filter JSONPath expressions are forbidden"}

      trimmed == "$" ->
        {:ok, data}

      true ->
        with {:ok, tokens} <- parse_jsonpath_tokens(String.slice(trimmed, 1..-1//1)) do
          if length(tokens) > @max_jsonpath_depth do
            {:error, "JSONPath exceeds maximum depth #{@max_jsonpath_depth}"}
          else
            {:ok, walk_jsonpath(tokens, data)}
          end
        end
    end
  end

  defp parse_jsonpath_tokens(rest) do
    regex = ~r/\G(?:\.([a-zA-Z0-9_-]+)|\[(\d+)\]|\[['"]([^'"]+)['"]\])/
    do_parse_tokens(rest, regex, 0, byte_size(rest), [])
  end

  defp do_parse_tokens(_str, _regex, pos, len, acc) when pos >= len do
    {:ok, Enum.reverse(acc)}
  end

  defp do_parse_tokens(str, regex, pos, len, acc) do
    case Regex.run(regex, str, offset: pos, return: :index) do
      [{^pos, match_len} | captures] ->
        token = extract_token_from_captures(str, captures)
        do_parse_tokens(str, regex, pos + match_len, len, [token | acc])

      _ ->
        {:error,
         "unsupported JSONPath selector syntax near '#{binary_part(str, pos, min(16, len - pos))}'"}
    end
  end

  defp extract_token_from_captures(str, [{s1, l1} | _]) when s1 >= 0 and l1 > 0,
    do: {:key, binary_part(str, s1, l1)}

  defp extract_token_from_captures(str, [_, {s2, l2} | _]) when s2 >= 0 and l2 > 0 do
    {idx, ""} = str |> binary_part(s2, l2) |> Integer.parse()
    {:index, idx}
  end

  defp extract_token_from_captures(str, [_, _, {s3, l3} | _]) when s3 >= 0 and l3 > 0,
    do: {:key, binary_part(str, s3, l3)}

  defp walk_jsonpath([], current), do: current
  defp walk_jsonpath(_tokens, nil), do: nil

  defp walk_jsonpath([{:key, key} | rest], current) when is_map(current) do
    next =
      case Map.fetch(current, key) do
        {:ok, v} ->
          v

        :error ->
          atom_k = safe_existing_atom(key)
          if atom_k, do: Map.get(current, atom_k)
      end

    walk_jsonpath(rest, next)
  end

  defp walk_jsonpath([{:index, idx} | rest], current) when is_list(current) and idx >= 0 do
    walk_jsonpath(rest, Enum.at(current, idx))
  end

  defp walk_jsonpath(_tokens, _current), do: nil

  defp lookup_dotted_path(current, []), do: current
  defp lookup_dotted_path(nil, _parts), do: nil

  defp lookup_dotted_path(current, [part | rest]) when is_map(current) do
    next =
      case Map.fetch(current, part) do
        {:ok, v} ->
          v

        :error ->
          atom_k = safe_existing_atom(part)
          if atom_k, do: Map.get(current, atom_k)
      end

    lookup_dotted_path(next, rest)
  end

  defp lookup_dotted_path(_current, _parts), do: nil

  defp cast_extracted(nil, _cast), do: {:ok, nil}
  defp cast_extracted(val, nil), do: {:ok, val}

  defp cast_extracted(val, type) when type in ["number", "float"] and is_number(val),
    do: {:ok, val * 1.0}

  defp cast_extracted(val, type) when type in ["number", "float"] and is_binary(val) do
    case Float.parse(String.trim(val)) do
      {num, ""} -> {:ok, num}
      _ -> {:error, "cannot cast #{inspect(val)} to #{type}"}
    end
  end

  defp cast_extracted(val, "integer") when is_integer(val), do: {:ok, val}
  defp cast_extracted(val, "integer") when is_float(val), do: {:ok, trunc(val)}

  defp cast_extracted(val, "integer") when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {num, ""} -> {:ok, num}
      _ -> {:error, "cannot cast #{inspect(val)} to integer"}
    end
  end

  defp cast_extracted(val, "string"), do: {:ok, to_string(val)}
  defp cast_extracted(val, "boolean") when is_boolean(val), do: {:ok, val}
  defp cast_extracted("true", "boolean"), do: {:ok, true}
  defp cast_extracted("false", "boolean"), do: {:ok, false}
  defp cast_extracted(val, type), do: {:error, "cannot cast #{inspect(val)} to #{type}"}

  ## 2. threshold_assert

  @doc """
  Evaluates a `threshold_assert` node (`fail_closed_field`, `crit`, `warn`) against
  an upstream signal or extracted value.
  """
  @spec evaluate_threshold_assert(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def evaluate_threshold_assert(config, upstream) when is_map(config) and is_map(upstream) do
    payload = unwrap_payload(upstream)
    field = Map.get(config, "field", "value")
    fail_closed_field = Map.get(config, "fail_closed_field")
    warn_spec = Map.get(config, "warn")
    crit_spec = Map.get(config, "crit")

    pass_verdict = Map.get(config, "pass_verdict", "healthy")
    warn_verdict = Map.get(config, "warn_verdict", "degraded")
    crit_verdict = Map.get(config, "crit_verdict", "down")
    unknown_verdict = Map.get(config, "unknown_verdict", "unknown")

    # If the upstream signal explicitly reports :unknown (e.g. unconfigured entitlement),
    # propagate :unknown unless fail_closed_field fired.
    upstream_status = Map.get(upstream, :status) || Map.get(upstream, "status")

    fail_closed_triggered? =
      is_binary(fail_closed_field) and
        lookup_dotted_path(payload, String.split(fail_closed_field, ".", trim: true)) == true

    subject_value =
      case lookup_dotted_path(payload, String.split(field, ".", trim: true)) do
        nil -> Map.get(upstream, :value, Map.get(upstream, "value"))
        found -> found
      end

    cond do
      fail_closed_triggered? ->
        {:ok,
         %{
           status: :down,
           verdict: crit_verdict,
           value: subject_value,
           matched_tier: "fail_closed",
           summary: "#{fail_closed_field} is active"
         }}

      upstream_status in [:unknown, "unknown"] and is_nil(subject_value) ->
        {:ok,
         %{
           status: :unknown,
           verdict: Map.get(payload, "verdict") || unknown_verdict,
           value: nil,
           matched_tier: "unknown",
           summary: Map.get(payload, "summary") || "signal value unavailable"
         }}

      is_nil(subject_value) ->
        {:ok,
         %{
           status: :unknown,
           verdict: unknown_verdict,
           value: nil,
           matched_tier: "unknown",
           summary: "field '#{field}' is nil"
         }}

      true ->
        with {:ok, crit_hit?} <- eval_optional_comparator(crit_spec, subject_value),
             {:ok, warn_hit?} <- eval_optional_comparator(warn_spec, subject_value) do
          cond do
            crit_hit? ->
              {:ok,
               %{
                 status: :down,
                 verdict: crit_verdict,
                 value: subject_value,
                 matched_tier: "crit",
                 summary: "#{field}=#{format_scalar(subject_value)} matched critical threshold"
               }}

            warn_hit? ->
              {:ok,
               %{
                 status: :degraded,
                 verdict: warn_verdict,
                 value: subject_value,
                 matched_tier: "warn",
                 summary: "#{field}=#{format_scalar(subject_value)} matched warning threshold"
               }}

            true ->
              {:ok,
               %{
                 status: :healthy,
                 verdict: pass_verdict,
                 value: subject_value,
                 matched_tier: "pass",
                 summary: "#{field}=#{format_scalar(subject_value)} within thresholds"
               }}
          end
        end
    end
  end

  defp eval_optional_comparator(nil, _subject), do: {:ok, false}

  defp eval_optional_comparator(spec, subject) when is_map(spec) do
    op = Map.get(spec, "op") || Map.get(spec, :op)
    expected = Map.get(spec, "value", Map.get(spec, :value))
    compare_values(op, subject, expected)
  end

  @doc "Evaluates a single typed comparator (`==`, `!=`, `>`, `>=`, `<`, `<=`, `in`, `contains`, `matches`)."
  @spec compare_values(String.t(), term(), term()) :: {:ok, boolean()} | {:error, String.t()}
  def compare_values("==", a, b) when is_number(a) and is_number(b), do: {:ok, a * 1.0 == b * 1.0}
  def compare_values("==", a, b), do: {:ok, normalize_cmp(a) == normalize_cmp(b)}
  def compare_values("!=", a, b) when is_number(a) and is_number(b), do: {:ok, a * 1.0 != b * 1.0}
  def compare_values("!=", a, b), do: {:ok, normalize_cmp(a) != normalize_cmp(b)}

  def compare_values(op, a, b) when op in [">", ">=", "<", "<="] do
    with {:ok, num_a} <- to_number(a),
         {:ok, num_b} <- to_number(b) do
      res =
        case op do
          ">" -> num_a > num_b
          ">=" -> num_a >= num_b
          "<" -> num_a < num_b
          "<=" -> num_a <= num_b
        end

      {:ok, res}
    end
  end

  def compare_values("in", a, list) when is_list(list) do
    norm_a = normalize_cmp(a)
    {:ok, Enum.any?(list, &(normalize_cmp(&1) == norm_a))}
  end

  def compare_values("contains", a, substr) when is_binary(a) and is_binary(substr) do
    {:ok, String.contains?(a, substr)}
  end

  def compare_values("matches", a, pattern) when is_binary(a) and is_binary(pattern) do
    cond do
      byte_size(pattern) > @max_regex_pattern_bytes ->
        {:error, "comparator regex exceeds #{@max_regex_pattern_bytes} bytes"}

      byte_size(a) > @max_regex_subject_bytes ->
        {:error, "comparator subject exceeds #{@max_regex_subject_bytes} bytes"}

      Regex.match?(~r/\\[1-9]/, pattern) or
          String.contains?(pattern, ["(?=", "(?!", "(?<=", "(?<!"]) ->
        {:error, "unsafe regex construct forbidden"}

      true ->
        with {:ok, regex} <- compile_regex(pattern) do
          {:ok, Regex.match?(regex, a)}
        end
    end
  end

  def compare_values(op, a, b) do
    {:error, "incompatible comparator '#{op}' for #{inspect(a)} and #{inspect(b)}"}
  end

  ## 3. decision_table

  @doc """
  Evaluates a `decision_table` node over resolved upstream node outputs and Edge
  observations, enforcing per-input `max_age_seconds` staleness (`-> "unknown"`)
  and ordered first-match-wins rules with a mandatory trailing catch-all row.
  """
  @spec evaluate_decision_table(map(), map(), DateTime.t() | keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def evaluate_decision_table(config, inputs_by_handle, opts)
      when is_map(config) and is_map(inputs_by_handle) and is_list(opts) do
    evaluate_decision_table(config, inputs_by_handle, Keyword.get(opts, :now, DateTime.utc_now()))
  end

  def evaluate_decision_table(config, inputs_by_handle, %DateTime{} = now)
      when is_map(config) and is_map(inputs_by_handle) do
    declared_inputs = Map.get(config, "inputs", [])
    rules = Map.get(config, "rules", [])

    {resolved_values, snapshots} =
      Enum.reduce(declared_inputs, {%{}, %{}}, fn input_spec, {vals_acc, snap_acc} ->
        key = to_string(Map.get(input_spec, "key") || Map.get(input_spec, "alias"))
        src_node_id = Map.get(input_spec, "source_node_id") || Map.get(input_spec, "source_node")
        field = Map.get(input_spec, "field")
        max_age = Map.get(input_spec, "max_age_seconds")

        raw_obs =
          Map.get(inputs_by_handle, key) ||
            Map.get(inputs_by_handle, "in:" <> key) ||
            (src_node_id && Map.get(inputs_by_handle, src_node_id)) ||
            %{}

        {coerced_value, snap} = resolve_decision_input(raw_obs, field, max_age, now)
        {Map.put(vals_acc, key, coerced_value), Map.put(snap_acc, key, snap)}
      end)

    case match_first_rule(rules, resolved_values) do
      {:ok, rule, idx} ->
        status = normalize_status_atom(Map.get(rule, "status", "unknown"))
        verdict = to_string(Map.get(rule, "verdict", "unknown"))

        summary =
          Map.get(rule, "summary") ||
            Map.get(rule, "description") ||
            Map.get(rule, "label") ||
            verdict

        {:ok,
         %{
           status: status,
           verdict: verdict,
           summary: summary,
           matched_rule_index: idx,
           resolved_inputs: snapshots
         }}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_decision_input(obs, field, max_age_seconds, now) when is_map(obs) do
    observed_at = parse_observed_at(Map.get(obs, :observed_at) || Map.get(obs, "observed_at"))
    explicit_stale? = Map.get(obs, :stale) == true or Map.get(obs, "stale") == true

    age_stale? =
      cond do
        explicit_stale? ->
          true

        is_integer(max_age_seconds) and max_age_seconds > 0 ->
          case observed_at do
            %DateTime{} = dt ->
              DateTime.diff(now, dt, :second) > max_age_seconds

            nil ->
              Map.get(obs, :from_edge_observation) == true or Map.has_key?(obs, "observed_at")
          end

        true ->
          false
      end

    raw_val = extract_decision_value(obs, field)

    cond do
      age_stale? ->
        {"unknown",
         %{
           "value" => "unknown",
           "stale" => true,
           "observed_at" => observed_at && DateTime.to_iso8601(observed_at),
           "reason" => "stale_observation"
         }}

      is_nil(raw_val) ->
        {"unknown",
         %{
           "value" => "unknown",
           "stale" => false,
           "observed_at" => observed_at && DateTime.to_iso8601(observed_at),
           "reason" => "missing_observation"
         }}

      true ->
        norm_str = normalize_cmp(raw_val)

        {norm_str,
         %{
           "value" => norm_str,
           "stale" => false,
           "observed_at" => observed_at && DateTime.to_iso8601(observed_at),
           "reason" => nil
         }}
    end
  end

  defp extract_decision_value(obs, field) when is_binary(field) and field != "" do
    payload = unwrap_payload(obs)
    lookup_dotted_path(payload, String.split(field, ".", trim: true))
  end

  defp extract_decision_value(obs, _nil_field) do
    cond do
      not is_nil(Map.get(obs, :value)) -> Map.get(obs, :value)
      not is_nil(Map.get(obs, "value")) -> Map.get(obs, "value")
      not is_nil(Map.get(obs, :verdict)) -> Map.get(obs, :verdict)
      not is_nil(Map.get(obs, "verdict")) -> Map.get(obs, "verdict")
      not is_nil(Map.get(obs, :status)) -> Map.get(obs, :status)
      not is_nil(Map.get(obs, "status")) -> Map.get(obs, "status")
      true -> nil
    end
  end

  defp match_first_rule(rules, resolved_values) do
    rules
    |> Enum.with_index()
    |> Enum.find(fn {rule, _idx} ->
      match_map = Map.get(rule, "match") || Map.get(rule, :match) || %{}

      Enum.all?(match_map, fn {k, matcher} ->
        actual = Map.get(resolved_values, to_string(k), :__absent__)
        rule_cell_matches?(matcher, actual)
      end)
    end)
    |> case do
      {rule, idx} -> {:ok, rule, idx}
      nil -> {:error, "no matching rule in decision_table"}
    end
  end

  defp rule_cell_matches?(_matcher, :__absent__), do: false
  defp rule_cell_matches?("*", _actual), do: true

  defp rule_cell_matches?(list, actual) when is_list(list) do
    Enum.any?(list, &rule_cell_matches?(&1, actual))
  end

  defp rule_cell_matches?(matcher, actual), do: normalize_cmp(matcher) == actual

  ## 4. alert_output

  @doc """
  Evaluates an `alert_output` terminal node, applying optional `verdict_map` and
  `summary_template` to the upstream verdict.
  """
  @spec evaluate_alert_output(map(), map()) :: {:ok, map()}
  def evaluate_alert_output(config, upstream) when is_map(config) and is_map(upstream) do
    status = normalize_status_atom(Map.get(upstream, :status) || Map.get(upstream, "status"))
    status_str = Atom.to_string(status)
    vmap = Map.get(config, "verdict_map") || %{}

    upstream_verdict = Map.get(upstream, :verdict) || Map.get(upstream, "verdict")

    verdict =
      cond do
        is_map(vmap) and is_binary(Map.get(vmap, status_str)) ->
          Map.get(vmap, status_str)

        is_binary(upstream_verdict) and upstream_verdict != "" ->
          upstream_verdict

        true ->
          status_str
      end

    summary =
      case Map.get(config, "summary_template") do
        tmpl when is_binary(tmpl) and tmpl != "" ->
          tmpl
          |> String.replace("{{verdict}}", verdict)
          |> String.replace("{{status}}", status_str)

        _ ->
          Map.get(upstream, :summary) || Map.get(upstream, "summary") || verdict
      end

    {:ok,
     %{
       status: status,
       verdict: verdict,
       summary: summary
     }}
  end

  ## Helpers

  defp unwrap_payload(%{payload: payload}) when is_map(payload), do: payload
  defp unwrap_payload(%{"payload" => payload}) when is_map(payload), do: payload
  defp unwrap_payload(map) when is_map(map), do: map

  defp compile_regex(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, pos}} -> {:error, "invalid regex at #{pos}: #{reason}"}
    end
  end

  defp to_number(n) when is_number(n), do: {:ok, n * 1.0}

  defp to_number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {num, ""} -> {:ok, num}
      _ -> {:error, "expected numeric value, got #{inspect(s)}"}
    end
  end

  defp to_number(other), do: {:error, "expected numeric value, got #{inspect(other)}"}

  defp normalize_cmp(v) when is_binary(v), do: v
  defp normalize_cmp(v) when is_atom(v), do: Atom.to_string(v)
  defp normalize_cmp(v), do: to_string(v)

  defp normalize_status_atom(s) when s in [:healthy, :degraded, :down, :unknown], do: s
  defp normalize_status_atom("healthy"), do: :healthy
  defp normalize_status_atom("degraded"), do: :degraded
  defp normalize_status_atom("down"), do: :down
  defp normalize_status_atom(_), do: :unknown

  defp parse_observed_at(%DateTime{} = dt), do: dt

  defp parse_observed_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_observed_at(_), do: nil

  defp format_scalar(f) when is_float(f), do: :erlang.float_to_binary(f, [:compact, decimals: 2])
  defp format_scalar(other), do: to_string(other)

  defp safe_existing_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end
end
