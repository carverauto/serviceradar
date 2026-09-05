defmodule ServiceRadarWebNGWeb.Api.NetworkCredentialSecretControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.NetworkCredentialsStub

  setup %{conn: conn} do
    previous = Application.get_env(:serviceradar_web_ng, :network_credentials)
    previous_pid = Application.get_env(:serviceradar_web_ng, :network_credentials_test_pid)

    Application.put_env(:serviceradar_web_ng, :network_credentials, NetworkCredentialsStub)
    Application.put_env(:serviceradar_web_ng, :network_credentials_test_pid, self())

    on_exit(fn ->
      restore_env(:network_credentials, previous)
      restore_env(:network_credentials_test_pid, previous_pid)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn}
  end

  describe "GET /api/admin/network-credential-secrets" do
    test "lists secrets without payloads", %{conn: conn} do
      conn = get(conn, ~p"/api/admin/network-credential-secrets")
      body = json_response(conn, 200)

      assert length(body) == 1
      assert hd(body)["name"] == "demo-proxmox-readonly"
      assert hd(body)["provider"] == "proxmox"
      refute Map.has_key?(hd(body), "secret_payload")
      refute Map.has_key?(hd(body), "encrypted_secret_payload")
      refute inspect(body) =~ "MUST-NOT-LEAK"
    end

    test "rejects viewers", %{conn: _conn} do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/admin/network-credential-secrets")

      assert conn.status == 403
    end
  end

  describe "POST /api/admin/network-credential-secrets" do
    test "creates a secret from descriptor values", %{conn: conn} do
      conn =
        post(conn, ~p"/api/admin/network-credential-secrets", %{
          "name" => "lab-proxmox",
          "provider" => "proxmox",
          "auth_method" => "proxmox_api_token",
          "values" => %{
            "user" => "root",
            "realm" => "pam",
            "token_id" => "demo",
            "token_secret" => "synthetic-token"
          }
        })

      body = json_response(conn, 201)
      assert body["name"] == "lab-proxmox"
      refute Map.has_key?(body, "secret_payload")

      assert_receive {:network_credentials_create_secret, attrs, _opts}
      assert attrs["provider"] == "proxmox"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
