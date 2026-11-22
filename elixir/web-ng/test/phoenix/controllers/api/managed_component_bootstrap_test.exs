defmodule ServiceRadarWebNGWeb.Api.ManagedComponentBootstrapTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Edge.HubReadiness
  alias ServiceRadarWebNGWeb.Api.ManagedComponentController, as: Controller

  @moduletag :db_free

  defmodule FakeCoreProcess do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      reply = Keyword.fetch!(opts, :reply)
      GenServer.start_link(__MODULE__, reply, name: name)
    end

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call(_request, _from, reply), do: {:reply, reply, reply}
  end

  setup do
    previous_auth = Application.get_env(:serviceradar, :nats_certificate_authorization_enabled)
    previous_leaf = Application.get_env(:serviceradar, :nats_leaf_listener_enabled)
    previous_seeds = Application.get_env(:serviceradar, :nats_callout_seeds_dir)
    previous_leaf_url = Application.get_env(:serviceradar, :nats_leaf_upstream_url)

    on_exit(fn ->
      restore_env(:serviceradar, :nats_certificate_authorization_enabled, previous_auth)
      restore_env(:serviceradar, :nats_leaf_listener_enabled, previous_leaf)
      restore_env(:serviceradar, :nats_callout_seeds_dir, previous_seeds)
      restore_env(:serviceradar, :nats_leaf_upstream_url, previous_leaf_url)
    end)

    scope = %Scope{
      user: %{id: "example-operator"},
      permissions: MapSet.new(["settings.edge.manage"])
    }

    %{conn: assign(build_conn(), :current_scope, scope)}
  end

  test "leaf_upstream_url_configured? is false when unset or blank (ignores hosted fallback)" do
    Application.delete_env(:serviceradar, :nats_leaf_upstream_url)
    refute HubReadiness.leaf_upstream_url_configured?()

    Application.put_env(:serviceradar, :nats_leaf_upstream_url, "")
    refute HubReadiness.leaf_upstream_url_configured?()

    Application.put_env(:serviceradar, :nats_leaf_upstream_url, "   ")
    refute HubReadiness.leaf_upstream_url_configured?()

    Application.put_env(:serviceradar, :nats_leaf_upstream_url, "tls://nats-leaf.example.com:7422")
    assert HubReadiness.leaf_upstream_url_configured?()
  end

  test "HubReadiness.fetch/0 fetches core readiness over RPC and merges web-ng's leaf_upstream_url" do
    Application.put_env(:serviceradar, :nats_certificate_authorization_enabled, true)
    Application.put_env(:serviceradar, :nats_leaf_listener_enabled, true)
    Application.delete_env(:serviceradar, :nats_callout_seeds_dir)
    Application.delete_env(:serviceradar, :nats_leaf_upstream_url)

    start_supervised!(
      Supervisor.child_spec(
        {FakeCoreProcess,
         name: ServiceRadar.NATS.ManagedCertificateAuthorization,
         reply: %{auth_mode: "static_mtls", account_name: "SERVICERADAR", ready: true, reason: nil}},
        id: :fake_authorizer
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {FakeCoreProcess,
         name: ServiceRadar.Edge.ChartIdentityInventory,
         reply: %{
           identities: [
             %{
               subject: "CN=serviceradar-core,O=ServiceRadar",
               status: :adopted,
               fingerprint: "aaa",
               reason: nil
             },
             %{
               subject: "CN=serviceradar-web-ng,O=ServiceRadar",
               status: :adopted,
               fingerprint: "bbb",
               reason: nil
             }
           ],
           unlisted: [],
           legacy_certificates: 0
         }},
        id: :fake_inventory
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {FakeCoreProcess, name: ServiceRadar.Edge.RuntimeCertificateRotation, reply: %{}},
        id: :fake_rotation
      )
    )

    assert {:ok, hub} = HubReadiness.fetch()
    assert hub.enforcement_configured == true
    assert hub.authorizer_answering == true
    assert hub.leaf_listener == true
    assert hub.leaf_upstream_url == false
    assert hub.chart_identities.total == 2
    assert hub.chart_identities.adopted == 2

    Application.put_env(:serviceradar, :nats_leaf_upstream_url, "tls://nats-leaf.example.com:7422")
    assert {:ok, hub_with_url} = HubReadiness.fetch()
    assert hub_with_url.leaf_upstream_url == true
  end

  test "HubReadiness.fetch/0 returns core_unavailable when no core authorizer is reachable" do
    assert Process.whereis(ServiceRadar.NATS.ManagedCertificateAuthorization) == nil
    assert HubReadiness.fetch() == {:error, :core_unavailable}
  end

  test "bootstrap refuses access without settings.edge.manage", %{conn: conn} do
    denied = assign(conn, :current_scope, %Scope{user: %{id: "example-viewer"}, permissions: MapSet.new()})

    assert {:error, :forbidden} = Controller.bootstrap(denied, %{})
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
