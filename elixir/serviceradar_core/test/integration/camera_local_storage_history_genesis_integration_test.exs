defmodule ServiceRadar.Camera.LocalStorageHistoryGenesisIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.LocalStorageBootstrapInstallation
  alias ServiceRadar.Camera.LocalStorageBootstrapPreparation
  alias ServiceRadar.Camera.LocalStorageHistoryGenesis
  alias ServiceRadar.Camera.LocalStorageQualification
  alias ServiceRadar.Test.LocalStorageFixtures

  @moduletag :integration

  setup do
    ctx = LocalStorageFixtures.context()
    generation = "00000000-0000-4000-8000-000000000abc"
    provisioner = Map.put(ctx.provisioner, :nvr_recovery_generation, generation)
    opts = [actor: provisioner]

    {:ok, preparation} =
      LocalStorageBootstrapPreparation.prepare(Ecto.UUID.generate(), ctx.binding.id, opts)

    {:ok, installation} =
      LocalStorageBootstrapInstallation.confirm(preparation.id, preparation.record_sha256, opts)

    Map.merge(ctx, %{
      preparation: preparation,
      installation: installation,
      generation: generation,
      provisioner: provisioner,
      opts: opts
    })
  end

  test "explicit genesis retains canonical sequence zero and original provenance on exact retries",
       ctx do
    installation = ctx.installation
    preparation = ctx.preparation

    # Installation itself never manufactures history.
    assert {:ok, []} = Ash.read(LocalStorageHistoryGenesis, ctx.opts)

    expected =
      ~s({"installation_sha256":"#{installation.record_sha256}",) <>
        ~s("kind":"local_storage_history_genesis","operation_id":"#{installation.id}",) <>
        ~s("preparation_sha256":"#{preparation.record_sha256}","previous_sha256":null,) <>
        ~s("recovery_generation":"#{ctx.generation}","sequence":0,) <>
        ~s("storage_id":"#{installation.storage_id}","version":1})

    assert {:ok, first} = establish(ctx)
    assert first.id == installation.id
    assert first.storage_id == installation.storage_id
    assert first.record == expected
    assert byte_size(first.record) <= 1024
    assert first.record_sha256 == Base.encode16(:crypto.hash(:sha256, expected), case: :lower)
    assert first.established_by == ctx.provisioner.id

    assert {:ok, _} =
             LocalStorageBinding.register(Map.put(ctx.configuration, "generation", 2), ctx.opts)

    rotated = Map.put(ctx.provisioner, :id, "system:synthetic_rotated_provisioner")
    assert {:ok, retry} = establish(%{ctx | opts: [actor: rotated]})
    assert retry.record == first.record
    assert retry.record_sha256 == first.record_sha256
    assert retry.established_by == first.established_by
    assert retry.inserted_at == first.inserted_at
    assert {:ok, [retained]} = Ash.read(LocalStorageHistoryGenesis, ctx.opts)
    assert retained.record == expected

    # Historical evidence does not qualify the storage provider.
    assert {:ok, %{qualification_status: :unknown}} =
             LocalStorageQualification.status(actor: ctx.qualifier)
  end

  test "missing installation, wrong digest and changed generation cannot create or reset genesis",
       ctx do
    other = LocalStorageFixtures.context()

    assert {:ok, empty_preparation} =
             LocalStorageBootstrapPreparation.prepare(Ecto.UUID.generate(), other.binding.id,
               actor: other.provisioner
             )

    other_actor = Map.put(other.provisioner, :nvr_recovery_generation, ctx.generation)

    assert {:error, error} =
             LocalStorageHistoryGenesis.establish(
               empty_preparation.id,
               ctx.installation.record_sha256,
               actor: other_actor
             )

    assert Exception.message(error) =~ "exact scoped installation"
    assert {:ok, []} = Ash.read(LocalStorageHistoryGenesis, actor: other_actor)

    for digest <- [
          String.duplicate("0", 64),
          String.upcase(ctx.installation.record_sha256),
          "",
          nil
        ] do
      assert {:error, _} =
               LocalStorageHistoryGenesis.establish(ctx.installation.id, digest, ctx.opts)
    end

    for generation <- [nil, "invalid", String.upcase(ctx.generation)] do
      actor = Map.put(ctx.provisioner, :nvr_recovery_generation, generation)
      assert {:error, _} = establish(%{ctx | opts: [actor: actor]})
    end

    assert {:ok, []} = Ash.read(LocalStorageHistoryGenesis, ctx.opts)
    assert {:ok, first} = establish(ctx)

    changed = Map.put(ctx.provisioner, :nvr_recovery_generation, Ecto.UUID.generate())
    assert {:error, error} = establish(%{ctx | opts: [actor: changed]})
    assert Exception.message(error) =~ "history genesis conflicts"
    assert {:ok, retained} = Ash.get(LocalStorageHistoryGenesis, first.id, ctx.opts)
    assert retained.record == first.record
    assert retained.record_sha256 == first.record_sha256
    assert retained.established_by == first.established_by
    assert retained.inserted_at == first.inserted_at
    assert {:ok, retry} = establish(ctx)
    assert retry.record == first.record
  end

  test "only the scoped provisioner can establish, retry or read genesis", ctx do
    other = LocalStorageFixtures.context()

    actors = [
      nil,
      SystemActor.system(:synthetic_recorder),
      ctx.qualifier,
      Map.put(ctx.provisioner, :nvr_storage_purpose, :record),
      Map.put(ctx.provisioner, :id, "invalid\nprincipal"),
      Map.put(other.provisioner, :nvr_recovery_generation, ctx.generation)
    ]

    for actor <- actors do
      assert {:error, _} = establish(%{ctx | opts: [actor: actor]})
    end

    assert {:ok, []} = Ash.read(LocalStorageHistoryGenesis, ctx.opts)
    assert {:ok, first} = establish(ctx)

    for actor <- actors do
      assert {:error, _} = establish(%{ctx | opts: [actor: actor]})
    end

    assert {:ok, []} = Ash.read(LocalStorageHistoryGenesis, actor: other.provisioner)
    assert {:ok, []} = Ash.read(LocalStorageHistoryGenesis, actor: ctx.qualifier)
    assert {:ok, [retained]} = Ash.read(LocalStorageHistoryGenesis, ctx.opts)
    assert retained.record == first.record
  end

  defp establish(ctx) do
    LocalStorageHistoryGenesis.establish(
      ctx.installation.id,
      ctx.installation.record_sha256,
      ctx.opts
    )
  end
end
