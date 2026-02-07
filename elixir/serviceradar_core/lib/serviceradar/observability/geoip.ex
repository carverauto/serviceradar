defmodule ServiceRadar.Observability.GeoIP do
  @moduledoc """
  GeoIP/ASN enrichment using local GeoLite2 MMDB databases (no external calls).

  Lookups are performed via `Geolix` which reads the MMDBs configured in
  `config/runtime.exs`.
  """

  require Logger

  @type geo_asn :: %{
          optional(:asn) => integer(),
          optional(:as_org) => String.t(),
          optional(:country_iso2) => String.t(),
          optional(:country_name) => String.t(),
          optional(:region) => String.t(),
          optional(:city) => String.t(),
          optional(:latitude) => float(),
          optional(:longitude) => float(),
          optional(:timezone) => String.t()
        }

  @spec lookup(String.t()) :: {:ok, geo_asn()} | {:error, term()}
  def lookup(ip) when is_binary(ip) do
    with {:ok, ip_tuple} <- parse_ip(ip) do
      result = Geolix.lookup(ip_tuple)

      # Geolix returns a map keyed by configured database ids (atoms).
      asn = normalize_asn(Map.get(result, :geolite2_asn))
      city = normalize_city(Map.get(result, :geolite2_city))
      country = normalize_country(Map.get(result, :geolite2_country))

      {:ok, Map.merge(asn, Map.merge(city, country))}
    end
  rescue
    e ->
      {:error, e}
  end

  def lookup(_), do: {:error, :invalid_ip}

  defp parse_ip(ip) when is_binary(ip) do
    ip = ip |> String.trim() |> String.split("/", parts: 2) |> List.first()

    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> {:error, :invalid_ip}
    end
  end

  defp normalize_asn(nil), do: %{}

  defp normalize_asn(%{} = data) do
    asn =
      data
      |> get_in(["autonomous_system_number"])
      |> case do
        n when is_integer(n) -> n
        _ -> nil
      end

    as_org =
      data
      |> get_in(["autonomous_system_organization"])
      |> case do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end

    %{}
    |> maybe_put(:asn, asn)
    |> maybe_put(:as_org, as_org)
  end

  defp normalize_asn(_), do: %{}

  defp normalize_country(nil), do: %{}

  defp normalize_country(%{} = data) do
    iso2 = get_in(data, ["country", "iso_code"])
    name = get_in(data, ["country", "names", "en"])

    %{}
    |> maybe_put(:country_iso2, normalize_string(iso2))
    |> maybe_put(:country_name, normalize_string(name))
  end

  defp normalize_country(_), do: %{}

  defp normalize_city(nil), do: %{}

  defp normalize_city(%{} = data) do
    city = get_in(data, ["city", "names", "en"])
    # MaxMind uses `subdivisions` list; take first for "region".
    region = get_in(data, ["subdivisions", Access.at(0), "names", "en"])

    {lat, lon} =
      case get_in(data, ["location"]) do
        %{"latitude" => lat, "longitude" => lon} when is_number(lat) and is_number(lon) ->
          {lat * 1.0, lon * 1.0}

        _ ->
          {nil, nil}
      end

    tz = get_in(data, ["location", "time_zone"])

    %{}
    |> maybe_put(:city, normalize_string(city))
    |> maybe_put(:region, normalize_string(region))
    |> maybe_put(:latitude, lat)
    |> maybe_put(:longitude, lon)
    |> maybe_put(:timezone, normalize_string(tz))
  end

  defp normalize_city(_), do: %{}

  defp normalize_string(v) when is_binary(v) do
    v = String.trim(v)
    if v == "", do: nil, else: v
  end

  defp normalize_string(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

