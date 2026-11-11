defmodule ServiceRadar.Observability.PluginResultIngestorProxmoxScopeTest do
  use ServiceRadar.Observability.PluginResultIngestorTestSupport

  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor

  defmodule ScopeResolverStub do
    @moduledoc false

    def resolve(payload, status, opts) do
      send(
        Application.fetch_env!(:serviceradar_core, :proxmox_scope_test_pid),
        {:scope_resolved, payload, status, opts}
      )

      Application.fetch_env!(:serviceradar_core, :proxmox_scope_test_result)
    end
  end

  defmodule PersistCapture do
    @moduledoc false

    def persist(records) do
      send(
        Application.fetch_env!(:serviceradar_core, :proxmox_scope_test_pid),
        {:proxmox_records, records}
      )

      :ok
    end
  end

  defmodule DeviceDiscoveryCapture do
    @moduledoc false

    def sync(updates, context) do
      send(
        Application.fetch_env!(:serviceradar_core, :proxmox_scope_test_pid),
        {:generic_device_discovery_ran, updates, context}
      )

      :ok
    end

    def membership(payload, context) do
      send(
        Application.fetch_env!(:serviceradar_core, :proxmox_scope_test_pid),
        {:generic_membership_reconciliation_ran, payload, context}
      )

      :ok
    end
  end

  setup do
    previous_resolver =
      Application.get_env(:serviceradar_core, :proxmox_source_scope_resolver)

    previous_pid = Application.get_env(:serviceradar_core, :proxmox_scope_test_pid)
    previous_result = Application.get_env(:serviceradar_core, :proxmox_scope_test_result)

    Application.put_env(
      :serviceradar_core,
      :proxmox_source_scope_resolver,
      ScopeResolverStub
    )

    Application.put_env(:serviceradar_core, :proxmox_scope_test_pid, self())

    Application.put_env(
      :serviceradar_core,
      :plugin_result_handlers,
      [{ProxmoxEnrichmentIngestor, persist: &PersistCapture.persist/1}]
    )

    on_exit(fn ->
      restore_env(:proxmox_source_scope_resolver, previous_resolver)
      restore_env(:proxmox_scope_test_pid, previous_pid)
      restore_env(:proxmox_scope_test_result, previous_result)
    end)

    :ok
  end

  test "live plugin-result routing injects the resolved trusted source scope" do
    scope = %{
      integration_id: "11111111-1111-4111-8111-111111111111",
      controller_id: "22222222-2222-4222-8222-222222222222",
      partition_id: "farm01"
    }

    Application.put_env(:serviceradar_core, :proxmox_scope_test_result, {:ok, scope})
    {payload, status, _observed_at} = proxmox_fixture()

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert_receive {:scope_resolved, ^payload, ^status, opts}
    assert Keyword.has_key?(opts, :actor)

    assert_receive {:proxmox_records, records}
    assert [cluster] = records.clusters
    assert cluster.integration_id == scope.integration_id
    assert cluster.controller_id == scope.controller_id
    assert cluster.metadata["partition"] == scope.partition_id
    assert cluster.identity_version == 3
    assert String.starts_with?(cluster.provider_ref, "proxmox:v3:")
  end

  test "live plugin-result routing fails closed before persistence when scope resolution fails" do
    Application.put_env(
      :serviceradar_core,
      :proxmox_scope_test_result,
      {:error, :trusted_scope_rejected}
    )

    {payload, status, _observed_at} = proxmox_fixture()

    assert {:error, {:plugin_result_handlers_failed, [{ProxmoxEnrichmentIngestor, error_text}]}} =
             PluginResultIngestor.ingest(payload, status)

    assert error_text =~ "trusted_scope_rejected"
    assert_receive {:scope_resolved, ^payload, ^status, _opts}
    refute_receive {:proxmox_records, _records}
  end

  test "a result whose assignment was withdrawn is acknowledged, counted and not applied" do
    attach_assignment_withdrawn()

    Application.put_env(
      :serviceradar_core,
      :proxmox_scope_test_result,
      {:error, :plugin_assignment_disabled}
    )

    {payload, status, _observed_at} = proxmox_fixture()

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert_receive {:assignment_withdrawn, %{count: 1},
                    %{
                      reason: :plugin_assignment_disabled,
                      assignment_id: "33333333-3333-4333-8333-333333333333"
                    }}

    refute_receive {:proxmox_records, _records}
  end

  # Absent provenance and absent labels must report no assignment id, not the string "nil".
  test "a withdrawn result that names no assignment reports none" do
    attach_assignment_withdrawn()

    Application.put_env(
      :serviceradar_core,
      :proxmox_scope_test_result,
      {:error, :plugin_assignment_disabled}
    )

    {payload, status, _observed_at} = proxmox_fixture()
    payload = Map.delete(payload, "labels")

    assert :ok = PluginResultIngestor.ingest(payload, status)

    assert_receive {:assignment_withdrawn, %{count: 1}, metadata}
    assert metadata.reason == :plugin_assignment_disabled
    assert metadata.assignment_id == nil
  end

  test "an unknown assignment is logged as a warning, any other withdrawal at info" do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    for {reason, level} <- [
          {:plugin_assignment_not_found, "warning"},
          {:plugin_assignment_disabled, "info"}
        ] do
      Application.put_env(:serviceradar_core, :proxmox_scope_test_result, {:error, reason})
      {payload, status, _observed_at} = proxmox_fixture()

      log =
        capture_log([format: "[$level] $message\n"], fn ->
          assert :ok = PluginResultIngestor.ingest(payload, status)
        end)

      assert log =~
               "[#{level}] Proxmox inventory result not applied, its assignment was withdrawn: " <>
                 "reason=#{reason}"
    end
  end

  test "Proxmox results bypass generic discovery before global device ids can reconcile" do
    scope = %{
      integration_id: "11111111-1111-4111-8111-111111111111",
      controller_id: "22222222-2222-4222-8222-222222222222",
      partition_id: "farm01"
    }

    Application.put_env(:serviceradar_core, :proxmox_scope_test_result, {:ok, scope})

    Application.put_env(
      :serviceradar_core,
      :plugin_result_handlers,
      [
        {DeviceDiscoveryIngestor,
         device_sync: &DeviceDiscoveryCapture.sync/2,
         membership_sync: &DeviceDiscoveryCapture.membership/2},
        {ProxmoxEnrichmentIngestor, persist: &PersistCapture.persist/1}
      ]
    )

    {payload, status, _observed_at} = proxmox_fixture()

    payload =
      Map.put(payload, "device_discovery", [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "proxmox",
          "devices" => [
            %{
              "device_id" => "proxmox:qemu:100",
              "hostname" => "vm-100",
              "metadata" => %{"integration_id" => "proxmox:qemu:100"}
            }
          ]
        }
      ])

    assert :ok = PluginResultIngestor.ingest(payload, status)
    assert_receive {:proxmox_records, records}
    assert [guest] = records.guests
    assert guest.identity_version == 3
    assert is_nil(guest.device_uid)
    refute_receive {:generic_device_discovery_ran, _updates, _context}
    refute_receive {:generic_membership_reconciliation_ran, _payload, _context}
  end

  defp attach_assignment_withdrawn do
    event = [:serviceradar, :inventory, :proxmox_result, :assignment_withdrawn]
    handler = "proxmox-assignment-withdrawn-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      event,
      fn ^event, measurements, metadata, _config ->
        send(parent, {:assignment_withdrawn, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp proxmox_fixture do
    {base_payload, base_status, observed_at} = plugin_result_fixture()
    assignment_id = "33333333-3333-4333-8333-333333333333"

    payload =
      Map.merge(base_payload, %{
        "labels" => %{
          "assignment_id" => assignment_id,
          "plugin_id" => "proxmox-inventory"
        },
        "details" => %{
          "schema" => "serviceradar.proxmox_enrichment.v1",
          "targets" => [
            %{
              "cluster" => [%{"type" => "cluster", "id" => "farm01", "name" => "farm01"}],
              "nodes" => [%{"node" => "pve01", "status" => "online"}],
              "guests" => [
                %{
                  "node" => "pve01",
                  "type" => "qemu",
                  "vmid" => 100,
                  "name" => "vm-100",
                  "status" => "running",
                  "interfaces" => [
                    %{"name" => "eth0", "ip_addresses" => ["192.168.2.100/24"]}
                  ]
                }
              ]
            }
          ]
        }
      })

    status =
      Map.put(base_status, :delivery_capabilities, [
        "plugin-host-authority:v1",
        "proxmox-semantic-connector:v1",
        "proxmox-identity:v3"
      ])

    {payload, status, observed_at}
  end
end
