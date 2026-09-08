defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryMatchGroups do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryFindings

  @severity_rank %{"critical" => 0, "high" => 1, "medium" => 2, "low" => 3}

  @doc """
  Groups stable assessments by installed package. Supporting raw match rows
  enrich the modal but never choose the winning applicability decision.
  """
  def group(assessments, supporting_matches \\ [])

  def group(assessments, supporting_matches) when is_list(assessments) and is_list(supporting_matches) do
    assessments
    |> Enum.group_by(&package_key/1)
    |> Enum.map(fn {key, grouped} -> build_group(key, grouped, supporting_matches) end)
    |> Enum.sort_by(&sort_key/1)
  end

  def group(_assessments, _supporting_matches), do: []

  def find(groups, id) when is_list(groups) and is_binary(id) do
    Enum.find(groups, &(&1.id == id)) ||
      Enum.find(groups, fn group ->
        Enum.any?(group.assessments, &(row_id(&1) == id)) or
          Enum.any?(group.advisories, fn advisory ->
            Enum.any?(advisory.matches, &(row_id(&1) == id))
          end)
      end)
  end

  def find(_groups, _id), do: nil

  @doc """
  Converts assessments for one package into unique advisory presentations,
  keeping supporting raw feeds only as enrichment.
  """
  def collapse_advisories(assessments, supporting_matches \\ [])

  def collapse_advisories(assessments, supporting_matches) when is_list(assessments) and is_list(supporting_matches) do
    assessments
    |> EndpointInventoryFindings.group(supporting_matches)
    |> Enum.map(fn finding ->
      %{
        id: normalize(field(finding, :cve_id) || field(finding, :advisory_id) || field(finding, :id)),
        cve_id: field(finding, :cve_id) || field(finding, :advisory_id),
        primary: finding,
        feeds: field(finding, :sources) || [],
        matches: field(finding, :supporting_matches) || []
      }
    end)
    |> Enum.sort_by(&advisory_sort/1)
  end

  def collapse_advisories(_assessments, _supporting_matches), do: []

  def wrap_match(nil), do: nil

  def wrap_match(match), do: match |> List.wrap() |> group() |> List.first()

  defp build_group(key, assessments, supporting_matches) do
    advisories = collapse_advisories(assessments, supporting_matches)
    findings = Enum.map(advisories, & &1.primary)
    representative = hd(findings)

    %{
      id: key,
      package_name: package_name(representative),
      installed_version: installed_version_display(representative),
      kev: Enum.any?(findings, &truthy?(field(&1, :kev))),
      exploit_available: Enum.any?(findings, &truthy?(field(&1, :exploit_available))),
      severity: worst_severity(findings),
      cvss_score: max_cvss(findings),
      confidence: field(representative, :assessment),
      advisory_count: length(advisories),
      cve_ids: advisories |> Enum.map(& &1.cve_id) |> Enum.reject(&blank?/1),
      sources:
        findings
        |> Enum.flat_map(&(field(&1, :sources) || []))
        |> Enum.uniq_by(&{field(&1, :provider), field(&1, :feed_key)}),
      fixed_versions:
        findings
        |> Enum.map(&field(&1, :fixed_version))
        |> Enum.reject(&blank?/1)
        |> Enum.uniq(),
      cwes:
        findings
        |> Enum.flat_map(&(field(&1, :cwes) || []))
        |> Enum.uniq(),
      assessments: assessments,
      matches: assessments,
      advisories: advisories
    }
  end

  defp package_key(match) do
    case field(match, :endpoint_package_ref) do
      ref when not is_nil(ref) and ref != "" ->
        "ref:#{ref}"

      _ ->
        Enum.join(
          [
            "coord",
            normalize(package_name(match)),
            normalize(package_manager(match)),
            normalize(installed_version(match))
          ],
          ":"
        )
    end
  end

  defp row_id(match) do
    case field(match, :id) do
      nil -> nil
      id -> to_string(id)
    end
  end

  defp package_name(match), do: field(match, :package_name)

  defp package_manager(match), do: field(match, :package_manager)

  defp installed_version(match), do: field(match, :installed_version)

  defp installed_version_display(match) do
    [package_manager(match), installed_version(match)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> case do
      "" -> "-"
      value -> value
    end
  end

  defp worst_severity(matches) do
    matches
    |> Enum.map(&field(&1, :severity))
    |> Enum.reject(&blank?/1)
    |> Enum.min_by(&severity_rank/1, fn -> nil end)
  end

  defp max_cvss(matches) do
    matches
    |> Enum.map(&field(&1, :cvss_score))
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> nil end)
  end

  defp sort_key(group) do
    {
      if(group.kev, do: 0, else: 1),
      if(group.exploit_available, do: 0, else: 1),
      severity_rank(group.severity),
      cvss_sort(group.cvss_score),
      normalize(group.package_name)
    }
  end

  defp advisory_sort(advisory), do: cve_desc_key(advisory.cve_id)

  defp cve_desc_key(cve) when is_binary(cve) do
    case Regex.run(~r/CVE-(\d{4})-(\d+)/i, cve) do
      [_, year, seq] -> {-String.to_integer(year), -String.to_integer(seq)}
      _ -> {0, 0}
    end
  end

  defp cve_desc_key(_cve), do: {0, 0}

  defp severity_rank(value), do: Map.get(@severity_rank, normalize(value), 9)
  defp cvss_sort(score) when is_number(score), do: -score
  defp cvss_sort(_score), do: 0

  defp field(nil, _key), do: nil

  defp field(%{} = row, key) do
    cond do
      Map.has_key?(row, key) -> Map.get(row, key)
      Map.has_key?(row, to_string(key)) -> Map.get(row, to_string(key))
      true -> nil
    end
  end

  defp field(_row, _key), do: nil

  defp normalize(nil), do: ""

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false
end
