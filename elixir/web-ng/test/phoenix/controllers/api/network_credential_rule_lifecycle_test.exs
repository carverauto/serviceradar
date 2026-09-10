defmodule ServiceRadarWebNGWeb.Api.NetworkCredentialRuleLifecycleTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.TestSupport.NetworkCredentialRuleLifecycleStub, as: Credentials
  alias ServiceRadarWebNGWeb.Api.NetworkCredentialRuleController, as: Controller

  @moduletag :db_free
  @id "00000000-0000-4000-8000-000000000901"
  @timestamp ~U[2025-06-07 08:09:10.000011Z]

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :network_credentials)
    Application.put_env(:serviceradar_web_ng, :network_credentials, Credentials)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :network_credentials, previous),
        else: Application.delete_env(:serviceradar_web_ng, :network_credentials)
    end)

    scope = %Scope{
      user: %{id: "00000000-0000-4000-8000-000000000902"},
      permissions: MapSet.new(["settings.credentials.manage"])
    }

    %{conn: assign(build_conn(), :current_scope, scope), scope: scope}
  end

  test "rule deletion requires authority and a current version", %{conn: conn, scope: scope} do
    assert {:error, :precondition_required} = Controller.delete(conn, %{"id" => @id})
    denied = assign(conn, :current_scope, %{scope | permissions: MapSet.new()})
    assert {:error, :forbidden} = Controller.delete(denied, %{"id" => @id})
    refute_received {:delete_rule, _, _}
  end

  test "rule deletion passes scope and concurrency condition and returns actual 204", %{conn: conn, scope: scope} do
    result =
      conn |> put_req_header("if-match", "\"#{DateTime.to_iso8601(@timestamp)}\"") |> Controller.delete(%{"id" => @id})

    assert response(result, 204) == ""
    assert_receive {:delete_rule, @id, opts}
    assert opts[:scope] == scope
    assert opts[:expected_updated_at] == @timestamp
  end

  test "enabled rules and live grants block deletion with a conflict", %{conn: conn} do
    conn = put_req_header(conn, "if-match", "\"#{DateTime.to_iso8601(@timestamp)}\"")

    for reason <- [:credential_rule_must_be_disabled, :credential_rule_in_use] do
      Process.put({Credentials, :result}, {:error, reason})
      assert json_response(Controller.delete(conn, %{"id" => @id}), 409)["error"] == Atom.to_string(reason)
    end
  end
end
