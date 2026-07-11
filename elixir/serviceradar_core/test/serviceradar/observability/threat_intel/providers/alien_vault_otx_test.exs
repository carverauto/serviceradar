defmodule ServiceRadar.Observability.ThreatIntel.Providers.AlienVaultOTXTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ThreatIntel.Page
  alias ServiceRadar.Observability.ThreatIntel.Providers.AlienVaultOTX
  alias ServiceRadar.Observability.ThreatIntelOTXSyncWorker

  test "fetches subscribed pulses with auth header and pagination params" do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:request, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "count" => 2,
           "next" => "https://otx.example/api/v1/pulses/subscribed?page=5",
           "results" => [
             %{
               "id" => "pulse-1",
               "name" => "Known C2",
               "author_name" => "otx-user",
               "created" => "2026-04-26T10:00:00Z",
               "modified" => "2026-04-27T10:00:00Z",
               "indicators" => [
                 %{
                   "indicator" => "198.51.100.10",
                   "type" => "IPv4",
                   "created" => "2026-04-26T10:30:00Z"
                 },
                 %{
                   "indicator" => "198.51.100.11",
                   "type" => "IPv4",
                   "created" => "2026-04-26T10:31:00Z"
                 },
                 %{"indicator" => "example.invalid", "type" => "domain"}
               ]
             }
           ]
         }
       }}
    end

    assert {:ok, %Page{} = page} =
             AlienVaultOTX.fetch_page(
               %{
                 api_key: "test-key",
                 base_url: "https://otx.example",
                 limit: 25,
                 page: 3,
                 max_iocs: 1,
                 max_indicators: 1,
                 http_get: http_get,
                 validate_url?: false
               },
               %{"modified_since" => "2026-04-27T00:00:00Z", "page" => 4}
             )

    assert_received {:request, url, opts}
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "otx.example"
    assert uri.path == "/api/v1/pulses/subscribed"
    assert query["limit"] == "25"
    assert query["page"] == "4"
    assert query["modified_since"] == "2026-04-27T00:00:00Z"
    assert {"x-otx-api-key", "test-key"} in opts[:headers]

    assert page.provider == "alienvault_otx"
    assert page.source == "alienvault_otx"
    assert page.collection_id == "otx:pulses:subscribed"
    assert page.cursor["page"] == 4
    assert page.cursor["next"] == "https://otx.example/api/v1/pulses/subscribed?page=5"
    assert page.cursor["next_page"] == 5

    assert ThreatIntelOTXSyncWorker.continuation_cursor(page.cursor) == %{
             "page" => 5,
             "next" => "https://otx.example/api/v1/pulses/subscribed?page=5",
             "modified_since" => "2026-04-27T00:00:00Z"
           }

    assert page.counts == %{
             "objects" => 1,
             "indicators" => 2,
             "skipped" => 1,
             "skipped_by_type" => %{"domain" => 1},
             "total" => 2
           }

    assert Enum.map(page.indicators, & &1["indicator"]) == [
             "198.51.100.10",
             "198.51.100.11"
           ]

    assert Enum.all?(page.indicators, fn indicator ->
             indicator["source_object_id"] == "pulse-1" and
               indicator["source_object_type"] == "otx-pulse" and
               indicator["source_context"] == "otx-user"
           end)
  end

  test "resumes a legacy cursor that only persisted the provider next URL" do
    parent = self()

    http_get = fn url, _opts ->
      send(parent, {:request, url})
      {:ok, %Req.Response{status: 200, body: %{"results" => []}}}
    end

    assert {:ok, %Page{}} =
             AlienVaultOTX.fetch_page(
               %{
                 api_key: "test-key",
                 base_url: "https://otx.example",
                 http_get: http_get,
                 validate_url?: false
               },
               %{"next" => "https://otx.example/api/v1/pulses/subscribed?limit=100&page=6"}
             )

    assert_received {:request, url}
    assert URI.decode_query(URI.parse(url).query)["page"] == "6"
  end

  test "stamps a durable completion high-water for the next root sync" do
    now = ~U[2026-07-11 03:00:00Z]

    page = %Page{
      provider: "alienvault_otx",
      source: "alienvault_otx",
      cursor: %{"page" => 7, "next" => nil},
      raw: %{}
    }

    stamped = ThreatIntelOTXSyncWorker.stamp_durable_cursor(page, now)

    assert stamped.cursor == %{
             "page" => 1,
             "next" => nil,
             "complete" => "true",
             "modified_since" => "2026-07-09T03:00:00Z"
           }

    assert stamped.raw["cursor"] == stamped.cursor
  end

  test "retries OTX rate limits and transient server failures" do
    parent = self()
    attempts = :counters.new(1, [])

    http_get = fn url, _opts ->
      :counters.add(attempts, 1, 1)
      send(parent, {:attempt, url})

      case :counters.get(attempts, 1) do
        1 -> {:ok, %Req.Response{status: 429, body: ""}}
        2 -> {:ok, %Req.Response{status: 500, body: ""}}
        _ -> {:ok, %Req.Response{status: 200, body: %{"results" => []}}}
      end
    end

    assert {:ok, %Page{counts: %{"objects" => 0}}} =
             AlienVaultOTX.fetch_page(%{
               api_key: "test-key",
               base_url: "https://otx.example",
               http_get: http_get,
               sleep_fun: fn _ -> :ok end,
               backoff_ms: 1,
               max_retries: 2,
               validate_url?: false
             })

    assert_received {:attempt, _}
    assert_received {:attempt, _}
    assert_received {:attempt, _}
  end

  test "returns terminal errors without leaking API key" do
    http_get = fn _url, _opts ->
      {:ok, %Req.Response{status: 401, body: "unauthorized"}}
    end

    assert {:error, {:http_status, 401}} =
             AlienVaultOTX.fetch_page(%{
               api_key: "super-secret-key",
               base_url: "https://otx.example",
               http_get: http_get,
               validate_url?: false
             })
  end

  test "requires an API key" do
    assert {:error, :missing_api_key} = AlienVaultOTX.fetch_page(%{})
  end
end
