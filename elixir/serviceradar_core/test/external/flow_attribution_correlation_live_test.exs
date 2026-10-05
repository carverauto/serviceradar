defmodule ServiceRadar.External.FlowAttributionCorrelationLiveTest do
  @moduledoc false

  # Runs the correlation statement against a live StarRocks warehouse, because
  # its match semantics are StarRocks SQL and nothing short of the engine can
  # check them. Excluded by default (`:external`); run with
  #
  #   SERVICERADAR_TEST_STARROCKS_HOST=127.0.0.1 SERVICERADAR_TEST_STARROCKS_PORT=9030 \
  #   SERVICERADAR_TEST_STARROCKS_USER=... SERVICERADAR_TEST_STARROCKS_PASSWORD=... \
  #   SERVICERADAR_TEST_STARROCKS_DATABASE=<scratch database> \
  #   mix test --include external test/external/flow_attribution_correlation_live_test.exs
  #
  # It creates two uniquely named tables in that database, the observation table
  # from the shipped DDL, and drops them afterwards. Point it at a scratch
  # database, never a deployment's warehouse.

  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadar.FlowAttribution.Correlation

  @moduletag :external
  @moduletag :starrocks_live

  @agent_ips [["agent-snat", "192.0.2.100"]]
  @backends [
    [6, "203.0.113.10", 443, "192.0.2.70", 8443, 0],
    [6, "203.0.113.10", 443, "192.0.2.71", 8443, 1]
  ]

  setup_all do
    database = required_env("SERVICERADAR_TEST_STARROCKS_DATABASE")

    {:ok, conn} = MyXQL.start_link(conn_opts(database))

    suffix = System.unique_integer([:positive])
    flows = "#{database}.fattr_live_flows_#{suffix}"
    observations = "#{database}.fattr_live_obs_#{suffix}"

    on_exit(fn ->
      {:ok, cleanup} = MyXQL.start_link(conn_opts(database))
      for table <- [flows, observations], do: query!(cleanup, "DROP TABLE IF EXISTS #{table}")
    end)

    query!(conn, """
    CREATE TABLE #{flows} (
      id VARCHAR(64) NOT NULL,
      `time` DATETIME NOT NULL,
      `partition` VARCHAR(128) NOT NULL,
      protocol_num INT,
      attribution_version BIGINT,
      src_endpoint_ip VARCHAR(64),
      dst_endpoint_ip VARCHAR(64),
      src_endpoint_port INT,
      dst_endpoint_port INT,
      pid INT
    )
    DUPLICATE KEY (id)
    DISTRIBUTED BY HASH(id) BUCKETS 1
    PROPERTIES ("replication_num" = "1")
    """)

    %{statements: [_create_db, create_table]} =
      Enum.find(Schema.migrations(), &(&1.name == "flow_process_attribution_observations"))

    query!(
      conn,
      create_table
      |> Schema.retarget(database, 1)
      |> String.replace(
        "#{database}.flow_process_attribution_observations",
        observations
      )
    )

    seed!(conn, flows, observations)

    sql =
      Correlation.correlation_sql(@agent_ips, @backends,
        flows_table: flows,
        observations_table: observations
      )

    %{columns: columns, rows: rows} = query!(conn, sql)

    picks =
      Map.new(rows, fn row ->
        pick = Map.new(Enum.zip(columns, row))
        {pick["id"], pick}
      end)

    %{picks: picks}
  end

  # Flow:        id, seconds before now, proto, src ip:port -> dst ip:port
  # Observation: seconds before now, agent, proto, local ip:port, remote ip:port,
  #              pid, container id
  defp seed!(conn, flows, observations) do
    flow_rows = [
      {"exact-over-wildcard", 60, 6, "192.0.2.1", 40_000, "198.51.100.1", 443},
      {"wildcard", 60, 6, "198.51.100.2", 51_000, "192.0.2.2", 8080},
      {"newest-at-equal-distance", 60, 6, "192.0.2.3", 40_003, "198.51.100.3", 443},
      {"container-over-host", 60, 6, "192.0.2.8", 40_008, "198.51.100.8", 443},
      {"relaxed-udp", 60, 17, "192.0.2.4", 0, "198.51.100.4", 53},
      {"icmp", 60, 1, "192.0.2.5", 0, "198.51.100.5", 2048},
      {"node-snat", 60, 6, "192.0.2.100", 61_000, "198.51.100.6", 443},
      {"public-endpoint", 60, 6, "198.51.100.7", 50_000, "203.0.113.10", 443},
      {"outside-window", 1_200, 6, "192.0.2.9", 40_009, "198.51.100.9", 443}
    ]

    observation_rows = [
      {60, "agent-a", 6, "192.0.2.1", 40_000, "198.51.100.1", 443, 101, nil},
      {60, "agent-a", 6, "192.0.2.1", 40_000, "0.0.0.0", 0, 102, nil},
      {60, "agent-a", 6, "192.0.2.2", 8080, "0.0.0.0", 0, 201, nil},
      {70, "agent-a", 6, "192.0.2.3", 40_003, "198.51.100.3", 443, 301, nil},
      {50, "agent-a", 6, "192.0.2.3", 40_003, "198.51.100.3", 443, 302, nil},
      {60, "agent-a", 6, "192.0.2.8", 40_008, "198.51.100.8", 443, 801, nil},
      {120, "agent-a", 6, "192.0.2.8", 40_008, "198.51.100.8", 443, 802, "c-808"},
      {90, "agent-a", 17, "192.0.2.4", 40_001, "198.51.100.4", 53, 401, nil},
      {65, "agent-a", 17, "192.0.2.4", 40_002, "198.51.100.4", 53, 402, nil},
      {60, "agent-a", 1, "192.0.2.5", 0, "198.51.100.5", 0, 501, nil},
      {60, "agent-snat", 6, "192.0.2.106", 38_000, "198.51.100.6", 443, 601, "c-601"},
      {120, "agent-gw", 6, "192.0.2.70", 8443, "0.0.0.0", 0, 701, nil},
      {60, "agent-lb", 6, "192.0.2.71", 8443, "0.0.0.0", 0, 702, nil},
      {1_200, "agent-a", 6, "192.0.2.9", 40_009, "198.51.100.9", 443, 901, nil}
    ]

    insert!(conn, flows, Enum.map(flow_rows, &flow_select/1))
    insert!(conn, observations, Enum.map(observation_rows, &observation_select/1))
  end

  defp flow_select({id, age, proto, src, sport, dst, dport}) do
    "SELECT '#{id}', DATE_SUB(UTC_TIMESTAMP(), INTERVAL #{age} SECOND), 'default', #{proto}, " <>
      "NULL, '#{src}', '#{dst}', #{sport}, #{dport}, NULL"
  end

  defp observation_select({age, agent, proto, lip, lport, rip, rport, pid, container}) do
    container = if container, do: "'#{container}'", else: "NULL"

    "SELECT DATE_SUB(UTC_TIMESTAMP(), INTERVAL #{age} SECOND), 'default', #{proto}, " <>
      "'#{lip}', #{lport}, '#{rip}', #{rport}, '#{agent}', md5('#{agent}#{lip}#{lport}'), " <>
      "#{pid}, 'proc-#{pid}', NULL, NULL, #{container}, NULL"
  end

  defp insert!(conn, table, selects),
    do: query!(conn, "INSERT INTO #{table} #{Enum.join(selects, " UNION ALL ")}")

  test "an exact tuple beats a wildcard listener", %{picks: picks} do
    assert %{"pid" => 101, "match_rank" => 0} = picks["exact-over-wildcard"]
  end

  test "a wildcard listener matches server-side fan-in", %{picks: picks} do
    assert %{"pid" => 201, "match_rank" => 1} = picks["wildcard"]
  end

  test "at equal distance from the flow the newest observation wins", %{picks: picks} do
    assert %{"pid" => 302} = picks["newest-at-equal-distance"]
  end

  test "a container-scoped owner beats a host-only one in the same rank", %{picks: picks} do
    assert %{"pid" => 802, "container_id" => "c-808"} = picks["container-over-host"]
  end

  test "relaxed UDP candidates resolve to the one closest in time", %{picks: picks} do
    assert %{"pid" => 402, "match_rank" => 1} = picks["relaxed-udp"]
  end

  test "ICMP matches on addresses without port equality", %{picks: picks} do
    assert %{"pid" => 501, "match_rank" => 0} = picks["icmp"]
  end

  test "a node-SNATed flow matches the pod socket behind the node IP", %{picks: picks} do
    assert %{"pid" => 601, "agent_id" => "agent-snat", "match_rank" => 2} = picks["node-snat"]
  end

  test "a Gateway public endpoint beats a LoadBalancer one", %{picks: picks} do
    assert %{"pid" => 701, "match_rank" => 3} = picks["public-endpoint"]
  end

  test "a flow outside the correlation window stays unattributed", %{picks: picks} do
    refute Map.has_key?(picks, "outside-window")
  end

  defp query!(conn, sql) do
    case MyXQL.query(conn, sql, [], query_type: :text, timeout: 60_000) do
      {:ok, result} -> result
      {:error, error} -> raise "StarRocks query failed: #{Exception.message(error)}\n#{sql}"
    end
  end

  defp conn_opts(database) do
    [
      hostname: required_env("SERVICERADAR_TEST_STARROCKS_HOST"),
      port: String.to_integer(System.get_env("SERVICERADAR_TEST_STARROCKS_PORT", "9030")),
      username: required_env("SERVICERADAR_TEST_STARROCKS_USER"),
      password: System.get_env("SERVICERADAR_TEST_STARROCKS_PASSWORD", ""),
      database: database,
      prepare: :unnamed,
      ssl: false
    ]
  end

  defp required_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> flunk("#{name} is required for the live StarRocks correlation test")
    end
  end
end
