defmodule ServiceRadar.Observability.IpInfo do
  @moduledoc """
  Local enrichment using the ipinfo.io lite MMDB database.

  The MMDB is downloaded by `ServiceRadar.Observability.IpinfoMmdbDownloadWorker`
  into the same directory as the GeoLite2 databases (default: `/var/lib/serviceradar/geoip`).
  """

  alias ServiceRadar.Observability.GeoIP

  @mmdb_id :ipinfo_lite
  @mmdb_filename "ipinfo_lite.mmdb"

  @spec mmdb_path() :: String.t()
  def mmdb_path do
    dir =
      Application.get_env(:serviceradar_core, :geolite_mmdb_dir, "/var/lib/serviceradar/geoip")

    Path.join(dir, @mmdb_filename)
  end

  @spec available?() :: boolean()
  def available? do
    File.exists?(mmdb_path())
  end

  @spec lookup(String.t()) :: {:ok, map()} | {:error, term()}
  def lookup(ip) when is_binary(ip) do
    with {:ok, ip_tuple} <- parse_ip(ip) do
      _ = GeoIP.ensure_loaded()
      result = Geolix.lookup(ip_tuple)

      case Map.get(result, @mmdb_id) do
        nil -> {:error, :not_found}
        %{} = data -> {:ok, normalize(data)}
        other -> {:error, {:unexpected_mmdb_payload, other}}
      end
    end
  rescue
    e -> {:error, e}
  end

  def lookup(_), do: {:error, :invalid_ip}

  defp parse_ip(ip) when is_binary(ip) do
    ip = ip |> String.trim() |> String.split("/", parts: 2) |> List.first()

    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> {:error, :invalid_ip}
    end
  end

  defp normalize(%{} = data) do
    country_code =
      get_first(data, [
        :country_code,
        "country_code",
        [:country, :code],
        ["country", "code"],
        :country,
        "country"
      ])

    %{
      country_code: normalize_string(country_code),
      country_name:
        normalize_string(
          get_first(data, [[:country, :name], ["country", "name"], :country_name, "country_name"])
        ),
      region: normalize_string(get_first(data, [:region, "region"])),
      city: normalize_string(get_first(data, [:city, "city"])),
      timezone: normalize_string(get_first(data, [:timezone, "timezone", :tz, "tz"])),
      as_number: normalize_asn(get_first(data, [:asn, "asn", [:as, :asn], ["as", "asn"]])),
      as_name:
        normalize_string(get_first(data, [:as_name, "as_name", [:as, :name], ["as", "name"]])),
      as_domain:
        normalize_string(
          get_first(data, [:as_domain, "as_domain", [:as, :domain], ["as", "domain"]])
        )
    }
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(value), do: value |> to_string() |> normalize_string()

  defp normalize_asn(nil), do: nil

  defp normalize_asn("AS" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_asn(value) when is_integer(value), do: value

  defp normalize_asn(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_asn(_), do: nil

  defp get_first(data, paths) when is_list(paths) do
    Enum.find_value(paths, fn
      key when is_atom(key) -> Map.get(data, key)
      key when is_binary(key) -> Map.get(data, key)
      path when is_list(path) -> get_in_mixed(data, path)
      _ -> nil
    end)
  end

  defp get_in_mixed(data, path) when is_list(path) do
    Enum.reduce_while(path, data, fn
      key, %{} = acc when is_atom(key) -> {:cont, Map.get(acc, key)}
      key, %{} = acc when is_binary(key) -> {:cont, Map.get(acc, key)}
      _key, _acc -> {:halt, nil}
    end)
  end
end
