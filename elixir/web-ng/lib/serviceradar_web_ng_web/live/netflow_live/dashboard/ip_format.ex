defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.IpFormat do
  @moduledoc false

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  def iso2_flag_emoji(nil), do: nil

  def iso2_flag_emoji(iso2) when is_binary(iso2) do
    iso2 = iso2 |> String.trim() |> String.upcase()

    if String.length(iso2) == 2 do
      <<a::utf8, b::utf8>> = iso2

      if a in ?A..?Z and b in ?A..?Z do
        <<0x1F1E6 + (a - ?A)::utf8, 0x1F1E6 + (b - ?A)::utf8>>
      end
    end
  end

  def iso2_flag_emoji(_), do: nil

  @sobelow_skip ["XSS.Raw"]
  def format_enriched_ip(ip, rdns_map, geo_iso2_map) do
    flag = iso2_flag_emoji(Map.get(geo_iso2_map, ip))
    hostname = Map.get(rdns_map, ip)

    parts = [flag, ip] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    if hostname do
      Phoenix.HTML.raw(
        "<span>#{parts |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()}" <>
          "<br/><span class=\"text-xs text-sr-muted\">#{hostname |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()}</span></span>"
      )
    else
      parts
    end
  end
end
