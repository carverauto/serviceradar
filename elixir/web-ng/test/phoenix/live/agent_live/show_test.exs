defmodule ServiceRadarWebNGWeb.AgentLive.ShowTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    old = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, __MODULE__.RecordingSRQLStub)

    on_exit(fn ->
      if is_nil(old) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, old)
      end
    end)

    %{conn: conn}
  end

  test "operator sees release-management handoff actions on the agent detail page", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/agents/agent-1")

    assert html =~ "Release Management"
    assert html =~ "Roll Out This Agent"
    assert html =~ "Manage Releases"
    assert html =~ "cohort=custom"
    assert html =~ "agent_ids=agent-1"
    assert html =~ "version=2.0.0"
  end

  test "viewer can inspect agent detail but does not see rollout actions", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/agents/agent-1")

    assert html =~ "Release Management"
    refute html =~ "Roll Out This Agent"
    refute html =~ "Manage Releases"
  end

  defmodule RecordingSRQLStub do
    @moduledoc false
    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query) when is_binary(query), do: query(query, %{})

    def query(query, _opts) when is_binary(query) do
      {:ok,
       %{
         "results" => sample_agents(query),
         "pagination" => %{},
         "error" => nil
       }}
    end

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    defp sample_agents(query) do
      if String.contains?(query, ~s(uid:"agent-1")) do
        [
          %{
            "uid" => "agent-1",
            "name" => "Alpha",
            "gateway_id" => "gw-1",
            "version" => "1.2.3",
            "desired_version" => "2.0.0",
            "release_rollout_state" => "failed",
            "last_update_error" => "digest mismatch",
            "last_update_at" => "2026-03-27T18:02:00Z",
            "last_seen_time" => "2026-03-27T18:03:00Z",
            "capabilities" => ["agent"]
          }
        ]
      else
        []
      end
    end
  end
end
