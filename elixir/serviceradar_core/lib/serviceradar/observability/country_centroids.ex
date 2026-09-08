defmodule ServiceRadar.Observability.CountryCentroids do
  @moduledoc """
  Approximate country centroids for map placement when an IP has a country
  code (for example from ipinfo lite) but no city coordinates.

  ipinfo lite stores country/ASN only. The dashboard map still needs a
  lon/lat pair to draw an arc, so we fall back to these points rather
  than dropping the conversation.
  """

  @type point :: [float()]

  # Compact ISO-3166 alpha-2 centroids. Values are [longitude, latitude].
  @centroids %{
    "AE" => [53.85, 23.42],
    "AR" => [-63.62, -38.42],
    "AT" => [14.55, 47.52],
    "AU" => [133.78, -25.27],
    "BE" => [4.47, 50.50],
    "BG" => [25.49, 42.73],
    "BR" => [-51.93, -14.24],
    "CA" => [-106.35, 56.13],
    "CH" => [8.23, 46.82],
    "CL" => [-71.54, -35.68],
    "CN" => [104.20, 35.86],
    "CO" => [-74.30, 4.57],
    "CZ" => [15.47, 49.82],
    "DE" => [10.45, 51.17],
    "DK" => [9.50, 56.26],
    "ES" => [-3.75, 40.46],
    "FI" => [25.75, 61.92],
    "FR" => [2.21, 46.23],
    "GB" => [-3.44, 55.38],
    "GR" => [21.82, 39.07],
    "HK" => [114.17, 22.32],
    "HU" => [19.50, 47.16],
    "ID" => [113.92, -0.79],
    "IE" => [-8.24, 53.41],
    "IL" => [34.85, 31.05],
    "IN" => [78.96, 20.59],
    "IT" => [12.57, 41.87],
    "JP" => [138.25, 36.20],
    "KR" => [127.77, 35.91],
    "MX" => [-102.55, 23.63],
    "MY" => [101.98, 4.21],
    "NL" => [5.29, 52.13],
    "NO" => [8.47, 60.47],
    "NZ" => [174.89, -40.90],
    "PA" => [-80.78, 8.54],
    "PE" => [-75.02, -9.19],
    "PH" => [121.77, 12.88],
    "PK" => [69.35, 30.38],
    "PL" => [19.15, 51.92],
    "PT" => [-8.22, 39.40],
    "RO" => [24.97, 45.94],
    "RU" => [105.32, 61.52],
    "SA" => [45.08, 23.89],
    "SE" => [18.64, 60.13],
    "SG" => [103.82, 1.35],
    "TH" => [100.99, 15.87],
    "TR" => [35.24, 38.96],
    "TW" => [120.96, 23.70],
    "UA" => [31.17, 48.38],
    "US" => [-98.58, 39.83],
    "VN" => [108.28, 14.06],
    "ZA" => [22.94, -30.56]
  }

  @spec point(term()) :: point() | nil
  def point(code) when is_binary(code) do
    Map.get(@centroids, String.upcase(String.trim(code)))
  end

  def point(_), do: nil
end
