defmodule ServiceRadar.FlowAttribution.CorrelationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.FlowAttribution.Correlation

  @moduletag :db_free

  # Match semantics run in StarRocks and are covered against a live warehouse by
  # test/external/flow_attribution_correlation_live_test.exs. This covers what
  # core does around the statement: the CNPG inputs it renders into it, the
  # workload identity and version it adds, and what it publishes.

  @match_columns ~w(id time attribution_version partition agent_id pid comm cmdline
                    container_id workload_identity match_rank)

  defp match(overrides) do
    base = %{
      "id" => "flow-1",
      "time" => ~N[2026-10-04 12:00:00],
      "attribution_version" => nil,
      "partition" => "default",
      "agent_id" => "agent-a",
      "pid" => 10,
      "comm" => "nginx",
      "cmdline" => "nginx -g daemon",
      "container_id" => nil,
      "workload_identity" => nil,
      "match_rank" => 0
    }

    row = Map.merge(base, overrides)
    Enum.map(@match_columns, &Map.fetch!(row, &1))
  end

  defp cnpg(sql, params, workload_rows, parent) do
    send(parent, {:cnpg, sql, params})

    cond do
      sql =~ "ocsf_agents" ->
        {:ok, %{rows: [["agent-o'brien\\", "192.0.2.1"]]}}

      sql =~ "public_endpoints_current" ->
        {:ok,
         %{
           rows: [
             [
               6,
               "198.51.100.10",
               443,
               "192.0.2.30",
               8443,
               0,
               ~s({"service_name":"example-service"})
             ]
           ]
         }}

      sql =~ "workload_identity_current" ->
        {:ok, %{rows: workload_rows}}

      sql =~ "flow_attribution_update_version" ->
        [count] = params
        {:ok, %{rows: Enum.map(1..count, &[100 + &1])}}
    end
  end

  test "a pass publishes each match with merged workload identity and a superseding version" do
    parent = self()

    matches = [
      match(%{
        "id" => "flow-1",
        "container_id" => "c1",
        "attribution_version" => 500,
        "workload_identity" => ~s({"pod_name":"from-observation","container_id":"c1"})
      }),
      match(%{"id" => "flow-2", "pid" => 20})
    ]

    workload_rows = [
      ["default", "agent-a", "c1", %{"pod_name" => "from-snapshot", "pod_namespace" => "shop"}]
    ]

    publish = fn %{subject: subject, payload: payload} ->
      send(parent, {:published, subject, payload})
      :ok
    end

    assert {{:ok, 2}, %{0 => 2}} =
             Correlation.run_pass(
               enabled: true,
               repo_query: &cnpg(&1, &2, workload_rows, parent),
               query: fn sql ->
                 send(parent, {:starrocks, sql})
                 {:ok, %{columns: @match_columns, rows: matches}}
               end,
               publish: publish
             )

    # The CNPG inputs reach the statement as escaped literals.
    assert_received {:starrocks, sql}
    assert sql =~ ~S|('agent-o\'brien\\', '192.0.2.1')|

    assert sql =~
             ~s|(6, '198.51.100.10', 443, '192.0.2.30', 8443, 0, '{"service_name":"example-service"}')|

    # Workload identity is looked up for the matched container only.
    assert_received {:cnpg, workload_sql, [["default"], ["agent-a"], ["c1"]]}
    assert workload_sql =~ "workload_identity_current"

    assert_received {:published, "events.flow.attribution", first}
    assert_received {:published, "events.flow.attribution", second}

    assert first["id"] == "flow-1"
    assert first["time"] == ~N[2026-10-04 12:00:00]
    # The observation's identity wins; the snapshot fills what it left out.
    assert first["workload_identity"] == %{
             "pod_name" => "from-observation",
             "pod_namespace" => "shop",
             "container_id" => "c1"
           }

    # Above both the flow's stored version and the sequence value it drew.
    assert first["attribution_version"] == 501

    assert second["id"] == "flow-2"
    assert second["workload_identity"] == nil
    assert second["attribution_version"] == 102
  end

  test "a failed warehouse statement fails the pass without publishing" do
    assert {:error, {:starrocks_mysql, "timeout"}} =
             Correlation.correlate(
               enabled: true,
               repo_query: &cnpg(&1, &2, [], self()),
               query: fn _sql -> {:error, {:starrocks_mysql, "timeout"}} end,
               publish: fn _update -> flunk("published after a failed pass") end
             )
  end

  test "without StarRocks the pass touches neither store" do
    assert {:ok, :not_applicable} =
             Correlation.correlate(
               enabled: false,
               repo_query: fn _sql, _params -> flunk("queried CNPG") end,
               query: fn _sql -> flunk("queried StarRocks") end
             )
  end
end
