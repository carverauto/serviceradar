defmodule ServiceRadar.Plugins.RolloutArtifactKindDbTest do
  @moduledoc """
  The rollout tables hold native add-on and Wasm plugin rollouts side by side.
  The database keeps each row's package pair matched to its `artifact_kind`,
  and add-on rollout readers never act on a Wasm row.
  """

  use ServiceRadar.DataCase, async: true

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.AddonRollout
  alias ServiceRadar.Plugins.AddonRolloutCoordinator
  alias ServiceRadar.Plugins.AddonRolloutTarget
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.Validations.NotHeldByActiveRollout

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:rollout_artifact_kind_db_test)
    unique = System.unique_integer([:positive])

    {:ok,
     actor: actor,
     unique: unique,
     addon: addon_package!("kind-addon-#{unique}", actor),
     plugin_previous: plugin_package!("kind-plugin-#{unique}", "1.0.0", true),
     plugin_candidate: plugin_package!("kind-plugin-#{unique}", "1.1.0", false)}
  end

  test "a rollout and its targets must carry the package pair of their artifact kind", ctx do
    addon_pair = %{previous_package_id: ctx.addon.id, candidate_package_id: ctx.addon.id}

    plugin_pair = %{
      previous_plugin_package_id: ctx.plugin_previous.id,
      candidate_plugin_package_id: ctx.plugin_candidate.id
    }

    rejected_rollouts = [
      {"wasm rollout with add-on packages", Map.put(addon_pair, :artifact_kind, :wasm_plugin)},
      {"add-on rollout with plugin packages",
       Map.put(plugin_pair, :artifact_kind, :native_addon)},
      {"add-on rollout with both pairs",
       addon_pair |> Map.merge(plugin_pair) |> Map.put(:artifact_kind, :native_addon)},
      {"add-on rollout with a Wasm owner",
       addon_pair
       |> Map.put(:artifact_kind, :native_addon)
       |> Map.put(:source_type, :target_policy)}
    ]

    for {label, attrs} <- rejected_rollouts do
      assert {:error, %Invalid{} = error} = create_rollout(ctx, attrs), label
      assert artifact_kind_error?(error), "#{label}: #{Exception.message(error)}"
    end

    assert {:ok, %AddonRollout{} = rollout} =
             create_rollout(ctx, Map.put(plugin_pair, :artifact_kind, :wasm_plugin))

    target = %{
      rollout_id: rollout.id,
      artifact_kind: :wasm_plugin,
      partition_id: "default",
      agent_uid: "kind-agent-#{ctx.unique}",
      addon_id: rollout.addon_id,
      source_type: :assignment,
      source_id: rollout.source_id,
      batch_index: 0
    }

    rejected_targets = [
      {"wasm target with add-on packages", Map.merge(target, addon_pair)},
      {"wasm target without a partition",
       target |> Map.merge(plugin_pair) |> Map.delete(:partition_id)}
    ]

    for {label, attrs} <- rejected_targets do
      assert {:error, %Invalid{} = error} = create_target(attrs, ctx.actor), label
      assert artifact_kind_error?(error), "#{label}: #{Exception.message(error)}"
    end

    assert {:ok, %AddonRolloutTarget{artifact_kind: :wasm_plugin}} =
             create_target(Map.merge(target, plugin_pair), ctx.actor)
  end

  test "add-on rollout readers ignore a Wasm rollout", ctx do
    {:ok, rollout} =
      create_rollout(ctx, %{
        artifact_kind: :wasm_plugin,
        previous_plugin_package_id: ctx.plugin_previous.id,
        candidate_plugin_package_id: ctx.plugin_candidate.id
      })

    # The coordinator has no Wasm implementation yet, so it cannot find the
    # rollout to pause it, and the row keeps its state.
    assert {:error, {:not_found, AddonRollout, id}} =
             AddonRolloutCoordinator.pause(rollout.id, actor: ctx.actor)

    assert id == rollout.id
    assert reload_rollout(rollout.id, ctx.actor).state == :running

    # An active Wasm rollout whose manual-assignment source id coincides with an
    # add-on assignment does not hold that add-on assignment.
    assert :ok = NotHeldByActiveRollout.check(:assignment, rollout.source_id)
  end

  defp create_rollout(ctx, attrs) do
    AddonRollout
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          addon_id: "kind-plugin-#{ctx.unique}",
          source_type: :assignment,
          source_id: Ecto.UUID.generate(),
          state: :running
        },
        attrs
      ),
      actor: ctx.actor
    )
    |> Ash.create(actor: ctx.actor)
  end

  defp create_target(attrs, actor) do
    AddonRolloutTarget
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create(actor: actor)
  end

  defp reload_rollout(id, actor) do
    AddonRollout
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: actor)
  end

  # The CHECK constraint, not some other validation, refused the row.
  defp artifact_kind_error?(%Invalid{errors: errors}) do
    Enum.any?(errors, &(Map.get(&1, :field) == :artifact_kind))
  end

  defp addon_package!(addon_id, actor) do
    AddonPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        addon_id: addon_id,
        version: "1.0.0",
        name: "Kind test add-on",
        source_type: :first_party,
        source_oci_ref: "registry.example/#{addon_id}:1.0.0",
        source_oci_digest: "sha256:#{addon_id}",
        verification_status: "verified",
        artifacts: %{
          "linux/amd64" => %{"object_key" => "addons/#{addon_id}/1.0.0", "sha256" => "artifact-1"}
        },
        requires: %{"platforms" => ["linux"]},
        config_schema: %{"type" => "object"}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp plugin_package!(plugin_id, version, create_plugin?) do
    if create_plugin? do
      Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: "Kind test plugin"},
        actor: admin()
      )
      |> Ash.create!()
    end

    PluginPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        plugin_id: plugin_id,
        name: "Kind test plugin",
        version: version,
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: "serviceradar.plugin_result.v1",
        manifest: %{
          "id" => plugin_id,
          "name" => "Kind test plugin",
          "version" => version,
          "entrypoint" => "run_check",
          "runtime" => "wasi-preview1",
          "capabilities" => ["submit_result"],
          "outputs" => "serviceradar.plugin_result.v1",
          "resources" => %{
            "requested_memory_mb" => 32,
            "requested_cpu_ms" => 100,
            "max_open_connections" => 1
          }
        },
        config_schema: %{},
        display_contract: %{},
        content_hash: "sha256:#{plugin_id}:#{version}",
        source_type: :upload,
        signature: %{}
      },
      actor: admin()
    )
    |> Ash.create!()
  end

  defp admin do
    %{
      id: "00000000-0000-0000-0000-000000000001",
      email: "rollout-kind-test@example.com",
      role: :admin
    }
  end
end
