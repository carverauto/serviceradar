defmodule ServiceRadar.Plugins.SNMPRequirementCatalogTest do
  @moduledoc """
  A plugin declares what it needs polled; it never arms the polling.

  The properties asserted here are the ones whose absence would be dangerous
  rather than merely wrong: a package that could enable its own profile would
  start probing production inventory on approval, and a re-sync that overwrote
  operator fields would silently undo a credential binding or a narrowed target
  query.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.SNMPRequirementCatalog
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  require Ash.Query

  @moduletag :integration

  setup do
    %{actor: SystemActor.system(:snmp_requirement_catalog_test)}
  end

  describe "sync_package/2" do
    test "materializes one template and one inert profile", %{actor: actor} do
      package = package_with([requirement()])

      assert :ok = SNMPRequirementCatalog.sync_package(package)

      assert [template] = package_rows(SNMPOIDTemplate, package.id, actor)
      # Keyed on plugin_id, not the display name: PluginPackage is unique on
      # (plugin_id, version), so the display name is shared across versions.
      assert template.name == "plugin:#{package.plugin_id}:clearpass-node-health"
      assert template.vendor == "plugin"
      assert template.is_builtin == false
      assert length(template.oids) == 2

      assert [profile] = package_rows(SNMPProfile, package.id, actor)
      assert profile.oid_template_ids == [template.id]

      # Inert on every axis the manifest cannot express.
      assert profile.enabled == false
      assert profile.is_default == false
      assert profile.priority == 0
      assert profile.agent_ids == []
      assert is_nil(profile.credential_secret_id)

      # Seeded so an operator is not reverse-engineering cadence or targeting.
      assert profile.poll_interval == 300
      assert profile.target_query == "in:devices device_type:clearpass"
    end

    test "a package declaring nothing is a no-op", %{actor: actor} do
      package = package_with([])

      assert :ok = SNMPRequirementCatalog.sync_package(package)
      assert package_rows(SNMPOIDTemplate, package.id, actor) == []
      assert package_rows(SNMPProfile, package.id, actor) == []
    end

    # The agent rejects duplicate OID *names* within a target while
    # load_template_oids dedupes by OID *string* only, so an unqualified name
    # colliding with an operator's template would reject the whole agent config.
    test "materialized OID names are namespaced by package", %{actor: actor} do
      package = package_with([requirement()])
      assert :ok = SNMPRequirementCatalog.sync_package(package)

      assert [template] = package_rows(SNMPOIDTemplate, package.id, actor)
      names = Enum.map(template.oids, &Map.get(&1, "name"))

      assert Enum.all?(names, &String.contains?(&1, "node_cpu_pct")) or
               Enum.any?(names, &String.contains?(&1, "service_name"))

      refute "node_cpu_pct" in names
      assert Enum.all?(names, &(byte_size(&1) <= 64))
    end

    # THE upgrade property. An operator's tuning is permanent; only the OID list
    # is the plugin's to own.
    test "re-sync updates OIDs and preserves every operator field", %{actor: actor} do
      package = package_with([requirement()])
      assert :ok = SNMPRequirementCatalog.sync_package(package)
      [profile] = package_rows(SNMPProfile, package.id, actor)

      {:ok, tuned} =
        profile
        |> Ash.Changeset.for_update(
          :update,
          %{
            enabled: true,
            poll_interval: 900,
            target_query: "in:devices device_type:clearpass partition:ord",
            oid_template_ids: []
          },
          actor: actor
        )
        |> Ash.update(actor: actor)

      upgraded =
        package_with(
          [
            requirement(%{
              "description" => "updated",
              "oids" =>
                requirement()["oids"] ++
                  [
                    %{
                      "oid" => ".1.3.6.1.4.1.14823.9.9.9.0",
                      "name" => "new_metric",
                      "data_type" => "gauge"
                    }
                  ]
            })
          ],
          package
        )

      assert :ok = SNMPRequirementCatalog.sync_package(upgraded)

      [template] = package_rows(SNMPOIDTemplate, package.id, actor)
      assert length(template.oids) == 3
      assert template.description == "updated"

      [after_sync] = package_rows(SNMPProfile, package.id, actor)
      assert after_sync.enabled == tuned.enabled
      assert after_sync.poll_interval == 900
      assert after_sync.target_query == "in:devices device_type:clearpass partition:ord"
      assert after_sync.oid_template_ids == []
    end

    # PluginPackage is unique on (plugin_id, version) and NOT on name, so a new
    # version is a separate row carrying the same display name. Keying the
    # materialized rows on the display name made v0.2.0 collide with v0.1.0 on
    # snmp_oid_templates_unique_name_per_vendor_index and fail the whole sync,
    # so approving an upgrade materialized nothing.
    test "approving a NEW VERSION of a package updates its rows rather than colliding", %{
      actor: actor
    } do
      package = package_with([requirement()])
      assert :ok = SNMPRequirementCatalog.sync_package(package)

      [profile] = package_rows(SNMPProfile, package.id, actor)

      {:ok, _tuned} =
        profile
        |> Ash.Changeset.for_update(:update, %{poll_interval: 900}, actor: actor)
        |> Ash.update(actor: actor)

      upgraded = next_version(package, [requirement(%{"description" => "v2"})])

      assert :ok = SNMPRequirementCatalog.sync_package(upgraded)

      # One row, not two, and it now belongs to the new package version.
      assert [template] = package_rows(SNMPOIDTemplate, upgraded.id, actor)
      assert template.description == "v2"
      assert package_rows(SNMPOIDTemplate, package.id, actor) == []

      assert [after_upgrade] = package_rows(SNMPProfile, upgraded.id, actor)
      assert after_upgrade.id == profile.id
      assert after_upgrade.poll_interval == 900
    end

    test "re-approving after a revoke does not re-arm polling", %{actor: actor} do
      package = package_with([requirement()])
      assert :ok = SNMPRequirementCatalog.sync_package(package)

      [profile] = package_rows(SNMPProfile, package.id, actor)

      {:ok, _} =
        profile
        |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor)
        |> Ash.update(actor: actor)

      assert :ok = SNMPRequirementCatalog.disable_package_snmp(package, [])
      assert [%{enabled: false}] = package_rows(SNMPProfile, package.id, actor)

      assert :ok = SNMPRequirementCatalog.sync_package(package)
      assert [%{enabled: false}] = package_rows(SNMPProfile, package.id, actor)
    end

    test "disabling keeps the template and the operator's tuning", %{actor: actor} do
      package = package_with([requirement()])
      assert :ok = SNMPRequirementCatalog.sync_package(package)

      assert :ok = SNMPRequirementCatalog.disable_package_snmp(package, [])

      assert [_template] = package_rows(SNMPOIDTemplate, package.id, actor)
      assert [profile] = package_rows(SNMPProfile, package.id, actor)
      assert profile.target_query == "in:devices device_type:clearpass"
    end
  end

  defp requirement(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "clearpass-node-health",
        "description" => "Node health from CLEARPASS-MIB.",
        "category" => "system",
        "default_poll_interval_seconds" => 300,
        "default_timeout_seconds" => 5,
        "default_retries" => 3,
        "target_hint" => "in:devices device_type:clearpass",
        "oids" => [
          %{
            "oid" => ".1.3.6.1.4.1.14823.1.6.1.1.1.1.1.16.0",
            "name" => "node_cpu_pct",
            "data_type" => "gauge"
          },
          %{
            "oid" => ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.2",
            "name" => "service_name",
            "data_type" => "string",
            "mode" => "walk",
            "max_rows" => 256
          }
        ]
      },
      overrides
    )
  end

  # Returns a struct carrying the requirements, reusing an existing package's
  # identity so a re-sync targets the same rows.
  defp package_with(requirements, existing \\ nil)

  defp package_with(requirements, nil) do
    actor = SystemActor.system(:snmp_requirement_catalog_test)

    suffix = System.unique_integer([:positive])
    plugin_id = "clearpass-policy-manager-#{suffix}"
    name = "ClearPass Policy Manager #{suffix}"

    manifest = %{
      "id" => plugin_id,
      "name" => name,
      "version" => "0.1.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["get_config", "log", "submit_result"],
      "resources" => %{
        "requested_memory_mb" => 32,
        "requested_cpu_ms" => 100,
        "max_open_connections" => 1
      },
      "snmp_requirements" => requirements
    }

    {:ok, _plugin} =
      ServiceRadar.Plugins.Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: name}, actor: actor)
      |> Ash.create()

    {:ok, package} =
      PluginPackage
      |> Ash.Changeset.for_create(:create, %{
        plugin_id: plugin_id,
        name: name,
        version: "0.1.0",
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: "serviceradar.plugin_result.v1",
        manifest: manifest,
        content_hash: "sha256:snmp-req-#{suffix}",
        source_type: :upload,
        snmp_requirements: requirements
      })
      |> Ash.create(actor: actor, domain: ServiceRadar.Plugins)

    package
  end

  defp package_with(requirements, %PluginPackage{} = existing),
    do: %{existing | snmp_requirements: requirements}

  # A genuinely separate package row: same plugin_id and display name, new
  # version. This is what approving an upgrade actually produces.
  defp next_version(%PluginPackage{} = package, requirements) do
    actor = SystemActor.system(:snmp_requirement_catalog_test)

    {:ok, upgraded} =
      PluginPackage
      |> Ash.Changeset.for_create(:create, %{
        plugin_id: package.plugin_id,
        name: package.name,
        version: "0.2.0",
        entrypoint: package.entrypoint,
        runtime: package.runtime,
        outputs: package.outputs,
        manifest: package.manifest,
        content_hash: package.content_hash <> "-v2",
        source_type: :upload,
        snmp_requirements: requirements
      })
      |> Ash.create(actor: actor, domain: ServiceRadar.Plugins)

    upgraded
  end

  defp package_rows(resource, package_id, actor) do
    {:ok, rows} =
      resource
      |> Ash.Query.filter(plugin_package_id == ^package_id)
      |> Ash.read(actor: actor)

    rows
  end
end
