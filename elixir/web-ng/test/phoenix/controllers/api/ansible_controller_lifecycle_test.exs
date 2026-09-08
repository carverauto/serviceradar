defmodule ServiceRadarWebNGWeb.Api.AnsibleControllerLifecycleTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.TestSupport.AnsibleControllerLifecycleStub, as: Controllers
  alias ServiceRadarWebNGWeb.Api.AnsibleControllerController, as: Controller

  @moduletag :db_free
  @id "00000000-0000-4000-8000-000000000801"
  @timestamp ~U[2025-04-05 06:07:08.000009Z]

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :ansible_controllers)
    Application.put_env(:serviceradar_web_ng, :ansible_controllers, Controllers)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :ansible_controllers, previous),
        else: Application.delete_env(:serviceradar_web_ng, :ansible_controllers)
    end)

    scope = %Scope{
      user: %{id: "00000000-0000-4000-8000-000000000803"},
      permissions: MapSet.new(["ansible.controllers.manage"])
    }

    %{conn: build_conn() |> assign(:current_scope, scope), scope: scope}
  end

  test "shows current version and applies optional If-Match to existing PATCH API", %{conn: conn, scope: scope} do
    shown = Controller.show(conn, %{"id" => @id})
    assert json_response(shown, 200)["id"] == @id
    assert get_resp_header(shown, "etag") == ["\"#{DateTime.to_iso8601(@timestamp)}\""]

    patched =
      conn
      |> put_req_header("if-match", hd(get_resp_header(shown, "etag")))
      |> Controller.update(%{"id" => @id, "name" => "updated-example"})

    assert json_response(patched, 200)["name"] == "updated-example"
    assert_receive {:update, @id, %{name: "updated-example"}, opts}
    assert opts[:scope] == scope
    assert opts[:expected_updated_at] == @timestamp
  end

  test "deletion requires a version and authorization before calling the context", %{conn: conn, scope: scope} do
    assert {:error, :precondition_required} = Controller.delete(conn, %{"id" => @id})
    denied = assign(conn, :current_scope, %{scope | permissions: MapSet.new()})
    assert {:error, :forbidden} = Controller.delete(denied, %{"id" => @id})
    refute_received {:delete, _, _}
  end

  test "delete conflicts remain visible and success is an empty 204", %{conn: conn} do
    conn = put_req_header(conn, "if-match", "\"#{DateTime.to_iso8601(@timestamp)}\"")

    for reason <- [:controller_in_use, :controller_must_be_disabled] do
      Process.put({Controllers, :delete}, {:error, reason})
      assert json_response(Controller.delete(conn, %{"id" => @id}), 409)["error"] == Atom.to_string(reason)
    end

    Process.put({Controllers, :delete}, {:ok, :ok})
    assert response(Controller.delete(conn, %{"id" => @id}), 204) == ""
  end

  test "readiness reports observed configuration and requires fresh launch preflight", %{conn: conn} do
    body = conn |> Controller.readiness(%{"id" => @id}) |> json_response(200)
    assert body["enabled"] == false
    assert body["observed_health"] == "unknown"
    assert body["credential_configuration"] == %{"sync" => true, "execution" => false, "callback" => false}
    assert body["live_preflight_required"]
    refute Map.has_key?(body, "ready")
    refute Map.has_key?(body, "sync_credential_secret_id")
  end
end
