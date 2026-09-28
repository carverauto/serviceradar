defmodule ServiceRadar.Inventory.DeviceRiskIocExposureRoutingTest do
  # Not async: the cutover list is global application env.
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Inventory.DeviceRiskIocExposure

  @moduletag :db_free

  @flow_columns ~w(hostile_ip dst_ip dst_port comm cmdline agent_id observed_at row_key)

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prev) end)
    %{prev: prev}
  end

  defp empty_opts(query, hostile_ioc_ips) do
    [
      flow_limit: 100,
      hostile_ioc_ips: hostile_ioc_ips,
      resolve_device_identifiers: fn _dst_ips -> {:ok, %{}} end,
      resolve_agent_devices: fn _agent_ids -> {:ok, %{}} end,
      query: query,
      query_findings: fn _device_uids, _opts -> [] end,
      query_active_contribution_uids: fn -> [] end,
      open_alert?: fn _source_id -> false end,
      upsert_contribution: fn _contribution, _opts -> :ok end,
      emit_event: fn _payload -> :ok end,
      create_alert: fn _attrs -> {:ok, %{id: "alert"}} end
    ]
  end

  test "flow_history_backend/0 follows the flows dataset", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:metrics])
    )

    assert DeviceRiskIocExposure.flow_history_backend() == {:error, :starrocks_required}

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    assert DeviceRiskIocExposure.flow_history_backend() == :starrocks
  end

  test "with flows cut over the flow page reads the warehouse, never CNPG", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    parent = self()

    query = fn sql ->
      send(parent, {:flow_sql, sql})
      {:ok, %{columns: @flow_columns, rows: []}}
    end

    hostile_ioc_ips = fn as_of ->
      send(parent, {:hostile_ioc_ips, as_of})
      {:ok, %{"203.0.113.9" => %{sources: ["alienvault_otx"], severity: 4}}}
    end

    assert {:ok, %{devices: 0, hits: 0}} =
             DeviceRiskIocExposure.evaluate(empty_opts(query, hostile_ioc_ips))

    assert_received {:hostile_ioc_ips, %DateTime{} = _as_of}
    assert_received {:flow_sql, sql}

    assert sql =~ "FROM serviceradar.ocsf_network_activity"
    assert sql =~ "event_type = 'attributed_flow'"
    assert sql =~ "IN ('203.0.113.9')"
    refute sql =~ "platform.ocsf_network_activity"
  end

  test "an empty hostile-IOC set skips the warehouse query", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    query = fn _sql -> flunk("no hostile IPs, so the warehouse must not be queried") end

    assert {:ok, %{devices: 0, hits: 0}} =
             DeviceRiskIocExposure.evaluate(empty_opts(query, fn _as_of -> {:ok, %{}} end))
  end

  test "the warehouse page keysets over time and the flow row key", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    parent = self()

    observed_at = ~U[2026-08-15 12:00:00Z]
    row_key = "obs-row-key-1"

    query = fn sql ->
      send(parent, {:flow_sql, sql})

      case Process.get(:page, :first) do
        :first ->
          Process.put(:page, :second)

          {:ok,
           %{
             columns: @flow_columns,
             rows: [
               ["203.0.113.9", "10.0.0.8", 443, "sshd", nil, nil, observed_at, row_key]
             ]
           }}

        :second ->
          {:ok, %{columns: @flow_columns, rows: []}}
      end
    end

    assert {:ok, %{devices: 0, hits: 0}} =
             DeviceRiskIocExposure.evaluate(
               flow_limit: 1,
               hostile_ioc_ips: fn _as_of ->
                 {:ok, %{"203.0.113.9" => %{sources: ["alienvault_otx"], severity: 4}}}
               end,
               resolve_device_identifiers: fn dst_ips ->
                 {:ok, Map.new(dst_ips, &{&1, "sr:device-a"})}
               end,
               resolve_agent_devices: fn _agent_ids -> {:ok, %{}} end,
               query: query,
               query_findings: fn _device_uids, _opts -> [] end,
               query_active_contribution_uids: fn -> [] end,
               open_alert?: fn _source_id -> false end,
               upsert_contribution: fn _contribution, _opts -> :ok end,
               emit_event: fn _payload -> :ok end,
               create_alert: fn _attrs -> {:ok, %{id: "alert"}} end
             )

    assert_received {:flow_sql, first_sql}
    assert_received {:flow_sql, second_sql}

    refute first_sql =~ "id <"
    assert second_sql =~ "id < 'obs-row-key-1'"
    assert second_sql =~ "`time` < '2026-08-15 12:00:00"
  end

  test "a full warehouse page of unresolved destinations keeps scanning", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    parent = self()

    query = fn sql ->
      send(parent, {:flow_sql, sql})

      case Process.get(:page, :first) do
        :first ->
          Process.put(:page, :second)

          {:ok,
           %{
             columns: @flow_columns,
             rows: [
               [
                 "203.0.113.9",
                 "10.0.0.8",
                 443,
                 "sshd",
                 nil,
                 nil,
                 ~U[2026-08-15 12:00:00Z],
                 "row-1"
               ],
               [
                 "203.0.113.9",
                 "10.0.0.9",
                 443,
                 "sshd",
                 nil,
                 nil,
                 ~U[2026-08-15 11:59:59Z],
                 "row-2"
               ]
             ]
           }}

        :second ->
          {:ok, %{columns: @flow_columns, rows: []}}
      end
    end

    assert {:ok, %{devices: 0, hits: 0}} =
             DeviceRiskIocExposure.evaluate(
               flow_limit: 2,
               hostile_ioc_ips: fn _as_of ->
                 {:ok, %{"203.0.113.9" => %{sources: ["alienvault_otx"], severity: 4}}}
               end,
               resolve_device_identifiers: fn _dst_ips -> {:ok, %{}} end,
               resolve_agent_devices: fn _agent_ids -> {:ok, %{}} end,
               query: query,
               query_findings: fn _device_uids, _opts -> [] end,
               query_active_contribution_uids: fn -> [] end,
               open_alert?: fn _source_id -> false end,
               upsert_contribution: fn _contribution, _opts -> :ok end,
               emit_event: fn _payload -> :ok end,
               create_alert: fn _attrs -> {:ok, %{id: "alert"}} end
             )

    assert_received {:flow_sql, first_sql}
    assert_received {:flow_sql, second_sql}

    refute first_sql =~ "id <"
    assert second_sql =~ "id < 'row-2'"
    assert second_sql =~ "`time` < '2026-08-15 11:59:59"
  end

  test "the warehouse page resolves device agent-first", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    observed_at = ~U[2026-08-15 12:00:00Z]

    query = fn _sql ->
      {:ok,
       %{
         columns: @flow_columns,
         rows: [
           ["203.0.113.9", "10.0.0.8", 443, "sshd", nil, "agent-001", observed_at, "row-1"]
         ]
       }}
    end

    assert {:ok, %{devices: 1, hits: 1}} =
             DeviceRiskIocExposure.evaluate(
               flow_limit: 100,
               hostile_ioc_ips: fn _as_of ->
                 {:ok, %{"203.0.113.9" => %{sources: ["alienvault_otx"], severity: 4}}}
               end,
               resolve_device_identifiers: fn _dst_ips -> {:ok, %{}} end,
               resolve_agent_devices: fn agent_ids ->
                 {:ok, Map.new(agent_ids, &{&1, "sr:device-from-agent"})}
               end,
               query: query,
               query_findings: fn device_uids, _opts ->
                 assert device_uids == ["sr:device-from-agent"]

                 [
                   %{
                     device_uid: hd(device_uids),
                     cve_id: "CVE-2026-0001",
                     kev: true,
                     cvss: 9.8,
                     package: "openssh"
                   }
                 ]
               end,
               query_active_contribution_uids: fn -> [] end,
               open_alert?: fn _source_id -> false end,
               upsert_contribution: fn _contribution, _opts -> :ok end,
               emit_event: fn _payload -> :ok end,
               create_alert: fn attrs ->
                 assert attrs.agent_uid == "agent-001"
                 {:ok, %{id: "alert"}}
               end
             )
  end

  test "the hostile-IOC lookup runs once per evaluate", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    parent = self()
    observed_at = ~U[2026-08-15 12:00:00Z]

    query = fn _sql ->
      case Process.get(:page, :first) do
        :first ->
          Process.put(:page, :second)

          {:ok,
           %{
             columns: @flow_columns,
             rows: [
               [
                 "203.0.113.9",
                 "10.0.0.8",
                 443,
                 "sshd",
                 nil,
                 nil,
                 observed_at,
                 "row-1"
               ]
             ]
           }}

        :second ->
          {:ok, %{columns: @flow_columns, rows: []}}
      end
    end

    assert {:ok, %{devices: 0, hits: 0}} =
             DeviceRiskIocExposure.evaluate(
               flow_limit: 1,
               hostile_ioc_ips: fn _as_of ->
                 send(parent, :ioc_lookup)
                 {:ok, %{"203.0.113.9" => %{sources: ["alienvault_otx"], severity: 4}}}
               end,
               resolve_device_identifiers: fn _dst_ips -> {:ok, %{}} end,
               resolve_agent_devices: fn _agent_ids -> {:ok, %{}} end,
               query: query,
               query_findings: fn _device_uids, _opts -> [] end,
               query_active_contribution_uids: fn -> [] end,
               open_alert?: fn _source_id -> false end,
               upsert_contribution: fn _contribution, _opts -> :ok end,
               emit_event: fn _payload -> :ok end,
               create_alert: fn _attrs -> {:ok, %{id: "alert"}} end
             )

    assert_received :ioc_lookup
    refute_received :ioc_lookup
  end
end
