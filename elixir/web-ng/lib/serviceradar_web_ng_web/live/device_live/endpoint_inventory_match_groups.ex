defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryMatchGroups do
  @moduledoc false

  @severity_rank %{"critical" => 0, "high" => 1, "medium" => 2, "low" => 3}
  @confidence_rank %{"low" => 0, "medium" => 1, "high" => 2}
  @provider_rank %{"cisa" => 0, "nvd" => 1, "vulncheck" => 2}

  @doc """
  Groups feed-level match rows by installed package, then collapses the same
  CVE across feeds so the Software tab shows one row per package.
  """
  def group(matches) when is_list(matches) do
    matches
    |> Enum.group_by(&package_key/1)
    |> Enum.map(fn {key, grouped} -> build_group(key, grouped) end)
    |> Enum.sort_by(&sort_key/1)
  end

  def group(_matches), do: []

  def find(groups, id) when is_list(groups) and is_binary(id) do
    Enum.find(groups, &(&1.id == id)) ||
      Enum.find(groups, fn group ->
        Enum.any?(group.matches, &(match_id(&1) == id))
      end)
  end

  def find(_groups, _id), do: nil

  @doc """
  Collapses matches for one package into unique advisories (CVE / advisory id),
  keeping every contributing feed on the surviving row.
  """
  def collapse_advisories(matches) when is_list(matches) do
    matches
    |> Enum.group_by(&advisory_key/1)
    |> Enum.map(fn {key, same_cve} ->
      primary = Enum.min_by(same_cve, &primary_rank/1)

      %{
        id: key,
        cve_id: field(primary, :cve_id) || field(primary, :advisory_id),
        primary: primary,
        feeds: unique_feeds(same_cve),
        matches: same_cve
      }
    end)
    |> Enum.sort_by(&advisory_sort/1)
  end

  def collapse_advisories(_matches), do: []

  def wrap_match(nil), do: nil

  def wrap_match(match) do
    [match]
    |> group()
    |> List.first()
  end

  defp build_group(key, matches) do
    advisories = collapse_advisories(matches)
    representative = hd(matches)

    %{
      id: key,
      package_name: package_name(representative),
      installed_version: installed_version_display(representative),
      kev: Enum.any?(matches, &truthy?(field(&1, :kev))),
      exploit_available: Enum.any?(matches, &truthy?(field(&1, :exploit_available))),
      severity: worst_severity(matches),
      cvss_score: max_cvss(matches),
      confidence: lowest_confidence(matches),
      advisory_count: length(advisories),
      cve_ids: advisories |> Enum.map(& &1.cve_id) |> Enum.reject(&blank?/1),
      sources: unique_feeds(matches),
      fixed_versions:
        matches
        |> Enum.map(&field(&1, :fixed_version))
        |> Enum.reject(&blank?/1)
        |> Enum.uniq(),
      cwes:
        matches
        |> Enum.flat_map(&match_cwes/1)
        |> Enum.uniq(),
      matches: matches,
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

  defp advisory_key(match) do
    match
    |> field(:cve_id)
    |> Kernel.||(field(match, :advisory_id))
    |> Kernel.||(match_id(match))
    |> normalize()
  end

  defp match_id(match) do
    case field(match, :id) do
      nil -> nil
      id -> to_string(id)
    end
  end

  defp package_name(match) do
    match
    |> vulnerability_package()
    |> field(:name)
  end

  defp package_manager(match) do
    match
    |> vulnerability_package()
    |> field(:package_manager)
  end

  defp installed_version(match) do
    match
    |> field(:version_evidence)
    |> field(:installed_version)
  end

  defp installed_version_display(match) do
    [package_manager(match), installed_version(match)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
    |> case do
      "" -> "-"
      value -> value
    end
  end

  defp vulnerability_package(match) do
    case match |> field(:evidence) |> field(:package) do
      %{} = package -> package
      _ -> %{}
    end
  end

  defp unique_feeds(matches) do
    matches
    |> Enum.map(fn match ->
      %{
        provider: field(match, :provider),
        feed_key: field(match, :feed_key)
      }
    end)
    |> Enum.reject(fn feed -> blank?(feed.provider) and blank?(feed.feed_key) end)
    |> Enum.uniq_by(fn feed -> {feed.provider, feed.feed_key} end)
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

  defp lowest_confidence(matches) do
    matches
    |> Enum.map(&field(&1, :confidence))
    |> Enum.reject(&blank?/1)
    |> Enum.min_by(&confidence_rank/1, fn -> nil end)
  end

  defp primary_rank(match) do
    {
      if(truthy?(field(match, :kev)), do: 0, else: 1),
      if(truthy?(field(match, :exploit_available)), do: 0, else: 1),
      cvss_sort(field(match, :cvss_score)),
      Map.get(@provider_rank, normalize(field(match, :provider)), 9)
    }
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

  defp advisory_sort(advisory) do
    {primary_rank(advisory.primary), cve_desc_key(advisory.cve_id)}
  end

  defp cve_desc_key(cve) when is_binary(cve) do
    case Regex.run(~r/CVE-(\d{4})-(\d+)/i, cve) do
      [_, year, seq] -> {-String.to_integer(year), -String.to_integer(seq)}
      _ -> {0, 0}
    end
  end

  defp cve_desc_key(_cve), do: {0, 0}

  defp severity_rank(value), do: Map.get(@severity_rank, normalize(value), 9)
  defp confidence_rank(value), do: Map.get(@confidence_rank, normalize(value), 9)

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

  defp match_cwes(match) do
    direct = List.wrap(field(match, :cwes))

    from_meta =
      case field(match, :metadata) do
        %{"cwes" => cwes} -> List.wrap(cwes)
        %{cwes: cwes} -> List.wrap(cwes)
        _ -> []
      end

    (direct ++ from_meta)
    |> Enum.map(&to_string/1)
    |> Enum.filter(&String.starts_with?(&1, "CWE-"))
    |> Enum.uniq()
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false
end
