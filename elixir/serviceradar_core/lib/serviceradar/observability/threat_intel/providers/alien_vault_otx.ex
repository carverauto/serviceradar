defmodule ServiceRadar.Observability.ThreatIntel.Providers.AlienVaultOTX do
  @moduledoc """
  AlienVault OTX DirectConnect provider adapter.

  Fetches subscribed OTX pulses and adapts them into the provider-neutral
  `ThreatIntel.Page` contract. The HTTP call uses `X-OTX-API-KEY` and bounded
  retry/backoff for OTX rate-limit or transient server failures.
  """

  @behaviour ServiceRadar.Observability.ThreatIntel.Provider

  alias ServiceRadar.Observability.OutboundFeedPolicy
  alias ServiceRadar.Observability.ThreatIntel.Page

  @provider "alienvault_otx"
  @collection_id "otx:pulses:subscribed"
  @default_base_url "https://otx.alienvault.com"
  @default_limit 10
  @default_page 1
  @default_timeout_ms 20_000
  @default_max_indicators 2_000
  @max_limit 100
  @max_indicators 5_000
  @default_max_retries 2
  @default_backoff_ms 500

  @impl true
  def fetch_page(config, cursor \\ %{}) when is_map(config) and is_map(cursor) do
    with {:ok, cfg} <- normalize_config(config, cursor),
         {:ok, url} <- subscribed_pulses_url(cfg),
         :ok <- maybe_validate_url(url, cfg),
         {:ok, response} <- request_with_retries(url, cfg),
         {:ok, body} <- decode_body(response.body) do
      {:ok, Page.from_map(page_map(body, cfg), %{})}
    end
  end

  @doc false
  def subscribed_pulses_url(cfg) when is_map(cfg) do
    base_url = cfg.base_url || @default_base_url

    with %URI{} = uri <- URI.parse(String.trim_trailing(base_url, "/")),
         true <- is_binary(uri.scheme) and is_binary(uri.host) do
      query =
        %{
          "limit" => cfg.limit,
          "page" => cfg.page
        }
        |> maybe_put("modified_since", cfg.modified_since)
        |> URI.encode_query()

      uri =
        uri
        |> Map.put(
          :path,
          String.trim_trailing(uri.path || "", "/") <> "/api/v1/pulses/subscribed"
        )
        |> Map.put(:query, query)

      {:ok, URI.to_string(uri)}
    else
      _ -> {:error, :invalid_base_url}
    end
  end

  defp normalize_config(config, cursor) do
    api_key = string_value(config, [:api_key, "api_key"])

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      {:ok,
       %{
         base_url: string_value(config, [:base_url, "base_url"]) || @default_base_url,
         api_key: api_key,
         modified_since:
           string_value(cursor, [:modified_since, "modified_since"]) ||
             string_value(config, [:modified_since, "modified_since"]),
         limit:
           config
           |> int_value([:limit, "limit"], @default_limit)
           |> clamp(1, @max_limit),
         page:
           cursor
           |> int_value([:page, "page"], int_value(config, [:page, "page"], @default_page))
           |> max(1),
         timeout_ms:
           config
           |> int_value([:timeout_ms, "timeout_ms"], @default_timeout_ms)
           |> max(1),
         max_indicators:
           config
           |> int_value([:max_indicators, "max_indicators"], @default_max_indicators)
           |> clamp(1, @max_indicators),
         max_retries:
           config
           |> int_value([:max_retries, "max_retries"], @default_max_retries)
           |> max(0),
         backoff_ms:
           config
           |> int_value([:backoff_ms, "backoff_ms"], @default_backoff_ms)
           |> max(0),
         http_get: Map.get(config, :http_get, &Req.get/2),
         sleep_fun: Map.get(config, :sleep_fun, &Process.sleep/1),
         validate_url?: Map.get(config, :validate_url?, Map.get(config, "validate_url?", true))
       }}
    end
  end

  defp maybe_validate_url(_url, %{validate_url?: false}), do: :ok
  defp maybe_validate_url(url, _cfg), do: OutboundFeedPolicy.validate(url)

  defp request_with_retries(url, cfg) do
    opts = [
      receive_timeout: cfg.timeout_ms,
      retry: false,
      finch: ServiceRadar.Finch,
      headers: [
        {"accept", "application/json"},
        {"x-otx-api-key", cfg.api_key}
      ]
    ]

    do_request_with_retries(url, opts, cfg, 0)
  end

  defp do_request_with_retries(url, opts, cfg, attempt) do
    case cfg.http_get.(url, opts) do
      {:ok, %Req.Response{status: status} = response} when status >= 200 and status < 300 ->
        {:ok, response}

      {:ok, %Req.Response{status: status}} when status == 429 or status >= 500 ->
        retry_or_error(url, opts, cfg, attempt, {:retryable_http_status, status})

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        retry_or_error(url, opts, cfg, attempt, reason)
    end
  end

  defp retry_or_error(url, opts, cfg, attempt, reason) do
    if attempt < cfg.max_retries do
      cfg.sleep_fun.(cfg.backoff_ms * (attempt + 1))
      do_request_with_retries(url, opts, cfg, attempt + 1)
    else
      {:error, reason}
    end
  end

  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(_body), do: {:error, :invalid_otx_payload}

  defp page_map(body, cfg) do
    results = list_value(body, ["results"])

    {indicators, skipped, skipped_by_type} =
      results
      |> Enum.flat_map(&pulse_indicators/1)
      |> Enum.reduce({[], 0, %{}}, fn {pulse, indicator}, {rows, skipped, skipped_by_type} ->
        if length(rows) >= cfg.max_indicators do
          {rows, skipped + 1, increment_skip(skipped_by_type, "max_indicators")}
        else
          case normalize_indicator(pulse, indicator) do
            {:ok, row} -> {[row | rows], skipped, skipped_by_type}
            :skip -> {rows, skipped + 1, increment_skip(skipped_by_type, skip_type(indicator))}
          end
        end
      end)

    indicators = Enum.reverse(indicators)

    %{
      "schema_version" => 1,
      "provider" => @provider,
      "source" => @provider,
      "collection_id" => @collection_id,
      "execution_mode" => "core_worker",
      "cursor" => %{
        "next" => string_value(body, ["next"]),
        "previous" => string_value(body, ["previous"]),
        "modified_since" => cfg.modified_since
      },
      "counts" => %{
        "objects" => length(results),
        "indicators" => length(indicators),
        "skipped" => skipped,
        "skipped_by_type" => skipped_by_type,
        "total" => int_value(body, ["count"], 0)
      },
      "indicators" => indicators,
      "raw" => %{"count" => int_value(body, ["count"], 0)}
    }
  end

  defp pulse_indicators(pulse) when is_map(pulse) do
    pulse
    |> list_value(["indicators"])
    |> Enum.map(&{pulse, &1})
  end

  defp pulse_indicators(_pulse), do: []

  defp normalize_indicator(pulse, indicator) when is_map(pulse) and is_map(indicator) do
    value = string_value(indicator, ["indicator"])
    type = string_value(indicator, ["type"])

    if is_binary(value) and supported_indicator_type?(type) do
      {:ok,
       %{
         "indicator" => value,
         "type" => "cidr",
         "source" => @provider,
         "label" => string_value(pulse, ["name"]) || string_value(indicator, ["title"]),
         "confidence" => 50,
         "first_seen_at" =>
           string_value(indicator, ["created"]) || string_value(pulse, ["created"]),
         "last_seen_at" =>
           string_value(pulse, ["modified"]) || string_value(indicator, ["created"]),
         "expires_at" => string_value(indicator, ["expiration"]),
         "source_object_id" => string_value(pulse, ["id"]),
         "source_object_type" => "otx-pulse",
         "source_context" => string_value(pulse, ["author_name"])
       }}
    else
      :skip
    end
  end

  defp normalize_indicator(_pulse, _indicator), do: :skip

  defp supported_indicator_type?(type) when is_binary(type) do
    type
    |> String.trim()
    |> String.downcase()
    |> Kernel.in(["ipv4", "ipv6", "cidr", "ipv4-cidr", "ipv6-cidr"])
  end

  defp supported_indicator_type?(_type), do: false

  defp increment_skip(counts, type) when is_map(counts) do
    type =
      type
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> case do
        "" -> "unknown"
        value -> value
      end

    Map.update(counts, type, 1, &(&1 + 1))
  end

  defp skip_type(indicator) when is_map(indicator) do
    cond do
      string_value(indicator, ["indicator"]) in [nil, ""] -> "empty"
      is_binary(string_value(indicator, ["type"])) -> string_value(indicator, ["type"])
      true -> "unknown"
    end
  end

  defp skip_type(_indicator), do: "unknown"

  defp list_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp string_value(map, keys) do
    case fetch_value(map, keys) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        Float.to_string(value)

      _ ->
        nil
    end
  end

  defp int_value(map, keys, default) do
    case fetch_value(map, keys) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> parse_int(value, default)
      _ -> default
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp fetch_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp fetch_value(_map, _keys), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp clamp(value, min, max), do: value |> max(min) |> min(max)
end
