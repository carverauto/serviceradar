defmodule ServiceRadar.Integrations.ArmisNorthboundRunnerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadar.Integrations.ArmisNorthboundRunner

  test "northbound_ready? rejects disabled or incomplete sources" do
    assert {:error, :northbound_disabled} =
             ArmisNorthboundRunner.northbound_ready?(%{northbound_enabled: false})

    assert {:error, :missing_custom_field} =
             ArmisNorthboundRunner.northbound_ready?(%{
               northbound_enabled: true,
               endpoint: "https://armis.example",
               credentials: %{secret_key: "secret"}
             })

    assert {:error, :missing_credentials} =
             ArmisNorthboundRunner.northbound_ready?(%{
               northbound_enabled: true,
               endpoint: "https://armis.example",
               custom_fields: ["availability"]
             })

    assert :ok =
             ArmisNorthboundRunner.northbound_ready?(%{
               northbound_enabled: true,
               endpoint: "https://armis.example",
               custom_fields: ["availability"],
               credentials: %{secret_key: "secret"}
             })
  end

  test "collapse_candidates emits one row per armis_device_id and prefers unavailable on conflicts" do
    collapsed =
      ArmisNorthboundRunner.collapse_candidates([
        %{
          armis_device_id: "armis-1",
          is_available: true,
          device_id: "dev-a",
          sync_service_id: "source-1",
          metadata: %{hostname: "router-a"}
        },
        %{
          armis_device_id: "armis-1",
          is_available: false,
          device_id: "dev-b",
          sync_service_id: "source-1",
          metadata: %{ip: "10.0.0.2"}
        },
        %{
          armis_device_id: "armis-2",
          is_available: true,
          device_id: "dev-c",
          sync_service_id: "source-2"
        }
      ])

    assert collapsed == [
             %{
               armis_device_id: "armis-1",
               is_available: false,
               device_ids: ["dev-a", "dev-b"],
               sync_service_ids: ["source-1"],
               metadata: %{hostname: "router-a", ip: "10.0.0.2"}
             },
             %{
               armis_device_id: "armis-2",
               is_available: true,
               device_ids: ["dev-c"],
               sync_service_ids: ["source-2"],
               metadata: %{}
             }
           ]
  end

  test "build_bulk_payload writes the configured custom field" do
    payload =
      ArmisNorthboundRunner.build_bulk_payload("availability", [
        %{
          armis_device_id: "armis-1",
          is_available: true,
          device_ids: ["dev-a"],
          sync_service_ids: ["source-1"],
          metadata: %{}
        },
        %{
          armis_device_id: "armis-2",
          is_available: false,
          device_ids: ["dev-b"],
          sync_service_ids: ["source-1"],
          metadata: %{}
        }
      ])

    assert payload == [
             %{"id" => "armis-1", "customProperties" => %{"availability" => true}},
             %{"id" => "armis-2", "customProperties" => %{"availability" => false}}
           ]
  end

  test "batch_size and batch_candidates honor configured bulk chunking" do
    source = %{settings: %{"batch_size" => "2"}}

    assert ArmisNorthboundRunner.batch_size(source) == 2

    candidates = [
      %{
        armis_device_id: "1",
        is_available: true,
        device_ids: [],
        sync_service_ids: [],
        metadata: %{}
      },
      %{
        armis_device_id: "2",
        is_available: true,
        device_ids: [],
        sync_service_ids: [],
        metadata: %{}
      },
      %{
        armis_device_id: "3",
        is_available: false,
        device_ids: [],
        sync_service_ids: [],
        metadata: %{}
      }
    ]

    assert ArmisNorthboundRunner.batch_candidates(candidates, 2) == [
             [Enum.at(candidates, 0), Enum.at(candidates, 1)],
             [Enum.at(candidates, 2)]
           ]
  end

  test "execute_batches authenticates, batches requests, and aggregates counts" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      settings: %{"batch_size" => 2},
      credentials: %{"api_key" => "key-1", "api_secret" => "secret-1"}
    }

    candidates = [
      %{
        armis_device_id: "armis-1",
        is_available: true,
        device_ids: ["d1"],
        sync_service_ids: ["source-1"],
        metadata: %{}
      },
      %{
        armis_device_id: "armis-2",
        is_available: false,
        device_ids: ["d2"],
        sync_service_ids: ["source-1"],
        metadata: %{}
      },
      %{
        armis_device_id: "armis-3",
        is_available: true,
        device_ids: ["d3"],
        sync_service_ids: ["source-1"],
        metadata: %{}
      }
    ]

    parent = self()

    token_fetcher = fn token_source ->
      send(parent, {:token_source, token_source})
      {:ok, "token-abc"}
    end

    request = fn path, method, headers, body, _opts ->
      send(parent, {:request, path, method, headers, body})
      {:ok, %{status: 200, body: %{"success" => true}}}
    end

    assert {:ok, result} =
             ArmisNorthboundRunner.execute_batches(source, candidates,
               token_fetcher: token_fetcher,
               request: request
             )

    assert result.device_count == 3
    assert result.updated_count == 3
    assert result.skipped_count == 0
    assert result.error_count == 0
    assert result.batch_count == 2

    assert_received {:token_source, ^source}

    assert_received {:request, "/api/v1/devices/custom-properties/_bulk/", :post, headers1, body1}

    assert_received {:request, "/api/v1/devices/custom-properties/_bulk/", :post, _headers2,
                     body2}

    assert headers1["authorization"] == "Bearer token-abc"
    assert headers1["content-type"] == "application/json"
    assert length(body1) == 2
    assert length(body2) == 1
  end

  test "execute_batches returns partial results when a later batch fails" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      settings: %{"batch_size" => 2},
      credentials: %{"api_key" => "key-1", "api_secret" => "secret-1"}
    }

    candidates = [
      %{
        armis_device_id: "armis-1",
        is_available: true,
        device_ids: ["d1"],
        sync_service_ids: ["source-1"],
        metadata: %{}
      },
      %{
        armis_device_id: "armis-2",
        is_available: false,
        device_ids: ["d2"],
        sync_service_ids: ["source-1"],
        metadata: %{}
      },
      %{
        armis_device_id: "armis-3",
        is_available: true,
        device_ids: ["d3"],
        sync_service_ids: ["source-1"],
        metadata: %{}
      }
    ]

    token_fetcher = fn _source -> {:ok, "token-abc"} end

    request = fn _path, _method, _headers, body, _opts ->
      case length(body) do
        2 -> {:ok, %{status: 200, body: %{"success" => true}}}
        1 -> {:error, :upstream_timeout}
      end
    end

    assert {:error, result} =
             ArmisNorthboundRunner.execute_batches(source, candidates,
               token_fetcher: token_fetcher,
               request: request
             )

    assert result.device_count == 3
    assert result.updated_count == 2
    assert result.skipped_count == 0
    assert result.error_count == 1
    assert result.batch_count == 2
    assert result.errors == [%{batch_size: 1, reason: :upstream_timeout}]
  end
end
