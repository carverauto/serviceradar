defmodule ServiceRadar.Integrations.ArmisNorthboundRunnerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadar.Integrations.ArmisNorthboundRunner

  @moduletag :requires_app

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:req)
    :ok
  end

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

    assert {:error, :missing_credentials} =
             ArmisNorthboundRunner.northbound_ready?(%{
               northbound_enabled: true,
               endpoint: "https://armis.example",
               custom_fields: ["availability"],
               credentials: %Ash.NotLoaded{field: :credentials, type: :calculation}
             })

    assert :ok =
             ArmisNorthboundRunner.northbound_ready?(%{
               northbound_enabled: true,
               endpoint: "https://armis.example",
               custom_fields: ["availability"],
               credentials: %{secret_key: "secret"}
             })
  end

  describe "composite_export/1" do
    defp composite_settings(overrides) do
      %{
        settings: %{
          "composite" =>
            Map.merge(
              %{
                "check_slug" => "pci-isolation",
                "value_form" => "verdict",
                "custom_field" => "sr_pci_isolation"
              },
              overrides
            )
        }
      }
    end

    test "is nil when nothing is configured" do
      assert ArmisNorthboundRunner.composite_export(%{settings: %{}}) == nil
      assert ArmisNorthboundRunner.composite_export(%{}) == nil
      assert ArmisNorthboundRunner.composite_export(%{settings: nil}) == nil
    end

    test "reads the selection from settings" do
      assert %{
               check_slug: "pci-isolation",
               value_form: :verdict,
               custom_field: "sr_pci_isolation"
             } = ArmisNorthboundRunner.composite_export(composite_settings(%{}))
    end

    test "reads the status value form" do
      assert %{value_form: :status} =
               ArmisNorthboundRunner.composite_export(
                 composite_settings(%{"value_form" => "status"})
               )
    end

    test "is nil when any of the three values is missing or blank" do
      # All three are needed to send anything at all, so a half-configured
      # export must read as "not configured" rather than partially applying.
      for blank <- ["", "   "] do
        for key <- ["check_slug", "value_form", "custom_field"] do
          source = composite_settings(%{key => blank})

          assert ArmisNorthboundRunner.composite_export(source) == nil,
                 "expected nil when #{key} is #{inspect(blank)}"
        end
      end

      assert ArmisNorthboundRunner.composite_export(%{
               settings: %{"composite" => %{"check_slug" => "pci-isolation"}}
             }) == nil
    end

    test "is nil for an unknown value form rather than guessing" do
      assert ArmisNorthboundRunner.composite_export(
               composite_settings(%{"value_form" => "whatever"})
             ) == nil
    end

    test "trims surrounding whitespace" do
      assert %{check_slug: "pci-isolation", custom_field: "sr_pci_isolation"} =
               ArmisNorthboundRunner.composite_export(
                 composite_settings(%{
                   "check_slug" => "  pci-isolation  ",
                   "custom_field" => " sr_pci_isolation ",
                   "value_form" => " verdict "
                 })
               )
    end

    test "is nil when the composite setting is not a map" do
      assert ArmisNorthboundRunner.composite_export(%{settings: %{"composite" => "verdict"}}) ==
               nil
    end
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

  test "build_bulk_payload writes inverted availability to the configured custom field" do
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
             %{"id" => "armis-1", "customProperties" => %{"availability" => "false"}},
             %{"id" => "armis-2", "customProperties" => %{"availability" => "true"}}
           ]
  end

  test "build_bulk_payload uses the same inversion for compliance and isolation fields" do
    payload =
      ArmisNorthboundRunner.build_bulk_payload("OT_Isolation_Compliant", [
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
             %{"id" => "armis-1", "customProperties" => %{"OT_Isolation_Compliant" => "false"}},
             %{"id" => "armis-2", "customProperties" => %{"OT_Isolation_Compliant" => "true"}}
           ]
  end

  test "build_bulk_payload uses legacy upsert shape for numeric Armis IDs" do
    payload =
      ArmisNorthboundRunner.build_bulk_payload("availability", [
        %{
          armis_device_id: "101",
          is_available: true,
          device_ids: ["dev-a"],
          sync_service_ids: ["source-1"],
          metadata: %{}
        },
        %{
          armis_device_id: 202,
          is_available: false,
          device_ids: ["dev-b"],
          sync_service_ids: ["source-1"],
          metadata: %{}
        }
      ])

    assert payload == [
             %{"upsert" => %{"deviceId" => 101, "key" => "availability", "value" => "false"}},
             %{"upsert" => %{"deviceId" => 202, "key" => "availability", "value" => "true"}}
           ]
  end

  test "execute_batches skips token fetch when there are no candidates" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{"api_key" => "key-1", "api_secret" => "secret-1"}
    }

    token_fetcher = fn _source ->
      flunk("empty candidate runs should not fetch an Armis token")
    end

    assert {:ok, result} =
             ArmisNorthboundRunner.execute_batches(source, [], token_fetcher: token_fetcher)

    assert result.device_count == 0
    assert result.updated_count == 0
    assert result.error_count == 0
    assert result.batch_count == 0
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

  test "agent availability candidate query casts metadata bind as text" do
    query =
      ArmisNorthboundRunner.candidates_query(%{
        id: "source-1",
        northbound_availability_source_agent_id: "agent-1"
      })

    {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, ServiceRadar.Repo, query)

    assert sql =~ "'availability_source_agent_id', $1::text"
  end

  test "execute_batches authenticates with the raw token, batches requests, and aggregates counts" do
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
      },
      %{
        armis_device_id: "armis-4",
        is_available: true,
        device_ids: ["d4"],
        sync_service_ids: ["source-1"],
        metadata: %{}
      },
      %{
        armis_device_id: "armis-5",
        is_available: true,
        device_ids: ["d5"],
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

    assert result.device_count == 5
    assert result.updated_count == 5
    assert result.skipped_count == 0
    assert result.error_count == 0
    assert result.batch_count == 3

    assert_received {:token_source, ^source}
    assert_received {:request, "/api/v1/devices/custom-properties/_bulk/", :post, headers1, body1}

    assert_received {:request, "/api/v1/devices/custom-properties/_bulk/", :post, _headers2,
                     body2}

    assert_received {:request, "/api/v1/devices/custom-properties/_bulk/", :post, _headers3,
                     body3}

    # Armis requires the raw access token; a "Bearer " prefix triggers a 401
    # "Invalid access token." (see authorization_header/1).
    assert headers1["Authorization"] == "token-abc"
    assert headers1["Content-Type"] == "application/json"
    assert headers1["Accept"] == "application/json"
    assert length(body1) == 2
    assert length(body2) == 2
    assert length(body3) == 1
  end

  test "execute_batches preserves tokens that already include an auth scheme" do
    parent = self()

    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{"api_secret" => "secret"}
    }

    token_fetcher = fn _source -> {:ok, "Bearer token-abc"} end

    request = fn _path, _method, headers, _body, _opts ->
      send(parent, {:headers, headers})
      {:ok, %{status: 200, body: %{"success" => true}}}
    end

    assert {:ok, _result} =
             ArmisNorthboundRunner.execute_batches(
               source,
               [%{armis_device_id: "1", is_available: true}],
               token_fetcher: token_fetcher,
               request: request
             )

    assert_received {:headers, %{"Authorization" => "Bearer token-abc"}}
  end

  # Regression guard: Armis rejects "Authorization: Bearer <token>" with
  # 401 "Invalid access token.". A JWT-shaped token (no whitespace) must be sent
  # raw. This protects against the 8e8b00b93 regression that re-added a Bearer
  # prefix and broke the example-namespace northbound sync (v1.2.78–v1.2.83).
  test "execute_batches sends the raw access token without a Bearer prefix" do
    parent = self()

    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{"api_secret" => "secret"}
    }

    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhcm1pcyJ9.s1gn4tur3"
    token_fetcher = fn _source -> {:ok, jwt} end

    request = fn _path, _method, headers, _body, _opts ->
      send(parent, {:headers, headers})
      {:ok, %{status: 200, body: %{"success" => true}}}
    end

    assert {:ok, _result} =
             ArmisNorthboundRunner.execute_batches(
               source,
               [%{armis_device_id: "1", is_available: true}],
               token_fetcher: token_fetcher,
               request: request
             )

    assert_received {:headers, %{"Authorization" => auth}}
    assert auth == jwt
    refute String.starts_with?(auth, "Bearer ")
  end

  test "execute_batches refreshes the access token once and retries a batch on a 401" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{"api_secret" => "secret"}
    }

    counter = :counters.new(1, [])

    token_fetcher = fn _source ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      {:ok, "token-#{n}"}
    end

    # The first (expired) token is rejected; the refreshed token is accepted.
    request = fn _path, _method, headers, _body, _opts ->
      case headers["Authorization"] do
        "token-0" -> {:ok, %{status: 401, body: %{"message" => "Invalid access token."}}}
        "token-1" -> {:ok, %{status: 200, body: %{"success" => true}}}
      end
    end

    assert {:ok, result} =
             ArmisNorthboundRunner.execute_batches(
               source,
               [%{armis_device_id: "1", is_available: true}],
               token_fetcher: token_fetcher,
               request: request
             )

    assert result.updated_count == 1
    assert result.error_count == 0
    # Initial fetch + one refresh.
    assert :counters.get(counter, 1) == 2
  end

  test "execute_batches fails after one retry when the 401 persists" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{"api_secret" => "secret"}
    }

    counter = :counters.new(1, [])

    token_fetcher = fn _source ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      {:ok, "token-#{n}"}
    end

    request = fn _path, _method, _headers, _body, _opts ->
      {:ok, %{status: 401, body: %{"message" => "Invalid access token."}}}
    end

    assert {:error, result} =
             ArmisNorthboundRunner.execute_batches(
               source,
               [%{armis_device_id: "1", is_available: true}],
               token_fetcher: token_fetcher,
               request: request
             )

    assert result.updated_count == 0
    assert result.error_count == 1
    assert [%{reason: {:unexpected_status, 401, _body}}] = result.errors
    # Bounded: initial fetch + exactly one refresh, no infinite retry loop.
    assert :counters.get(counter, 1) == 2
  end

  test "execute_batches fails before token request when secret key is unavailable" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{"api_key" => "key-only"}
    }

    candidates = [
      %{
        armis_device_id: "armis-1",
        is_available: true,
        device_ids: ["d1"],
        sync_service_ids: ["source-1"],
        metadata: %{}
      }
    ]

    assert {:error, result} = ArmisNorthboundRunner.execute_batches(source, candidates)
    assert result.errors == [%{reason: :missing_secret_key}]
  end

  test "execute_batches posts inverted sample availability data to a fake Armis bulk endpoint" do
    {:ok, endpoint, stop_server} = start_fake_armis_bulk_server(self())
    on_exit(stop_server)

    source = %{
      id: "source-faker-contract",
      northbound_enabled: true,
      endpoint: endpoint,
      custom_fields: ["OT_Isolation_Compliant"],
      settings: %{"batch_size" => 2},
      credentials: %{"api_key" => "fake-secret"}
    }

    candidates = [
      %{
        armis_device_id: "101",
        is_available: true,
        device_ids: ["sr-device-available"],
        sync_service_ids: ["source-faker-contract"],
        metadata: %{}
      },
      %{
        armis_device_id: "202",
        is_available: false,
        device_ids: ["sr-device-unavailable"],
        sync_service_ids: ["source-faker-contract"],
        metadata: %{}
      }
    ]

    assert {:ok, result} =
             ArmisNorthboundRunner.execute_batches(source, candidates,
               token_fetcher: fn _source -> {:ok, "fake-token-test"} end
             )

    assert result.device_count == 2
    assert result.updated_count == 2
    assert result.error_count == 0
    assert result.batch_count == 1

    assert_receive {:fake_armis_bulk_request, request}, 1_000
    assert request.path == "/api/v1/devices/custom-properties/_bulk/"
    assert request.headers["authorization"] == "fake-token-test"
    assert request.headers["content-type"] =~ "application/json"

    assert request.body == [
             %{
               "upsert" => %{
                 "deviceId" => 101,
                 "key" => "OT_Isolation_Compliant",
                 "value" => "false"
               }
             },
             %{
               "upsert" => %{
                 "deviceId" => 202,
                 "key" => "OT_Isolation_Compliant",
                 "value" => "true"
               }
             }
           ]
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
      },
      %{
        armis_device_id: "armis-4",
        is_available: true,
        device_ids: ["d4"],
        sync_service_ids: ["source-1"],
        metadata: %{}
      },
      %{
        armis_device_id: "armis-5",
        is_available: true,
        device_ids: ["d5"],
        sync_service_ids: ["source-1"],
        metadata: %{}
      }
    ]

    token_fetcher = fn _source -> {:ok, "token-abc"} end

    request = fn _path, _method, _headers, _body, _opts ->
      request_number = Process.get(:stopped_batch_request_number, 0) + 1
      Process.put(:stopped_batch_request_number, request_number)

      case request_number do
        1 -> {:ok, %{status: 200, body: %{"success" => true}}}
        2 -> {:error, :upstream_timeout}
      end
    end

    assert {:error, result} =
             ArmisNorthboundRunner.execute_batches(source, candidates,
               token_fetcher: token_fetcher,
               request: request
             )

    assert result.device_count == 5
    assert result.updated_count == 2
    assert result.skipped_count == 0
    assert result.error_count == 2
    assert result.batch_count == 3
    assert result.accepted_ids == ["armis-1", "armis-2"]
    assert result.failed_ids == ["armis-3", "armis-4"]
    assert result.unattempted_ids == ["armis-5"]
    assert result.errors == [%{batch_size: 2, reason: :upstream_timeout}]
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

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, %{id: "event-1", attrs: attrs}}
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
               record_event: record_event,
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

    assert_received {:record_event,
                     %{
                       status_code: "armis_northbound_bulk_update_succeeded",
                       status_detail: "All Armis northbound bulk updates succeeded",
                       message: message,
                       log_name: "integrations.armis.northbound",
                       raw_data: raw_data
                     }}

    assert message =~ "finished with success"
    assert message =~ "2/2 source IDs accepted by Armis"
    assert raw_data =~ ~s("integration_type":"armis")
    assert raw_data =~ "\"updated_count\":2"
  end

  test "run_for_source exposes identity conflict skips in run metadata and event data" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{api_key: "key", api_secret: "secret"}
    }

    actor = %{role: :system}
    parent = self()

    start_run = fn _source, _actor, _opts -> {:ok, %{id: "run-conflicts"}} end

    update_source = fn _src, action, attrs, _actor ->
      send(parent, {:update_source, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    finish_run = fn _run, action, attrs, _actor, _opts ->
      send(parent, {:finish_run, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, %{id: "event-conflicts", attrs: attrs}}
    end

    load_candidates = fn _src, _opts ->
      {:ok,
       [
         %{
           armis_device_id: "armis-ok",
           is_available: true,
           device_id: "d-ok",
           sync_service_id: "source-1",
           metadata: %{}
         }
       ]}
    end

    load_identity_conflicts = fn _src, _opts ->
      %{
        "total_count" => 2,
        "categories" => %{"metadata_identifier_disagreement" => 2},
        "examples" => [
          %{
            "category" => "metadata_identifier_disagreement",
            "device_uid" => "sr:bad-1",
            "source_identifier_value" => "armis-stale"
          }
        ]
      }
    end

    execute_batches = fn _src, _collapsed, _opts ->
      {:ok,
       %{
         device_count: 1,
         updated_count: 1,
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
               record_event: record_event,
               load_candidates: load_candidates,
               load_identity_conflicts: load_identity_conflicts,
               execute_batches: execute_batches
             )

    assert result.device_count == 3
    assert result.updated_count == 1
    assert result.skipped_count == 2

    assert_received {:update_source, :northbound_start, %{device_count: 3}}

    assert_received {:finish_run, :finish_success,
                     %{
                       device_count: 3,
                       updated_count: 1,
                       skipped_count: 2,
                       metadata: %{
                         "identity_conflicts" => %{
                           "total_count" => 2,
                           "categories" => %{"metadata_identifier_disagreement" => 2}
                         }
                       }
                     }}

    assert_received {:record_event, %{raw_data: raw_data}}

    assert raw_data =~ ~s("identity_conflicts")
    assert raw_data =~ ~s("metadata_identifier_disagreement")
  end

  test "run_for_source folds only withholding conflicts into counts but surfaces the full report" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{api_key: "key", api_secret: "secret"}
    }

    actor = %{role: :system}
    parent = self()

    start_run = fn _source, _actor, _opts -> {:ok, %{id: "run-disjoint"}} end

    update_source = fn _src, action, attrs, _actor ->
      send(parent, {:update_source, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    finish_run = fn _run, action, attrs, _actor, _opts ->
      send(parent, {:finish_run, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    record_event = fn attrs, _actor -> {:ok, %{id: "event-disjoint", attrs: attrs}} end

    load_candidates = fn _src, _opts ->
      {:ok,
       [
         %{
           armis_device_id: "armis-ok",
           is_available: true,
           device_id: "d-ok",
           sync_service_id: "source-1",
           metadata: %{}
         }
       ]}
    end

    # 5 open conflicts, but only 2 are withholding categories; the other 3
    # (typed_id_on_multiple_devices) can still be sent and must not be counted
    # as skipped.
    load_identity_conflicts = fn _src, _opts ->
      %{
        "total_count" => 5,
        "skipped_count" => 2,
        "categories" => %{
          "metadata_identifier_disagreement" => 2,
          "typed_id_on_multiple_devices" => 3
        },
        "examples" => []
      }
    end

    execute_batches = fn _src, _collapsed, _opts ->
      {:ok,
       %{
         device_count: 1,
         updated_count: 1,
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
               record_event: record_event,
               load_candidates: load_candidates,
               load_identity_conflicts: load_identity_conflicts,
               execute_batches: execute_batches
             )

    # 1 sent + 2 withholding, NOT 1 + 5.
    assert result.device_count == 3
    assert result.skipped_count == 2

    assert_received {:update_source, :northbound_start, %{device_count: 3}}

    # The full report (total_count 5) is still surfaced for operator visibility.
    assert_received {:finish_run, :finish_success,
                     %{
                       device_count: 3,
                       skipped_count: 2,
                       metadata: %{"identity_conflicts" => %{"total_count" => 5}}
                     }}
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

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, %{id: "event-2", attrs: attrs}}
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
               record_event: record_event,
               load_candidates: load_candidates,
               execute_batches: execute_batches
             )

    assert result.error_message =~ ":upstream_timeout"

    assert_received {:finish_run, :finish_partial,
                     %{error_count: 1, error_message: error_message}}

    assert error_message =~ ":upstream_timeout"

    assert_received {:update_source, :northbound_success,
                     %{result: :partial, device_count: 1, updated_count: 1, skipped_count: 1}}

    assert_received {:record_event,
                     %{
                       status_code: "armis_northbound_bulk_update_partial",
                       status_detail: "Some Armis northbound bulk updates failed",
                       message: message,
                       raw_data: raw_data
                     }}

    assert message =~ "finished with partial"
    assert message =~ ":upstream_timeout"
    assert raw_data =~ "\"error_count\":1"
    assert raw_data =~ ~s("error_message":":upstream_timeout")
  end

  test "run_for_source serializes tuple-valued errors before finish_failed" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{api_key: "key", api_secret: "secret"}
    }

    actor = %{role: :system}
    parent = self()

    start_run = fn _source, _actor, _opts -> {:ok, %{id: "run-3"}} end

    update_source = fn _src, action, attrs, _actor ->
      send(parent, {:update_source, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    finish_run = fn _run, action, attrs, _actor, _opts ->
      send(parent, {:finish_run, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, %{id: "event-3", attrs: attrs}}
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
         updated_count: 0,
         skipped_count: 0,
         error_count: 1,
         batch_count: 1,
         errors: [%{batch_size: 1, reason: {:unexpected_status, 404, "404 page not found\n"}}]
       }}
    end

    assert {:error, %{result: result}} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               start_run: start_run,
               update_source: update_source,
               finish_run: finish_run,
               record_event: record_event,
               load_candidates: load_candidates,
               execute_batches: execute_batches
             )

    assert result.error_message =~ ":unexpected_status"
    assert result.error_message =~ "404"

    assert_received {:finish_run, :finish_failed,
                     %{
                       error_count: 1,
                       error_message: error_message,
                       metadata: %{
                         batch_count: 1,
                         errors: [%{batch_size: 1, reason: serialized_reason}]
                       }
                     }}

    assert error_message =~ ":unexpected_status"
    assert serialized_reason =~ ":unexpected_status"
    assert serialized_reason =~ "404 page not found"

    assert_received {:update_source, :northbound_failed,
                     %{
                       result: :failed,
                       device_count: 1,
                       updated_count: 0,
                       skipped_count: 1,
                       error_message: source_error
                     }}

    assert source_error =~ ":unexpected_status"

    assert_received {:record_event,
                     %{
                       status_code: "armis_northbound_bulk_update_failed",
                       status_detail: "Armis northbound bulk update run failed",
                       message: message,
                       raw_data: raw_data
                     }}

    assert message =~ "finished with failed"
    assert message =~ "404"
    assert raw_data =~ "\"error_count\":1"
    assert raw_data =~ ~s("integration_type":"armis")
  end

  test "run_for_source finalizes started run when candidate loading fails" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{api_key: "key", api_secret: "secret"}
    }

    actor = %{role: :system}
    parent = self()

    start_run = fn _source, _actor, _opts -> {:ok, %{id: "run-load-failed"}} end

    update_source = fn _src, action, attrs, _actor ->
      send(parent, {:update_source, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    finish_run = fn _run, action, attrs, _actor, opts ->
      send(parent, {:finish_run, action, attrs, opts})
      {:ok, %{action: action, attrs: attrs}}
    end

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, %{id: "event-load-failed", attrs: attrs}}
    end

    load_candidates = fn _src, _opts -> {:error, :missing_credentials} end

    assert {:error, %{result: result}} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               start_run: start_run,
               update_source: update_source,
               finish_run: finish_run,
               record_event: record_event,
               load_candidates: load_candidates
             )

    assert result.error_message =~ ":missing_credentials"

    assert_received {:finish_run, :finish_failed,
                     %{
                       device_count: 0,
                       updated_count: 0,
                       skipped_count: 0,
                       error_count: 0,
                       error_message: error_message,
                       metadata: %{batch_count: 0, errors: [%{reason: serialized_reason}]}
                     }, %{status: :failed}}

    assert error_message =~ ":missing_credentials"
    assert serialized_reason =~ ":missing_credentials"

    assert_received {:update_source, :northbound_failed,
                     %{
                       result: :failed,
                       device_count: 0,
                       updated_count: 0,
                       skipped_count: 0,
                       error_message: source_error
                     }}

    assert source_error =~ ":missing_credentials"

    assert_received {:record_event,
                     %{
                       status_code: "armis_northbound_bulk_update_failed",
                       raw_data: raw_data
                     }}

    assert raw_data =~ "\"error_count\":0"
  end

  test "run_for_source finalizes started run when bulk execution raises" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{api_key: "key", api_secret: "secret"}
    }

    actor = %{role: :system}
    parent = self()

    start_run = fn _source, _actor, _opts -> {:ok, %{id: "run-execute-crashed"}} end

    update_source = fn _src, action, attrs, _actor ->
      send(parent, {:update_source, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    finish_run = fn _run, action, attrs, _actor, opts ->
      send(parent, {:finish_run, action, attrs, opts})
      {:ok, %{action: action, attrs: attrs}}
    end

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, %{id: "event-execute-crashed", attrs: attrs}}
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
      raise RuntimeError, "bulk API client crashed"
    end

    assert {:error, %{result: result}} =
             ArmisNorthboundRunner.run_for_source(source,
               actor: actor,
               start_run: start_run,
               update_source: update_source,
               finish_run: finish_run,
               record_event: record_event,
               load_candidates: load_candidates,
               execute_batches: execute_batches
             )

    assert result.error_message =~ "bulk API client crashed"

    assert_received {:update_source, :northbound_start, %{device_count: 1}}
    assert_received {:finish_run, :finish_failed, %{device_count: 1, error_count: 1}, _opts}
    assert_received {:update_source, :northbound_failed, %{device_count: 1, skipped_count: 1}}
  end

  test "reconcile_stale_runs marks only orphaned stale running rows as timeout" do
    parent = self()
    actor = %{role: :system}
    now = ~U[2026-04-14 03:30:00Z]
    source = %{id: "source-1"}

    stale_orphan = %{
      id: "run-stale-orphan",
      status: :running,
      started_at: ~U[2026-04-14 03:20:00Z],
      oban_job_id: 101,
      device_count: 0,
      updated_count: 0,
      skipped_count: 0,
      error_count: 0,
      metadata: %{}
    }

    fresh_orphan =
      %{stale_orphan | id: "run-fresh", started_at: ~U[2026-04-14 03:29:30Z], oban_job_id: 102}

    stale_active = %{stale_orphan | id: "run-active", oban_job_id: 103}
    already_success = %{stale_orphan | id: "run-success", status: :success, oban_job_id: 104}
    stale_abandoned = %{stale_orphan | id: "run-abandoned", oban_job_id: 105}

    list_runs = fn _src, _actor ->
      [stale_orphan, fresh_orphan, stale_active, already_success, stale_abandoned]
    end

    finish_run = fn run, action, attrs, _actor, opts ->
      send(parent, {:finish_run, run.id, action, attrs, opts})
      {:ok, %{id: run.id, action: action, attrs: attrs}}
    end

    update_source = fn _source, action, attrs, _actor ->
      send(parent, {:update_source, action, attrs})
      {:ok, %{action: action, attrs: attrs}}
    end

    oban_state = fn
      101 -> nil
      102 -> nil
      103 -> "executing"
      104 -> "completed"
      105 -> %{state: "executing", attempted_at: ~N[2026-04-14 03:20:00]}
    end

    assert :ok =
             ArmisNorthboundRunner.reconcile_stale_runs(source, actor,
               list_runs: list_runs,
               finish_run: finish_run,
               update_source: update_source,
               oban_state: oban_state,
               now: now,
               stale_run_cutoff_seconds: 120
             )

    assert_received {:finish_run, "run-stale-orphan", :finish_timeout, attrs, %{status: :timeout}}
    assert attrs.error_message == "Marked timed out after orphaned Oban job"
    assert attrs.metadata["reconciled"] == false
    assert attrs.metadata["reason"] == "orphaned_oban_job"

    assert_received {:finish_run, "run-abandoned", :finish_timeout, _attrs, %{status: :timeout}}

    assert_received {:update_source, :northbound_failed,
                     %{
                       result: :timeout,
                       device_count: 0,
                       updated_count: 0,
                       skipped_count: 0,
                       error_message: "Marked timed out after orphaned Oban job"
                     }}

    refute_received {:finish_run, "run-fresh", _, _, _}
    refute_received {:finish_run, "run-active", _, _, _}
    refute_received {:finish_run, "run-success", _, _, _}
  end

  defp start_fake_armis_bulk_server(parent) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)
    pid = spawn(fn -> accept_fake_armis_requests(listen_socket, parent) end)

    stop = fn ->
      :gen_tcp.close(listen_socket)

      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end

    {:ok, "http://127.0.0.1:#{port}", stop}
  end

  defp accept_fake_armis_requests(listen_socket, parent) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        handle_fake_armis_socket(socket, parent)
        accept_fake_armis_requests(listen_socket, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp handle_fake_armis_socket(socket, parent) do
    with {:ok, header_bytes} <- recv_until(socket, "\r\n\r\n"),
         {header_part, initial_body} <- split_http_header_and_body(header_bytes),
         {headers, body_mode} <- parse_http_headers(header_part),
         {:ok, body_bytes} <- recv_http_body(socket, body_mode, initial_body),
         {:ok, body} <- Jason.decode(body_bytes) do
      path =
        header_part
        |> String.split("\r\n", parts: 2)
        |> hd()
        |> String.split(" ")
        |> Enum.at(1)

      send(parent, {:fake_armis_bulk_request, %{path: path, headers: headers, body: body}})
      send_json_response(socket, %{"success" => true, "data" => %{"updated" => length(body)}})
    else
      _ ->
        send_json_response(socket, %{"success" => false}, 400)
    end

    :gen_tcp.close(socket)
  end

  defp split_http_header_and_body(bytes) do
    [header_part, body] = String.split(bytes, "\r\n\r\n", parts: 2)
    {header_part, body}
  end

  defp recv_until(socket, marker, acc \\ "") do
    if String.contains?(acc, marker) do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, bytes} -> recv_until(socket, marker, acc <> bytes)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp recv_exact_body(_socket, 0, _initial_body), do: {:ok, ""}

  defp recv_exact_body(socket, length, initial_body) do
    existing = byte_size(initial_body)

    cond do
      existing == length ->
        {:ok, initial_body}

      existing > length ->
        {:ok, binary_part(initial_body, 0, length)}

      true ->
        case :gen_tcp.recv(socket, length - existing, 5_000) do
          {:ok, bytes} -> {:ok, initial_body <> bytes}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp recv_http_body(socket, {:content_length, content_length}, initial_body),
    do: recv_exact_body(socket, content_length, initial_body)

  defp recv_http_body(socket, :chunked, initial_body), do: recv_chunked_body(socket, initial_body)

  defp recv_chunked_body(socket, bytes) do
    case decode_chunked_body(bytes) do
      {:ok, body} ->
        {:ok, body}

      :more ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, more} -> recv_chunked_body(socket, bytes <> more)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_chunked_body(bytes, decoded \\ "") do
    case :binary.match(bytes, "\r\n") do
      :nomatch ->
        :more

      {header_size, 2} ->
        header = binary_part(bytes, 0, header_size)
        rest = binary_part(bytes, header_size + 2, byte_size(bytes) - header_size - 2)

        case Integer.parse(header, 16) do
          {chunk_size, ""} ->
            cond do
              chunk_size == 0 ->
                {:ok, decoded}

              byte_size(rest) < chunk_size + 2 ->
                :more

              binary_part(rest, chunk_size, 2) != "\r\n" ->
                {:error, :invalid_chunk_terminator}

              true ->
                chunk = binary_part(rest, 0, chunk_size)
                remaining_size = byte_size(rest) - chunk_size - 2
                remaining = binary_part(rest, chunk_size + 2, remaining_size)
                decode_chunked_body(remaining, decoded <> chunk)
            end

          _ ->
            {:error, :invalid_chunk_size}
        end
    end
  end

  defp parse_http_headers(header_bytes) do
    [_request_line | header_lines] = String.split(header_bytes, "\r\n")

    headers =
      Map.new(header_lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.downcase(key), String.trim(value)}
      end)

    body_mode =
      case Map.fetch(headers, "content-length") do
        {:ok, content_length} ->
          {:content_length, String.to_integer(content_length)}

        :error ->
          if headers
             |> Map.get("transfer-encoding", "")
             |> String.downcase()
             |> String.contains?("chunked") do
            :chunked
          else
            {:content_length, 0}
          end
      end

    {headers, body_mode}
  end

  defp send_json_response(socket, body, status \\ 200) do
    encoded = Jason.encode!(body)
    reason = if status in 200..299, do: "OK", else: "Bad Request"

    response = [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: #{byte_size(encoded)}\r\n",
      "Connection: close\r\n",
      "\r\n",
      encoded
    ]

    :gen_tcp.send(socket, response)
  end

  describe "build_bulk_payload/3 with a composite export" do
    defp candidate(armis_device_id, device_ids, is_available \\ true) do
      %{
        armis_device_id: armis_device_id,
        is_available: is_available,
        device_ids: device_ids,
        sync_service_ids: ["source-1"],
        metadata: %{}
      }
    end

    test "appends a composite entry for a device that has a value" do
      payload =
        ArmisNorthboundRunner.build_bulk_payload(
          "availability",
          [candidate("1", ["dev-a"])],
          composite: %{custom_field: "sr_isolation", values: %{"dev-a" => "isolated_verified"}}
        )

      # One key per entry in the upsert shape, so a second field is a second
      # entry rather than a second key on the same one.
      assert payload == [
               %{"upsert" => %{"deviceId" => 1, "key" => "availability", "value" => "false"}},
               %{
                 "upsert" => %{
                   "deviceId" => 1,
                   "key" => "sr_isolation",
                   "value" => "isolated_verified"
                 }
               }
             ]
    end

    test "a device with no composite value gets no composite entry" do
      payload =
        ArmisNorthboundRunner.build_bulk_payload(
          "availability",
          [candidate("1", ["dev-a"])],
          composite: %{custom_field: "sr_isolation", values: %{}}
        )

      # Not a placeholder, not an empty string — nothing at all.
      assert payload == [
               %{"upsert" => %{"deviceId" => 1, "key" => "availability", "value" => "false"}}
             ]
    end

    test "only the devices that have values gain an entry" do
      payload =
        ArmisNorthboundRunner.build_bulk_payload(
          "availability",
          [candidate("1", ["dev-a"]), candidate("2", ["dev-b"])],
          composite: %{custom_field: "sr_isolation", values: %{"dev-b" => "not_isolated"}}
        )

      assert [
               %{"upsert" => %{"deviceId" => 1, "key" => "availability"}},
               %{"upsert" => %{"deviceId" => 2, "key" => "availability"}},
               %{
                 "upsert" => %{
                   "deviceId" => 2,
                   "key" => "sr_isolation",
                   "value" => "not_isolated"
                 }
               }
             ] = payload
    end

    test "a candidate collapsed from several device ids picks the first uid with a value" do
      # `collapse_candidates/1` merges rows by armis_device_id, so one Armis
      # device can carry several ServiceRadar uids. Two entries for one Armis
      # device would be a last-writer-wins race inside a single batch, so the
      # choice is made here and pinned rather than left to iteration order.
      payload =
        ArmisNorthboundRunner.build_bulk_payload(
          "availability",
          [candidate("1", ["dev-a", "dev-b"])],
          composite: %{
            custom_field: "sr_isolation",
            values: %{"dev-a" => "isolated_verified", "dev-b" => "not_isolated"}
          }
        )

      assert [
               _availability,
               %{"upsert" => %{"key" => "sr_isolation", "value" => "isolated_verified"}}
             ] = payload
    end

    test "a collapsed candidate falls through to a later uid when the first has no value" do
      payload =
        ArmisNorthboundRunner.build_bulk_payload(
          "availability",
          [candidate("1", ["dev-a", "dev-b"])],
          composite: %{custom_field: "sr_isolation", values: %{"dev-b" => "not_isolated"}}
        )

      assert [_availability, %{"upsert" => %{"value" => "not_isolated"}}] = payload
    end

    test "the customProperties fallback carries both keys on one entry" do
      payload =
        ArmisNorthboundRunner.build_bulk_payload(
          "availability",
          [candidate("armis-1", ["dev-a"], false)],
          composite: %{custom_field: "sr_isolation", values: %{"dev-a" => "healthy"}}
        )

      # That shape can hold several keys, so it stays one entry per device.
      assert payload == [
               %{
                 "id" => "armis-1",
                 "customProperties" => %{"availability" => "true", "sr_isolation" => "healthy"}
               }
             ]
    end

    test "the customProperties fallback omits the key entirely when there is no value" do
      payload =
        ArmisNorthboundRunner.build_bulk_payload(
          "availability",
          [candidate("armis-1", ["dev-a"], false)],
          composite: %{custom_field: "sr_isolation", values: %{}}
        )

      assert payload == [%{"id" => "armis-1", "customProperties" => %{"availability" => "true"}}]
    end

    test "no composite option leaves the payload exactly as before" do
      # The existing export must be untouched when nothing is configured.
      without =
        ArmisNorthboundRunner.build_bulk_payload("availability", [candidate("1", ["dev-a"])])

      with_empty =
        ArmisNorthboundRunner.build_bulk_payload("availability", [candidate("1", ["dev-a"])],
          composite: nil
        )

      assert without == with_empty

      assert without == [
               %{"upsert" => %{"deviceId" => 1, "key" => "availability", "value" => "false"}}
             ]
    end

    test "a candidate with no device ids gets no composite entry" do
      payload =
        ArmisNorthboundRunner.build_bulk_payload(
          "availability",
          [candidate("1", [])],
          composite: %{custom_field: "sr_isolation", values: %{"dev-a" => "isolated_verified"}}
        )

      assert length(payload) == 1
    end
  end

  test "run_for_source records the composite selection in run metadata" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{api_key: "key", api_secret: "secret"},
      settings: %{
        "composite" => %{
          "check_slug" => "pci-isolation",
          "value_form" => "status",
          "custom_field" => "sr_isolation"
        }
      }
    }

    parent = self()

    stubs = [
      actor: %{role: :system},
      start_run: fn _src, _actor, _opts -> {:ok, %{id: "run-1"}} end,
      update_source: fn _src, action, attrs, _actor -> {:ok, %{action: action, attrs: attrs}} end,
      finish_run: fn _run, action, attrs, _actor, _opts ->
        send(parent, {:finish_run, action, attrs})
        {:ok, %{action: action, attrs: attrs}}
      end,
      record_event: fn attrs, _actor -> {:ok, %{id: "event-1", attrs: attrs}} end,
      load_candidates: fn _src, _opts -> {:ok, []} end,
      execute_batches: fn _src, _collapsed, _opts ->
        {:ok,
         %{
           device_count: 0,
           updated_count: 0,
           skipped_count: 0,
           error_count: 0,
           batch_count: 0,
           errors: []
         }}
      end
    ]

    assert {:ok, _} = ArmisNorthboundRunner.run_for_source(source, stubs)

    # Recorded on the run rather than read back from the source at display
    # time: run status has to describe *that* run, and the selection can change
    # afterwards.
    assert_received {:finish_run, :finish_success,
                     %{
                       metadata: %{
                         composite_check_slug: "pci-isolation",
                         composite_value_form: "status",
                         composite_custom_field: "sr_isolation"
                       }
                     }}
  end

  test "run_for_source records no composite keys when nothing is configured" do
    source = %{
      id: "source-1",
      northbound_enabled: true,
      endpoint: "https://armis.example",
      custom_fields: ["availability"],
      credentials: %{api_key: "key", api_secret: "secret"}
    }

    parent = self()

    stubs = [
      actor: %{role: :system},
      start_run: fn _src, _actor, _opts -> {:ok, %{id: "run-1"}} end,
      update_source: fn _src, action, attrs, _actor -> {:ok, %{action: action, attrs: attrs}} end,
      finish_run: fn _run, action, attrs, _actor, _opts ->
        send(parent, {:finish_run, action, attrs})
        {:ok, %{action: action, attrs: attrs}}
      end,
      record_event: fn attrs, _actor -> {:ok, %{id: "event-1", attrs: attrs}} end,
      load_candidates: fn _src, _opts -> {:ok, []} end,
      execute_batches: fn _src, _collapsed, _opts ->
        {:ok,
         %{
           device_count: 0,
           updated_count: 0,
           skipped_count: 0,
           error_count: 0,
           batch_count: 0,
           errors: []
         }}
      end
    ]

    assert {:ok, _} = ArmisNorthboundRunner.run_for_source(source, stubs)

    assert_received {:finish_run, :finish_success, %{metadata: metadata}}

    # Omitted entirely rather than stored as nils, which would read like a
    # lookup that failed.
    refute Map.has_key?(metadata, :composite_check_slug)
    refute Map.has_key?(metadata, :composite_value_form)
  end
end
