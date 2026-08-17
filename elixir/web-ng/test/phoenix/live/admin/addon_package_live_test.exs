defmodule ServiceRadarWebNGWeb.Admin.AddonPackageLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.NativeAddonArtifactMirror

  require Ash.Query

  defmodule FakeNativeAddonCatalogClient do
    @moduledoc false

    def get(url, _opts) do
      fixture = Application.fetch_env!(:serviceradar_web_ng, :native_addon_live_catalog_fixture)

      cond do
        String.contains?(url, "/releases?per_page=") ->
          {:ok, %Req.Response{status: 200, body: [fixture.release]}}

        String.ends_with?(url, "/serviceradar-native-addon-index.json") ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(fixture.index)}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end
  end

  setup %{conn: conn} do
    user = admin_user_fixture()
    %{conn: log_in_user(conn, user), actor: actor_for_user(user)}
  end

  test "add-on catalog filters imported packages by release", %{
    conn: conn,
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    release_major = 10_000 + rem(unique, 100_000)
    older_release = "v#{release_major}.0.0"
    newer_release = "v#{release_major}.1.0"

    _older =
      create_addon_package!(actor, %{
        addon_id: "latest-only-addon-#{unique}",
        name: "Latest Only Add-on #{unique}",
        version: "0.1.0",
        source_release_tag: older_release,
        status: :approved,
        approved_capabilities: ["addon.run"]
      })

    newer =
      create_addon_package!(actor, %{
        addon_id: "latest-only-addon-#{unique}",
        name: "Latest Only Add-on #{unique}",
        version: "0.2.0",
        source_release_tag: newer_release,
        status: :approved,
        approved_capabilities: ["addon.run"]
      })

    _non_release =
      create_addon_package!(actor, %{
        addon_id: "non-release-addon-#{unique}",
        name: "Non Release Add-on #{unique}",
        version: "0.3.0",
        source_release_tag: "netprobe-0.2.20-demo-#{unique}",
        status: :approved,
        approved_capabilities: ["addon.run"]
      })

    _sample =
      create_addon_package!(actor, %{
        addon_id: "rust-sample",
        name: "Rust Sample Add-on #{unique}",
        version: "0.4.0",
        source_release_tag: newer_release,
        status: :approved,
        approved_capabilities: ["addon.run"]
      })

    {:ok, lv, html} = live(conn, ~p"/settings/agents/addons")

    assert html =~ "Add-on catalog"
    refute html =~ "Available add-ons"
    assert html =~ newer.id
    assert html =~ "0.2.0"
    refute html =~ "0.1.0"
    refute html =~ "netprobe-0.2.20-demo-#{unique}"
    refute html =~ "Non Release Add-on #{unique}"
    refute html =~ "Rust Sample Add-on #{unique}"

    html =
      lv
      |> element("#select-addon-release-form")
      |> render_change(%{"release_tag" => older_release})

    assert html =~ "0.1.0"
    refute html =~ "0.2.0"
  end

  test "catalog matches an imported bundle reused through a newer release envelope", %{
    conn: conn,
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    addon_id = "oci-catalog-addon-#{unique}"
    version = "1.0.0"
    release_tag = "v#{20_000 + rem(unique, 100_000)}.0.0"
    imported_oci_ref = "registry.carverauto.dev/serviceradar/#{addon_id}:previous-release"
    imported_oci_digest = "sha256:" <> String.duplicate("a", 64)
    discovered_oci_ref = "registry.carverauto.dev/serviceradar/#{addon_id}:#{release_tag}"
    discovered_oci_digest = "sha256:" <> String.duplicate("e", 64)
    bundle_digest = "sha256:" <> String.duplicate("d", 64)
    tarball_sha256 = String.duplicate("b", 64)

    package =
      create_addon_package!(actor, %{
        addon_id: addon_id,
        name: "OCI Catalog Add-on #{unique}",
        version: version,
        source_oci_ref: imported_oci_ref,
        source_oci_digest: imported_oci_digest,
        source_release_tag: nil,
        source_metadata: %{"bundle_digest" => bundle_digest},
        artifacts: %{
          "linux/amd64" => %{
            "object_key" =>
              NativeAddonArtifactMirror.object_key(
                addon_id,
                version,
                "linux",
                "amd64",
                tarball_sha256
              ),
            "sha256" => tarball_sha256,
            "signature" => "catalog-signature",
            "signature_digest" => "sha256:" <> String.duplicate("c", 64)
          }
        }
      })

    release = %{
      "tag_name" => release_tag,
      "name" => "ServiceRadar #{release_tag}",
      "html_url" => "https://github.com/carverauto/serviceradar/releases/tag/#{release_tag}",
      "assets" => [
        %{
          "name" => "serviceradar-native-addon-index.json",
          "browser_download_url" =>
            "https://github.com/carverauto/serviceradar/releases/download/#{release_tag}/serviceradar-native-addon-index.json"
        }
      ]
    }

    index = %{
      "schema_version" => 1,
      "addons" => [
        %{
          "addon_id" => addon_id,
          "name" => package.name,
          "version" => version,
          "oci_ref" => discovered_oci_ref,
          "oci_digest" => discovered_oci_digest,
          "bundle_digest" => bundle_digest,
          "artifacts" => [
            %{
              "os" => "linux",
              "arch" => "amd64",
              "tarball_digest" => "sha256:#{tarball_sha256}",
              "signature_digest" => "sha256:" <> String.duplicate("c", 64),
              "tarball_sha256" => tarball_sha256
            }
          ]
        }
      ]
    }

    original_client =
      Application.get_env(:serviceradar_web_ng, :first_party_plugin_import_http_client)

    original_fixture =
      Application.get_env(:serviceradar_web_ng, :native_addon_live_catalog_fixture)

    Application.put_env(
      :serviceradar_web_ng,
      :first_party_plugin_import_http_client,
      FakeNativeAddonCatalogClient
    )

    Application.put_env(
      :serviceradar_web_ng,
      :native_addon_live_catalog_fixture,
      %{release: release, index: index}
    )

    on_exit(fn ->
      restore_env(:first_party_plugin_import_http_client, original_client)
      restore_env(:native_addon_live_catalog_fixture, original_fixture)
    end)

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/addons")
    html = render_click(lv, "sync_first_party_catalog", %{})
    assert html =~ "Syncing"

    html = render_async(lv, 5_000)

    assert html =~ "Catalog refreshed from the registry"
    assert html =~ "Nothing was imported"
    assert html =~ "Last refresh"
    assert html =~ release_tag
    assert html =~ package.id
    assert html =~ "staged"
    refute html =~ "not imported"

    assert has_element?(
             lv,
             ~s(button[phx-click="view_package"][phx-value-id="#{package.id}"])
           )

    refute has_element?(
             lv,
             ~s(button[phx-click="import_first_party_addon"][phx-value-addon_id="#{addon_id}"])
           )
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
    assert html =~ "approve a verified package"
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

  test "surfaces approved add-on packages with missing artifact blobs", %{conn: conn, actor: actor} do
    package =
      create_addon_package!(actor, %{
        addon_id: "missing-blob-addon",
        name: "Missing Blob Add-on",
        status: :approved,
        approved_capabilities: ["addon.run"],
        artifacts: %{
          "linux/amd64" => %{
            "object_key" => "native-addons/missing-blob-addon/1.0.0/linux/amd64/sha.tar.gz",
            "sha256" => "abc",
            "signature" => "sig"
          }
        },
        verification_status: "blob_missing",
        verification_error:
          "native add-on artifact object missing: native-addons/missing-blob-addon/1.0.0/linux/amd64/sha.tar.gz"
      })

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/addons/#{package.id}")

    assert html =~ "blob missing"
    assert html =~ "Object storage no longer has one or more native add-on artifacts"
    assert html =~ "native-addons/missing-blob-addon/1.0.0/linux/amd64/sha.tar.gz"
    assert html =~ "cannot be assigned until its missing artifact is re-imported"
    assert html =~ "Re-import this add-on package before creating profiles or assignments."
    assert html =~ ~r/<button[^>]*disabled[^>]*>\s*Create Profile/s
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

    {:ok, lv, html} = live(conn, ~p"/settings/agents/addons/#{package.id}")

    # The override panel must carry the DetailsState hook so its open/closed
    # state survives the phx-change re-renders triggered by the selects below.
    assert html =~ ~s(id="advanced-manual-assignment-override")
    assert html =~ ~s(phx-hook="DetailsState")

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

  test "profile creation defaults blank SRQL target query to all agents", %{
    conn: conn,
    actor: actor
  } do
    package =
      create_addon_package!(actor, %{
        addon_id: "endpoint-inventory-profile-default",
        name: "Endpoint Inventory Profile Default",
        status: :approved,
        approved_capabilities: ["endpoint.inventory"]
      })

    {:ok, lv, html} = live(conn, ~p"/settings/agents/addons/#{package.id}")

    assert html =~ "Profile assignment"
    assert html =~ "Advanced Profile Options"
    assert html =~ "Advanced Manual Assignment Override"

    html =
      lv
      |> form("#create-addon-profile-form", %{
        "profile" => %{
          "name" => "Inventory everywhere",
          "target_query" => "   ",
          "priority" => "100",
          "max_targets" => "10000",
          "params" => "{}",
          "args" => ""
        }
      })
      |> render_submit()

    assert html =~ "Add-on profile created."

    [profile] =
      AddonProfile
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(addon_package_id == ^package.id)
      |> Ash.read!(actor: system_actor())

    assert profile.target_query == "in:agents"

    html =
      lv
      |> form("#create-addon-profile-form", %{
        "profile" => %{
          "name" => "Inventory devices",
          "target_query" => "in:devices hostname:dusk*",
          "priority" => "100",
          "max_targets" => "10000",
          "params" => "{}",
          "args" => ""
        }
      })
      |> render_submit()

    assert html =~ "must target agents"
    refute html =~ "Inventory devices"

    html = render_click(lv, "reconcile_profile", %{"id" => Ecto.UUID.generate()})

    assert html =~ "Profile reconcile failed"
    assert render(lv) =~ "Profile assignment"

    html =
      lv
      |> element("button[phx-click='delete_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

    assert html =~ "Add-on profile removed."
    refute html =~ "Inventory everywhere"

    assert [] =
             AddonProfile
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(addon_package_id == ^package.id)
             |> Ash.read!(actor: system_actor())
  end

  test "profile form exposes and enables a schema runtime switch by default", %{
    conn: conn,
    actor: actor
  } do
    package =
      create_addon_package!(actor, %{
        addon_id: "netprobe",
        name: "Netprobe Profile Runtime Enabled",
        version: "9999.0.0",
        status: :approved,
        supervision: :systemd_service,
        approved_capabilities: ["flow.capture", "host.process"],
        config_schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "enabled" => %{
              "type" => "boolean",
              "title" => "Enabled",
              "default" => false
            },
            "flow_attribution_ipc_batch" => %{
              "type" => "boolean",
              "title" => "Flow attribution IPC batch",
              "default" => true
            },
            "device_bindings" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "ip" => %{"type" => "string"}
                }
              }
            }
          }
        }
      })

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/addons/#{package.id}")

    assert has_element?(lv, "#addon-profile-configuration")

    assert has_element?(
             lv,
             ~s(#create-addon-profile-form input[name="profile[params][enabled]"][checked])
           )

    form_params = %{
      "profile" => %{
        "name" => "Host visibility",
        "target_query" => "in:agents",
        "priority" => "100",
        "max_targets" => "10000",
        "params" => %{
          "enabled" => "true",
          "flow_attribution_ipc_batch" => "true"
        },
        "params_raw" => Jason.encode!(%{"device_bindings" => [%{"ip" => "192.0.2.10"}]}),
        "args" => ""
      }
    }

    lv
    |> form("#create-addon-profile-form", form_params)
    |> render_change()

    assert has_element?(
             lv,
             ~s(#create-addon-profile-form input[name="profile[params][enabled]"][checked])
           )

    html =
      lv
      |> form("#create-addon-profile-form", form_params)
      |> render_submit()

    assert html =~ "Add-on profile created."

    [profile] =
      AddonProfile
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(addon_package_id == ^package.id)
      |> Ash.read!(actor: system_actor())

    assert profile.params["enabled"] == true
    assert profile.params["flow_attribution_ipc_batch"] == true
    assert profile.params["device_bindings"] == [%{"ip" => "192.0.2.10"}]
  end

  test "profile raw params override defaults for complex-only schema fields", %{
    conn: conn,
    actor: actor
  } do
    package =
      create_addon_package!(actor, %{
        addon_id: "complex-profile-defaults",
        name: "Complex Profile Defaults",
        version: "9999.0.0",
        status: :approved,
        approved_capabilities: ["flow.capture"],
        config_schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "device_bindings" => %{
              "type" => "array",
              "default" => [%{"ip" => "198.51.100.1"}],
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "ip" => %{"type" => "string"}
                }
              }
            }
          }
        }
      })

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/addons/#{package.id}")

    refute has_element?(lv, "#addon-profile-configuration")

    html =
      lv
      |> form("#create-addon-profile-form", %{
        "profile" => %{
          "name" => "Custom device bindings",
          "target_query" => "in:agents",
          "priority" => "100",
          "max_targets" => "10000",
          "params_raw" => Jason.encode!(%{"device_bindings" => [%{"ip" => "192.0.2.20"}]}),
          "args" => ""
        }
      })
      |> render_submit()

    assert html =~ "Add-on profile created."

    [profile] =
      AddonProfile
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(addon_package_id == ^package.id)
      |> Ash.read!(actor: system_actor())

    assert profile.params["device_bindings"] == [%{"ip" => "192.0.2.20"}]
  end

  test "assignment list shows profile provenance and reconcile state", %{
    conn: conn,
    actor: actor
  } do
    package =
      create_addon_package!(actor, %{
        addon_id: "endpoint-inventory-profile-owned",
        name: "Endpoint Inventory Profile Owned",
        status: :approved,
        approved_capabilities: ["endpoint.inventory"]
      })

    profile =
      AddonProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Inventory everywhere",
          addon_package_id: package.id,
          target_query: "in:agents",
          params: %{},
          args: []
        },
        actor: actor
      )
      |> Ash.Changeset.force_change_attribute(:last_reconcile_summary, %{
        "status" => "failed",
        "last_error" => "agent capability missing"
      })
      |> Ash.Changeset.force_change_attribute(:last_reconciled_at, DateTime.utc_now())
      |> Ash.create!()

    AddonAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        agent_uid: "agent-profile-owned",
        addon_package_id: package.id,
        source: :profile,
        source_key: "profile:#{profile.id}:endpoint-inventory-profile-owned:agent-profile-owned",
        addon_profile_id: profile.id,
        profile_reconcile_status: "failed",
        profile_reconcile_error: "agent capability missing",
        profile_last_reconciled_at: DateTime.utc_now(),
        params: %{},
        args: []
      },
      actor: actor
    )
    |> Ash.create!()

    {:ok, _lv, html} = live(conn, ~p"/settings/agents/addons/#{package.id}")

    assert html =~ "agent-profile-owned"
    assert html =~ "profile: Inventory everywhere"
    assert html =~ "failed"
    assert html =~ "agent capability missing"
    refute html =~ "manual override"
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
