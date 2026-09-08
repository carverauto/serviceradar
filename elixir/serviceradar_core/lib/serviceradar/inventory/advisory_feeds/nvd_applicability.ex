defmodule ServiceRadar.Inventory.AdvisoryFeeds.NvdApplicability do
  @moduledoc """
  Normalizes and evaluates NVD configuration expressions without database or IO.

  Evaluation uses strong Kleene three-valued logic. An absent endpoint fact is
  therefore `:unknown`; it is never silently promoted to true or contradicted.
  """

  alias ServiceRadar.Inventory.AdvisoryFeeds.Cpe
  alias ServiceRadar.Inventory.AdvisoryFeeds.VersionRange

  @expression_version 2
  @cpe_fields ~w(part vendor product version update edition language sw_edition target_sw target_hw other)a

  @type truth :: true | false | :unknown

  @spec expression_version() :: pos_integer()
  def expression_version, do: @expression_version

  @doc false
  @spec merge_metadata(map(), map()) :: map()
  def merge_metadata(left, right) when is_map(left) and left == right, do: left

  def merge_metadata(left, right) when is_map(left) and is_map(right) do
    merged = deterministic_map_merge(left, right)

    case {metadata_value(left, "nvd_applicability"), metadata_value(right, "nvd_applicability")} do
      {%{} = left_applicability, %{} = right_applicability} ->
        merged
        |> Map.delete(:nvd_applicability)
        |> Map.put(
          "nvd_applicability",
          merge_applicability(left_applicability, right_applicability)
        )

      {%{} = applicability, _missing_or_invalid} ->
        merged
        |> Map.delete(:nvd_applicability)
        |> Map.put("nvd_applicability", applicability)

      {_missing_or_invalid, %{} = applicability} ->
        merged
        |> Map.delete(:nvd_applicability)
        |> Map.put("nvd_applicability", applicability)

      _none ->
        merged
    end
  end

  def merge_metadata(left, _right) when is_map(left), do: deterministic_map_merge(left, %{})
  def merge_metadata(_left, right) when is_map(right), do: deterministic_map_merge(%{}, right)
  def merge_metadata(_left, _right), do: %{}

  @spec normalize(term()) ::
          {:ok, %{coordinates: [map()], expression_version: pos_integer()}} | {:error, term()}
  def normalize(%{"configurations" => configurations}), do: normalize(configurations)

  def normalize(configurations) when is_list(configurations) do
    alternatives =
      configurations
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {configuration, index} when is_map(configuration) ->
          path = "configurations/#{index}"
          expression = normalize_group(configuration, path, "and", "configuration_id")

          expression
          |> terms()
          |> Enum.filter(&(&1["role"] == "affected"))
          |> Enum.flat_map(fn term ->
            case coordinate(term) do
              nil -> []
              coordinate -> [{coordinate, term, require_term(expression, term["term_id"])}]
            end
          end)

        _ ->
          []
      end)

    coordinates =
      alternatives
      |> Enum.group_by(fn {coordinate, _term, _expression} -> coordinate_identity(coordinate) end)
      |> Enum.map(fn {_identity, occurrences} -> merge_occurrences(occurrences) end)
      |> Enum.sort_by(&coordinate_identity/1)

    {:ok, %{coordinates: coordinates, expression_version: @expression_version}}
  end

  def normalize(_configurations), do: {:error, :invalid_configurations}

  @spec evaluate(map(), map()) :: %{
          result: truth(),
          matched_terms: [map()],
          contradicted_terms: [map()],
          unknown_terms: [map()]
        }
  def evaluate(expression, facts) when is_map(expression) and is_map(facts) do
    {result, evaluated_terms} = eval(expression, facts)

    classified =
      evaluated_terms
      |> Enum.reduce(%{}, fn {term, truth}, acc ->
        Map.put_new(acc, term_key(term), {term, truth})
      end)
      |> Map.values()
      |> Enum.sort_by(fn {term, _truth} -> term_key(term) end)

    %{
      result: result,
      matched_terms: classified_terms(classified, true),
      contradicted_terms: classified_terms(classified, false),
      unknown_terms: classified_terms(classified, :unknown)
    }
  end

  def evaluate(_expression, _facts) do
    %{result: :unknown, matched_terms: [], contradicted_terms: [], unknown_terms: []}
  end

  defp normalize_group(group, path, default_operator, id_key) do
    direct_terms =
      group
      |> Map.get("cpeMatch", [])
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {term, index} -> normalize_term(term, "#{path}/cpeMatch/#{index}") end)

    nested =
      [Map.get(group, "nodes", []), Map.get(group, "children", [])]
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.with_index()
      |> Enum.map(fn {child, index} ->
        child_path = "#{path}/nodes/#{index}"

        if is_map(child) do
          normalize_group(child, child_path, "or", "node_id")
        else
          %{
            "kind" => "unsupported",
            "node_id" => child_path,
            "path" => child_path,
            "op" => "unsupported",
            "negate" => false,
            "children" => []
          }
        end
      end)

    negate = normalize_negate(group)

    %{
      "kind" => if(is_boolean(negate), do: "group", else: "unsupported"),
      id_key => stable_id(group, path),
      "path" => path,
      "op" => normalize_operator(Map.get(group, "operator"), default_operator),
      "negate" => negate,
      "children" => direct_terms ++ nested
    }
  end

  defp normalize_term(term, path) when is_map(term) do
    case {normalize_vulnerable(term), VersionRange.from_cpe_match(term)} do
      {vulnerable, {:ok, bounds}} when is_boolean(vulnerable) ->
        %{
          "kind" => "cpe",
          "term_id" => stable_id(term, path),
          "path" => path,
          "role" => if(vulnerable, do: "affected", else: "environment"),
          "vulnerable" => vulnerable,
          "criteria" => Map.get(term, "criteria"),
          "bounds" => string_bounds(bounds)
        }

      {_invalid_vulnerable_or_bounds, _result} ->
        %{
          "kind" => "unsupported",
          "term_id" => stable_id(term, path),
          "path" => path,
          "criteria" => Map.get(term, "criteria")
        }
    end
  end

  defp normalize_term(_term, path) do
    %{"kind" => "unsupported", "term_id" => path, "path" => path}
  end

  defp stable_id(value, fallback) do
    Enum.find_value(
      ~w(matchCriteriaId match_criteria_id id nodeId configurationId),
      fallback,
      fn key ->
        case Map.get(value, key) do
          id when is_binary(id) and id != "" -> id
          _ -> nil
        end
      end
    )
  end

  defp normalize_operator(value, _default) when is_binary(value), do: String.downcase(value)
  defp normalize_operator(_value, default), do: default

  defp normalize_negate(group) do
    case Map.fetch(group, "negate") do
      :error -> false
      {:ok, value} when is_boolean(value) -> value
      {:ok, _value} -> nil
    end
  end

  defp normalize_vulnerable(term) do
    case Map.fetch(term, "vulnerable") do
      :error -> :invalid
      {:ok, value} when is_boolean(value) -> value
      {:ok, _value} -> :invalid
    end
  end

  defp string_bounds(bounds) do
    %{
      "version_start" => bounds.version_start,
      "version_start_inclusive" => bounds.version_start_inclusive,
      "version_end" => bounds.version_end,
      "version_end_inclusive" => bounds.version_end_inclusive
    }
  end

  defp coordinate(%{"criteria" => criteria, "bounds" => bounds} = term)
       when is_binary(criteria) do
    case Cpe.parse(criteria) do
      {:ok, %{part: "a"} = components} ->
        %{
          coordinate_type: "cpe",
          value: criteria,
          cpe_part: components.part,
          cpe_vendor: components.vendor,
          cpe_product: components.product,
          cpe_version: components.version,
          version_start: bounds["version_start"],
          version_start_inclusive: bounds["version_start_inclusive"],
          version_end: bounds["version_end"],
          version_end_inclusive: bounds["version_end_inclusive"],
          metadata: %{"match_criteria_id" => term["term_id"]}
        }

      _ ->
        nil
    end
  end

  defp coordinate(_term), do: nil

  defp coordinate_identity(coordinate) do
    {coordinate.value, coordinate.version_start, coordinate.version_end}
  end

  defp require_term(expression, term_id) do
    Map.put(expression, "required_term_ids", [term_id])
  end

  defp merge_occurrences([{first_coordinate, _term, _expression} | _] = occurrences) do
    coordinate =
      Enum.reduce(occurrences, first_coordinate, fn {candidate, _term, _expression}, acc ->
        merge_coordinate_prefilter(acc, candidate)
      end)

    expressions = occurrences |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

    term_ids =
      occurrences
      |> Enum.map(fn {_coordinate, term, _expression} -> term["term_id"] end)
      |> Enum.uniq()

    expression =
      case expressions do
        [single] ->
          single

        alternatives ->
          %{
            "kind" => "group",
            "node_id" => "coordinate-alternatives",
            "path" => "coordinate-alternatives",
            "op" => "or",
            "negate" => false,
            "children" => alternatives
          }
      end

    metadata =
      Map.put(coordinate.metadata, "nvd_applicability", %{
        "expression_version" => @expression_version,
        "affected_term_ids" => term_ids,
        "expression" => expression
      })

    %{coordinate | metadata: metadata}
  end

  defp merge_coordinate_prefilter(left, right) do
    left
    |> Map.put(
      :version_start_inclusive,
      inclusive_superset(left.version_start_inclusive, right.version_start_inclusive)
    )
    |> Map.put(
      :version_end_inclusive,
      inclusive_superset(left.version_end_inclusive, right.version_end_inclusive)
    )
  end

  defp inclusive_superset(true, _right), do: true
  defp inclusive_superset(_left, true), do: true
  defp inclusive_superset(false, _right), do: false
  defp inclusive_superset(_left, false), do: false
  defp inclusive_superset(_left, _right), do: nil

  defp terms(%{"kind" => "cpe"} = term), do: [term]

  defp terms(%{"kind" => "group", "children" => children}) when is_list(children),
    do: Enum.flat_map(children, &terms/1)

  defp terms(_expression), do: []

  defp eval(%{"kind" => "cpe"} = term, facts) do
    truth = evaluate_term(term, facts)
    {truth, [{term, truth}]}
  end

  defp eval(%{"kind" => "group", "op" => op, "children" => children} = expression, facts)
       when op in ["and", "or"] and is_list(children) do
    evaluated = Enum.map(children, &eval(&1, facts))
    child_truths = Enum.map(evaluated, &elem(&1, 0))
    evidence = Enum.flat_map(evaluated, &elem(&1, 1))
    base = combine(op, child_truths)

    case Map.get(expression, "negate", false) do
      negate when is_boolean(negate) ->
        source_truth = maybe_negate(base, negate)

        case evaluate_required(expression, facts) do
          {:ok, required_truths, required_evidence} ->
            truth = combine("and", [source_truth | required_truths])
            {truth, evidence ++ required_evidence}

          :invalid ->
            {:unknown, evidence}
        end

      _invalid ->
        {:unknown, evidence}
    end
  end

  defp eval(%{"children" => children}, facts) when is_list(children) do
    evidence = children |> Enum.map(&eval(&1, facts)) |> Enum.flat_map(&elem(&1, 1))
    {:unknown, evidence}
  end

  defp eval(%{"kind" => _kind} = term, _facts), do: {:unknown, [{term, :unknown}]}
  defp eval(_expression, _facts), do: {:unknown, []}

  defp evaluate_required(expression, facts) do
    case Map.fetch(expression, "required_term_ids") do
      :error ->
        {:ok, [], []}

      {:ok, ids} when is_list(ids) ->
        if Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != "")) do
          by_id = Map.new(terms(expression), &{&1["term_id"], &1})

          {truths, evidence} =
            ids
            |> Enum.map(fn id ->
              case Map.fetch(by_id, id) do
                {:ok, term} ->
                  truth = evaluate_required_term(term, facts)
                  scoped_term = Map.put(term, "evaluation_scope", "current_application")
                  {truth, {scoped_term, truth}}

                :error ->
                  {:unknown, {%{"kind" => "cpe", "term_id" => id}, :unknown}}
              end
            end)
            |> Enum.unzip()

          {:ok, truths, evidence}
        else
          :invalid
        end

      {:ok, _invalid} ->
        :invalid
    end
  end

  defp evaluate_required_term(%{"criteria" => criteria} = term, facts) when is_binary(criteria) do
    case {valid_bounds?(term), Cpe.parse(criteria)} do
      {true, {:ok, %{part: "a"} = wanted}} ->
        evaluate_known_inventory(
          wanted,
          term,
          Map.get(facts, "current_application_cpes", []),
          true
        )

      {true, _other} ->
        evaluate_term(term, facts)

      {false, _other} ->
        :unknown
    end
  end

  defp evaluate_required_term(term, facts), do: evaluate_term(term, facts)

  defp combine("and", truths) do
    cond do
      Enum.any?(truths, &(&1 == false)) -> false
      truths != [] and Enum.all?(truths, &(&1 == true)) -> true
      true -> :unknown
    end
  end

  defp combine("or", truths) do
    cond do
      Enum.any?(truths, &(&1 == true)) -> true
      truths != [] and Enum.all?(truths, &(&1 == false)) -> false
      true -> :unknown
    end
  end

  defp maybe_negate(true, true), do: false
  defp maybe_negate(false, true), do: true
  defp maybe_negate(:unknown, true), do: :unknown
  defp maybe_negate(truth, _negate), do: truth

  defp evaluate_term(%{"term_id" => term_id} = term, %{"term_results" => overrides} = facts)
       when is_map(overrides) do
    case Map.fetch(overrides, term_id) do
      {:ok, truth} when truth in [true, false, :unknown] -> truth
      _ -> evaluate_cpe_term(term, Map.delete(facts, "term_results"))
    end
  end

  defp evaluate_term(term, facts), do: evaluate_cpe_term(term, facts)

  defp evaluate_cpe_term(%{"criteria" => criteria} = term, facts) when is_binary(criteria) do
    if valid_bounds?(term) do
      case Cpe.parse(criteria) do
        {:ok, wanted} -> evaluate_parsed_cpe_term(wanted, term, facts)
        :error -> :unknown
      end
    else
      :unknown
    end
  end

  defp evaluate_cpe_term(_term, _facts), do: :unknown

  defp evaluate_parsed_cpe_term(%{version: "-"} = wanted, term, facts) when is_map(term) do
    if version_bounds_present?(term["bounds"]) do
      :unknown
    else
      evaluate_parsed_cpe_part(wanted, term, facts)
    end
  end

  defp evaluate_parsed_cpe_term(wanted, term, facts),
    do: evaluate_parsed_cpe_part(wanted, term, facts)

  defp evaluate_parsed_cpe_part(%{part: "a"} = wanted, term, facts),
    do: evaluate_application(wanted, term, facts)

  defp evaluate_parsed_cpe_part(%{part: "o"} = wanted, term, facts),
    do: evaluate_os(wanted, term, facts)

  defp evaluate_parsed_cpe_part(%{part: "h"} = wanted, term, facts),
    do: evaluate_inventory(wanted, term, facts, "hardware")

  defp evaluate_parsed_cpe_part(_wanted, _term, _facts), do: :unknown

  defp evaluate_application(wanted, term, facts) do
    evaluate_known_inventory(
      wanted,
      term,
      Map.get(facts, "application_cpes", []),
      Map.get(facts, "application_inventory_complete", false)
    )
  end

  defp evaluate_inventory(wanted, term, facts, kind) do
    evaluate_known_inventory(
      wanted,
      term,
      Map.get(facts, "#{kind}_cpes", []),
      Map.get(facts, "#{kind}_inventory_complete", false)
    )
  end

  defp evaluate_known_inventory(wanted, term, known, complete?) do
    cond do
      Enum.any?(known, &cpe_satisfies?(wanted, term, &1)) -> true
      known == [] and not complete? -> :unknown
      complete? -> false
      true -> :unknown
    end
  end

  defp evaluate_os(wanted, term, facts) do
    explicit = Map.get(facts, "os_cpes", [])

    cond do
      Enum.any?(explicit, &cpe_satisfies?(wanted, term, &1)) -> true
      is_map(Map.get(facts, "os")) -> compare_os_fact(wanted, term, Map.fetch!(facts, "os"))
      true -> :unknown
    end
  end

  defp compare_os_fact(wanted, term, os) do
    wanted_family = os_family(wanted.vendor, wanted.product)
    actual_family = os_family(Map.get(os, "namespace"), nil)

    cond do
      is_nil(wanted_family) or is_nil(actual_family) -> :unknown
      wanted_family != actual_family -> false
      constrained_os_fields?(wanted, wanted_family) -> :unknown
      true -> compare_os_releases(wanted.version, term["bounds"], os_releases(os))
    end
  end

  defp compare_os_releases(wanted, bounds, releases) do
    cond do
      not is_map(bounds) ->
        :unknown

      release_unconstrained?(wanted, bounds) ->
        true

      present?(bounds["version_start"]) or present?(bounds["version_end"]) ->
        compare_os_release_bounds(bounds, releases)

      true ->
        compare_exact_os_release(wanted, releases)
    end
  end

  defp compare_exact_os_release(wanted, releases) do
    wanted = normalize_token(wanted)

    cond do
      Enum.any?(releases, &(&1 == wanted)) ->
        true

      wanted == "-" ->
        false

      release_vocabulary(wanted) in [:numeric, :codename] ->
        comparable =
          Enum.filter(releases, &(release_vocabulary(&1) == release_vocabulary(wanted)))

        if comparable == [], do: :unknown, else: false

      true ->
        :unknown
    end
  end

  defp compare_os_release_bounds(bounds, releases) do
    boundary_values =
      [bounds["version_start"], bounds["version_end"]]
      |> Enum.filter(&present?/1)
      |> Enum.map(&normalize_token/1)

    case Enum.uniq(Enum.map(boundary_values, &release_vocabulary/1)) do
      [:numeric] ->
        vocabulary = :numeric
        comparable = Enum.filter(releases, &(release_vocabulary(&1) == vocabulary))

        cond do
          comparable == [] -> :unknown
          Enum.any?(comparable, &version_satisfies?("*", bounds, &1)) -> true
          true -> false
        end

      _mixed_or_unsupported ->
        :unknown
    end
  end

  defp os_releases(os) do
    [Map.get(os, "release") | List.wrap(Map.get(os, "releases", []))]
    |> Enum.map(&normalize_token/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp release_unconstrained?(wanted, bounds) do
    wanted in ["*", nil] and not present?(bounds["version_start"]) and
      not present?(bounds["version_end"])
  end

  defp release_vocabulary(value) when is_binary(value) do
    cond do
      Regex.match?(~r/\A\d+(?:\.\d+)*\z/, value) -> :numeric
      Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, value) -> :codename
      true -> :unsupported
    end
  end

  defp release_vocabulary(_value), do: :unsupported

  defp constrained_os_fields?(wanted, family) do
    not generic_os_product?(family, wanted.product) or
      Enum.any?(
        [:update, :edition, :language, :sw_edition, :target_sw, :target_hw, :other],
        &(Map.get(wanted, &1) not in [nil, "*"])
      )
  end

  defp generic_os_product?(_family, product) when product in [nil, "*"], do: true
  defp generic_os_product?("redhat", "enterprise_linux"), do: true
  defp generic_os_product?("ubuntu", "ubuntu_linux"), do: true
  defp generic_os_product?("debian", "debian_linux"), do: true
  defp generic_os_product?(_family, _product), do: false

  defp os_family(value, product) do
    value = normalize_token(value)
    product = normalize_token(product)

    cond do
      value == "-" -> nil
      value in ["redhat", "red_hat", "rhel"] -> "redhat"
      value in ["canonical", "ubuntu"] -> "ubuntu"
      value == "debian" -> "debian"
      String.starts_with?(product || "", "enterprise_linux") -> "redhat"
      product == "ubuntu_linux" -> "ubuntu"
      product == "debian_linux" -> "debian"
      true -> nil
    end
  end

  defp cpe_satisfies?(wanted, term, known) when is_map(known) do
    non_version_match =
      Enum.all?(@cpe_fields -- [:version], fn field ->
        Cpe.component_match?(Map.get(wanted, field), Map.get(known, field))
      end)

    non_version_match and
      version_satisfies?(wanted.version, term["bounds"] || %{}, Map.get(known, :version))
  end

  defp cpe_satisfies?(_wanted, _term, _known), do: false

  defp version_satisfies?(wanted, bounds, installed) do
    normalized_bounds = %{
      version_start: bounds["version_start"],
      version_start_inclusive: bounds["version_start_inclusive"],
      version_end: bounds["version_end"],
      version_end_inclusive: bounds["version_end_inclusive"]
    }

    cond do
      wanted == "-" ->
        installed == "-" and not version_bounds_present?(bounds)

      version_bounds_present?(bounds) ->
        VersionRange.satisfies?(installed, normalized_bounds)

      true ->
        wanted in ["*", nil] or
          (is_binary(installed) and String.downcase(wanted) == String.downcase(installed))
    end
  end

  defp version_bounds_present?(bounds) when is_map(bounds) do
    present?(bounds["version_start"]) or present?(bounds["version_end"]) or
      present?(bounds[:version_start]) or present?(bounds[:version_end])
  end

  defp version_bounds_present?(_bounds), do: false

  defp valid_bounds?(term) do
    case Map.fetch(term, "bounds") do
      :error ->
        true

      {:ok, bounds} when is_map(bounds) ->
        valid_bound_pair?(
          bounds["version_start"],
          bounds["version_start_inclusive"]
        ) and
          valid_bound_pair?(bounds["version_end"], bounds["version_end_inclusive"])

      {:ok, _invalid} ->
        false
    end
  end

  defp valid_bound_pair?(value, inclusive) when is_binary(value) do
    if String.trim(value) == "", do: is_nil(inclusive), else: is_boolean(inclusive)
  end

  defp valid_bound_pair?(nil, inclusive), do: is_nil(inclusive)
  defp valid_bound_pair?(_value, _inclusive), do: false

  defp merge_applicability(left, right) do
    left_expression = metadata_value(left, "expression")
    right_expression = metadata_value(right, "expression")
    expression_versions = merged_expression_versions(left, right)

    left
    |> deterministic_map_merge(right)
    |> Map.delete(:expression_version)
    |> Map.delete(:expression_versions)
    |> Map.delete(:affected_term_ids)
    |> Map.delete(:expression)
    |> Map.put("expression_versions", expression_versions)
    |> Map.put("expression_version", compatible_expression_version(expression_versions))
    |> Map.put("affected_term_ids", merged_term_ids(left, right))
    |> Map.put("expression", merge_expressions(left_expression, right_expression))
  end

  defp compatible_expression_version(versions) do
    case versions do
      [version] -> version
      _missing_or_incompatible -> nil
    end
  end

  defp merged_expression_versions(left, right) do
    [left, right]
    |> Enum.flat_map(&expression_versions/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp expression_versions(applicability) do
    case metadata_value(applicability, "expression_versions") do
      versions when is_list(versions) -> Enum.filter(versions, &is_integer/1)
      _missing -> List.wrap(metadata_value(applicability, "expression_version"))
    end
  end

  defp merged_term_ids(left, right) do
    [metadata_value(left, "affected_term_ids"), metadata_value(right, "affected_term_ids")]
    |> Enum.flat_map(fn ids -> if is_list(ids), do: ids, else: [] end)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp merge_expressions(left, right) do
    alternatives =
      [left, right]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&expression_alternatives/1)
      |> Enum.uniq()
      |> Enum.sort()

    case alternatives do
      [single] ->
        single

      children ->
        %{
          "kind" => "group",
          "node_id" => "coordinate-alternatives",
          "path" => "coordinate-alternatives",
          "op" => "or",
          "negate" => false,
          "children" => children
        }
    end
  end

  defp expression_alternatives(%{
         "kind" => "group",
         "node_id" => "coordinate-alternatives",
         "op" => "or",
         "negate" => false,
         "children" => children
       })
       when is_list(children), do: children

  defp expression_alternatives(expression), do: [expression]

  defp deterministic_map_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value -> min(left_value, right_value) end)
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, String.to_existing_atom(key))
  end

  defp classified_terms(classified, truth) do
    Enum.flat_map(classified, fn
      {term, ^truth} -> [term]
      _ -> []
    end)
  end

  defp term_key(term) do
    {term["term_id"] || term["path"] || inspect(term), term["evaluation_scope"]}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_token(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_token(_value), do: nil
end
