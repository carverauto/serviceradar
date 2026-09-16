defmodule ServiceRadar.Jobs.BootstrapFlowAppDimensionsWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Jobs.BootstrapFlowAppDimensionsWorker, as: Worker

  @first ~U[2035-06-07 09:00:00Z]
  @next ~U[2035-06-07 10:00:00Z]
  @finish ~U[2035-06-07 11:00:00Z]

  test "initialization captures a fixed closed-hour range before any refresh" do
    query = fn sql, params, opts ->
      assert opts[:timeout] == 60_000

      if String.starts_with?(sql, "SELECT to_regclass") do
        {:ok, %{rows: [["aggregate"]]}}
      else
        assert sql =~ "ORDER BY time ASC LIMIT 1"
        assert params == [DateTime.add(@finish, -395 * 86_400), @finish]
        {:ok, %{rows: [[@first]]}}
      end
    end

    assert {:snooze, 1} =
             Worker.run(%Oban.Job{id: 1, args: %{}},
               query: query,
               now: ~U[2035-06-07 11:37:24Z],
               checkpoint: checkpoint()
             )

    assert_receive {:checkpoint,
                    %{
                      "start_hour" => "2035-06-07T09:00:00Z",
                      "next_hour" => "2035-06-07T11:00:00Z"
                    }}
  end

  test "one successful hour moves backward only after refresh and preserves the earliest hour" do
    assert {:snooze, 1} =
             Worker.run(job(@finish), query: refresh_query(), checkpoint: checkpoint())

    assert_receive {:refresh, [@next, @finish]}

    assert_receive {:checkpoint,
                    %{
                      "start_hour" => "2035-06-07T09:00:00Z",
                      "next_hour" => "2035-06-07T10:00:00Z"
                    }}

    refute_receive {:refresh, _}

    assert :ok = Worker.run(job(@next), query: refresh_query(), checkpoint: checkpoint())
    assert_receive {:refresh, [@first, @next]}
    assert_receive {:checkpoint, %{"next_hour" => "2035-06-07T09:00:00Z"}}
  end

  test "failed refresh never advances and retries the same hour" do
    assert {:error, :temporary_failure} =
             Worker.run(job(@finish),
               query: refresh_query({:error, :temporary_failure}),
               checkpoint: checkpoint()
             )

    assert_receive {:refresh, [@next, @finish]}
    refute_receive {:checkpoint, _}

    assert {:snooze, 1} =
             Worker.run(job(@finish), query: refresh_query(), checkpoint: checkpoint())

    assert_receive {:refresh, [@next, @finish]}
    assert_receive {:checkpoint, _}
  end

  test "checkpoint failure repeats the already refreshed hour without skipping data" do
    assert {:error, :checkpoint_unavailable} =
             Worker.run(job(@finish),
               query: refresh_query(),
               checkpoint: fn _, _ -> {:error, :checkpoint_unavailable} end
             )

    assert_receive {:refresh, [@next, @finish]}

    assert {:snooze, 1} =
             Worker.run(job(@finish), query: refresh_query(), checkpoint: checkpoint())

    assert_receive {:refresh, [@next, @finish]}
  end

  test "completed, empty and missing aggregates finish without a refresh" do
    assert :ok = Worker.run(job(@first), query: refresh_query(), checkpoint: checkpoint())
    refute_receive {:refresh, _}

    assert :ok =
             Worker.run(%Oban.Job{args: %{}}, query: fn _, _, _ -> {:ok, %{rows: [[nil]]}} end)

    query = fn sql, _, _ ->
      if String.starts_with?(sql, "SELECT to_regclass"),
        do: {:ok, %{rows: [["aggregate"]]}},
        else: {:ok, %{rows: []}}
    end

    assert :ok = Worker.run(%Oban.Job{args: %{}}, query: query, checkpoint: checkpoint())
    refute_receive {:checkpoint, _}
  end

  test "invalid or non-hour checkpoint cannot trigger an unbounded refresh" do
    for args <- [
          %{"next_hour" => "invalid"},
          %{"start_hour" => "2035-06-07T09:00:01Z", "next_hour" => "2035-06-07T11:00:00Z"},
          %{"start_hour" => "2035-06-07T12:00:00Z", "next_hour" => "2035-06-07T11:00:00Z"},
          %{"start_hour" => "2030-06-07T09:00:00Z", "next_hour" => "2035-06-07T11:00:00Z"}
        ] do
      assert {:error, :invalid_flow_bootstrap_checkpoint} =
               Worker.run(%Oban.Job{args: args}, query: refresh_query(), checkpoint: checkpoint())
    end

    refute_receive {:refresh, _}
    refute_receive {:checkpoint, _}
  end

  defp job(upper) do
    %Oban.Job{
      id: 1,
      args: %{
        "start_hour" => DateTime.to_iso8601(@first),
        "next_hour" => DateTime.to_iso8601(upper)
      }
    }
  end

  defp checkpoint do
    fn _, args ->
      send(self(), {:checkpoint, args})
      {:ok, %Oban.Job{args: args}}
    end
  end

  defp refresh_query(result \\ {:ok, %{rows: []}}) do
    fn sql, params, opts ->
      assert opts[:timeout] == 60_000

      if String.starts_with?(sql, "SELECT to_regclass") do
        {:ok, %{rows: [["aggregate"]]}}
      else
        assert String.starts_with?(sql, "CALL refresh_continuous_aggregate(")
        send(self(), {:refresh, params})
        result
      end
    end
  end
end
