defmodule ServiceRadar.External.ArmisNorthboundLiveTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Integrations.ArmisNorthboundRunner

  @moduletag :external
  @moduletag :armis_northbound_live

  @default_page_size 1_000
  @default_max_pages 50

  @tag timeout: 120_000
  test "live Armis northbound auth and single-device bulk custom property update" do
    Application.ensure_all_started(:req)

    endpoint = required_env("SERVICERADAR_ARMIS_API_URL")
    secret = required_env("SERVICERADAR_ARMIS_API_SECRET")
    api_key = System.get_env("SERVICERADAR_ARMIS_API_KEY")
    device_ip = required_env("SERVICERADAR_ARMIS_DEVICE_IP")
    custom_field = required_env("SERVICERADAR_ARMIS_CUSTOM_FIELD")
    desired_value = System.get_env("SERVICERADAR_ARMIS_NORTHBOUND_VALUE", "false")

    token = fetch_access_token!(endpoint, secret)
    device = find_device_by_ip!(endpoint, token, device_ip)
    armis_device_id = Map.fetch!(device, "id")

    source = %{
      id: "external-armis-live",
      northbound_enabled: true,
      endpoint: endpoint,
      custom_fields: [custom_field],
      settings: %{"batch_size" => 1},
      credentials: compact_credentials(api_key, secret)
    }

    candidates = [
      %{
        armis_device_id: to_string(armis_device_id),
        is_available: availability_for_desired_northbound_value(desired_value),
        device_ids: [device_ip],
        sync_service_ids: ["external-armis-live"],
        metadata: %{"ipAddress" => Map.get(device, "ipAddress")}
      }
    ]

    assert {:ok, result} = ArmisNorthboundRunner.execute_batches(source, candidates)
    assert result.device_count == 1
    assert result.updated_count == 1
    assert result.error_count == 0
    assert result.errors == []
  end

  defp required_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          missing_env!(name)
        else
          value
        end

      _ ->
        missing_env!(name)
    end
  end

  defp missing_env!(name) do
    raise """
    Missing required environment variable #{name}.

    Required:
      SERVICERADAR_ARMIS_API_URL
      SERVICERADAR_ARMIS_API_SECRET
      SERVICERADAR_ARMIS_DEVICE_IP
      SERVICERADAR_ARMIS_CUSTOM_FIELD

    Optional:
      SERVICERADAR_ARMIS_API_KEY
      SERVICERADAR_ARMIS_NORTHBOUND_VALUE=true|false
      SERVICERADAR_ARMIS_SEARCH_AQL
      SERVICERADAR_ARMIS_SEARCH_MAX_PAGES
    """
  end

  defp compact_credentials(nil, secret), do: %{"api_secret" => secret, "secret_key" => secret}
  defp compact_credentials("", secret), do: %{"api_secret" => secret, "secret_key" => secret}

  defp compact_credentials(api_key, secret) do
    %{"api_key" => api_key, "api_secret" => secret, "secret_key" => secret}
  end

  defp fetch_access_token!(endpoint, secret) do
    url = endpoint_url(endpoint, "/api/v1/access_token/")

    case Req.post(url,
           form: %{"secret_key" => secret},
           headers: [
             {"Content-Type", "application/x-www-form-urlencoded"},
             {"Accept", "application/json"}
           ]
         ) do
      {:ok, %{status: status, body: %{"data" => %{"access_token" => token}}}}
      when status in 200..299 and is_binary(token) and token != "" ->
        token

      {:ok, %{status: status, body: body}} ->
        flunk(
          "Armis access token request failed with HTTP #{status}: #{inspect(redact_body(body))}"
        )

      {:error, reason} ->
        flunk("Armis access token request failed: #{inspect(reason)}")
    end
  end

  defp find_device_by_ip!(endpoint, token, device_ip) do
    aql = System.get_env("SERVICERADAR_ARMIS_SEARCH_AQL", "in:devices")
    max_pages = positive_int_env("SERVICERADAR_ARMIS_SEARCH_MAX_PAGES", @default_max_pages)

    0..(max_pages - 1)
    |> Enum.reduce_while(nil, fn page, _acc ->
      from = page * @default_page_size

      case search_devices(endpoint, token, aql, from, @default_page_size) do
        {:ok, %{"data" => %{"results" => results, "next" => next}}} ->
          case Enum.find(results, &device_matches_ip?(&1, device_ip)) do
            nil when next in [nil, 0] ->
              {:halt, nil}

            nil ->
              {:cont, nil}

            device ->
              {:halt, device}
          end

        {:ok, body} ->
          flunk("Unexpected Armis search response body: #{inspect(redact_body(body))}")

        {:error, {status, body}} ->
          flunk("Armis device search failed with HTTP #{status}: #{inspect(redact_body(body))}")

        {:error, reason} ->
          flunk("Armis device search failed: #{inspect(reason)}")
      end
    end)
    |> case do
      nil ->
        flunk(
          "No Armis device with IP #{device_ip} found using AQL #{inspect(aql)} in #{@default_page_size * max_pages} scanned rows"
        )

      device ->
        device
    end
  end

  defp search_devices(endpoint, token, aql, from, length) do
    url = endpoint_url(endpoint, "/api/v1/search/")

    params =
      if from > 0, do: [aql: aql, from: from, length: length], else: [aql: aql, length: length]

    case Req.get(url,
           params: params,
           headers: [{"Authorization", token}, {"Accept", "application/json"}]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp device_matches_ip?(device, expected_ip) do
    device
    |> Map.get("ipAddress", "")
    |> to_string()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.member?(expected_ip)
  end

  defp availability_for_desired_northbound_value(value) do
    case String.downcase(String.trim(value)) do
      "true" ->
        false

      "false" ->
        true

      other ->
        raise "SERVICERADAR_ARMIS_NORTHBOUND_VALUE must be true or false, got #{inspect(other)}"
    end
  end

  defp endpoint_url(endpoint, path) do
    endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp positive_int_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> raise "#{name} must be a positive integer"
        end
    end
  end

  defp redact_body(body) when is_map(body) do
    Map.drop(body, ["access_token", "token", "secret", "secret_key", "api_key", "api_secret"])
  end

  defp redact_body(body), do: body
end
