defmodule ServiceRadarWebNGWeb.LogLive.NetflowActivityTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.LogLive.NetflowActivity

  @moduletag :db_free
  @scope %{permissions: MapSet.new(["observability.netflow.view"])}
  @points [%{bucket_start: ~U[2025-01-01 00:00:00Z]}, %{bucket_start: ~U[2025-01-01 00:05:00Z]}]

  test "protocol failure cannot become a zero-filled activity chart" do
    responses([{:error, :synthetic_timeout}])
    assert {:error, :activity_query_failed} = load(:protocol)
    assert_receive {:query, _, %{scope: @scope}}
    refute_receive {:query, _, _}
  end

  test "application ranking failure stops before downsample" do
    responses([{:error, :synthetic_timeout}])
    assert {:error, :activity_query_failed} = load(:app)
    assert_receive {:query, query, _}
    assert query =~ ~s|stats:"sum(bytes_total) as total_bytes by app"|
    refute_receive {:query, _, _}
  end

  test "empty or unrecognized application rankings never run an unrestricted query" do
    for rows <- [[], [%{"app" => "Unknown"}], [%{"payload" => %{"app" => " "}}]] do
      responses([{:ok, %{"results" => rows}}])
      assert {:ok, %{keys: [], points: [], error: nil}} = load(:app)
      assert_receive {:query, _, _}
      refute_receive {:query, _, _}
    end
  end

  test "a failed application downsample remains distinct from a successful empty response" do
    responses([{:ok, %{"results" => [%{"app" => "synthetic-app"}]}}, {:error, :synthetic_timeout}])
    assert {:error, :activity_query_failed} = load(:app)
    assert_receive {:query, _, _}
    assert_receive {:query, query, _}
    assert query =~ ~s|app:("synthetic-app")|
    assert query =~ "series:app limit:2000"
    refute_receive {:query, _, _}
  end

  test "successful protocol samples preserve filters, normalize instants, and zero-fill missing series" do
    responses([
      {:ok,
       %{
         "results" => [
           %{"timestamp" => "2025-01-01T00:00:00.000000Z", "series" => "tcp", "value" => Decimal.new("10.9")},
           %{"timestamp" => "2024-12-31T18:00:00-06:00", "series" => "tcp", "value" => 4},
           %{"timestamp" => "2025-01-01T00:05:00", "series" => "udp", "value" => "30.5"}
         ]
       }}
    ])

    query =
      "in:flows time:last_7d src_ip:192.0.2.9 protocol_group:tcp dst_port:443 limit:50 sort:time:desc cursor:synthetic"

    assert {:ok, activity} = NetflowActivity.load(:protocol, __MODULE__, query, @scope, 300, @points)

    assert activity.points == [
             %{"t" => "2025-01-01T00:00:00Z", "tcp" => 14, "udp" => 0, "other" => 0},
             %{"t" => "2025-01-01T00:05:00Z", "tcp" => 0, "udp" => 30, "other" => 0}
           ]

    assert activity.colors == %{"tcp" => "#4e79a7", "udp" => "#59a14f", "other" => "#bab0ac"}
    assert activity.error == nil
    assert_receive {:query, actual, %{scope: @scope}}
    assert actual =~ "time:last_7d src_ip:192.0.2.9 protocol_group:tcp dst_port:443"
    assert actual =~ ~s|protocol_group:("tcp","udp","other")|
    assert actual =~ "bucket:5m agg:sum value_field:bytes_total series:protocol_group limit:2000"
    refute actual =~ "limit:50"
    refute actual =~ "cursor:"
    refute actual =~ "sort:"
  end

  test "application labels remain quoted and payload-wrapped rankings are accepted" do
    responses([
      {:ok, %{"results" => [%{"payload" => %{"app" => ~s|synthetic," app|}}]}},
      {:ok, %{"results" => []}}
    ])

    assert {:ok, %{keys: [~s(synthetic," app)], error: nil}} = load(:app)
    assert_receive {:query, _, _}
    assert_receive {:query, query, _}
    assert query =~ ~S|app:("synthetic,\" app")|
  end

  test "invalid query responses and raised query errors remain explicit failures" do
    for response <- [{:ok, %{}}, {:ok, %{"results" => [nil]}}, :raise] do
      responses([response])
      assert {:error, _} = load(:protocol)
      assert_receive {:query, _, _}
    end
  end

  def query(query, opts) do
    send(self(), {:query, query, opts})
    [response | remaining] = Process.get(:activity_responses)
    Process.put(:activity_responses, remaining)
    if response == :raise, do: raise("synthetic failure"), else: response
  end

  defp responses(responses), do: Process.put(:activity_responses, responses)
  defp load(kind), do: NetflowActivity.load(kind, __MODULE__, "in:flows time:last_7d", @scope, 300, @points)
end
