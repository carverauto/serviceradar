defmodule ServiceRadarWebNGWeb.Admin.ManagedComponentsLiveRenderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Edge.ManagedComponent
  alias ServiceRadarWebNGWeb.Admin.ManagedComponentsLive.Index

  @moduletag :db_free
  @active "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  @retired "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  @generation_retired "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

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

      html = render_inventory([component], %{component.component_id => operation}, %{selected: component.component_id})

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

    html = render_inventory([adopted, unadopted, collector], %{}, %{selected: adopted.component_id})
    doc = LazyHTML.from_fragment(html)

    gateway = LazyHTML.query(doc, "#managed-component-grant-example-gateway")
    assert LazyHTML.text(gateway) =~ "Stored NATS grant"
    assert LazyHTML.text(gateway) =~ "Publish allow: metrics.example.>"
    assert LazyHTML.text(gateway) =~ "Publish deny: (empty)"
    assert LazyHTML.text(gateway) =~ "Subscribe allow: >"
    assert LazyHTML.text(gateway) =~ "Subscribe deny: $SYS.>, flow.example.>"

    core_doc =
      [adopted, unadopted, collector]
      |> render_inventory(%{}, %{selected: unadopted.component_id})
      |> LazyHTML.from_fragment()

    core = LazyHTML.query(core_doc, "#managed-component-grant-example-core")
    assert LazyHTML.text(core) =~ "No stored NATS grant."

    collector_doc =
      [adopted, unadopted, collector]
      |> render_inventory(%{}, %{selected: collector.component_id})
      |> LazyHTML.from_fragment()

    collector_row = LazyHTML.query(collector_doc, "#managed-component-synthetic-log-collector")
    refute LazyHTML.text(collector_row) =~ "Stored NATS grant"
    refute LazyHTML.text(collector_row) =~ "No stored NATS grant."
    assert Enum.empty?(LazyHTML.query(doc, "#managed-component-example-gateway [phx-click=rotate]"))
  end

  test "history revokes one fingerprint and leaves the component enrolled" do
    component = %ManagedComponent{
      component_id: "example-gateway",
      component_type: "agent-gateway",
      host_agent_id: nil,
      generation: 1,
      blocked: false
    }

    html =
      render_inventory([component], %{}, %{
        selected: component.component_id,
        certificates: [
          certificate(@active, 1),
          certificate(@retired, 1),
          certificate(@generation_retired, 2)
        ],
        revoked_fingerprints: MapSet.new([@retired]),
        revoked_generations: MapSet.new([2])
      })

    doc = LazyHTML.from_fragment(html)
    row = LazyHTML.query(doc, "#managed-component-example-gateway")
    active = LazyHTML.query(doc, "#managed-certificate-#{@active}")
    retired = LazyHTML.query(doc, "#managed-certificate-#{@retired}")
    generation = LazyHTML.query(doc, "#managed-certificate-#{@generation_retired}")

    assert LazyHTML.text(row) =~ "Enrollment allowed"
    assert LazyHTML.to_html(row) =~ "Revoke this component and block its automatic renewal?"
    refute Enum.empty?(LazyHTML.query(row, "[phx-click=revoke]"))
    assert Enum.empty?(LazyHTML.query(row, "[phx-click=revoke-certificate]"))

    assert LazyHTML.to_html(active) =~ ~s(phx-click="revoke-certificate")
    assert LazyHTML.to_html(active) =~ ~s(phx-value-id="example-gateway")
    assert LazyHTML.to_html(active) =~ ~s(phx-value-fingerprint="#{@active}")
    assert LazyHTML.to_html(active) =~ "The component stays enrolled."
    assert LazyHTML.text(active) =~ "Revoke fingerprint"
    refute LazyHTML.text(active) =~ "Revoked"
    refute LazyHTML.to_html(active) =~ ~s(phx-click="revoke")

    assert LazyHTML.text(retired) =~ "Revoked"
    assert Enum.empty?(LazyHTML.query(retired, "[phx-click=revoke-certificate]"))
    assert LazyHTML.text(generation) =~ "Revoked"
    assert Enum.empty?(LazyHTML.query(generation, "[phx-click=revoke-certificate]"))
  end

  test "inventory keeps details in a dismissible modal and exposes page navigation" do
    component = %ManagedComponent{
      component_id: "example-collector",
      component_type: "log-collector",
      host_agent_id: "example-host",
      generation: 1,
      blocked: false
    }

    doc = [component] |> render_inventory() |> LazyHTML.from_fragment()
    assert Enum.count(LazyHTML.query(doc, "#managed-components-table tbody tr")) == 1
    assert Enum.count(LazyHTML.query(doc, "button[phx-click=inspect][aria-haspopup=dialog]")) == 1
    assert Enum.empty?(LazyHTML.query(doc, "#component-details-modal"))
    assert Enum.empty?(LazyHTML.query(doc, "[phx-click=revoke]"))
    assert Enum.count(LazyHTML.query(doc, "[phx-click=previous][disabled]")) == 1
    assert Enum.count(LazyHTML.query(doc, "[phx-click=next][disabled]")) == 1

    page =
      [component]
      |> render_inventory(%{}, %{cursor: "example-before", previous_cursors: [nil], more?: true})
      |> LazyHTML.from_fragment()

    assert LazyHTML.text(page) =~ "Page 2"
    assert Enum.empty?(LazyHTML.query(page, "[phx-click=previous][disabled], [phx-click=next][disabled]"))

    details = [component] |> render_inventory(%{}, %{selected: component.component_id}) |> LazyHTML.from_fragment()
    assert Enum.count(LazyHTML.query(details, "dialog#component-details-modal[data-cancel=close]")) == 1
    assert LazyHTML.text(LazyHTML.query(details, "#component-details-modal")) =~ "No certificates issued yet."
    assert Enum.count(LazyHTML.query(details, "#component-details-modal [phx-click=revoke]")) == 1
  end

  defp certificate(fingerprint, generation) do
    %{role: "client", generation: generation, fingerprint: fingerprint, not_after: "2027-06-01"}
  end

  defp render_inventory(components, operations \\ %{}, history \\ %{}) do
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
      selected: Map.get(history, :selected),
      certificates: Map.get(history, :certificates, []),
      revoked_fingerprints: Map.get(history, :revoked_fingerprints, MapSet.new()),
      revoked_generations: Map.get(history, :revoked_generations, MapSet.new()),
      cursor: Map.get(history, :cursor),
      previous_cursors: Map.get(history, :previous_cursors, []),
      more?: Map.get(history, :more?, false)
    )
  end
end
