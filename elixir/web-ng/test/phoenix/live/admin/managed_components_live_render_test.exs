defmodule ServiceRadarWebNGWeb.Admin.ManagedComponentsLiveRenderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadarWebNGWeb.Admin.ManagedComponentsLive.Index

  @moduletag :db_free

  setup_all do
    case ServiceRadarWebNGWeb.Endpoint.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  test "activation never claims receiver enforcement and revoked components only offer re-enrollment" do
    for blocked <- [false, true] do
      component = %ManagedComponent{
        component_id: "synthetic-log-collector",
        component_type: "log-collector",
        host_agent_id: "synthetic-host",
        generation: 3,
        blocked: blocked
      }

      operation = %{
        status: :activated,
        receipt: %{"installed" => true, "activated" => true},
        observed_roles: %{},
        renew_after: ~U[2026-01-02 00:00:00Z],
        error: nil
      }

      html = render_inventory([component], %{component.component_id => operation})

      doc = LazyHTML.from_fragment(html)
      assert LazyHTML.text(doc) =~ "Receiver-observed roles: Not confirmed"
      assert LazyHTML.text(doc) =~ "Revocation enforcement across receivers: unconfirmed."
      refute LazyHTML.text(doc) =~ "Stored NATS grant"
      refute LazyHTML.text(doc) =~ "No stored NATS grant."
      assert Enum.empty?(LazyHTML.query(doc, "[phx-click=rotate]")) == blocked
      assert Enum.empty?(LazyHTML.query(doc, "[phx-click=revoke]")) == blocked
      assert Enum.empty?(LazyHTML.query(doc, "[phx-click=reenroll]")) == !blocked
    end
  end

  test "shows a stored infrastructure grant and a missing grant without labeling a host service" do
    adopted = %ManagedComponent{
      component_id: "example-gateway",
      component_type: "agent-gateway",
      host_agent_id: nil,
      generation: 1,
      blocked: false,
      nats_permissions: %{
        "publish" => ["metrics.example.>"],
        "publish_deny" => [],
        "subscribe" => [">"],
        "subscribe_deny" => ["$SYS.>", "flow.example.>"]
      }
    }

    unadopted = %ManagedComponent{
      component_id: "example-core",
      component_type: "core",
      host_agent_id: nil,
      generation: 1,
      blocked: false,
      nats_permissions: nil
    }

    collector = %ManagedComponent{
      component_id: "synthetic-log-collector",
      component_type: "log-collector",
      host_agent_id: "synthetic-host",
      generation: 3,
      blocked: false
    }

    html = render_inventory([adopted, unadopted, collector])
    doc = LazyHTML.from_fragment(html)

    gateway = LazyHTML.query(doc, "#managed-component-grant-example-gateway")
    assert LazyHTML.text(gateway) =~ "Stored NATS grant"
    assert LazyHTML.text(gateway) =~ "Publish allow: metrics.example.>"
    assert LazyHTML.text(gateway) =~ "Publish deny: (empty)"
    assert LazyHTML.text(gateway) =~ "Subscribe allow: >"
    assert LazyHTML.text(gateway) =~ "Subscribe deny: $SYS.>, flow.example.>"

    core = LazyHTML.query(doc, "#managed-component-grant-example-core")
    assert LazyHTML.text(core) =~ "No stored NATS grant."

    collector_row = LazyHTML.query(doc, "#managed-component-synthetic-log-collector")
    refute LazyHTML.text(collector_row) =~ "Stored NATS grant"
    refute LazyHTML.text(collector_row) =~ "No stored NATS grant."
    assert Enum.empty?(LazyHTML.query(doc, "#managed-component-example-gateway [phx-click=rotate]"))
  end

  defp render_inventory(components, operations \\ %{}) do
    render_component(&Index.render/1,
      flash: %{},
      current_scope: %{user: %{email: "operator@example.com", role: :admin, timezone: "Etc/UTC"}},
      settings_active_view: nil,
      settings_active_category: nil,
      settings_breadcrumbs: [],
      settings_nav_tree: %{categories: [], groups: []},
      settings_palette: [],
      settings_stats: [],
      components: components,
      operations: operations,
      loading?: false,
      selected: nil,
      certificates: [],
      cursor: nil,
      more?: false
    )
  end
end
