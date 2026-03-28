defmodule ServiceRadarWebNGWeb.Settings.AgentsReleasesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true
  use ServiceRadarWebNG.AshTestHelpers

  import Ash.Expr
  import Phoenix.LiveViewTest

  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Edge.AgentReleaseRollout
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query
  @release_public_key "ot8W1BsqSvXV7KEjLL+RkQz106lzcIJNCY91OXSqBpk="
  @release_private_key "kRqU4UnTUPjychwJGH4ZdsuijaxuGUNFPezyY+iSnBY="

  setup :register_and_log_in_admin_user

  setup_all do
    previous = Application.get_env(:serviceradar_core, :agent_release_public_key)
    Application.put_env(:serviceradar_core, :agent_release_public_key, @release_public_key)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, :agent_release_public_key)
      else
        Application.put_env(:serviceradar_core, :agent_release_public_key, previous)
      end
    end)

    :ok
  end

  test "renders releases settings page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/agents/releases")

    assert html =~ "Agent Releases"
    assert html =~ "Publish Release"
    assert html =~ "Create Rollout"
  end

  test "prefills the rollout form from agent inventory handoff params", %{conn: conn} do
    params = %{
      "version" => "4.2.0",
      "cohort" => "custom",
      "agent_ids" => "agent-a\nagent-b",
      "notes" => "Imported from /agents inventory view",
      "source" => "agents"
    }

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/releases?#{params}")

    assert html =~ "Prefilled 2 visible agents from the inventory view."
    assert html =~ ~s(value="4.2.0")
    assert html =~ "agent-a"
    assert html =~ "agent-b"
    assert html =~ "Imported from /agents inventory view"
  end

  test "publishes a release from the UI", %{conn: conn, scope: scope} do
    version = "2.0.#{System.unique_integer([:positive])}"
    manifest = release_manifest(version)
    signature = sign_manifest(manifest)

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    lv
    |> form("#publish-release-form", %{
        "release" => %{
          "version" => version,
          "signature" => signature,
          "artifact_url" => "https://example.test/releases/#{version}/serviceradar-agent.tar.gz",
          "artifact_sha256" => String.duplicate("a", 64),
          "artifact_format" => "tar.gz",
        "entrypoint" => "serviceradar-agent",
        "os" => "linux",
        "arch" => "amd64",
        "release_notes" => "Release #{version}"
      }
    })
    |> render_submit()

    assert render(lv) =~ "Published agent release #{version}"
    assert has_element?(lv, "td", version)

    release =
      AgentRelease
      |> Ash.Query.for_read(:by_version, %{version: version})
      |> Ash.read_one!(scope: scope)

    assert release.version == version
    assert release.signature == signature
  end

  test "creates a rollout for connected agents from the UI", %{conn: conn, scope: scope} do
    version = "3.0.#{System.unique_integer([:positive])}"
    manifest = release_manifest(version)

    {:ok, _release} =
      AgentReleaseManager.publish_release(
        %{
          version: version,
          signature: sign_manifest(manifest),
          manifest: manifest
        },
        scope: scope
      )

    gateway = gateway_fixture()
    agent_id = "agent-release-ui-#{System.unique_integer([:positive])}"

    _agent =
      Agent
      |> Ash.Changeset.for_create(:register_connected, %{
        uid: agent_id,
        name: "Release Test Agent",
        gateway_id: gateway.id,
        version: "1.0.0",
        type_id: 4,
        type: "Performance",
        capabilities: ["agent"],
        metadata: %{"os" => "linux", "arch" => "amd64"}
      }, actor: system_actor())
      |> Ash.create!()

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    lv
    |> form("#create-rollout-form", %{
      "rollout" => %{
        "version" => version,
        "cohort" => "connected",
        "batch_size" => "1",
        "batch_delay_seconds" => "0",
        "agent_ids" => "",
        "notes" => "Roll out #{version}"
      }
    })
    |> render_submit()

    assert render(lv) =~ "Created rollout for #{version} targeting 1 agents"
    assert has_element?(lv, "td", version)

    rollout =
      AgentReleaseRollout
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(desired_version == ^version))
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
      |> List.first()

    assert rollout
    assert rollout.cohort_agent_ids == [agent_id]

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(rollout_id == ^rollout.id and agent_id == ^agent_id))
      |> Ash.read_one!(scope: scope)

    assert target.status == :pending
    assert target.desired_version == version
  end

  test "viewer is blocked from releases settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/agents/releases")
    assert to == ~p"/settings/profile"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp release_manifest(version) do
    %{
      "version" => version,
      "artifacts" => [
        %{
          "os" => "linux",
          "arch" => "amd64",
          "format" => "tar.gz",
          "entrypoint" => "serviceradar-agent",
          "url" => "https://example.test/releases/#{version}/serviceradar-agent.tar.gz",
          "sha256" => String.duplicate("a", 64)
        }
      ]
    }
  end

  defp sign_manifest(manifest) do
    {:ok, payload} = ServiceRadar.Edge.ReleaseManifestValidator.canonical_json(manifest)
    private_key = Base.decode64!(@release_private_key)

    :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
    |> Base.encode64()
  end
end
