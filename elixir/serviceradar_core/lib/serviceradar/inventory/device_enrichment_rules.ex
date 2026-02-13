defmodule ServiceRadar.Inventory.DeviceEnrichmentRules do
  @moduledoc """
  Rule-based device enrichment for vendor/type/model classification.

  Rules are loaded from:
  1) Built-in defaults: priv/device_enrichment/rules/*.yaml
  2) Optional filesystem overrides: /var/lib/serviceradar/rules/device-enrichment/*.yaml
  """

  require Logger

  @persistent_term_key {__MODULE__, :rules}
  @default_rules_dir "/var/lib/serviceradar/rules/device-enrichment"
  @allowed_match_keys ~w(sys_descr sys_name hostname model source sys_object_id_prefixes ip_forwarding)
  @allowed_set_keys ~w(vendor_name model type type_id model_from_sys_descr_prefix)

  @type classification :: %{
          vendor_name: String.t() | nil,
          model: String.t() | nil,
          type: String.t() | nil,
          type_id: integer() | nil,
          rule_id: String.t() | nil,
          confidence: integer() | nil,
          reason: String.t() | nil,
          source: String.t() | nil
        }
  @type normalized_rule :: %{
          id: String.t(),
          enabled: boolean(),
          priority: integer(),
          match: map(),
          set: map(),
          confidence: integer(),
          reason: String.t(),
          source: String.t()
        }

  @spec classify(map()) :: classification()
  def classify(update) when is_map(update) do
    ctx = build_context(update)

    rules()
    |> Enum.find(&matches_rule?(&1, ctx))
    |> apply_rule(ctx)
  end

  @spec reload() :: :ok
  def reload do
    :persistent_term.erase(@persistent_term_key)
    :ok
  end

  @spec reload_cluster() ::
          {:ok, [node()]} | {:error, %{reloaded: [node()], failed: [{node(), term()}]}}
  def reload_cluster do
    targets =
      case discover_core_nodes() do
        [] -> [Node.self()]
        nodes -> nodes
      end

    {reloaded, failed} =
      Enum.reduce(targets, {[], []}, fn node, {ok_acc, err_acc} ->
        result =
          if node == Node.self() do
            reload()
          else
            :rpc.call(node, __MODULE__, :reload, [], 5_000)
          end

        case result do
          :ok -> {[node | ok_acc], err_acc}
          {:badrpc, reason} -> {ok_acc, [{node, reason} | err_acc]}
          other -> {ok_acc, [{node, other} | err_acc]}
        end
      end)

    reloaded = Enum.reverse(reloaded)
    failed = Enum.reverse(failed)

    if failed == [] do
      {:ok, reloaded}
    else
      {:error, %{reloaded: reloaded, failed: failed}}
    end
  end

  @spec parse_and_validate_yaml(binary(), keyword()) ::
          {:ok, [normalized_rule()]} | {:error, [String.t()]}
  def parse_and_validate_yaml(content, opts \\ []) when is_binary(content) do
    source = Keyword.get(opts, :source, "filesystem")
    file = Keyword.get(opts, :file, "<inline>")

    case YamlElixir.read_from_string(content) do
      {:ok, parsed} -> validate_rule_document(parsed, source: source, file: file)
      {:error, reason} -> {:error, ["YAML parse error: #{inspect(reason)}"]}
      parsed -> validate_rule_document(parsed, source: source, file: file)
    end
  end

  @spec validate_rule_document(term(), keyword()) ::
          {:ok, [normalized_rule()]} | {:error, [String.t()]}
  def validate_rule_document(parsed, opts \\ []) do
    source = Keyword.get(opts, :source, "filesystem")
    file = Keyword.get(opts, :file, "<inline>")
    rules = extract_rules(parsed)

    if rules == [] do
      {:error, ["rules must be a non-empty list"]}
    else
      {normalized, errors} = normalize_rules(rules, source, file)
      validate_rule_document_result(normalized, errors)
    end
  end

  defp normalize_rules(rules, source, file) do
    Enum.reduce(rules, {[], []}, fn rule, {ok_acc, err_acc} ->
      case normalize_rule_result(rule, source, file) do
        {:ok, normalized_rule} -> {[normalized_rule | ok_acc], err_acc}
        {:error, message} -> {ok_acc, [message | err_acc]}
      end
    end)
  end

  defp validate_rule_document_result(normalized, []), do: {:ok, Enum.reverse(normalized)}
  defp validate_rule_document_result(_normalized, errors), do: {:error, Enum.reverse(errors)}

  defp rules do
    case :persistent_term.get(@persistent_term_key, :missing) do
      :missing ->
        loaded = load_rules()
        :persistent_term.put(@persistent_term_key, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  defp load_rules do
    builtin_files = Path.wildcard(Path.join([priv_rules_dir(), "*.yaml"]))
    override_files = Path.wildcard(Path.join([rules_dir(), "*.yaml"]))

    builtin_rules = load_rule_files(builtin_files, "builtin")
    override_rules = load_rule_files(override_files, "filesystem")

    merged =
      (builtin_rules ++ override_rules)
      |> Enum.reduce(%{}, fn rule, acc -> Map.put(acc, rule.id, rule) end)
      |> Map.values()
      |> Enum.sort_by(fn rule -> {-rule.priority, rule.id} end)

    Logger.info(
      "Device enrichment rules loaded: total=#{length(merged)} builtin=#{length(builtin_rules)} filesystem=#{length(override_rules)}"
    )

    merged
  end

  defp load_rule_files(files, source_label) do
    Enum.flat_map(files, fn file ->
      case YamlElixir.read_from_file(file) do
        {:ok, parsed} ->
          parsed
          |> extract_rules()
          |> Enum.map(&normalize_rule(&1, source_label, file))
          |> Enum.reject(&is_nil/1)

        {:error, reason} ->
          Logger.warning("Skipping invalid enrichment rule file #{file}: #{inspect(reason)}")
          []

        parsed ->
          parsed
          |> extract_rules()
          |> Enum.map(&normalize_rule(&1, source_label, file))
          |> Enum.reject(&is_nil/1)
      end
    end)
  rescue
    e ->
      Logger.warning("Failed to load enrichment rules: #{inspect(e)}")
      []
  end

  defp extract_rules(%{"rules" => rules}) when is_list(rules), do: rules
  defp extract_rules(%{rules: rules}) when is_list(rules), do: rules
  defp extract_rules(list) when is_list(list), do: list
  defp extract_rules(_), do: []

  defp normalize_rule(rule, source_label, file) do
    case normalize_rule_result(rule, source_label, file) do
      {:ok, normalized_rule} ->
        normalized_rule

      {:error, reason} ->
        Logger.warning(reason)
        nil
    end
  end

  defp normalize_rule_result(rule, source_label, file) do
    id = get_string(rule, ["id", :id])
    match = get_map(rule, ["match", :match])
    set = get_map(rule, ["set", :set])
    confidence = get_int(rule, ["confidence", :confidence], 50)

    case normalize_rule_errors(id, confidence, match, set, file) do
      :ok ->
        {:ok,
         %{
           id: id,
           enabled: get_bool(rule, ["enabled", :enabled], true),
           priority: get_int(rule, ["priority", :priority], 0),
           match: match,
           set: set,
           confidence: confidence,
           reason: get_string(rule, ["reason", :reason]) || "rule:#{id}",
           source: source_label
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_rule_errors(nil, _confidence, _match, _set, file),
    do: {:error, "Skipping enrichment rule without id in #{file}"}

  defp normalize_rule_errors("", _confidence, _match, _set, file),
    do: {:error, "Skipping enrichment rule without id in #{file}"}

  defp normalize_rule_errors(id, confidence, _match, _set, file)
       when not (is_integer(confidence) and confidence >= 0 and confidence <= 100),
       do:
         {:error,
          "Skipping enrichment rule #{id} in #{file}: confidence must be an integer between 0 and 100"}

  defp normalize_rule_errors(id, _confidence, match, set, file) do
    with :ok <- validate_match(match),
         :ok <- validate_set(set) do
      :ok
    else
      {:error, reason} ->
        {:error, "Skipping enrichment rule #{id} in #{file}: #{reason}"}
    end
  end

  defp validate_match(match) when is_map(match) do
    all = get_map(match, ["all", :all])
    any = get_map(match, ["any", :any])

    cond do
      map_size(match) == 0 ->
        {:error, "match must be a non-empty map"}

      map_size(all) == 0 and map_size(any) == 0 ->
        {:error, "match must include non-empty all and/or any conditions"}

      true ->
        case validate_match_branch(all, "match.all") do
          :ok -> validate_match_branch(any, "match.any")
          error -> error
        end
    end
  end

  defp validate_match(_), do: {:error, "match must be a map"}

  defp validate_match_branch(branch, _label) when branch == %{}, do: :ok

  defp validate_match_branch(branch, label) when is_map(branch) do
    Enum.reduce_while(branch, :ok, fn {key, value}, _acc ->
      normalized_key = normalize_key(key)

      cond do
        normalized_key not in @allowed_match_keys ->
          {:halt, {:error, "#{label} contains unsupported key #{inspect(key)}"}}

        invalid_match_value?(normalized_key, value) ->
          {:halt,
           {:error,
            "#{label}.#{normalized_key} must be a scalar or list of scalars (sys_object_id_prefixes and ip_forwarding support lists)"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_match_branch(_branch, label), do: {:error, "#{label} must be a map"}

  defp invalid_match_value?(_key, value) do
    invalid_scalar_or_list?(value, &(is_integer(&1) or is_binary(&1) or is_atom(&1)))
  end

  defp validate_set(set) when is_map(set) do
    cond do
      map_size(set) == 0 ->
        {:error, "set must be a non-empty map"}

      Enum.any?(Map.keys(set), &(normalize_key(&1) not in @allowed_set_keys)) ->
        invalid =
          set
          |> Map.keys()
          |> Enum.map(&normalize_key/1)
          |> Enum.filter(&(&1 not in @allowed_set_keys))
          |> Enum.uniq()
          |> Enum.join(", ")

        {:error, "set contains unsupported keys: #{invalid}"}

      Enum.empty?(Map.keys(set)) ->
        {:error, "set must include at least one supported output field"}

      true ->
        :ok
    end
  end

  defp validate_set(_), do: {:error, "set must be a map"}

  defp invalid_scalar_or_list?(value, validator) when is_list(value) do
    value == [] or Enum.any?(value, &(not validator.(&1)))
  end

  defp invalid_scalar_or_list?(value, validator), do: not validator.(value)

  defp matches_rule?(%{enabled: false}, _ctx), do: false

  defp matches_rule?(rule, ctx) do
    match = rule.match || %{}

    if map_size(match) == 0 do
      false
    else
      all_match?(ctx, get_map(match, ["all", :all])) and
        any_match?(ctx, get_map(match, ["any", :any]))
    end
  end

  defp all_match?(_ctx, all) when all in [%{}, []], do: true

  defp all_match?(ctx, all) when is_map(all) do
    Enum.all?(all, fn {key, expected} ->
      matches_condition?(ctx, key, expected)
    end)
  end

  defp all_match?(_ctx, _), do: true

  defp any_match?(_ctx, any) when any in [%{}, []], do: true

  defp any_match?(ctx, any) when is_map(any) do
    Enum.any?(any, fn {key, expected} ->
      matches_condition?(ctx, key, expected)
    end)
  end

  defp any_match?(_ctx, _), do: true

  defp matches_condition?(ctx, key, expected) do
    normalized_key = normalize_key(key)
    value = Map.get(ctx, normalized_key)

    cond do
      is_list(expected) ->
        case normalized_key do
          "sys_object_id_prefixes" ->
            Enum.any?(expected, &matches_prefix?(Map.get(ctx, "sys_object_id"), to_string(&1)))

          _ ->
            contains_any?(value, expected)
        end

      is_binary(expected) ->
        case normalized_key do
          "sys_object_id_prefixes" ->
            matches_prefix?(Map.get(ctx, "sys_object_id"), expected)

          _ ->
            contains_token?(value, expected)
        end

      is_integer(expected) ->
        value == expected

      true ->
        false
    end
  end

  defp contains_any?(value, expected) when is_binary(value) and is_list(expected) do
    expected
    |> Enum.map(&to_string/1)
    |> Enum.any?(&contains_token?(value, &1))
  end

  defp contains_any?(value, expected) when is_integer(value) and is_list(expected) do
    Enum.any?(expected, fn candidate ->
      case Integer.parse(to_string(candidate)) do
        {parsed, ""} -> parsed == value
        _ -> false
      end
    end)
  end

  defp contains_any?(_, _), do: false

  defp contains_token?(value, token) when is_binary(value) and is_binary(token) do
    String.contains?(String.downcase(value), String.downcase(String.trim(token)))
  end

  defp contains_token?(_, _), do: false

  defp matches_prefix?(nil, _prefix), do: false
  defp matches_prefix?("", _prefix), do: false

  defp matches_prefix?(value, prefix) when is_binary(value) and is_binary(prefix) do
    normalized_value = value |> String.trim() |> String.trim_leading(".")
    normalized_prefix = prefix |> String.trim() |> String.trim_leading(".")
    String.starts_with?(normalized_value, normalized_prefix)
  end

  defp apply_rule(nil, _ctx),
    do: %{
      vendor_name: nil,
      model: nil,
      type: nil,
      type_id: nil,
      rule_id: nil,
      confidence: nil,
      reason: nil,
      source: nil
    }

  defp apply_rule(rule, ctx) do
    set = rule.set || %{}
    model = extract_model(set, ctx)

    %{
      vendor_name: get_string(set, ["vendor_name", :vendor_name]),
      model: model,
      type: get_string(set, ["type", :type]),
      type_id: get_int(set, ["type_id", :type_id], nil),
      rule_id: rule.id,
      confidence: rule.confidence,
      reason: rule.reason,
      source: rule.source
    }
  end

  defp extract_model(set, ctx) do
    explicit = get_string(set, ["model", :model])

    if explicit in [nil, ""] do
      model_from_prefix(set, ctx)
    else
      explicit
    end
  end

  defp model_from_prefix(set, ctx) do
    case get_string(set, ["model_from_sys_descr_prefix", :model_from_sys_descr_prefix]) do
      nil ->
        nil

      prefix ->
        normalized_prefix = String.trim(prefix)

        if normalized_prefix == "" do
          nil
        else
          sys_descr = Map.get(ctx, "sys_descr", "")
          extract_model_from_prefix(sys_descr, normalized_prefix)
        end
    end
  end

  defp extract_model_from_prefix(sys_descr, prefix)
       when is_binary(sys_descr) and is_binary(prefix) do
    if String.contains?(sys_descr, prefix) do
      sys_descr
      |> String.split(prefix, parts: 2)
      |> Enum.at(1)
      |> to_string()
      |> String.split(~r/\s+Linux/i, parts: 2)
      |> List.first()
      |> String.split(",", parts: 2)
      |> List.first()
      |> String.trim()
      |> case do
        "" -> nil
        value -> value
      end
    else
      nil
    end
  end

  defp extract_model_from_prefix(_sys_descr, _prefix), do: nil

  defp build_context(update) do
    metadata = Map.get(update, :metadata) || %{}
    sys_descr = get_string(metadata, ["sys_descr", "sysDescr", "sys_description"]) || ""
    sys_name = get_string(metadata, ["sys_name", "sysName"]) || ""

    sys_object_id =
      get_string(metadata, ["sys_object_id", "sysObjectID", "sys_objectid", "sysObjectId"]) || ""

    %{
      "sys_descr" => String.downcase(sys_descr),
      "sys_name" => String.downcase(sys_name),
      "sys_object_id" => sys_object_id,
      "hostname" => String.downcase(to_string(Map.get(update, :hostname) || "")),
      "model" =>
        String.downcase(
          to_string(get_string(metadata, ["model", "device_model", "model_name"]) || "")
        ),
      "ip_forwarding" =>
        metadata
        |> get_string(["ip_forwarding", "ipForwarding"])
        |> parse_int(),
      "source" => String.downcase(to_string(Map.get(update, :source) || ""))
    }
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(_), do: nil

  defp get_string(map, keys) do
    case get_value(map, keys) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      value when is_atom(value) ->
        value |> Atom.to_string() |> String.trim()

      _ ->
        nil
    end
  end

  defp get_int(map, keys, default) do
    case get_value(map, keys) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp get_bool(map, keys, default) do
    case get_value(map, keys) do
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp get_map(map, keys) do
    case get_value(map, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp get_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case map do
        %{^key => value} -> value
        _ -> nil
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key),
    do: key |> String.downcase() |> String.replace("-", "_")

  defp rules_dir do
    case Application.get_env(:serviceradar_core, :device_enrichment_rules_dir, @default_rules_dir) do
      nil -> @default_rules_dir
      "" -> @default_rules_dir
      dir -> dir
    end
  end

  defp priv_rules_dir do
    priv_dir =
      :serviceradar_core
      |> :code.priv_dir()
      |> to_string()

    Path.join([priv_dir, "device_enrichment", "rules"])
  end

  defp discover_core_nodes do
    [Node.self() | Node.list()]
    |> Enum.filter(fn node ->
      node
      |> to_string()
      |> String.starts_with?("serviceradar_core@")
    end)
    |> Enum.uniq()
  end
end
