defmodule ServiceRadarWebNGWeb.Api.AnsibleControllerControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.AnsibleControllersStub

  setup %{conn: conn} do
    previous = Application.get_env(:serviceradar_web_ng, :ansible_controllers)
    previous_pid = Application.get_env(:serviceradar_web_ng, :ansible_controllers_test_pid)

    Application.put_env(:serviceradar_web_ng, :ansible_controllers, AnsibleControllersStub)
    Application.put_env(:serviceradar_web_ng, :ansible_controllers_test_pid, self())

    on_exit(fn ->
      restore_env(:ansible_controllers, previous)
      restore_env(:ansible_controllers_test_pid, previous_pid)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn}
  end

  describe "GET /api/admin/ansible-controllers" do
    test "lists controllers by secret id without tokens", %{conn: conn} do
      conn = get(conn, ~p"/api/admin/ansible-controllers")
      body = json_response(conn, 200)

      assert hd(body)["name"] == "demo-awx"
      assert hd(body)["sync_credential_secret_id"]
      refute Map.has_key?(hd(body), "api_token")
      refute Map.has_key?(hd(body), "sync_awx_api_token")
    end

    test "rejects viewers", %{conn: _conn} do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/admin/ansible-controllers")

      assert conn.status == 403
    end
  end

  describe "POST /api/admin/ansible-controllers" do
    test "creates a controller from secret ids", %{conn: conn} do
      conn =
        post(conn, ~p"/api/admin/ansible-controllers", %{
          "name" => "lab-awx",
          "base_url" => "https://awx.example.com",
          "agent_id" => "agent-site01-01",
          "sync_credential_secret_id" => "00000000-0000-4000-8000-000000000101"
        })

      body = json_response(conn, 201)
      assert body["name"] == "lab-awx"

      assert_receive {:ansible_controllers_create, attrs, _opts}
      refute Map.has_key?(attrs, :credential_secret_id)
      assert attrs[:base_url] == "https://awx.example.com"
      assert attrs[:sync_credential_secret_id] == "00000000-0000-4000-8000-000000000101"
    end
  end

  test "PATCH clears explicit optional credential bindings and preserves omitted fields", %{
    conn: conn
  } do
    id = AnsibleControllersStub.controller().id

    conn =
      patch(conn, ~p"/api/admin/ansible-controllers/#{id}", %{
        "execution_credential_secret_id" => nil,
        "callback_credential_secret_id" => nil
      })

    assert %{"execution_credential_secret_id" => nil, "callback_credential_secret_id" => nil} =
             json_response(conn, 200)

    assert_receive {:ansible_controllers_update, ^id, attrs, _opts}
    assert attrs == %{execution_credential_secret_id: nil, callback_credential_secret_id: nil}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
