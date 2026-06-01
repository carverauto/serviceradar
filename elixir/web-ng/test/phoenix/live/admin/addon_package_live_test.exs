defmodule ServiceRadarWebNGWeb.Admin.AddonPackageLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage

  require Ash.Query

  setup %{conn: conn} do
    user = admin_user_fixture()
    %{conn: log_in_user(conn, user), actor: actor_for_user(user)}
  end

  test "approves a staged add-on package with narrowed capabilities", %{conn: conn, actor: actor} do
    package =
      create_addon_package!(actor, %{
        addon_id: "netprobe-review",
        name: "Netprobe Review",
        capabilities: ["flow.capture", "host.process"]
      })

    {:ok, lv, html} = live(conn, ~p"/settings/agents/addons/#{package.id}")

    assert html =~ "Approval review"
    assert html =~ "flow.capture"
    assert html =~ "host.process"

    html =
      lv
      |> form("#approve-addon-#{package.id}", %{
        "review" => %{"approved_capabilities" => ["flow.capture"]}
      })
      |> render_submit()

    assert html =~ "Add-on approved"

    approved = Ash.get!(AddonPackage, package.id, actor: system_actor())
    assert approved.status == :approved
    assert approved.approved_capabilities == ["flow.capture"]
  end

  test "cohort assignment previews unsupported agents and fans out to compatible members", %{
    conn: conn,
    actor: actor
  } do
    gateway = gateway_fixture(%{id: "addon-cohort-gw", component_id: "addon-cohort-component"})

    compatible =
      gateway
      |> agent_fixture(%{uid: "addon-agent-amd64", name: "Addon AMD64"})
      |> put_agent_metadata!(%{"os" => "linux", "arch" => "amd64"})

    unsupported =
      gateway
      |> agent_fixture(%{uid: "addon-agent-arm64", name: "Addon ARM64"})
      |> put_agent_metadata!(%{"os" => "linux", "arch" => "arm64"})

    package =
      create_addon_package!(actor, %{
        addon_id: "netprobe-cohort",
        name: "Netprobe Cohort",
        status: :approved,
        approved_capabilities: ["flow.capture"],
        artifacts: %{
          "linux/amd64" => %{
            "object_key" => "addons/netprobe/linux-amd64.tar",
            "sha256" => "abc",
            "signature" => "sig"
          }
        }
      })

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/addons/#{package.id}")

    params = %{
      "assignment" => %{
        "target_mode" => "cohort",
        "cohort" => "custom",
        "agent_ids" => "#{compatible.uid}, #{unsupported.uid}",
        "params" => "{}",
        "args" => ""
      }
    }

    lv
    |> form("#create-addon-assignment-form", %{
      "assignment" => %{"target_mode" => "cohort"}
    })
    |> render_change()

    lv
    |> form("#create-addon-assignment-form", %{
      "assignment" => %{"target_mode" => "cohort", "cohort" => "custom"}
    })
    |> render_change()

    html =
      lv
      |> form("#create-addon-assignment-form", params)
      |> render_change()

    assert html =~ "Compatibility Preview"
    assert html =~ "1 compatible"
    assert html =~ "1 unsupported"
    assert html =~ unsupported.uid

    html =
      lv
      |> form("#create-addon-assignment-form", params)
      |> render_submit()

    assert html =~ "Add-on assigned to agent."

    assignments =
      AddonAssignment
      |> Ash.Query.for_read(:by_package, %{addon_package_id: package.id})
      |> Ash.read!(actor: system_actor())

    assert Enum.map(assignments, & &1.agent_uid) == [compatible.uid]
  end

  defp create_addon_package!(actor, attrs) do
    defaults = %{
      addon_id: "addon-#{System.unique_integer([:positive])}",
      name: "Live Add-on",
      version: "1.0.0",
      description: "LiveView test add-on",
      kind: :native,
      delivery: :pushed_artifact,
      supervision: :agent_sidecar,
      binary: "serviceradar-addon",
      install_path: "/usr/local/lib/serviceradar/bin",
      capabilities: ["addon.run"],
      config_schema: %{},
      artifacts: %{},
      requires: %{},
      source_type: :first_party,
      source_oci_ref: "registry.carverauto.dev/serviceradar/addon:test",
      source_oci_digest: "sha256:test",
      source_release_tag: "v1.0.0",
      source_metadata: %{},
      imported_at: DateTime.utc_now(),
      verification_status: "verified"
    }

    desired_status = Map.get(attrs, :status, :staged)
    desired_approved_capabilities = Map.get(attrs, :approved_capabilities)
    attrs = defaults |> Map.merge(attrs) |> Map.drop([:status, :approved_capabilities])

    package =
      AddonPackage
      |> Ash.Changeset.for_create(:create, attrs, actor: actor)
      |> Ash.create!()

    if desired_status == :approved do
      package
      |> Ash.Changeset.for_update(
        :approve,
        %{approved_capabilities: desired_approved_capabilities || Map.get(attrs, :capabilities, [])},
        actor: actor
      )
      |> Ash.update!()
    else
      package
    end
  end

  defp put_agent_metadata!(%Agent{} = agent, metadata) do
    agent
    |> Ash.Changeset.for_update(:update, %{metadata: metadata}, actor: system_actor())
    |> Ash.Changeset.force_change_attribute(:last_seen_time, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:status, :connected)
    |> Ash.update!()
  end
end
