defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.AsnLookup do
  @moduledoc false

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.Params, only: [normalize_optional_string: 1]

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.AsnLookup.Cache

  def fetch_arin_asn(asn) when is_integer(asn) and asn > 0 do
    case Cache.get(asn) do
      {:hit, result} ->
        result

      :miss ->
        result = fetch_arin_asn_remote(asn)
        Cache.put(asn, result)
        result
    end
  end

  def fetch_arin_asn(_), do: {:error, :invalid_asn}

  def fetch_asn_registry_data(asn, rir_hint) when is_integer(asn) and asn > 0 do
    strategy =
      case rir_hint do
        :ripe -> [:ripe, :arin]
        :arin -> [:arin, :ripe]
        _ -> [:arin, :ripe]
      end

    run_asn_lookup_strategy(asn, strategy)
  end

  def fetch_asn_registry_data(_asn, _rir_hint), do: {:error, :invalid_asn}

  def run_asn_lookup_strategy(asn, [first, second]) do
    case run_asn_lookup(asn, first) do
      {:ok, data} ->
        {:ok, data}

      {:error, first_reason} ->
        case run_asn_lookup(asn, second) do
          {:ok, data} ->
            {:ok, data}

          {:error, second_reason} ->
            {:error, {:lookup_failed, first, first_reason, second, second_reason}}
        end
    end
  end

  def run_asn_lookup(asn, :arin), do: fetch_arin_asn(asn)
  def run_asn_lookup(asn, :ripe), do: fetch_ripe_asn(asn)

  def normalize_rir_hint(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "ripe" -> :ripe
      "arin" -> :arin
      _ -> :auto
    end
  end

  def normalize_rir_hint(_), do: :auto

  def fetch_arin_asn_remote(asn) when is_integer(asn) and asn > 0 do
    url = "https://whois.arin.net/rest/asn/AS#{asn}.json"

    case Req.get(url, http_req_opts()) do
      {:ok, %Req.Response{status: 200, body: %{"asn" => asn_payload}}} when is_map(asn_payload) ->
        {:ok, normalize_arin_asn(asn_payload)}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  def fetch_arin_asn_remote(_), do: {:error, :invalid_asn}

  def fetch_ripe_asn(asn) when is_integer(asn) and asn > 0 do
    url = "https://stat.ripe.net/data/whois/data.json?resource=AS#{asn}"

    case Req.get(url, http_req_opts()) do
      {:ok, %Req.Response{status: 200, body: %{"data" => %{"records" => records}}}}
      when is_list(records) ->
        case normalize_ripe_asn(asn, records) do
          %{} = data when map_size(data) > 0 -> {:ok, data}
          _ -> {:error, :not_found}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  def fetch_ripe_asn(_), do: {:error, :invalid_asn}

  def http_req_opts do
    opts = [receive_timeout: 8_000, retry: false, headers: [{"accept", "application/json"}]]

    if Process.whereis(ServiceRadar.Finch) do
      Keyword.put(opts, :finch, ServiceRadar.Finch)
    else
      opts
    end
  end

  def normalize_arin_asn(%{} = asn_payload) do
    org_ref = Map.get(asn_payload, "orgRef")
    start_as = arin_leaf_value(Map.get(asn_payload, "startAsNumber"))
    end_as = arin_leaf_value(Map.get(asn_payload, "endAsNumber"))

    %{
      source: "ARIN Whois-RWS",
      handle: arin_leaf_value(Map.get(asn_payload, "handle")),
      name: arin_leaf_value(Map.get(asn_payload, "name")),
      range: arin_as_range(start_as, end_as),
      registration_date: arin_leaf_value(Map.get(asn_payload, "registrationDate")),
      update_date: arin_leaf_value(Map.get(asn_payload, "updateDate")),
      rdap_ref: arin_leaf_value(Map.get(asn_payload, "rdapRef")),
      ref: arin_leaf_value(Map.get(asn_payload, "ref")),
      org_handle: if(is_map(org_ref), do: Map.get(org_ref, "@handle")),
      org_name: if(is_map(org_ref), do: Map.get(org_ref, "@name")),
      org_ref: if(is_map(org_ref), do: Map.get(org_ref, "$")),
      comment: arin_comment(Map.get(asn_payload, "comment"))
    }
  end

  def normalize_ripe_asn(asn, records) when is_integer(asn) and is_list(records) do
    flat =
      records
      |> List.flatten()
      |> Enum.filter(&is_map/1)

    name = ripe_record_value(flat, ["as-name", "ASName"])
    org_name = ripe_record_value(flat, ["org-name", "OrgName", "org"])
    descr = flat |> ripe_record_values(["descr", "Description", "remarks"]) |> Enum.join(" | ")
    country = ripe_record_value(flat, ["country"])
    registration_date = ripe_record_value(flat, ["RegDate", "created"])
    update_date = ripe_record_value(flat, ["Updated", "last-modified"])

    ref =
      ripe_record_details_link(flat, ["aut-num", "ASHandle", "ASNumber"]) ||
        "https://stat.ripe.net/AS#{asn}"

    %{
      source: "RIPE Stat Whois",
      handle: "AS#{asn}",
      name: normalize_optional_string(name),
      range: "AS#{asn}",
      registration_date: normalize_optional_string(registration_date),
      update_date: normalize_optional_string(update_date),
      org_handle: nil,
      org_name:
        [normalize_optional_string(org_name), normalize_optional_string(country)]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" ")
        |> normalize_optional_string(),
      org_ref: nil,
      comment: normalize_optional_string(descr),
      rdap_ref: nil,
      ref: normalize_optional_string(ref)
    }
  end

  def normalize_ripe_asn(_asn, _records), do: %{}

  def ripe_record_value(records, keys) when is_list(records) and is_list(keys) do
    Enum.find_value(records, fn
      %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) ->
        if key in keys, do: String.trim(value)

      _ ->
        nil
    end)
  end

  def ripe_record_values(records, keys) when is_list(records) and is_list(keys) do
    records
    |> Enum.flat_map(fn
      %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) ->
        if Enum.member?(keys, key), do: [String.trim(value)], else: []

      _ ->
        []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def ripe_record_details_link(records, keys) when is_list(records) and is_list(keys) do
    Enum.find_value(records, fn
      %{"key" => key, "details_link" => value} when is_binary(key) and is_binary(value) ->
        if key in keys, do: String.trim(value)

      _ ->
        nil
    end)
  end

  def arin_leaf_value(%{"$" => value}) when is_binary(value), do: String.trim(value)
  def arin_leaf_value(value) when is_binary(value), do: String.trim(value)
  def arin_leaf_value(_), do: nil

  def arin_comment(%{"line" => lines}) when is_list(lines) do
    lines
    |> Enum.map(&arin_leaf_value/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> normalize_optional_string()
  end

  def arin_comment(%{"line" => line}) do
    arin_leaf_value(line)
  end

  def arin_comment(_), do: nil

  def arin_as_range(start_as, end_as) when is_binary(start_as) and is_binary(end_as) do
    if start_as == end_as, do: "AS#{start_as}", else: "AS#{start_as}-AS#{end_as}"
  end

  def arin_as_range(_start_as, _end_as), do: nil

  def arin_error_text(:invalid_asn), do: "Invalid ASN."
  def arin_error_text({:lookup_failed, _, _, _, _}), do: "ASN lookup failed in ARIN and RIPE."
  # Use country as a cheap first-pass hint:
  # - US/CA usually ARIN first
  # - everything else RIPE first, with fallback still enabled
  def asn_rir_hint(country_code) when is_binary(country_code) do
    case country_code |> String.trim() |> String.upcase() do
      "US" -> "arin"
      "CA" -> "arin"
      "" -> "arin"
      _ -> "ripe"
    end
  end

  def asn_rir_hint(_), do: "arin"
end
