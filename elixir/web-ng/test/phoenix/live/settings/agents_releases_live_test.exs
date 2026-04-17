defmodule ServiceRadarWebNGWeb.Settings.AgentsReleasesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Ash.Expr
  import Phoenix.LiveViewTest

  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Edge.AgentReleaseRollout
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Edge.ReleaseManifestValidator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  @release_public_key "ot8W1BsqSvXV7KEjLL+RkQz106lzcIJNCY91OXSqBpk="
  @release_private_key "kRqU4UnTUPjychwJGH4ZdsuijaxuGUNFPezyY+iSnBY="

  defmodule ReleaseImportClient do
    @moduledoc false
    @release_private_key "kRqU4UnTUPjychwJGH4ZdsuijaxuGUNFPezyY+iSnBY="

    def get(url, _opts) do
      cond do
        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases?per_page=") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [
               %{
                 "tag_name" => "v7.0.0",
                 "name" => "ServiceRadar 7.0.0",
                 "body" => "Imported release notes",
                 "html_url" => "https://code.carverauto.dev/carverauto/serviceradar/releases/tag/v7.0.0",
                 "published_at" => "2026-03-28T20:00:00Z",
                 "assets" => [
                   %{
                     "name" => "serviceradar-agent-release-manifest.json",
                     "browser_download_url" =>
                       "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v7.0.0/manifest.json"
                   },
                   %{
                     "name" => "serviceradar-agent-release-manifest.sig",
                     "browser_download_url" =>
                       "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v7.0.0/manifest.sig"
                   }
                 ]
               },
               %{
                 "tag_name" => "v6.9.9",
                 "name" => "ServiceRadar 6.9.9",
                 "body" => "Missing manifest",
                 "html_url" => "https://code.carverauto.dev/carverauto/serviceradar/releases/tag/v6.9.9",
                 "published_at" => "2026-03-27T20:00:00Z",
                 "assets" => [
                   %{
                     "name" => "serviceradar-agent-release-manifest.sig",
                     "browser_download_url" =>
                       "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v6.9.9/manifest.sig"
                   }
                 ]
               }
             ]
           }}

        String.contains?(url, "/api/v1/repos/carverauto/serviceradar/releases/tags/v7.0.0") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "tag_name" => "v7.0.0",
               "name" => "ServiceRadar 7.0.0",
               "body" => "Imported release notes",
               "html_url" => "https://code.carverauto.dev/carverauto/serviceradar/releases/tag/v7.0.0",
               "assets" => [
                 %{
                   "name" => "serviceradar-agent-release-manifest.json",
                   "browser_download_url" =>
                     "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v7.0.0/manifest.json"
                 },
                 %{
                   "name" => "serviceradar-agent-release-manifest.sig",
                   "browser_download_url" =>
                     "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v7.0.0/manifest.sig"
                 }
               ]
             }
           }}

        String.ends_with?(url, "/manifest.json") ->
          manifest = release_manifest("7.0.0")
          {:ok, %Req.Response{status: 200, body: Jason.encode!(manifest)}}

        String.ends_with?(url, "/manifest.sig") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: "7.0.0" |> release_manifest() |> sign_manifest() |> Kernel.<>("\n")
           }}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
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
            "url" =>
              "https://code.carverauto.dev/carverauto/serviceradar/releases/download/v#{version}/serviceradar-agent-linux-amd64.tar.gz",
            "sha256" => String.duplicate("a", 64)
          }
        ]
      }
    end

    defp sign_manifest(manifest) do
      {:ok, payload} = ReleaseManifestValidator.canonical_json(manifest)
      private_key = Base.decode64!(@release_private_key)

      :eddsa
      |> :crypto.sign(:none, payload, [private_key, :ed25519])
      |> Base.encode64()
    end
  end

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

  setup do
    original_client = Application.get_env(:serviceradar_web_ng, :agent_release_import_http_client)

    on_exit(fn ->
      if is_nil(original_client) do
        Application.delete_env(:serviceradar_web_ng, :agent_release_import_http_client)
      else
        Application.put_env(
          :serviceradar_web_ng,
          :agent_release_import_http_client,
          original_client
        )
      end
    end)

    :ok
  end

  test "renders releases settings page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/agents/releases")

    assert html =~ "Agent Releases"
    assert html =~ "Publish Release"
    assert html =~ "Create Rollout"
    assert html =~ "https://code.carverauto.dev/carverauto/serviceradar"
    refute html =~ "Release Provider"
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

  test "prefills the rollout form from selected inventory agents", %{conn: conn} do
    params = %{
      "version" => "4.2.1",
      "cohort" => "custom",
      "agent_ids" => "agent-a\nagent-b\nagent-c",
      "notes" => "Imported from selected /agents rows",
      "source" => "agents_selection"
    }

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/releases?#{params}")

    assert html =~ "Prefilled 3 selected agents from the inventory view."
    assert html =~ "Imported from selected /agents rows"
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
    assert render(lv) =~ "linux/amd64"

    release =
      AgentRelease
      |> Ash.Query.for_read(:by_version, %{version: version})
      |> Ash.read_one!(scope: scope)

    assert release.version == version
    assert release.signature == signature
  end

  test "imports and publishes a release from a repository release", %{conn: conn, scope: scope} do
    Application.put_env(
      :serviceradar_web_ng,
      :agent_release_import_http_client,
      ReleaseImportClient
    )

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    lv
    |> form("#import-release-form", %{
      "release_import" => %{
        "repo_url" => "https://code.carverauto.dev/carverauto/serviceradar",
        "release_tag" => "v7.0.0",
        "manifest_asset_name" => "serviceradar-agent-release-manifest.json",
        "signature_asset_name" => "serviceradar-agent-release-manifest.sig"
      }
    })
    |> render_submit()

    assert render(lv) =~ "Imported and published agent release 7.0.0 from Forgejo Releases"
    assert render(lv) =~ "Forgejo Releases"
    assert render(lv) =~ "carverauto/serviceradar"

    release =
      AgentRelease
      |> Ash.Query.for_read(:by_version, %{version: "7.0.0"})
      |> Ash.read_one!(scope: scope)

    assert release.release_notes == "Imported release notes"
    assert get_in(release.metadata, ["source", "provider"]) == "forgejo"
    assert get_in(release.metadata, ["source", "release_tag"]) == "v7.0.0"
  end

  test "loads recent repository releases automatically and disables missing-asset imports", %{
    conn: conn
  } do
    Application.put_env(
      :serviceradar_web_ng,
      :agent_release_import_http_client,
      ReleaseImportClient
    )

    {:ok, lv, html} = live(conn, ~p"/settings/agents/releases")

    assert html =~ "Recent Repository Releases"
    assert html =~ "v7.0.0"
    assert html =~ "v6.9.9"
    assert has_element?(lv, "button[phx-value-release_tag='v7.0.0']:not([disabled])")
    assert has_element?(lv, "button[phx-value-release_tag='v6.9.9'][disabled]")
  end

  test "imports a recent repository release with one click", %{conn: conn, scope: scope} do
    Application.put_env(
      :serviceradar_web_ng,
      :agent_release_import_http_client,
      ReleaseImportClient
    )

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    lv
    |> element("button[phx-value-release_tag='v7.0.0']")
    |> render_click()

    assert render(lv) =~ "Imported and published agent release 7.0.0 from Forgejo Releases"

    release =
      AgentRelease
      |> Ash.Query.for_read(:by_version, %{version: "7.0.0"})
      |> Ash.read_one!(scope: scope)

    assert release.version == "7.0.0"
  end

  test "shows rollout compatibility preview for the connected cohort", %{conn: conn, scope: scope} do
    version = "2.1.#{System.unique_integer([:positive])}"
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

    for {agent_id, arch} <- [
          {"agent-preview-compatible-#{System.unique_integer([:positive])}", "amd64"},
          {"agent-preview-unsupported-#{System.unique_integer([:positive])}", "arm64"}
        ] do
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Preview Agent #{arch}",
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => arch}
        },
        actor: system_actor()
      )
      |> Ash.create!()
    end

    {:ok, lv, html} = live(conn, ~p"/settings/agents/releases")

    assert html =~ "Compatibility Preview"
    assert html =~ "Current connected cohort"
    assert html =~ "2 selected"
    assert html =~ "1 compatible"
    assert html =~ "1 unsupported"
    assert html =~ "Release Supports"
    assert html =~ "linux/amd64"
    assert html =~ "linux/arm64"
    assert html =~ "Unsupported Targets"

    assert html =~
             "Unsupported agents will be skipped; the rollout will target the compatible subset."

    refute has_element?(lv, "#create-rollout-form button[disabled]")
  end

  test "treats atom-key agent metadata as compatible in rollout preview", %{
    conn: conn,
    scope: scope
  } do
    version = "2.2.#{System.unique_integer([:positive])}"
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

    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: "agent-preview-atom-#{System.unique_integer([:positive])}",
        name: "Atom Metadata Agent",
        gateway_id: gateway.id,
        version: "1.0.0",
        type_id: 4,
        type: "Performance",
        capabilities: ["agent"],
        metadata: %{os: "linux", arch: "amd64"}
      },
      actor: system_actor()
    )
    |> Ash.create!()

    {:ok, lv, html} = live(conn, ~p"/settings/agents/releases")

    assert html =~ "Compatibility Preview"
    assert html =~ "1 selected"
    assert html =~ "1 compatible"
    refute html =~ "1 unsupported"
    refute html =~ "unknown platform"
    refute has_element?(lv, "#create-rollout-form button[disabled]")
  end

  test "ignores container-managed agents in the connected rollout cohort", %{
    conn: conn,
    scope: scope
  } do
    version = "2.3.#{System.unique_integer([:positive])}"
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

    for attrs <- [
          %{
            uid: "agent-preview-host-#{System.unique_integer([:positive])}",
            name: "Host Agent",
            metadata: %{"os" => "linux", "arch" => "amd64", "deployment_type" => "bare-metal"}
          },
          %{
            uid: "agent-preview-docker-#{System.unique_integer([:positive])}",
            name: "Docker Agent",
            metadata: %{"os" => "linux", "arch" => "amd64", "deployment_type" => "docker"}
          },
          %{
            uid: "agent-preview-k8s-#{System.unique_integer([:positive])}",
            name: "Kubernetes Agent",
            metadata: %{"os" => "linux", "arch" => "amd64", "deployment_type" => "kubernetes"}
          }
        ] do
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: attrs.uid,
          name: attrs.name,
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: attrs.metadata
        },
        actor: system_actor()
      )
      |> Ash.create!()
    end

    {:ok, lv, html} = live(conn, ~p"/settings/agents/releases")

    assert html =~ "1 selected"
    assert html =~ "1 compatible"
    refute html =~ "3 selected"
    refute html =~ "Unsupported agents will be skipped"
    refute has_element?(lv, "#create-rollout-form button[disabled]")
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
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Release Test Agent",
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => "amd64"}
        },
        actor: system_actor()
      )
      |> Ash.create!()

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    refute has_element?(lv, "#create-rollout-form button[disabled]")

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

  test "custom cohorts ignore container-managed agents", %{conn: conn, scope: scope} do
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

    host_id = "agent-preview-custom-host-#{System.unique_integer([:positive])}"
    docker_id = "agent-preview-custom-docker-#{System.unique_integer([:positive])}"
    k8s_id = "agent-preview-custom-k8s-#{System.unique_integer([:positive])}"

    for attrs <- [
          %{
            uid: host_id,
            name: "Host Agent",
            metadata: %{"os" => "linux", "arch" => "amd64", "deployment_type" => "bare-metal"}
          },
          %{
            uid: docker_id,
            name: "Docker Agent",
            metadata: %{"os" => "linux", "arch" => "amd64", "deployment_type" => "docker"}
          },
          %{
            uid: k8s_id,
            name: "Kubernetes Agent",
            metadata: %{"os" => "linux", "arch" => "amd64", "deployment_type" => "kubernetes"}
          }
        ] do
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: attrs.uid,
          name: attrs.name,
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: attrs.metadata
        },
        actor: system_actor()
      )
      |> Ash.create!()
    end

    {:ok, lv, html} = live(conn, ~p"/settings/agents/releases")

    html =
      lv
      |> form("#create-rollout-form", %{
        "rollout" => %{
          "version" => version,
          "cohort" => "custom",
          "batch_size" => "1",
          "batch_delay_seconds" => "0",
          "agent_ids" => Enum.join([host_id, docker_id, k8s_id], "\n"),
          "notes" => "custom cohort filter"
        }
      })
      |> render_submit()

    assert html =~ "Created rollout for #{version} targeting 1 agents"

    rollout =
      AgentReleaseRollout
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(desired_version == ^version))
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
      |> List.first()

    assert rollout
    assert rollout.cohort_agent_ids == [host_id]
  end

  test "updates rollout compatibility preview for custom cohorts with unresolved ids", %{
    conn: conn,
    scope: scope
  } do
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
    agent_id = "agent-preview-custom-#{System.unique_integer([:positive])}"

    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_id,
        name: "Custom Preview Agent",
        gateway_id: gateway.id,
        version: "1.0.0",
        type_id: 4,
        type: "Performance",
        capabilities: ["agent"],
        metadata: %{"os" => "linux", "arch" => "amd64"}
      },
      actor: system_actor()
    )
    |> Ash.create!()

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    html =
      lv
      |> form("#create-rollout-form", %{
        "rollout" => %{
          "version" => version,
          "cohort" => "custom",
          "batch_size" => "1",
          "batch_delay_seconds" => "0",
          "agent_ids" => "#{agent_id}\nmissing-agent-1",
          "notes" => "preview"
        }
      })
      |> render_change()

    assert html =~ "Compatibility Preview"
    assert html =~ "Current custom cohort"
    assert html =~ "2 selected"
    assert html =~ "1 compatible"
    assert html =~ "1 unresolved"
    assert html =~ "Unresolved Agent IDs"
    assert html =~ "missing-agent-1"

    assert html =~
             "Rollout creation is blocked until unresolved agent IDs are corrected or removed."

    assert has_element?(lv, "#create-rollout-form button[disabled]")
  end

  test "shows detailed rollout progress badges for per-agent states", %{conn: conn, scope: scope} do
    version = "3.1.#{System.unique_integer([:positive])}"
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
    agent_id = "agent-release-progress-#{System.unique_integer([:positive])}"

    _agent =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Progress Test Agent",
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => "amd64"}
        },
        actor: system_actor()
      )
      |> Ash.create!()

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(
        %{
          version: version,
          agent_ids: [agent_id],
          batch_size: 1,
          batch_delay_seconds: 0,
          notes: "progress badges"
        },
        scope: scope
      )

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(rollout_id == ^rollout.id and agent_id == ^agent_id))
      |> Ash.read_one!(scope: scope)

    {:ok, _target} =
      AgentReleaseTarget.set_status(
        target,
        %{
          status: :downloading,
          progress_percent: 42,
          last_status_message: "downloading artifact"
        },
        scope: scope
      )

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/releases")

    assert html =~ "1 downloading"
    assert html =~ "0/1 healthy"
  end

  test "shows recent target diagnostics under each rollout", %{conn: conn, scope: scope} do
    version = "3.2.#{System.unique_integer([:positive])}"
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
    agent_id = "agent-release-failure-#{System.unique_integer([:positive])}"

    _agent =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Failure Test Agent",
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => "amd64"}
        },
        actor: system_actor()
      )
      |> Ash.create!()

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(
        %{
          version: version,
          agent_ids: [agent_id],
          batch_size: 1,
          batch_delay_seconds: 0,
          notes: "target diagnostics"
        },
        scope: scope
      )

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(rollout_id == ^rollout.id and agent_id == ^agent_id))
      |> Ash.read_one!(scope: scope)

    {:ok, _target} =
      AgentReleaseTarget.set_status(
        target,
        %{
          status: :failed,
          progress_percent: 100,
          last_status_message: "verification failed",
          last_error: "digest mismatch"
        },
        scope: scope
      )

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/releases")

    assert html =~ "Recent Target States"
    assert html =~ agent_id
    assert html =~ "digest mismatch"
    assert html =~ "verification failed"
  end

  test "blocks rollout creation when the cohort has no compatible agents", %{
    conn: conn,
    scope: scope
  } do
    version = "3.3.#{System.unique_integer([:positive])}"
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
    agent_id = "agent-release-platform-#{System.unique_integer([:positive])}"

    _agent =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Platform Test Agent",
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => "arm64"}
        },
        actor: system_actor()
      )
      |> Ash.create!()

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    html =
      lv
      |> form("#create-rollout-form", %{
        "rollout" => %{
          "version" => version,
          "cohort" => "custom",
          "batch_size" => "1",
          "batch_delay_seconds" => "0",
          "agent_ids" => agent_id,
          "notes" => "platform diagnostics"
        }
      })
      |> render_submit()

    assert html =~ "linux/amd64"
    assert html =~ "linux/arm64"
    assert html =~ "1 unsupported"

    assert html =~
             "Rollout creation is blocked until the cohort includes at least one agent supported by the published release."

    assert has_element?(lv, "#create-rollout-form button[disabled]")
    assert html =~ "No compatible agents are available for the selected release"
  end

  test "creates a rollout for the compatible subset when the cohort includes unsupported agents",
       %{
         conn: conn,
         scope: scope
       } do
    version = "3.3.#{System.unique_integer([:positive])}"
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
    compatible_id = "agent-release-compatible-#{System.unique_integer([:positive])}"
    unsupported_id = "agent-release-unsupported-#{System.unique_integer([:positive])}"

    for {agent_id, arch} <- [{compatible_id, "amd64"}, {unsupported_id, "arm64"}] do
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Subset Test Agent #{arch}",
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => arch}
        },
        actor: system_actor()
      )
      |> Ash.create!()
    end

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    html =
      lv
      |> form("#create-rollout-form", %{
        "rollout" => %{
          "version" => version,
          "cohort" => "custom",
          "batch_size" => "1",
          "batch_delay_seconds" => "0",
          "agent_ids" => "#{compatible_id}
#{unsupported_id}",
          "notes" => "subset rollout"
        }
      })
      |> render_submit()

    assert html =~
             "Created rollout for #{version} targeting 1 agents and skipped 1 unsupported agent"

    rollout =
      AgentReleaseRollout
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(desired_version == ^version))
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
      |> List.first()

    assert rollout
    assert rollout.cohort_agent_ids == [compatible_id]
    assert get_in(rollout.metadata || %{}, ["skipped_unsupported_agent_ids"]) == [unsupported_id]
  end

  test "rollout metadata keeps all skipped unsupported agent ids", %{conn: conn, scope: scope} do
    version = "3.4.#{System.unique_integer([:positive])}"
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
    compatible_id = "agent-release-compatible-#{System.unique_integer([:positive])}"

    unsupported_ids =
      for _ <- 1..9 do
        "agent-release-unsupported-#{System.unique_integer([:positive])}"
      end

    for {agent_id, arch} <- [{compatible_id, "amd64"} | Enum.map(unsupported_ids, &{&1, "arm64"})] do
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Metadata Test Agent #{arch}",
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => arch}
        },
        actor: system_actor()
      )
      |> Ash.create!()
    end

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    html =
      lv
      |> form("#create-rollout-form", %{
        "rollout" => %{
          "version" => version,
          "cohort" => "custom",
          "batch_size" => "1",
          "batch_delay_seconds" => "0",
          "agent_ids" => Enum.join([compatible_id | unsupported_ids], "\n"),
          "notes" => "metadata rollout"
        }
      })
      |> render_submit()

    assert html =~
             "Created rollout for #{version} targeting 1 agents and skipped 9 unsupported agents"

    rollout =
      AgentReleaseRollout
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(desired_version == ^version))
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
      |> List.first()

    assert rollout
    assert rollout.cohort_agent_ids == [compatible_id]
    assert get_in(rollout.metadata || %{}, ["skipped_unsupported_agent_ids"]) == unsupported_ids
  end

  test "create rollout normalizes surrounding whitespace in the selected version", %{
    conn: conn,
    scope: scope
  } do
    version = "4.4.#{System.unique_integer([:positive])}"
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
    compatible_id = "agent-release-whitespace-#{System.unique_integer([:positive])}"

    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: compatible_id,
        name: "Whitespace Version Agent",
        gateway_id: gateway.id,
        version: "1.0.0",
        type_id: 4,
        type: "Performance",
        capabilities: ["agent"],
        metadata: %{"os" => "linux", "arch" => "amd64"}
      },
      actor: system_actor()
    )
    |> Ash.create!()

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    html =
      lv
      |> form("#create-rollout-form", %{
        "rollout" => %{
          "version" => "  #{version}  ",
          "cohort" => "custom",
          "batch_size" => "1",
          "batch_delay_seconds" => "0",
          "agent_ids" => compatible_id,
          "notes" => "whitespace rollout"
        }
      })
      |> render_submit()

    assert html =~ "Created rollout for #{version} targeting 1 agents"
  end

  test "selecting a published release updates the rollout form version", %{
    conn: conn,
    scope: scope
  } do
    older = "5.0.#{System.unique_integer([:positive])}"
    newer = "5.1.#{System.unique_integer([:positive])}"

    for version <- [newer, older] do
      {:ok, _release} =
        AgentReleaseManager.publish_release(
          %{
            version: version,
            signature: sign_manifest(release_manifest(version)),
            manifest: release_manifest(version)
          },
          scope: scope
        )
    end

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/releases")

    assert has_element?(lv, "#use-release-#{older}")

    lv
    |> element("#use-release-#{older}")
    |> render_click()

    assert has_element?(
             lv,
             "select[name='rollout[version]'] option[selected][value='#{older}']"
           )
  end

  test "release command updates trigger a debounced page refresh", %{conn: conn, scope: scope} do
    version = "6.0.#{System.unique_integer([:positive])}"
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
    agent_id = "agent-release-refresh-#{System.unique_integer([:positive])}"

    _agent =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Refresh Test Agent",
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => "amd64"}
        },
        actor: system_actor()
      )
      |> Ash.create!()

    {:ok, lv, html} = live(conn, ~p"/settings/agents/releases")
    refute html =~ version

    {:ok, _rollout} =
      AgentReleaseManager.create_rollout(
        %{
          version: version,
          agent_ids: [agent_id],
          batch_size: 1,
          batch_delay_seconds: 0,
          notes: "refresh test"
        },
        scope: scope
      )

    send(
      lv.pid,
      {:command_progress, %{"command_type" => "agent.update_release", "agent_id" => agent_id}}
    )

    send(lv.pid, :refresh_releases_page)

    assert render(lv) =~ version
  end

  test "delayed final rollout updates still refresh to healthy without a manual reload", %{
    conn: conn,
    scope: scope
  } do
    version = "6.1.#{System.unique_integer([:positive])}"
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
    agent_id = "agent-release-race-#{System.unique_integer([:positive])}"

    _agent =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Race Test Agent",
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => "amd64"}
        },
        actor: system_actor()
      )
      |> Ash.create!()

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(
        %{
          version: version,
          agent_ids: [agent_id],
          batch_size: 1,
          batch_delay_seconds: 0,
          notes: "refresh race test"
        },
        scope: scope
      )

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(expr(rollout_id == ^rollout.id and agent_id == ^agent_id))
      |> Ash.read_one!()

    :ok =
      AgentReleaseManager.handle_command_progress(
        %{
          command_type: "agent.update_release",
          command_id: target.command_id,
          message: "restarting",
          progress_percent: 95
        },
        scope: scope
      )

    {:ok, lv, html} = live(conn, ~p"/settings/agents/releases")
    assert html =~ "Restarting"

    send(lv.pid, {:command_progress, %{"command_type" => "agent.update_release"}})
    Process.sleep(200)
    send(lv.pid, {:command_result, %{"command_type" => "agent.update_release"}})
    Process.sleep(125)

    :ok =
      AgentReleaseManager.handle_command_result(
        %{
          command_type: "agent.update_release",
          command_id: target.command_id,
          success: true,
          message: "release activated",
          payload: %{"status" => "healthy", "current_version" => version}
        },
        scope: scope
      )

    Process.sleep(200)
    assert render(lv) =~ "Healthy"
  end

  test "failed rollouts render failed status and hide cancel even if the rollout row is stale active",
       %{
         conn: conn,
         scope: scope
       } do
    version = "6.2.#{System.unique_integer([:positive])}"
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
    agent_id = "agent-release-failed-#{System.unique_integer([:positive])}"

    _agent =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_id,
          name: "Failed Rollout Agent",
          gateway_id: gateway.id,
          version: "1.0.0",
          type_id: 4,
          type: "Performance",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => "amd64"}
        },
        actor: system_actor()
      )
      |> Ash.create!()

    {:ok, rollout} =
      AgentReleaseManager.create_rollout(
        %{
          version: version,
          agent_ids: [agent_id],
          batch_size: 1,
          batch_delay_seconds: 0,
          notes: "failed rollout test"
        },
        scope: scope
      )

    target =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{}, actor: scope)
      |> Ash.Query.filter(expr(rollout_id == ^rollout.id and agent_id == ^agent_id))
      |> Ash.read_one!()

    :ok =
      AgentReleaseManager.handle_command_result(
        %{
          command_type: "agent.update_release",
          command_id: target.command_id,
          success: false,
          message: "release manifest signature verification failed",
          payload: %{
            "status" => "failed",
            "reason" => "release manifest signature verification failed"
          }
        },
        scope: scope
      )

    Ecto.Adapters.SQL.query!(
      ServiceRadar.Repo,
      """
      UPDATE platform.agent_release_rollouts
      SET status = 'active', completed_at = NULL
      WHERE rollout_id = $1
      """,
      [rollout.id]
    )

    {:ok, lv, html} = live(conn, ~p"/settings/agents/releases")

    assert html =~ version
    assert html =~ "Failed"
    refute has_element?(lv, "button[phx-click='cancel_rollout'][phx-value-id='#{rollout.id}']")
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
    {:ok, payload} = ReleaseManifestValidator.canonical_json(manifest)
    private_key = Base.decode64!(@release_private_key)

    :eddsa
    |> :crypto.sign(:none, payload, [private_key, :ed25519])
    |> Base.encode64()
  end
end
