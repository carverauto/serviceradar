defmodule ServiceRadar.Analytics.StarRocks.BenchmarkMatrixTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Benchmark
  alias ServiceRadar.Analytics.StarRocks.Rows

  @moduletag :db_free

  test "synthetic flows are invented RFC5737 rows encoded by Rows" do
    [row] = Benchmark.synthetic_flows(1, run_id: "unit")

    assert row ==
             hd(
               Rows.encode(:flows, [
                 %{
                   "id" => "flow-bench-unit-000001",
                   "device_uid" => "device-bench-000001",
                   "time" => "1999-06-15 12:00:00",
                   "src_endpoint_ip" => "192.0.2.2",
                   "dst_endpoint_ip" => "198.51.100.2",
                   "src_endpoint_port" => nil,
                   "dst_endpoint_port" => nil,
                   "protocol_num" => nil,
                   "protocol_name" => nil,
                   "direction_label" => nil,
                   "dst_service_label" => nil,
                   "bytes_in" => 1200,
                   "bytes_out" => 80,
                   "packets_in" => 10,
                   "packets_out" => 2,
                   "sampling_rate" => 1,
                   "attribution_version" => 0
                 }
               ])
             )

    refute row["src_endpoint_ip"] =~ ~r/^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)/
  end

  test "matrix drives StreamLoad then Query and fails unexecuted capacity cells" do
    parent = self()
    {:ok, loaded} = Agent.start_link(fn -> 0 end)

    http = fn
      %{method: :put, url: url, body: body} ->
        assert url =~ "/api/serviceradar/ocsf_network_activity/_stream_load"
        rows = Jason.decode!(body)
        Agent.update(loaded, fn _ -> length(rows) end)
        send(parent, {:stream_load, length(rows), hd(rows)["id"]})

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "Status" => "Success",
               "NumberLoadedRows" => length(rows),
               "NumberFilteredRows" => 0
             })
         }}
    end

    mysql = fn sql ->
      assert sql =~ "FROM serviceradar.ocsf_network_activity"
      assert sql =~ "flow-bench-unit-"
      count = Agent.get(loaded, & &1)
      send(parent, {:query, sql, count})

      {:ok,
       %Postgrex.Result{
         command: :select,
         columns: ["c", "b"],
         rows: [[count, count * 1200]],
         num_rows: 1,
         connection_id: nil
       }}
    end

    results =
      Benchmark.run_matrix(
        http: http,
        mysql: mysql,
        run_id: "unit",
        max_identity: 100,
        max_readers: 1
      )

    by_id = Map.new(results, &{&1.id, &1})

    assert by_id["identities_1"].verdict == :pass
    assert by_id["identities_100"].verdict == :pass
    assert by_id["identities_1000"].verdict == :fail
    assert by_id["identities_1000"].reason =~ "max_identity"
    assert by_id["identities_10000"].verdict == :fail
    assert by_id["rate_10k"].verdict == :fail
    assert by_id["rate_50k"].verdict == :fail
    assert by_id["rate_100k"].verdict == :fail
    assert by_id["soak_1h"].verdict == :fail
    assert by_id["readers_1"].verdict == :pass
    assert by_id["readers_10"].verdict == :fail
    assert by_id["readers_50"].verdict == :fail

    assert_received {:stream_load, 1, "flow-bench-unit-000001"}
    assert_received {:query, sql_one, 1} when is_binary(sql_one)
    assert_received {:stream_load, 100, "flow-bench-unit-000001"}
    assert_received {:query, sql_hundred, 100} when is_binary(sql_hundred)
    assert_received {:query, _reader_sql, 100}
    refute Enum.any?(results, &(&1.verdict == :pass and &1.id =~ ~r/rate_|soak_/))
    refute Benchmark.profile().cutover
  end
end
