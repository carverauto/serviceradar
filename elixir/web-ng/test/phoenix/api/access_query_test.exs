defmodule ServiceRadarWebNG.Api.AccessQueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Api.Access

  @moduletag :db_free

  defmodule ScopeProbe do
    @moduledoc false
    def query_request(params) do
      send(self(), {:srql_request, params})
      {:ok, %{"results" => [], "pagination" => %{}}}
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, ScopeProbe)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, previous)
      end
    end)

    :ok
  end

  test "execute_query puts current_scope on the SRQL request" do
    scope =
      %Scope{
        user: %{id: "user-1", email: "viewer@localhost"},
        permissions: MapSet.new(["devices.view"])
      }

    assert {:ok, _} = Access.execute_query(scope, %{"query" => "in:devices"})
    assert_received {:srql_request, params}
    assert params["scope"] == scope
    assert params["query"] == "in:devices"
  end

  test "execute_query does not call SRQL when the catalog key is missing" do
    scope =
      %Scope{
        user: %{id: "user-1", email: "custom@localhost"},
        permissions: MapSet.new(["observability.logs.view"])
      }

    assert {:error, :forbidden} = Access.execute_query(scope, %{"query" => "in:devices"})
    refute_received {:srql_request, _}
  end
end
