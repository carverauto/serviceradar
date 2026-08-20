defmodule ServiceRadar.Plugins.DisplayContractsDBTest do
  @moduledoc """
  DB-backed coverage of the `display_contracts` column added for tasks 3.5.1-3.5.2.

  Two things only a database can prove: that the hand-written migration's column
  round-trips a contract document unchanged, and that the resource validation
  refuses one the renderer could not trust - on the resource, so every writer is
  covered, not only the importer that happens to have a test.

  Run against the srql-fixtures scratch DB (see the srql-fixtures-db-tests skill).
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.PluginPackage

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok,
     actor: %{id: Ash.UUID.generate(), email: "test@serviceradar.local", role: :admin},
     uid: :erlang.unique_integer([:positive])}
  end

  defp contract(id) do
    %{
      "id" => id,
      "version" => "1.0.0",
      "schema_id" => "com.thirdparty.thing",
      "schema_version" => "1.0.0",
      "widgets" => [
        %{"type" => "summary", "title" => "thing.name", "message" => "message"},
        %{"type" => "facts", "fields" => [%{"label" => "Zone", "path" => "thing.zone"}]}
      ]
    }
  end

  defp plugin_attrs(uid, display_contracts) do
    plugin_id = "thirdparty-#{uid}"

    %{
      plugin_id: plugin_id,
      name: "Third Party #{uid}",
      version: "1.0.0",
      entrypoint: "run_check",
      outputs: "serviceradar.plugin_result.v1",
      display_contracts: display_contracts,
      manifest: %{
        "id" => plugin_id,
        "name" => "Third Party #{uid}",
        "version" => "1.0.0",
        "entrypoint" => "run_check",
        "outputs" => "serviceradar.plugin_result.v1",
        "capabilities" => ["log"],
        "resources" => %{"requested_memory_mb" => 16, "requested_cpu_ms" => 500}
      }
    }
  end

  defp create_plugin_package(uid, display_contracts, actor) do
    plugin_id = "thirdparty-#{uid}"

    {:ok, _plugin} =
      ServiceRadar.Plugins.Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Third Party #{uid}"},
        actor: actor
      )
      |> Ash.create()

    PluginPackage
    |> Ash.Changeset.for_create(:create, plugin_attrs(uid, display_contracts), actor: actor)
    |> Ash.create()
  end

  test "a plugin package round-trips a shipped display contract", %{actor: actor, uid: uid} do
    contract = contract("com.thirdparty.thing.display")
    contracts = %{"com.thirdparty.thing.display@1.0.0" => contract}

    assert {:ok, package} = create_plugin_package(uid, contracts, actor)
    assert {:ok, reloaded} = Ash.get(PluginPackage, package.id, actor: actor)

    assert reloaded.display_contracts == contracts

    assert get_in(reloaded.display_contracts, ["com.thirdparty.thing.display@1.0.0", "widgets"]) ==
             contract["widgets"]
  end

  test "the column defaults to an empty map for a package that ships none", %{
    actor: actor,
    uid: uid
  } do
    assert {:ok, package} = create_plugin_package(uid, %{}, actor)
    assert package.display_contracts == %{}
  end

  # The resource, not the importer, is where this has to hold: the admin API and
  # the packages LiveView both write packages, and a renderer that trusted stored
  # data would inherit whatever validation the writer skipped.
  test "a package carrying a UI-code key is refused", %{actor: actor, uid: uid} do
    contracts = %{
      "com.thirdparty.thing.display@1.0.0" =>
        Map.put(contract("com.thirdparty.thing.display"), "live_view", "Evil")
    }

    assert {:error, error} = create_plugin_package(uid, contracts, actor)
    assert Exception.message(error) =~ "live_view is not allowed"
  end

  test "a package whose contract key disagrees with its document is refused", %{
    actor: actor,
    uid: uid
  } do
    contracts = %{"wrong-key@9.9.9" => contract("com.thirdparty.thing.display")}

    assert {:error, error} = create_plugin_package(uid, contracts, actor)
    assert Exception.message(error) =~ "must be keyed as com.thirdparty.thing.display@1.0.0"
  end

  test "an add-on package carries display contracts on the same terms", %{
    actor: actor,
    uid: uid
  } do
    contracts = %{
      "com.thirdparty.thing.display@1.0.0" => contract("com.thirdparty.thing.display")
    }

    assert {:ok, package} =
             AddonPackage
             |> Ash.Changeset.for_create(
               :create,
               %{
                 addon_id: "thirdparty-addon-#{uid}",
                 name: "Third Party Addon #{uid}",
                 version: "1.0.0",
                 kind: :native,
                 delivery: :pushed_artifact,
                 supervision: :agent_sidecar,
                 display_contracts: contracts
               },
               actor: actor
             )
             |> Ash.create()

    assert package.display_contracts == contracts

    assert {:error, error} =
             AddonPackage
             |> Ash.Changeset.for_create(
               :create,
               %{
                 addon_id: "thirdparty-addon-bad-#{uid}",
                 name: "Third Party Addon #{uid}",
                 version: "1.0.0",
                 kind: :native,
                 delivery: :pushed_artifact,
                 supervision: :agent_sidecar,
                 display_contracts: %{"x@1.0.0" => %{"widgets" => []}}
               },
               actor: actor
             )
             |> Ash.create()

    assert Exception.message(error) =~ "display_contracts.x@1.0.0"
  end
end
