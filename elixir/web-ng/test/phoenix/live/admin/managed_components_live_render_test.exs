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

      html =
        render_component(&Index.render/1,
          flash: %{},
          current_scope: %{user: %{email: "operator@example.com", role: :admin, timezone: "Etc/UTC"}},
          settings_active_view: nil,
          settings_active_category: nil,
          settings_breadcrumbs: [],
          settings_nav_tree: %{categories: [], groups: []},
          settings_palette: [],
          settings_stats: [],
          components: [component],
          operations: %{component.component_id => operation},
          loading?: false,
          selected: nil,
          certificates: [],
          cursor: nil,
          more?: false
        )

      doc = LazyHTML.from_fragment(html)
      assert LazyHTML.text(doc) =~ "Receiver-observed roles: Not confirmed"
      assert LazyHTML.text(doc) =~ "Revocation enforcement across receivers: unconfirmed."
      assert Enum.empty?(LazyHTML.query(doc, "[phx-click=rotate]")) == blocked
      assert Enum.empty?(LazyHTML.query(doc, "[phx-click=revoke]")) == blocked
      assert Enum.empty?(LazyHTML.query(doc, "[phx-click=reenroll]")) == !blocked
    end
  end
end
