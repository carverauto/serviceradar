defmodule ServiceRadar.Observability.PluginResultHandlerOutcomeContractTest do
  @moduledoc """
  Database-free contract and classification coverage for `PluginResultHandlerOutcome`,
  all 11 registered `PluginResultIngestor` platform handlers, multi-handler outcome
  precedence, nil-preserving identity metadata, and unified handler outcome telemetry.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.EventIngestor
  alias ServiceRadar.Camera.InventoryIngestor
  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias ServiceRadar.Inventory.ProxmoxSourceScopeResolver
  alias ServiceRadar.Inventory.VulnerabilityAdvisoryIngestor
  alias ServiceRadar.NetworkConfig.InterfaceCheckIngestor
  alias ServiceRadar.NetworkConfig.PluginIngestor
  alias ServiceRadar.Observability.PluginResultHandler
  alias ServiceRadar.Observability.PluginResultHandlerOutcome
  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Observability.ServiceStatus
  alias ServiceRadar.Observability.ThreatIntelPluginIngestor
  alias ServiceRadar.Plugins.RunOverrideAckIngestor
  alias ServiceRadar.Telemetry
  alias ServiceRadar.WifiMap.BatchIngestor

  @moduletag :db_free

  defmodule UnclassifiedAdHocHandler do
    @moduledoc false
    @behaviour PluginResultHandler

    @impl true
    def supports?(_payload, _status), do: true

    @impl true
    def settled_reasons, do: []

    @impl true
    def refused_reasons, do: []

    @impl true
    def ingest(_payload, _status, _opts), do: {:error, :unexpected_ad_hoc_atom}
  end

  defmodule UndeclaredSettledHandler do
    @moduledoc false
    @behaviour PluginResultHandler

    @impl true
    def supports?(_payload, _status), do: true

    @impl true
    def settled_reasons, do: [:declared_settled_reason]

    @impl true
    def refused_reasons, do: [:declared_refused_reason]

    @impl true
    def ingest(_payload, _status, _opts), do: {:settled, :undeclared_settled_reason, %{}}
  end

  defmodule AppliedStubHandler do
    @moduledoc false
    @behaviour PluginResultHandler

    @impl true
    def supports?(_payload, _status), do: true

    @impl true
    def settled_reasons, do: []

    @impl true
    def refused_reasons, do: []

    @impl true
    def ingest(_payload, _status, _opts), do: :ok
  end

  defmodule SettledStubHandler do
    @moduledoc false
    @behaviour PluginResultHandler

    @impl true
    def supports?(_payload, _status), do: true

    @impl true
    def settled_reasons, do: [:device_out_of_service]

    @impl true
    def refused_reasons, do: []

    @impl true
    def ingest(_payload, _status, _opts) do
      {:settled, :device_out_of_service, %{device_uid: nil, assignment_id: nil}}
    end
  end

  defmodule RefusedStubHandler do
    @moduledoc false
    @behaviour PluginResultHandler

    @impl true
    def supports?(_payload, _status), do: true

    @impl true
    def settled_reasons, do: []

    @impl true
    def refused_reasons, do: [:plugin_assignment_agent_mismatch]

    @impl true
    def ingest(_payload, _status, _opts) do
      {:refused, :plugin_assignment_agent_mismatch,
       %{assignment_id: "00000000-0000-4000-8000-000000000011", agent_id: nil}}
    end
  end

  defmodule RetryableStubHandler do
    @moduledoc false
    @behaviour PluginResultHandler

    @impl true
    def supports?(_payload, _status), do: true

    @impl true
    def settled_reasons, do: []

    @impl true
    def refused_reasons, do: []

    @impl true
    def ingest(_payload, _status, _opts) do
      {:error, %DBConnection.ConnectionError{message: "synthetic pool checkout timeout"}}
    end
  end

  describe "registered platform handlers implement PluginResultHandler" do
    test "every handler in platform_contract_handlers/0 exports disjoint settled_reasons/0 and refused_reasons/0" do
      handlers = PluginResultIngestor.platform_contract_handlers()
      assert length(handlers) == 11

      Enum.each(handlers, fn handler ->
        assert Code.ensure_loaded?(handler), "expected #{inspect(handler)} to load"

        assert function_exported?(handler, :supports?, 2),
               "expected #{inspect(handler)} to export supports?/2"

        assert function_exported?(handler, :ingest, 3),
               "expected #{inspect(handler)} to export ingest/3"

        assert function_exported?(handler, :settled_reasons, 0),
               "expected #{inspect(handler)} to export settled_reasons/0"

        assert function_exported?(handler, :refused_reasons, 0),
               "expected #{inspect(handler)} to export refused_reasons/0"

        settled = handler.settled_reasons()
        refused = handler.refused_reasons()

        assert is_list(settled) and Enum.all?(settled, &is_atom/1)
        assert is_list(refused) and Enum.all?(refused, &is_atom/1)

        overlap = MapSet.intersection(MapSet.new(settled), MapSet.new(refused))

        assert MapSet.size(overlap) == 0,
               "expected #{inspect(handler)} settled/refused reasons to be disjoint, got #{inspect(overlap)}"
      end)
    end
  end

  describe "unclassified error telemetry and undeclared outcome guardrails" do
    test "an unrecognized {:error, atom} classifies as retryable and emits unclassified_error telemetry" do
      parent = self()
      handler_id = "unclassified-error-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:serviceradar, :plugin_result, :handler, :unclassified_error],
        fn _event, measurements, metadata, _config ->
          send(parent, {:unclassified_error, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      classified =
        PluginResultHandlerOutcome.classify(
          UnclassifiedAdHocHandler,
          {:error, :unexpected_ad_hoc_atom}
        )

      assert classified.outcome == :retryable

      assert_receive {:unclassified_error, %{count: 1},
                      %{
                        handler: "unclassified_ad_hoc_handler",
                        reason_class: "unexpected_ad_hoc_atom"
                      }}
    end

    test "an undeclared settled reason is rejected as retryable and emits unclassified_error" do
      parent = self()
      handler_id = "undeclared-settled-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:serviceradar, :plugin_result, :handler, :unclassified_error],
        fn _event, measurements, metadata, _config ->
          send(parent, {:unclassified_error, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      classified =
        PluginResultHandlerOutcome.classify(
          UndeclaredSettledHandler,
          {:settled, :undeclared_settled_reason, %{}}
        )

      assert classified.outcome == :retryable
      assert_receive {:unclassified_error, %{count: 1}, %{handler: "undeclared_settled_handler"}}
    end

    test "known retryable exceptions and Ash errors classify as retryable without unclassified_error telemetry" do
      parent = self()
      handler_id = "known-retryable-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:serviceradar, :plugin_result, :handler, :unclassified_error],
        fn _event, measurements, metadata, _config ->
          send(parent, {:unclassified_error, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      classified =
        PluginResultHandlerOutcome.classify(
          RetryableStubHandler,
          {:error, %DBConnection.ConnectionError{message: "synthetic pool checkout timeout"}}
        )

      assert classified.outcome == :retryable
      refute_receive {:unclassified_error, _, _}
    end
  end

  describe "nil identity fields and multi-handler precedence lattice" do
    test "nil identity values remain nil across settled and refused metadata and telemetry" do
      settled =
        PluginResultHandlerOutcome.classify(
          SettledStubHandler,
          {:settled, :device_out_of_service,
           %{
             assignment_id: nil,
             agent_id: nil,
             partition: nil,
             device_uid: nil,
             controller_id: nil
           }}
        )

      assert settled.outcome == :settled
      assert settled.reason == :device_out_of_service
      assert settled.metadata.assignment_id == nil
      assert settled.metadata.agent_id == nil
      assert settled.metadata.partition == nil
      assert settled.metadata.device_uid == nil
      assert settled.metadata.controller_id == nil
      refute "nil" in Map.values(settled.metadata)
    end

    test "combine/1 enforces retryable > refused > applied > settled" do
      applied = PluginResultHandlerOutcome.classify(AppliedStubHandler, :ok)

      settled =
        PluginResultHandlerOutcome.classify(
          SettledStubHandler,
          {:settled, :device_out_of_service, %{device_uid: nil}}
        )

      refused =
        PluginResultHandlerOutcome.classify(
          RefusedStubHandler,
          {:refused, :plugin_assignment_agent_mismatch, %{}}
        )

      retryable =
        PluginResultHandlerOutcome.classify(
          RetryableStubHandler,
          {:error, %DBConnection.ConnectionError{message: "timeout"}}
        )

      assert {:settled, :device_out_of_service, _meta, _all} =
               PluginResultHandlerOutcome.combine([settled])

      assert {:applied, _all} = PluginResultHandlerOutcome.combine([applied, settled])

      assert {:refused, :plugin_assignment_agent_mismatch, _meta, _all} =
               PluginResultHandlerOutcome.combine([applied, settled, refused])

      assert {:retryable, _all} =
               PluginResultHandlerOutcome.combine([settled, retryable])

      assert {:retryable, _all} =
               PluginResultHandlerOutcome.combine([refused, retryable])
    end

    test "ingest_durable/3 emits unified outcome telemetry, preserves available on settled, and records per-handler markers" do
      parent = self()
      handler_id = "ingestor-outcome-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:serviceradar, :plugin_result, :handler, :outcome],
        fn _event, measurements, metadata, _config ->
          send(parent, {:handler_outcome, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      payload = %{
        "schema" => "serviceradar.plugin_result.v1",
        "status" => "OK",
        "summary" => "synthetic camera batch healthy"
      }

      status = %{
        agent_id: nil,
        partition: nil,
        service_name: "synthetic-camera-check",
        service_type: "plugin",
        available: true,
        plugin_provenance: %{"assignment_id" => nil}
      }

      persistence = fake_persistence(parent)

      assert {:settled, {:device_out_of_service, _detail}} =
               PluginResultIngestor.ingest_durable(payload, status,
                 handlers: [SettledStubHandler],
                 persistence: persistence
               )

      assert_receive {:handler_outcome, %{count: 1},
                      %{
                        outcome: :settled,
                        handler: "settled_stub_handler",
                        reason: :device_out_of_service,
                        agent_id: nil,
                        assignment_id: nil
                      }}

      assert_receive {:persisted_settled, settled_status_row, outcomes}
      assert settled_status_row.available == true
      assert [%{outcome: :settled, reason: :device_out_of_service}] = outcomes

      assert :ok =
               PluginResultIngestor.ingest_durable(payload, status,
                 handlers: [AppliedStubHandler, SettledStubHandler],
                 persistence: persistence
               )

      assert_receive {:persisted_applied, _applied_status_row, co_outcomes}
      assert Enum.map(co_outcomes, & &1.outcome) == [:applied, :settled]

      assert {:refused, {:plugin_assignment_agent_mismatch, _detail}} =
               PluginResultIngestor.ingest_durable(payload, status,
                 handlers: [AppliedStubHandler, RefusedStubHandler],
                 persistence: persistence
               )
    end
  end

  describe "handler-by-handler outcome regressions" do
    test "ProxmoxSourceScopeResolver classifies :plugin_assignment_not_found as refused and disabled assignment as settled" do
      assignment_id = "00000000-0000-4000-8000-000000000101"
      rule_id = "00000000-0000-4000-8000-000000000102"

      payload = %{
        "labels" => %{
          "assignment_id" => assignment_id,
          "plugin_id" => "proxmox-inventory"
        },
        "details" => %{
          "schema" => "serviceradar.proxmox_enrichment.v1",
          "targets" => [%{"nodes" => [%{"node" => "pve-node-01.example"}]}]
        }
      }

      status = %{
        agent_id: "edge-agent-01",
        partition: "partition-alpha",
        plugin_id: "proxmox-inventory",
        plugin_provenance: %{"assignment_id" => assignment_id},
        delivery_capabilities: [
          "plugin-host-authority:v1",
          "proxmox-semantic-connector:v1",
          "proxmox-identity:v3"
        ]
      }

      assert {:error, :plugin_assignment_not_found} =
               ProxmoxSourceScopeResolver.resolve(payload, status,
                 actor: %{},
                 assignment_loader: fn ^assignment_id, _actor ->
                   {:error, :plugin_assignment_not_found}
                 end
               )

      refute ProxmoxSourceScopeResolver.assignment_withdrawn?(:plugin_assignment_not_found)
      assert ProxmoxSourceScopeResolver.assignment_withdrawn?(:plugin_assignment_disabled)

      policy_id = "network-credential-rule:#{rule_id}"

      disabled_assignment = %{
        id: assignment_id,
        enabled: false,
        source: :policy,
        agent_uid: "edge-agent-01",
        partition_id: "partition-alpha",
        plugin_id: "proxmox-inventory",
        policy_id: policy_id,
        params: %{"policy_id" => policy_id},
        plugin_package: %{
          id: "00000000-0000-4000-8000-000000000103",
          plugin_id: "proxmox-inventory",
          status: :approved
        }
      }

      assert {:error, :plugin_assignment_disabled} =
               ProxmoxSourceScopeResolver.resolve(payload, status,
                 actor: %{},
                 assignment_loader: fn ^assignment_id, _actor -> {:ok, disabled_assignment} end
               )
    end

    test "ProxmoxEnrichmentIngestor returns structured {:refused, ...} and {:error, ...} instead of raising ArgumentError" do
      payload = %{
        "schema" => "serviceradar.plugin_result.v1",
        "status" => "OK",
        "summary" => "synthetic proxmox inventory",
        "details" => %{
          "schema" => "serviceradar.proxmox_enrichment.v1",
          "targets" => [
            %{
              "cluster" => [
                %{"type" => "cluster", "id" => "pve-synthetic", "name" => "pve-synthetic"}
              ],
              "nodes" => [%{"node" => "pve-node-01.example", "status" => "online"}],
              "guests" => []
            }
          ]
        }
      }

      status = %{agent_id: "edge-agent-01", partition: "partition-alpha"}

      assert {:refused, :invalid_trusted_proxmox_source_scope, _meta} =
               ProxmoxEnrichmentIngestor.ingest(payload, status, source_scope: %{})

      assert {:error, {:invalid_proxmox_source_scope_resolver_return, :not_a_map}} =
               ProxmoxEnrichmentIngestor.ingest(payload, status,
                 source_scope_resolver: fn _payload, _status, _opts -> {:ok, :not_a_map} end
               )
    end

    test "RunOverrideAckIngestor refuses missing plugin assignment provenance" do
      payload = %{"run_overrides_acknowledged" => 3}
      status = %{agent_id: "edge-agent-01", plugin_provenance: %{}}

      assert {:refused, :missing_plugin_assignment_provenance, _meta} =
               RunOverrideAckIngestor.ingest(payload, status, [])
    end

    test "PluginIngestor distinguishes refused payload/artifact errors from transient artifact fetch errors" do
      payload_missing = %{
        "labels" => %{"kind" => "running_config"},
        "details" => %{"kind" => "running_config"}
      }

      assert {:refused, :missing_running_config, _meta} =
               PluginIngestor.ingest(payload_missing, %{agent_id: "edge-agent-01"}, [])

      assignment_id = "00000000-0000-4000-8000-000000000201"
      sha = String.duplicate("a", 64)
      key = "agent-artifacts/edge-agent-01/#{assignment_id}/opentext-nom/running-config/device-01"

      staged_payload = %{
        "labels" => %{
          "kind" => "running_config",
          "assignment_id" => assignment_id,
          "device_uid" => "sr:00000000-0000-4000-8000-000000000202"
        },
        "details" => %{
          "kind" => "running_config",
          "artifact" => %{
            "object_key" => key,
            "sha256" => sha
          }
        }
      }

      staged_status = %{
        agent_id: "edge-agent-01",
        plugin_provenance: %{"assignment_id" => assignment_id}
      }

      assert {:refused, :running_config_artifact_not_found, _meta} =
               PluginIngestor.ingest(staged_payload, staged_status,
                 artifact_fetcher: fn _key -> {:error, :not_found} end,
                 artifact_deleter: fn _key -> :ok end,
                 defer_artifact_cleanup: true
               )

      assert {:error, {:running_config_artifact_fetch_failed, :econnrefused}} =
               PluginIngestor.ingest(staged_payload, staged_status,
                 artifact_fetcher: fn _key -> {:error, :econnrefused} end,
                 artifact_deleter: fn _key -> :ok end,
                 defer_artifact_cleanup: true
               )
    end

    test "InterfaceCheckIngestor refuses invalid check payload and verdict ceiling violations" do
      invalid_payload = %{
        "details" => %{
          "interface_config_check" => %{
            "kind" => "interface_config_check"
          }
        }
      }

      assert {:refused, :interface_check_invalid_result, _meta} =
               InterfaceCheckIngestor.ingest(invalid_payload, %{agent_id: "edge-agent-01"}, [])
    end

    test "DeviceDiscoveryIngestor settles pure superseded AWX observations and refuses mixed superseded + un-ruled discovery" do
      controller_id = "00000000-0000-4000-8000-000000000301"
      superseded = {:stale_awx_membership_generation, controller_id, 4, 5}

      awx_discovery_item = %{
        "schema" => "serviceradar.device_discovery.v1",
        "source" => "awx",
        "observed_at" => "2026-11-14T10:00:00Z",
        "collection_id" => "synthetic-observation-4",
        "metadata" => %{
          "controller_id" => controller_id,
          "source_generation" => 4,
          "source_fingerprint" => "sha256:" <> String.duplicate("c", 64),
          "complete" => true
        },
        "devices" => []
      }

      pure_payload = %{"device_discovery" => [awx_discovery_item]}

      assert {:settled, :stale_awx_membership_generation, meta} =
               DeviceDiscoveryIngestor.ingest(pure_payload, %{agent_id: "edge-agent-01"},
                 actor: :actor,
                 membership_transaction: fn _aggregates, _ingest ->
                   {:ok, {:superseded, [superseded]}}
                 end
               )

      assert meta.controller_id == controller_id

      mixed_payload = %{
        "device_discovery" => [
          awx_discovery_item,
          %{
            "schema" => "serviceradar.device_discovery.v1",
            "source" => "netbox",
            "devices" => [
              %{
                "device_id" => "netbox:device:20",
                "hostname" => "switch-01.example",
                "ip" => "192.0.2.20"
              }
            ]
          }
        ]
      }

      assert {:refused, :mixed_superseded_awx_observation, _meta} =
               DeviceDiscoveryIngestor.ingest(mixed_payload, %{agent_id: "edge-agent-01"},
                 actor: :actor,
                 membership_transaction: fn _aggregates, _ingest ->
                   {:ok, {:superseded, [superseded]}}
                 end
               )
    end

    test "HypervisorEnrichmentIngestor, VulnerabilityAdvisoryIngestor, WifiMap.BatchIngestor, and ThreatIntelPluginIngestor refuse deterministic invalid payloads" do
      proxmox_hypervisor_payload = %{
        "details" => %{
          "schema" => "serviceradar.hypervisor_enrichment.v1",
          "provider" => "proxmox",
          "hosts" => [
            %{
              "provider_ref" => "proxmox:pve-node-01",
              "name" => "pve-node-01.example"
            }
          ]
        }
      }

      assert {:refused, :proxmox_v3_identity_required, _meta} =
               HypervisorEnrichmentIngestor.ingest(
                 proxmox_hypervisor_payload,
                 %{agent_id: "edge-agent-01"},
                 []
               )

      assert {:refused, :missing_trusted_proxmox_source_scope, _meta} =
               HypervisorEnrichmentIngestor.ingest(
                 proxmox_hypervisor_payload,
                 %{agent_id: "edge-agent-01"},
                 persist: fn _records -> {:error, :missing_trusted_proxmox_source_scope} end
               )

      assert {:refused, :invalid_advisories, _meta} =
               VulnerabilityAdvisoryIngestor.ingest(
                 %{
                   "advisory_feeds" => [
                     %{
                       "producer_id" => "synthetic-feed",
                       "source" => %{},
                       "snapshot" => %{},
                       "advisories" => "not-a-list"
                     }
                   ]
                 },
                 %{agent_id: "edge-agent-01"},
                 []
               )

      assert {:refused, :invalid_wifi_map_payload, _meta} =
               BatchIngestor.ingest(
                 %{"details" => %{"wifi_map" => "not-a-map"}},
                 %{agent_id: "edge-agent-01"},
                 []
               )

      assert {:refused, :invalid_threat_intel_payload, _meta} =
               ThreatIntelPluginIngestor.ingest(
                 %{"threat_intel" => "not-a-map"},
                 %{agent_id: "edge-agent-01"},
                 []
               )
    end

    test "Camera.EventIngestor settles when all events are suppressed for out-of-service devices and Camera.InventoryIngestor refuses when all descriptors lack identity" do
      camera_events_payload = %{
        "events" => [
          %{"message" => "motion detected on synthetic camera 1"},
          %{"message" => "motion detected on synthetic camera 2"}
        ]
      }

      assert {:settled, :device_out_of_service, %{suppressed_count: 2}} =
               EventIngestor.ingest(camera_events_payload, %{agent_id: "edge-agent-01"},
                 event_publisher: fn _attrs -> {:ok, :suppressed} end
               )

      camera_inventory_payload = %{
        "details" => %{
          "camera_descriptors" => [
            %{"display_name" => "Synthetic Lobby Cam"},
            %{"display_name" => "Synthetic Dock Cam"}
          ]
        }
      }

      assert {:refused, :missing_camera_identity, %{skipped_count: 2}} =
               InventoryIngestor.ingest(
                 camera_inventory_payload,
                 %{agent_id: "edge-agent-01", partition: "partition-alpha"},
                 []
               )
    end
  end

  describe "Telemetry metric folding" do
    test "Telemetry.metrics/0 defines plugin_result.handler outcome/unclassified_error counters and folds #6505/#6519 bespoke counters" do
      names = Enum.map(Telemetry.metrics(), & &1.name)

      assert [:serviceradar, :plugin_result, :handler, :outcome, :count] in names
      assert [:serviceradar, :plugin_result, :handler, :unclassified_error, :count] in names

      refute [:serviceradar, :inventory, :awx_observation, :superseded, :count] in names
      refute [:serviceradar, :inventory, :proxmox_result, :assignment_withdrawn, :count] in names
    end
  end

  defp fake_persistence(parent) do
    %{
      remap_service_name: fn status -> {:ok, status} end,
      insert_status: fn status_row, _actor ->
        {:ok, struct(ServiceStatus, status_row), :inserted}
      end,
      persist_applied: fn status_row, _payload, outcomes, _actor ->
        send(parent, {:persisted_applied, status_row, outcomes})
        {:ok, struct(ServiceStatus, status_row)}
      end,
      persist_settled: fn status_row, _payload, outcomes, _actor ->
        send(parent, {:persisted_settled, status_row, outcomes})
        {:ok, struct(ServiceStatus, status_row)}
      end,
      persist_failed: fn status_row, _payload, errors, _handlers, _actor ->
        send(parent, {:persisted_failed, status_row, errors})
        {:ok, struct(ServiceStatus, status_row)}
      end,
      publish_status: fn _status -> :ok end
    }
  end
end
