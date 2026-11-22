defmodule ServiceRadarWebNGWeb.Api.ManagedComponentBootstrapTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Edge.HubReadiness
  alias ServiceRadarWebNGWeb.Api.ManagedComponentController, as: Controller

  @moduletag :db_free

  setup do
    previous_fetcher = Application.get_env(:serviceradar_web_ng, :hub_readiness_fetcher)
    previous_leaf_url = Application.get_env(:serviceradar, :nats_leaf_upstream_url)

    on_exit(fn ->
      restore_env(:serviceradar_web_ng, :hub_readiness_fetcher, previous_fetcher)
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

  test "HubReadiness.fetch/0 merges core readiness with web-ng's leaf_upstream_url" do
    core_hub = %{
      enforcement_configured: true,
      authorizer_answering: true,
      authorizer_reason: nil,
      signing_keys_provisioned: true,
      leaf_listener: true,
      chart_identities: %{total: 2, adopted: 2, legacy_certificates: 0, not_adopted: [], unlisted: []}
    }

    Application.put_env(:serviceradar_web_ng, :hub_readiness_fetcher, fn -> {:ok, core_hub} end)
    Application.delete_env(:serviceradar, :nats_leaf_upstream_url)

    assert {:ok, hub} = HubReadiness.fetch()
    assert hub.enforcement_configured == true
    assert hub.authorizer_answering == true
    assert hub.leaf_listener == true
    assert hub.leaf_upstream_url == false

    Application.put_env(:serviceradar, :nats_leaf_upstream_url, "tls://nats-leaf.example.com:7422")
    assert {:ok, hub_with_url} = HubReadiness.fetch()
    assert hub_with_url.leaf_upstream_url == true
  end

  test "HubReadiness.fetch/0 propagates core_unavailable when core cannot be reached" do
    Application.put_env(:serviceradar_web_ng, :hub_readiness_fetcher, fn ->
      {:error, :core_unavailable}
    end)

    assert HubReadiness.fetch() == {:error, :core_unavailable}
  end

  test "bootstrap refuses access without settings.edge.manage", %{conn: conn} do
    denied = assign(conn, :current_scope, %Scope{user: %{id: "example-viewer"}, permissions: MapSet.new()})

    assert {:error, :forbidden} = Controller.bootstrap(denied, %{})
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
