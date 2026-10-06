defmodule ServiceRadarWebNGWeb.Api.EdgeSiteControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0, system_actor: 0]

  alias ServiceRadar.Edge.NatsLeafServer
  alias ServiceRadar.Edge.Workers.ProvisionLeafWorker
  alias ServiceRadarWebNG.Auth.Guardian

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  defmodule LeafIssuerStub do
    @moduledoc false
    def issue(_edge_site) do
      %{cert: der, key: key} = :public_key.pkix_test_root_cert(~c"edge-site-api-test", [])
      cert = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
      key_pem = :public_key.pem_encode([:public_key.pem_entry_encode(elem(key, 0), key)])

      {:ok,
       %{
         leaf_cert_pem: cert,
         leaf_key_pem: key_pem,
         server_cert_pem: cert,
         server_key_pem: key_pem,
         ca_chain_pem: cert
       }}
    end
  end

  setup %{conn: conn} do
    prior_name = Application.get_env(:serviceradar, :nats_account_name)
    prior_seed = Application.get_env(:serviceradar, :nats_account_seed)
    Application.delete_env(:serviceradar, :nats_account_name)
    Application.delete_env(:serviceradar, :nats_account_seed)

    on_exit(fn ->
      restore(:nats_account_name, prior_name)
      restore(:nats_account_seed, prior_seed)
    end)

    %{conn: authed(conn, admin_user_fixture())}
  end

  test "creates, lists, shows and deletes an edge site", %{conn: conn} do
    u = System.unique_integer([:positive])

    created = conn |> post(~p"/api/admin/edge-sites", %{"name" => "NYC Office #{u}"}) |> json_response(201)
    site = created["data"]

    assert site["slug"] == "nyc-office-#{u}"
    assert site["status"] == "pending"
    assert %{"status" => "pending", "upstream_url" => "tls://" <> _} = site["leaf_server"]
    assert site["leaf_server"]["local_listen"] == "0.0.0.0:4222"
    assert site["leaf_server"]["client_url"] == "tls://127.0.0.1:4222"

    listed = conn |> get(~p"/api/admin/edge-sites") |> json_response(200)
    assert Enum.any?(listed["data"], &(&1["id"] == site["id"]))

    shown = conn |> get(~p"/api/admin/edge-sites/#{site["id"]}") |> json_response(200)
    assert shown["data"]["name"] == "NYC Office #{u}"

    assert conn |> delete(~p"/api/admin/edge-sites/#{site["id"]}") |> response(204)
    assert conn |> get(~p"/api/admin/edge-sites/#{site["id"]}") |> json_response(404)
  end

  test "accepts an explicit slug and rejects a missing name", %{conn: conn} do
    u = System.unique_integer([:positive])

    created = conn |> post(~p"/api/admin/edge-sites", %{"name" => "Plant", "slug" => "plant-#{u}"}) |> json_response(201)
    assert created["data"]["slug"] == "plant-#{u}"

    assert conn |> post(~p"/api/admin/edge-sites", %{}) |> json_response(400) == %{"error" => "name is required"}
  end

  test "bundle is 409 leaf_not_ready until the leaf server is provisioned", %{conn: conn} do
    site = create_site(conn)

    assert conn |> post(~p"/api/admin/edge-sites/#{site["id"]}/bundle") |> json_response(409) ==
             %{"error" => "leaf_not_ready"}
  end

  test "bundle is a gzip tarball once provisioned, with no placeholder creds", %{conn: conn} do
    site = create_site(conn)
    provision!(site["id"])

    conn = post(conn, ~p"/api/admin/edge-sites/#{site["id"]}/bundle")
    body = response(conn, 200)
    assert response_content_type(conn, :gzip) =~ "application/gzip"

    {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])
    files = Map.new(files, fn {name, content} -> {to_string(name), IO.iodata_to_binary(content)} end)
    prefix = "edge-site-#{site["slug"]}/"

    for name <- ~w(setup.sh README.md nats/nats-leaf.conf nats/certs/nats-leaf.pem nats/certs/nats-leaf-key.pem
                   nats/certs/nats-server.pem nats/certs/nats-server-key.pem nats/certs/ca-chain.pem) do
      assert Map.has_key?(files, prefix <> name), "missing #{name}"
    end

    refute Map.has_key?(files, prefix <> "creds/account.creds")
    refute Enum.any?(files, fn {_name, body} -> body =~ "PLACEHOLDER" end)
    assert files[prefix <> "nats/nats-leaf.conf"] =~ site["leaf_server"]["upstream_url"]
    refute files[prefix <> "nats/nats-leaf.conf"] =~ "credentials:"
  end

  test "requires settings.edge.manage" do
    conn = authed(build_conn(), viewer_user_fixture())

    assert conn |> get(~p"/api/admin/edge-sites") |> json_response(403)
    assert conn |> post(~p"/api/admin/edge-sites", %{"name" => "x"}) |> json_response(403)
  end

  test "rejects unauthenticated requests" do
    assert build_conn() |> get(~p"/api/admin/edge-sites") |> response(401)
  end

  describe "GET /api/admin/agents" do
    test "lists agents in the edge shape", %{conn: conn} do
      uid = "edge-api-agent-#{System.unique_integer([:positive])}"

      {:ok, _agent} =
        ServiceRadar.Infrastructure.Agent
        |> Ash.Changeset.for_create(:register, %{uid: uid, name: "Edge Agent", metadata: %{"partition_id" => "acme"}})
        |> Ash.create(actor: system_actor())

      body = conn |> get(~p"/api/admin/agents?limit=1000") |> json_response(200)
      agent = Enum.find(body["data"], &(&1["uid"] == uid))

      assert agent["name"] == "Edge Agent"
      assert agent["partition"] == "acme"
      assert agent |> Map.keys() |> Enum.sort() == ~w(gateway_id last_seen name partition status uid version)
    end

    test "requires settings.edge.manage" do
      assert build_conn() |> authed(viewer_user_fixture()) |> get(~p"/api/admin/agents") |> json_response(403)
    end
  end

  describe "GET /api/admin/version" do
    test "returns the running release without the v prefix", %{conn: conn} do
      prior = System.get_env("SERVICERADAR_RELEASE_VERSION")
      System.put_env("SERVICERADAR_RELEASE_VERSION", "v1.4.82")

      on_exit(fn ->
        if prior,
          do: System.put_env("SERVICERADAR_RELEASE_VERSION", prior),
          else: System.delete_env("SERVICERADAR_RELEASE_VERSION")
      end)

      assert conn |> get(~p"/api/admin/version") |> json_response(200) == %{"version" => "1.4.82"}
    end
  end

  defp create_site(conn) do
    u = System.unique_integer([:positive])
    conn |> post(~p"/api/admin/edge-sites", %{"name" => "Site #{u}"}) |> json_response(201) |> Map.fetch!("data")
  end

  defp provision!(site_id) do
    {:ok, leaf_server} =
      NatsLeafServer
      |> Ash.Query.for_read(:by_edge_site, %{edge_site_id: site_id})
      |> Ash.read_one(actor: system_actor())

    :ok =
      ProvisionLeafWorker.perform(%Oban.Job{args: %{"leaf_server_id" => leaf_server.id}},
        certificate_issuer: LeafIssuerStub
      )
  end

  defp authed(conn, user) do
    {:ok, token, _claims} = Guardian.create_access_token(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp restore(key, nil), do: Application.delete_env(:serviceradar, key)
  defp restore(key, value), do: Application.put_env(:serviceradar, key, value)
end
