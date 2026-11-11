defmodule ServiceRadar.Camera.LocalStorageBindingIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.LocalStorageBinding

  @moduletag :integration

  setup do
    storage_id = Ecto.UUID.generate()

    configuration = %{
      "schema_version" => 1,
      "storage_id" => storage_id,
      "generation" => 1,
      "provider_resource_ref" => "invented-volume-reference",
      "profile_sha256" => String.duplicate("a", 64)
    }

    actor =
      :synthetic_storage_provisioner
      |> SystemActor.system()
      |> Map.merge(%{nvr_storage_purpose: :provision, nvr_storage_id: storage_id})

    %{configuration: configuration, actor: actor, opts: [actor: actor]}
  end

  test "identical retries preserve binding UUID, original principal and insertion time", ctx do
    assert {:ok, first} = LocalStorageBinding.register(ctx.configuration, ctx.opts)
    rotated = Map.put(ctx.actor, :id, "system:synthetic_replacement_provisioner")
    assert {:ok, retry} = LocalStorageBinding.register(ctx.configuration, actor: rotated)
    assert retry.id == first.id
    assert retry.inserted_at == first.inserted_at
    assert retry.provisioned_by == ctx.actor.id
    assert retry.binding_sha256 == first.binding_sha256
    assert {:ok, [retained]} = Ash.read(LocalStorageBinding, ctx.opts)
    assert retained.id == first.id
  end

  test "a generation cannot be rebound to another provider resource or profile", ctx do
    assert {:ok, first} = LocalStorageBinding.register(ctx.configuration, ctx.opts)

    for {key, value} <- [
          {"provider_resource_ref", "invented-different-volume"},
          {"profile_sha256", String.duplicate("b", 64)}
        ] do
      assert {:error, error} =
               LocalStorageBinding.register(Map.put(ctx.configuration, key, value), ctx.opts)

      assert Exception.message(error) =~ "local storage binding conflicts"
    end

    assert {:ok, retained} = Ash.get(LocalStorageBinding, first.id, ctx.opts)
    assert retained.provider_resource_ref == first.provider_resource_ref
    assert retained.profile_sha256 == first.profile_sha256
    assert retained.binding_sha256 == first.binding_sha256

    changed =
      ctx.configuration
      |> Map.put("generation", 2)
      |> Map.put("profile_sha256", String.duplicate("b", 64))

    assert {:ok, next} = LocalStorageBinding.register(changed, ctx.opts)
    assert next.id != first.id
    assert next.generation == 2
    assert next.storage_id == first.storage_id
    assert next.binding_sha256 != first.binding_sha256
    assert {:ok, historical} = Ash.get(LocalStorageBinding, first.id, ctx.opts)
    assert historical.profile_sha256 == first.profile_sha256
  end

  test "only a provisioner scoped to the storage lifetime may create or retry a binding", ctx do
    assert {:ok, first} = LocalStorageBinding.register(ctx.configuration, ctx.opts)

    for actor <- [
          nil,
          SystemActor.system(:nvr_recorder),
          Map.put(ctx.actor, :role, :admin),
          Map.put(ctx.actor, :nvr_storage_purpose, :record),
          Map.put(ctx.actor, :nvr_storage_id, Ecto.UUID.generate()),
          Map.put(ctx.actor, :id, "invalid\nprincipal")
        ],
        generation <- [1, 2] do
      assert {:error, _} =
               LocalStorageBinding.register(
                 Map.put(ctx.configuration, "generation", generation),
                 actor: actor
               )
    end

    assert {:ok, [retained]} = Ash.read(LocalStorageBinding, ctx.opts)
    assert retained.id == first.id
  end

  test "read scope excludes another lifetime even when its provider reference is the same", ctx do
    assert {:ok, first} = LocalStorageBinding.register(ctx.configuration, ctx.opts)
    other_storage = Ecto.UUID.generate()
    other_actor = Map.put(ctx.actor, :nvr_storage_id, other_storage)

    assert {:ok, other} =
             LocalStorageBinding.register(
               Map.put(ctx.configuration, "storage_id", other_storage),
               actor: other_actor
             )

    assert other.id != first.id
    assert other.binding_sha256 != first.binding_sha256
    assert {:ok, [visible]} = Ash.read(LocalStorageBinding, ctx.opts)
    assert visible.id == first.id
    assert {:ok, [visible]} = Ash.read(LocalStorageBinding, actor: other_actor)
    assert visible.id == other.id
    assert {:ok, []} = Ash.read(LocalStorageBinding, actor: SystemActor.system(:nvr_recorder))
  end
end
