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

  test "northbound_ready? allows manual runs even when recurring northbound is disabled" do
    source = %{
      northbound_enabled: false,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{api_key: "key-1", api_secret: "secret-1"}
    }

    assert :ok = ArmisNorthboundRunner.northbound_ready?(source, manual?: true)
    assert {:error, :northbound_disabled} = ArmisNorthboundRunner.northbound_ready?(source)
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

  test "run_for_source persists success lifecycle with normalized counts" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{api_key: "key", api_secret: "secret"}
    }

    actor = %{role: :system}
    parent = self()

    candidates = [
      %{
        armis_device_id: "armis-2",
        is_available: true,
        device_id: "d2",
        sync_service_id: "source-1",
        metadata: %{}
      },
      %{
        armis_device_id: "armis-1",
        is_available: false,
        device_id: "d1",
        sync_service_id: "source-1",
        metadata: %{}
      }
    ]

    start_run = fn start_source, start_actor, _opts ->
      send(parent, {:start_run, start_source.id, start_actor})
      {:ok, %{id: "run-1"}}
    end

    update_source = fn _src, action, attrs, _actor ->
      send(parent, {:update_source, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    finish_run = fn _run, action, attrs, _actor, _opts ->
      send(parent, {:finish_run, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    load_candidates = fn _src, _opts -> {:ok, candidates} end

    execute_batches = fn _src, collapsed, _opts ->
      send(parent, {:collapsed_candidates, collapsed})

      {:ok,
       %{
         device_count: 2,
         updated_count: 2,
         skipped_count: 0,
         error_count: 0,
         batch_count: 1,
         errors: []
       }}
    end

    assert {:ok, %{result: result}} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               start_run: start_run,
               update_source: update_source,
               finish_run: finish_run,
               load_candidates: load_candidates,
               execute_batches: execute_batches
             )

    assert result.updated_count == 2
    assert_received {:start_run, "source-1", ^actor}

    assert_received {:collapsed_candidates,
                     [%{armis_device_id: "armis-1"}, %{armis_device_id: "armis-2"}]}

    assert_received {:update_source, :northbound_start, %{device_count: 2}}

    assert_received {:finish_run, :finish_success,
                     %{
                       device_count: 2,
                       updated_count: 2,
                       skipped_count: 0,
                       error_count: 0,
                       error_message: nil,
                       metadata: %{batch_count: 1, errors: []}
                     }}

    assert_received {:update_source, :northbound_success,
                     %{result: :success, device_count: 2, updated_count: 2, skipped_count: 0}}
  end

  test "run_for_source records partial failures when some batches already succeeded" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{api_key: "key", api_secret: "secret"}
    }

    actor = %{role: :system}
    parent = self()

    start_run = fn _source, _actor, _opts -> {:ok, %{id: "run-2"}} end

    update_source = fn _src, action, attrs, _actor ->
      send(parent, {:update_source, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    finish_run = fn _run, action, attrs, _actor, _opts ->
      send(parent, {:finish_run, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    load_candidates = fn _src, _opts ->
      {:ok,
       [
         %{
           armis_device_id: "armis-1",
           is_available: true,
           device_id: "d1",
           sync_service_id: "source-1",
           metadata: %{}
         }
       ]}
    end

    execute_batches = fn _src, _collapsed, _opts ->
      {:error,
       %{
         device_count: 1,
         updated_count: 1,
         skipped_count: 0,
         error_count: 1,
         batch_count: 2,
         errors: [%{batch_size: 1, reason: :upstream_timeout}]
       }}
    end

    assert {:error, %{result: result}} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               start_run: start_run,
               update_source: update_source,
               finish_run: finish_run,
               load_candidates: load_candidates,
               execute_batches: execute_batches
             )

    assert result.error_message =~ ":upstream_timeout"

    assert_received {:finish_run, :finish_partial,
                     %{error_count: 1, error_message: error_message}}

    assert error_message =~ ":upstream_timeout"

    assert_received {:update_source, :northbound_success,
                     %{result: :partial, device_count: 1, updated_count: 1, skipped_count: 1}}
  end
end
