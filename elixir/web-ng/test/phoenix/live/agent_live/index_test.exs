defmodule ServiceRadarWebNGWeb.AgentLive.IndexTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)

    :persistent_term.put({__MODULE__, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :test_pid})

      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    %{conn: conn}
  end

  test "renders release distribution and filters on the agents index", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/agents")

    assert html =~ "Version Distribution"
    assert html =~ "Rollout States"
    assert html =~ "Target Version"
    assert html =~ "1.2.3"
    assert html =~ "Healthy"
    assert html =~ "Failed"
    assert html =~ "Select Visible"
    assert html =~ "Roll Out Visible Cohort"
    assert html =~ "cohort=custom"
    assert html =~ "agent_ids=agent-1%0Aagent-2"
  end

  test "builds a selected-agent rollout handoff from explicit inventory selection", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/agents")

    lv
    |> element("#select-agent-agent-2")
    |> render_click()

    html = render(lv)

    assert html =~ "Roll Out Selected"
    assert html =~ "agent_ids=agent-2"
    assert html =~ "source=agents_selection"
  end

  test "applies rollout filters through the agents index controls", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/agents")

    lv
    |> form("#agent-release-filters-form", %{
      "filters" => %{
        "release_rollout_state" => "failed",
        "desired_version" => "2.0.0"
      }
    })
    |> render_submit()

    queries = collect_srql_queries([])

    assert Enum.any?(queries, fn query ->
             String.contains?(query, "release_rollout_state:failed") and
               String.contains?(query, "desired_version:2.0.0")
           end)
  end

  defp collect_srql_queries(acc) do
    receive do
      {:srql_query, query} when is_binary(query) ->
        collect_srql_queries([query | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defmodule RecordingSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query) when is_binary(query), do: query(query, %{})

    def query(query, _opts) when is_binary(query) do
      case :persistent_term.get({ServiceRadarWebNGWeb.AgentLive.IndexTest, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:srql_query, query})
        _ -> :ok
      end

      {:ok,
       %{
         "results" => sample_agents(),
         "pagination" => %{},
         "error" => nil
       }}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp sample_agents do
      [
        %{
          "uid" => "agent-1",
          "name" => "Alpha",
          "gateway_id" => "gw-1",
          "version" => "1.2.3",
          "desired_version" => "1.2.3",
          "release_rollout_state" => "healthy",
          "last_update_at" => "2026-03-27T18:00:00Z",
          "last_seen_time" => "2026-03-27T18:01:00Z",
          "capabilities" => ["agent"]
        },
        %{
          "uid" => "agent-2",
          "name" => "Beta",
          "gateway_id" => "gw-2",
          "version" => "1.1.0",
          "desired_version" => "2.0.0",
          "release_rollout_state" => "failed",
          "last_update_error" => "digest mismatch",
          "last_update_at" => "2026-03-27T18:02:00Z",
          "last_seen_time" => "2026-03-27T18:03:00Z",
          "capabilities" => ["agent"]
        }
      ]
    end
  end
end
