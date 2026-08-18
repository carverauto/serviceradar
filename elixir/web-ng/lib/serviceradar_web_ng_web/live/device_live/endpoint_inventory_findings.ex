defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryFindings do
  @moduledoc """
  Collapse stored endpoint vulnerability matches into one operator finding
  per `(package, CVE)`.

  Storage still keeps the CPE row and the KEV name-match row. The Software
  tab shows a single card: NVD description + CVSS + KEV badges + due date +
  EPSS + CPE evidence.
  """

  @doc "Group match rows into one finding per package CVE."
  @spec group(list()) :: [map()]
  def group(matches) when is_list(matches) do
    matches
    |> Enum.group_by(&finding_key/1)
    |> Enum.map(fn {_key, group} -> compose(group) end)
    |> Enum.sort_by(&sort_tuple/1)
  end

  def group(_matches), do: []

  defp finding_key(match) do
    {package_key(match), cve_key(match)}
  end

  defp package_key(match) do
    field(match, :endpoint_package_ref) ||
      get_in(package(match), ["purl_canonical"]) ||
      get_in(package(match), [:purl_canonical]) ||
      get_in(package(match), ["name"]) ||
      get_in(package(match), [:name]) ||
      field(match, :id)
  end

  defp cve_key(match) do
    field(match, :cve_id) || field(match, :advisory_id) || field(match, :id)
  end

  defp compose(group) do
    primary = primary_match(group)
    priority = merged_priority(group)
    kev? = Enum.any?(group, &(truthy?(field(&1, :kev)) or priority_flag(priority, "kev")))
    exploit? = Enum.any?(group, &(truthy?(field(&1, :exploit_available)) or priority_flag(priority, "exploit_available")))
    name_only? = Enum.all?(group, &name_match?/1)

    %{
      id: field(primary, :id),
      cve_id: field(primary, :cve_id),
      advisory_id: field(primary, :advisory_id),
      kev: kev?,
      exploit_available: exploit?,
      cvss_score: first_present(group, :cvss_score),
      severity: first_present(group, :severity),
      fixed_version: first_present(group, :fixed_version),
      confidence: if(name_only?, do: "low", else: field(primary, :confidence)),
      status: field(primary, :status),
      description: description(primary, priority),
      title: title(primary, priority),
      due_date: priority_value(priority, "due_date"),
      epss_score: priority_value(priority, "epss_score"),
      ransomware_use: priority_value(priority, "ransomware_use"),
      coordinate_type: field(primary, :coordinate_type),
      coordinate_value: field(primary, :coordinate_value),
      provider: field(primary, :provider),
      feed_key: field(primary, :feed_key),
      evidence: field(primary, :evidence),
      version_evidence: field(primary, :version_evidence),
      advisory: field(primary, :advisory),
      sources: sources(group, priority),
      match_kind: if(name_only?, do: "name", else: field(primary, :coordinate_type) || "cpe"),
      name_match_only?: name_only?,
      cwes: group_cwes(group)
    }
  end

  defp primary_match(group) do
    Enum.min_by(group, fn match ->
      case field(match, :coordinate_type) do
        "purl" -> 0
        "cpe" -> 1
        _ -> 2
      end
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
      _ -> %{}
    end
  end

  defp description(match, priority) do
    field(match, :description) ||
      priority_value(priority, "description") ||
      get_in(field(match, :metadata) || %{}, ["description"]) ||
      advisory_field(match, :description) ||
      field(match, :title) ||
      priority_value(priority, "title")
  end

  defp title(match, priority) do
    priority_value(priority, "title") ||
      field(match, :title) ||
      advisory_field(match, :title)
  end

  defp advisory_field(match, key) do
    match
    |> field(:advisory)
    |> field(key)
  end

  defp sources(group, priority) do
    from_priority = priority |> Map.get("sources", []) |> List.wrap()

    from_matches =
      Enum.map(group, fn match ->
        [field(match, :provider), field(match, :feed_key)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("/")
      end)

    (from_priority ++ from_matches)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp name_match?(match) do
    field(match, :coordinate_type) == "vendor_product" or
      field(match, :confidence) == "low" or
      get_in(field(match, :metadata) || %{}, ["match_kind"]) == "name"
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

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp package(match) do
    case field(match, :evidence) do
      %{} = evidence -> field(evidence, :package) || %{}
      _ -> %{}
    end
  end

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
