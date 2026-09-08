defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryFindings do
  @moduledoc """
  Builds the Software UI's one-row-per-assessment presentation contract.

  Persisted assessments own applicability, lifecycle, authority, package
  identity, and fixed-version decisions. Coordinate-level matches are optional
  modal enrichment for descriptions, references, CWE, KEV, and EPSS only.
  """

  alias ServiceRadar.Inventory.EndpointVulnerabilityAssessment

  @priority_fields ~w(kev exploit_available due_date ransomware_use epss_score title description sources)

  @doc "Build one finding per persisted assessment."
  @spec group(list(), list()) :: [map()]
  def group(assessments, supporting_matches \\ [])

  def group(assessments, supporting_matches) when is_list(assessments) and is_list(supporting_matches) do
    assessments
    |> Enum.uniq_by(&finding_key/1)
    |> Enum.map(fn assessment ->
      compose(assessment, matches_for_assessment(assessment, supporting_matches))
    end)
    |> Enum.sort_by(&sort_tuple/1)
  end

  def group(_assessments, _supporting_matches), do: []

  @doc "Partition assessment findings into actionable, candidate, and historical sections."
  @spec partition(list(), list()) :: %{confirmed: list(), candidates: list(), history: list()}
  def partition(assessments, supporting_matches \\ []) do
    assessments
    |> group(supporting_matches)
    |> Enum.group_by(&section/1)
    |> then(fn grouped ->
      %{
        confirmed: Map.get(grouped, :confirmed, []),
        candidates: Map.get(grouped, :candidates, []),
        history: Map.get(grouped, :history, [])
      }
    end)
  end

  defp finding_key(assessment) do
    field(assessment, :id) ||
      {field(assessment, :endpoint_package_ref), field(assessment, :cve_id)}
  end

  defp section(finding) do
    cond do
      EndpointVulnerabilityAssessment.actionable?(finding) -> :confirmed
      field(finding, :status) == "resolved" -> :history
      field(finding, :assessment) == "candidate" -> :candidates
      field(finding, :disposition) in ["fixed", "not_affected"] -> :history
      true -> :candidates
    end
  end

  defp compose(assessment, supporting_matches) do
    priority = merged_priority([assessment | supporting_matches])
    descriptive_match = Enum.find(supporting_matches, &(field(&1, :advisory) not in [nil, %{}]))
    coordinate_match = List.first(supporting_matches)

    %{
      id: field(assessment, :id),
      cve_id: field(assessment, :cve_id),
      advisory_id: field(assessment, :advisory_id),
      status: field(assessment, :status),
      assessment: field(assessment, :assessment),
      disposition: field(assessment, :disposition),
      state_label: state_label(assessment),
      authority: field(assessment, :authority),
      applicability_reason: field(assessment, :applicability_reason),
      authority_generation: field(assessment, :authority_generation),
      authority_as_of: field(assessment, :authority_as_of),
      freshness: field(assessment, :freshness),
      provider: field(assessment, :provider),
      feed_key: field(assessment, :feed_key),
      package_type: field(assessment, :package_type),
      package_manager: field(assessment, :package_manager),
      ecosystem: field(assessment, :ecosystem),
      package_namespace: field(assessment, :package_namespace),
      package_release: field(assessment, :package_release),
      package_name: field(assessment, :package_name),
      package_purl: field(assessment, :package_purl),
      endpoint_package_ref: field(assessment, :endpoint_package_ref),
      installed_version: field(assessment, :installed_version),
      source_package: field(assessment, :source_package),
      source_version: field(assessment, :source_version),
      binary_package: field(assessment, :binary_package),
      architecture: field(assessment, :architecture),
      version_scheme: field(assessment, :version_scheme),
      fixed_version: field(assessment, :fixed_version),
      severity: field(assessment, :severity) || first_present(supporting_matches, :severity),
      cvss_score: field(assessment, :cvss_score) || first_present(supporting_matches, :cvss_score),
      cvss_vector: field(assessment, :cvss_vector),
      kev:
        truthy?(field(assessment, :kev)) or
          Enum.any?(supporting_matches, &truthy?(field(&1, :kev))) or
          priority_flag(priority, "kev"),
      exploit_available:
        truthy?(field(assessment, :exploit_available)) or
          Enum.any?(supporting_matches, &truthy?(field(&1, :exploit_available))) or
          priority_flag(priority, "exploit_available"),
      description: description(supporting_matches, priority),
      title: title(supporting_matches, priority),
      due_date: priority_value(priority, "due_date"),
      epss_score: priority_value(priority, "epss_score"),
      ransomware_use: priority_value(priority, "ransomware_use"),
      coordinate_type: field(coordinate_match, :coordinate_type),
      coordinate_value: field(coordinate_match, :coordinate_value),
      evidence: field(assessment, :evidence) || %{},
      metadata: field(assessment, :metadata) || %{},
      unknown_terms: unknown_terms(assessment),
      transition_reason: field(assessment, :transition_reason),
      first_seen_at: field(assessment, :first_seen_at),
      last_seen_at: field(assessment, :last_seen_at),
      resolved_at: field(assessment, :resolved_at),
      advisory: field(descriptive_match, :advisory) || %{},
      sources: sources(assessment, supporting_matches),
      supporting_matches: supporting_matches,
      cwes: group_cwes(supporting_matches),
      name_match_only?: false
    }
  end

  defp matches_for_assessment(assessment, supporting_matches) do
    ids =
      assessment
      |> field(:supporting_match_ids)
      |> List.wrap()
      |> MapSet.new(&to_string/1)

    matches =
      if MapSet.size(ids) > 0 do
        Enum.filter(supporting_matches, fn match ->
          id = field(match, :id)
          not is_nil(id) and MapSet.member?(ids, to_string(id))
        end)
      else
        Enum.filter(supporting_matches, fn match ->
          same_value?(field(match, :endpoint_package_ref), field(assessment, :endpoint_package_ref)) and
            same_value?(field(match, :cve_id), field(assessment, :cve_id))
        end)
      end

    Enum.sort_by(matches, fn match ->
      {normalize(field(match, :provider)), normalize(field(match, :feed_key)), normalize(field(match, :id))}
    end)
  end

  defp merged_priority(group) do
    Enum.reduce(group, %{}, fn match, acc ->
      match
      |> priority_map()
      |> Map.merge(acc, fn _key, left, right ->
        cond do
          is_nil(right) or right == [] -> left
          is_nil(left) or left == [] -> right
          is_list(left) and is_list(right) -> Enum.uniq(right ++ left)
          true -> right
        end
      end)
    end)
  end

  defp priority_map(match) do
    metadata = field(match, :metadata) || %{}

    case field(metadata, :priority) do
      %{} = priority -> stringify_keys(priority)
      _ -> metadata |> stringify_keys() |> Map.take(@priority_fields)
    end
  end

  defp description(matches, priority) do
    Enum.find_value(matches, fn match ->
      field(match, :description) ||
        get_in(field(match, :metadata) || %{}, ["description"]) ||
        advisory_field(match, :description)
    end) || priority_value(priority, "description") || priority_value(priority, "title")
  end

  defp title(matches, priority) do
    Enum.find_value(matches, fn match ->
      field(match, :title) || advisory_field(match, :title)
    end) || priority_value(priority, "title")
  end

  defp advisory_field(match, key) do
    match
    |> field(:advisory)
    |> field(key)
  end

  defp sources(assessment, matches) do
    [assessment | matches]
    |> Enum.map(fn match ->
      %{provider: field(match, :provider), feed_key: field(match, :feed_key)}
    end)
    |> Enum.reject(&(blank?(&1.provider) and blank?(&1.feed_key)))
    |> Enum.uniq_by(&{&1.provider, &1.feed_key})
  end

  defp first_present(group, key) do
    Enum.find_value(group, &field(&1, key))
  end

  defp priority_value(priority, key) do
    Map.get(priority, key)
  end

  defp priority_flag(priority, key), do: truthy?(priority_value(priority, key))

  defp sort_tuple(finding) do
    kev_rank = if finding.kev, do: 0, else: 1
    cvss = finding.cvss_score || 0.0
    cve = finding.cve_id || finding.advisory_id || ""
    {kev_rank, -cvss, cve}
  end

  defp state_label(assessment) do
    cond do
      EndpointVulnerabilityAssessment.actionable?(assessment) -> "Confirmed affected"
      field(assessment, :status) == "resolved" -> "Resolved · #{humanize(field(assessment, :disposition))}"
      field(assessment, :assessment) == "candidate" -> "Unverified candidate"
      true -> "Needs review"
    end
  end

  defp unknown_terms(assessment) do
    assessment
    |> field(:evidence)
    |> field(:matches)
    |> List.wrap()
    |> Enum.flat_map(fn match ->
      match
      |> field(:nvd_applicability)
      |> field(:unknown_terms)
      |> List.wrap()
    end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp same_value?(nil, _value), do: false
  defp same_value?(_value, nil), do: false
  defp same_value?(left, right), do: to_string(left) == to_string(right)

  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.downcase()

  defp humanize(nil), do: "unknown"
  defp humanize(value), do: value |> to_string() |> String.replace("_", " ")

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp group_cwes(group) do
    group
    |> Enum.flat_map(&finding_cwes/1)
    |> Enum.map(&normalize_cwe/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp finding_cwes(match) do
    metadata = field(match, :metadata) || %{}
    advisory = field(match, :advisory) || %{}
    advisory_metadata = field(advisory, :metadata) || %{}

    List.wrap(field(match, :cwes)) ++
      List.wrap(field(metadata, :cwes)) ++
      List.wrap(field(advisory, :cwes)) ++
      List.wrap(field(advisory_metadata, :cwes))
  end

  defp normalize_cwe(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.upcase()
    if String.starts_with?(trimmed, "CWE-"), do: trimmed
  end

  defp normalize_cwe(_value), do: nil

  defp field(nil, _key), do: nil

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp field(_map, _key), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false
end
