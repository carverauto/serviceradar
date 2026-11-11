defmodule ServiceRadar.Camera.LocalStorageBootstrapPreparationIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.LocalStorageBootstrapPreparation
  alias ServiceRadar.Camera.LocalStorageQualification
  alias ServiceRadar.Test.LocalStorageFixtures

  @moduletag :integration

  setup do
    ctx = LocalStorageFixtures.context()
    Map.merge(ctx, %{operation_id: Ecto.UUID.generate(), opts: [actor: ctx.provisioner]})
  end

  test "preparation retains exact canonical bytes and provenance without qualifying storage",
       ctx do
    operation_id = ctx.operation_id
    binding = ctx.binding

    expected =
      ~s({"binding_id":"#{binding.id}","binding_sha256":"#{binding.binding_sha256}",) <>
        ~s("kind":"local_storage_bootstrap_prepared","operation_id":"#{operation_id}",) <>
        ~s("storage_id":"#{binding.storage_id}","version":1})

    assert {:ok, first} =
             LocalStorageBootstrapPreparation.prepare(operation_id, binding.id, ctx.opts)

    assert first.id == operation_id
    assert first.storage_id == binding.storage_id
    assert first.local_storage_binding_id == binding.id
    assert first.record == expected
    assert first.record_sha256 == Base.encode16(:crypto.hash(:sha256, expected), case: :lower)
    assert first.prepared_by == ctx.provisioner.id

    rotated = Map.put(ctx.provisioner, :id, "system:synthetic_rotated_provisioner")

    assert {:ok, retry} =
             LocalStorageBootstrapPreparation.prepare(operation_id, binding.id, actor: rotated)

    assert retry.id == first.id
    assert retry.record == first.record
    assert retry.prepared_by == first.prepared_by
    assert retry.inserted_at == first.inserted_at

    assert {:ok, %{qualification_status: :unknown}} =
             LocalStorageQualification.status(actor: ctx.qualifier)

    assert {:ok, [retained]} = Ash.read(LocalStorageBootstrapPreparation, ctx.opts)
    assert retained.id == operation_id
  end

  test "a different operation or binding cannot replace a lifetime's preparation", ctx do
    assert {:ok, first} =
             LocalStorageBootstrapPreparation.prepare(ctx.operation_id, ctx.binding.id, ctx.opts)

    assert {:ok, next_binding} =
             LocalStorageBinding.register(Map.put(ctx.configuration, "generation", 2), ctx.opts)

    for {operation, binding} <- [
          {Ecto.UUID.generate(), ctx.binding.id},
          {ctx.operation_id, next_binding.id},
          {Ecto.UUID.generate(), next_binding.id}
        ] do
      assert {:error, error} =
               LocalStorageBootstrapPreparation.prepare(operation, binding, ctx.opts)

      assert Exception.message(error) =~ "bootstrap preparation conflicts"
    end

    assert {:ok, retained} = Ash.get(LocalStorageBootstrapPreparation, first.id, ctx.opts)
    assert retained.record == first.record
    assert retained.local_storage_binding_id == ctx.binding.id
    assert retained.inserted_at == first.inserted_at
  end

  test "missing and foreign bindings cannot create a preparation or reuse an operation", ctx do
    other = LocalStorageFixtures.context()

    for binding_id <- [Ecto.UUID.generate(), other.binding.id] do
      assert {:error, error} =
               LocalStorageBootstrapPreparation.prepare(ctx.operation_id, binding_id, ctx.opts)

      assert Exception.message(error) =~ "requires an available scoped storage binding"
    end

    assert {:ok, []} = Ash.read(LocalStorageBootstrapPreparation, ctx.opts)

    assert {:ok, first} =
             LocalStorageBootstrapPreparation.prepare(ctx.operation_id, ctx.binding.id, ctx.opts)

    assert {:error, _} =
             LocalStorageBootstrapPreparation.prepare(ctx.operation_id, other.binding.id,
               actor: other.provisioner
             )

    assert {:ok, []} = Ash.read(LocalStorageBootstrapPreparation, actor: other.provisioner)
    assert {:ok, retained} = Ash.get(LocalStorageBootstrapPreparation, first.id, ctx.opts)
    assert retained.record == first.record
  end

  test "only the scoped provisioning principal can prepare or retry and reads remain scoped",
       ctx do
    for actor <- [
          nil,
          SystemActor.system(:synthetic_recorder),
          ctx.qualifier,
          Map.put(ctx.provisioner, :role, :admin),
          Map.put(ctx.provisioner, :nvr_storage_purpose, :record),
          Map.put(ctx.provisioner, :nvr_storage_id, Ecto.UUID.generate()),
          Map.put(ctx.provisioner, :id, "invalid\nprincipal")
        ] do
      assert {:error, _} =
               LocalStorageBootstrapPreparation.prepare(ctx.operation_id, ctx.binding.id,
                 actor: actor
               )
    end

    assert {:ok, []} = Ash.read(LocalStorageBootstrapPreparation, ctx.opts)

    assert {:ok, first} =
             LocalStorageBootstrapPreparation.prepare(ctx.operation_id, ctx.binding.id, ctx.opts)

    assert {:error, _} =
             LocalStorageBootstrapPreparation.prepare(ctx.operation_id, ctx.binding.id,
               actor: ctx.qualifier
             )

    assert {:ok, []} = Ash.read(LocalStorageBootstrapPreparation, actor: ctx.qualifier)

    other = Map.put(ctx.provisioner, :nvr_storage_id, Ecto.UUID.generate())
    assert {:ok, []} = Ash.read(LocalStorageBootstrapPreparation, actor: other)
    assert {:ok, [retained]} = Ash.read(LocalStorageBootstrapPreparation, ctx.opts)
    assert retained.id == first.id
  end
end
