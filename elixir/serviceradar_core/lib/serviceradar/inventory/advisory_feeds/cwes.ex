defmodule ServiceRadar.Inventory.AdvisoryFeeds.Cwes do
  @moduledoc """
  Extract CWE identifiers from NVD 2.0 weakness blocks and CISA/VulnCheck KEV
  `cwes` fields. Pure — no DB.
  """

  @cwe ~r/CWE-\d+/i

  @doc "CWE ids from an NVD 2.0 `cve` object (`weaknesses[].description[].value`)."
  def from_nvd_cve(cve) when is_map(cve) do
    cve
    |> Map.get("weaknesses", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"description" => descriptions} -> List.wrap(descriptions)
      other -> List.wrap(other)
    end)
    |> Enum.flat_map(&values/1)
    |> normalize()
  end

  def from_nvd_cve(_cve), do: []

  @doc "CWE ids from a CISA/VulnCheck KEV entry (`cwes` / `cwe`)."
  def from_kev_entry(entry) when is_map(entry) do
    [Map.get(entry, "cwes"), Map.get(entry, "cwe"), Map.get(entry, "CWE")]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.flat_map(&values/1)
    |> normalize()
  end

  def from_kev_entry(_entry), do: []

  @doc """
  CWE ids from a stored advisory: `metadata.cwes`, then NVD/KEV shapes in `raw`.
  """
  def from_advisory(advisory) when is_map(advisory) do
    normalize(metadata_cwes(advisory) ++ from_raw(advisory))
  end

  def from_advisory(_advisory), do: []

  defp from_raw(advisory) do
    raw = get(advisory, :raw)

    case raw do
      %{} = map ->
        cve = Map.get(map, "cve") || Map.get(map, :cve) || %{}
        from_nvd_cve(cve) ++ from_kev_entry(map)

      _ ->
        []
    end
  end

  defp metadata_cwes(advisory) do
    case get(advisory, :metadata) do
      %{"cwes" => cwes} -> List.wrap(cwes)
      %{cwes: cwes} -> List.wrap(cwes)
      _ -> []
    end
  end

  defp values(%{"value" => value}), do: values(value)
  defp values(%{value: value}), do: values(value)
  defp values(value) when is_binary(value), do: @cwe |> Regex.scan(value) |> List.flatten()
  defp values(value) when is_list(value), do: Enum.flat_map(value, &values/1)
  defp values(_value), do: []

  defp normalize(values) do
    values
    |> Enum.map(fn value -> value |> to_string() |> String.trim() |> String.upcase() end)
    |> Enum.filter(&String.starts_with?(&1, "CWE-"))
    |> Enum.uniq()
  end

  defp get(row, key) when is_map(row) do
    Map.get(row, key) || Map.get(row, to_string(key))
  end

  defp get(_row, _key), do: nil
end
