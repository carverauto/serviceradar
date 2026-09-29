defmodule ServiceRadar.Inventory.DeviceRiskIocExposureRoutingTest do
  # Not async: the cutover list is global application env.
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Inventory.DeviceRiskIocExposure

  @moduletag :db_free

  @flow_columns ~w(hostile_ip dst_ip dst_port comm cmdline agent_id observed_at row_key)

  @cnpg_flow_columns ~w(
    device_uid agent_id hostile_ip dst_ip dst_port comm cmdline observed_at ioc_sources ioc_severity row_key
  )

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

  test "full and partial flow writes retain maximum risk for an agent-only device", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    observed_at = ~U[2026-08-15 12:00:00Z]

    for process <- [
          %{comm: "sshd", cmdline: nil},
          %{comm: "worker", cmdline: "/opt/openssh/sbin/sshd -D"}
        ] do
      flow = %{
        id: "flow-example-01",
        time: observed_at,
        src_endpoint_ip: "198.51.100.9",
        dst_endpoint_ip: "192.0.2.8",
        dst_endpoint_port: 22,
        ocsf_payload: %{
          "agent_id" => "agent-example-01",
          "event_type" => "attributed_flow",
          "attribution" => %{
            "pid" => 73,
            "comm" => process.comm,
            "redacted_cmdline" => process.cmdline
          }
        }
      }

      [full] = Rows.encode(:flows, [flow])

      update =
        process
        |> Map.merge(%{id: flow.id, time: observed_at, agent_id: "agent-example-01", pid: 73})
        |> Attribution.update_event(1)

      [partial] = Rows.encode(:flow_attribution, [update])

      for encoded <- [full, partial] do
        query = fn _sql ->
          {:ok,
           %{
             columns: @flow_columns,
             rows: [
               [
                 flow.src_endpoint_ip,
                 flow.dst_endpoint_ip,
                 flow.dst_endpoint_port,
                 encoded["comm"],
                 encoded["cmdline"],
                 encoded["agent_id"],
                 encoded["time"],
                 encoded["id"]
               ]
             ]
           }}
        end

        assert {:ok, %{devices: 1, hits: 1}} =
                 DeviceRiskIocExposure.evaluate(
                   as_of: observed_at,
                   flow_limit: 100,
                   hostile_ioc_ips: fn _as_of ->
                     {:ok, %{"198.51.100.9" => %{sources: ["alienvault_otx"], severity: 4}}}
                   end,
                   resolve_device_identifiers: fn _dst_ips -> {:ok, %{}} end,
                   resolve_agent_devices: fn agent_ids ->
                     assert agent_ids == ["agent-example-01"]
                     {:ok, %{"agent-example-01" => "sr:device-from-agent"}}
                   end,
                   query: query,
                   query_findings: fn device_uids, _opts ->
                     assert device_uids == ["sr:device-from-agent"]

                     [
                       %{
                         device_uid: "sr:device-from-agent",
                         cve_id: "CVE-2026-0001",
                         kev: true,
                         cvss: 9.8,
                         package: "openssh"
                       }
                     ]
                   end,
                   query_active_contribution_uids: fn -> ["sr:device-from-agent"] end,
                   open_alert?: fn _source_id -> false end,
                   upsert_contribution: fn contribution, _opts ->
                     send(self(), {:contribution, contribution})
                     :ok
                   end,
                   emit_event: fn _payload -> :ok end,
                   create_alert: fn attrs ->
                     assert attrs.agent_uid == "agent-example-01"
                     {:ok, %{id: "alert"}}
                   end
                 )

        assert_received {:contribution,
                         %{device_uid: "sr:device-from-agent", score: 100, active: true}}

        refute_received {:contribution, _}
      end
    end
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

  # The CNPG fallback arm. A warehouse-disabled installation (or an operator's
  # explicit cutover list that omits flows) keeps the risk read on the CNPG
  # query, which resolves the device agent-first inside the SQL: an
  # agent-only device -- one whose `dst_endpoint_ip` is not a
  # `device_identifiers` row -- is detected there even though warehouse rows
  # written before `agent_id` enrichment cannot see it.
  test "a warehouse-disabled installation keeps the risk read on CNPG with agent-first resolution",
       %{
         prev: prev
       } do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev |> Keyword.put(:enabled, false) |> Keyword.put(:cutover_datasets, [])
    )

    parent = self()
    as_of = ~U[2026-08-15 12:00:00Z]

    cnpg_query = fn sql, params ->
      send(parent, {:cnpg_sql, sql, params})

      {:ok,
       %{
         columns: @cnpg_flow_columns,
         rows: [
           # The SQL resolved this device through ocsf_agents: its dst IP has
           # no device_identifiers row.
           [
             "sr:device-from-agent",
             "agent-001",
             "203.0.113.9",
             "10.0.0.8",
             22,
             "sshd",
             nil,
             as_of,
             ["alienvault_otx"],
             4,
             "rk-1"
           ]
         ]
       }}
    end

    assert {:ok, %{devices: 1, hits: 1}} =
             DeviceRiskIocExposure.evaluate(
               as_of: as_of,
               cnpg_query: cnpg_query,
               query: fn _sql -> flunk("the warehouse must not be queried before the cutover") end,
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
               create_alert: fn _attrs -> {:ok, %{id: "alert"}} end
             )

    assert_received {:cnpg_sql, sql, params}

    assert sql =~ "FROM platform.ocsf_network_activity"
    assert sql =~ "LEFT JOIN platform.ocsf_agents"
    assert sql =~ "COALESCE(a.device_uid, di.device_id)"
    refute sql =~ "serviceradar.ocsf_network_activity"

    # The CNPG window is [as_of - window, as_of], same bounds the warehouse
    # page enforces after the cutover.
    assert [^as_of, 3600, _page_size, nil, nil] = params
  end

  test "the warehouse window is strictly bounded by the risk lookback", %{prev: prev} do
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

    assert {:ok, %{devices: 0, hits: 0}} =
             DeviceRiskIocExposure.evaluate(
               as_of: ~U[2026-08-15 12:00:00Z],
               flow_limit: 100,
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

    assert_received {:flow_sql, sql}

    assert sql =~ "`time` > '2026-08-15 11:00:00'"
    assert sql =~ "`time` <= '2026-08-15 12:00:00'"
  end

  # The hazard inside the accepted gap, pinned so the claim stays honest: a
  # warehouse row from before the enriched writes (agent_id NULL) whose device
  # is reachable only through its agent resolves no device and produces no
  # hit, for as long as such a row stays inside the window above -- and an
  # un-enriched row must stay dropped rather than be attributed to a wrong
  # device.
  test "an un-enriched warehouse row inside the window produces no device", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    query = fn _sql ->
      {:ok,
       %{
         columns: @flow_columns,
         rows: [
           ["203.0.113.9", "10.0.0.8", 22, "sshd", nil, nil, ~U[2026-08-15 11:59:00Z], "row-1"]
         ]
       }}
    end

    assert {:ok, %{devices: 0, hits: 0}} =
             DeviceRiskIocExposure.evaluate(
               as_of: ~U[2026-08-15 12:00:00Z],
               flow_limit: 100,
               hostile_ioc_ips: fn _as_of ->
                 {:ok, %{"203.0.113.9" => %{sources: ["alienvault_otx"], severity: 4}}}
               end,
               resolve_device_identifiers: fn _dst_ips -> {:ok, %{}} end,
               resolve_agent_devices: fn agent_ids ->
                 # No agent on the row: there is nothing to resolve.
                 assert agent_ids == [nil]
                 {:ok, %{}}
               end,
               query: query,
               query_findings: fn _device_uids, _opts -> [] end,
               query_active_contribution_uids: fn -> [] end,
               open_alert?: fn _source_id -> false end,
               upsert_contribution: fn _contribution, _opts -> :ok end,
               emit_event: fn _payload -> :ok end,
               create_alert: fn _attrs -> {:ok, %{id: "alert"}} end
             )
  end
end
