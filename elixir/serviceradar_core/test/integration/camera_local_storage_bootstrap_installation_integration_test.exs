defmodule ServiceRadar.Camera.LocalStorageBootstrapInstallationIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.LocalStorageBinding
  alias ServiceRadar.Camera.LocalStorageBootstrapInstallation
  alias ServiceRadar.Camera.LocalStorageBootstrapPreparation
  alias ServiceRadar.Camera.LocalStorageQualification
  alias ServiceRadar.Test.LocalStorageFixtures

  @moduletag :integration

  setup do
    ctx = LocalStorageFixtures.context()
    opts = [actor: ctx.provisioner]

    {:ok, preparation} =
      LocalStorageBootstrapPreparation.prepare(Ecto.UUID.generate(), ctx.binding.id, opts)

    Map.merge(ctx, %{preparation: preparation, opts: opts})
  end

  test "installation retains exact acknowledgement and original provenance across retries", ctx do
    preparation = ctx.preparation

    expected =
      ~s({"kind":"local_storage_bootstrap_installed","operation_id":"#{preparation.id}",) <>
        ~s("preparation_sha256":"#{preparation.record_sha256}",) <>
        ~s("storage_id":"#{preparation.storage_id}","version":1})

    assert {:ok, first} =
             LocalStorageBootstrapInstallation.confirm(
               preparation.id,
               preparation.record_sha256,
               ctx.opts
             )

    assert first.id == preparation.id
    assert first.storage_id == preparation.storage_id
    assert first.record == expected
    assert first.record_sha256 == Base.encode16(:crypto.hash(:sha256, expected), case: :lower)
    assert first.confirmed_by == ctx.provisioner.id

    # A newer binding does not rewrite the historical installation acknowledgement.
    assert {:ok, _} =
             LocalStorageBinding.register(Map.put(ctx.configuration, "generation", 2), ctx.opts)

    rotated = Map.put(ctx.provisioner, :id, "system:synthetic_rotated_provisioner")

    assert {:ok, retry} =
             LocalStorageBootstrapInstallation.confirm(preparation.id, preparation.record_sha256,
               actor: rotated
             )

    assert retry.record == expected
    assert retry.record_sha256 == first.record_sha256
    assert retry.confirmed_by == first.confirmed_by
    assert retry.inserted_at == first.inserted_at
    assert {:ok, [retained]} = Ash.read(LocalStorageBootstrapInstallation, ctx.opts)
    assert retained.id == first.id
    assert retained.record == expected

    assert {:ok, %{qualification_status: :unknown}} =
             LocalStorageQualification.status(actor: ctx.qualifier)
  end

  test "wrong or missing preparation and digest cannot create or replace installation", ctx do
    preparation = ctx.preparation
    wrong_digest = String.duplicate("0", 64)
    refute wrong_digest == preparation.record_sha256

    for digest <- [wrong_digest, String.upcase(preparation.record_sha256), "", nil] do
      assert {:error, _} =
               LocalStorageBootstrapInstallation.confirm(preparation.id, digest, ctx.opts)
    end

    assert {:error, error} =
             LocalStorageBootstrapInstallation.confirm(
               Ecto.UUID.generate(),
               preparation.record_sha256,
               ctx.opts
             )

    assert Exception.message(error) =~ "exact scoped bootstrap preparation and digest"
    assert {:ok, []} = Ash.read(LocalStorageBootstrapInstallation, ctx.opts)

    assert {:ok, first} =
             LocalStorageBootstrapInstallation.confirm(
               preparation.id,
               preparation.record_sha256,
               ctx.opts
             )

    assert {:error, error} =
             LocalStorageBootstrapInstallation.confirm(preparation.id, wrong_digest, ctx.opts)

    assert Exception.message(error) =~ "exact scoped bootstrap preparation and digest"
    assert {:ok, retained} = Ash.get(LocalStorageBootstrapInstallation, first.id, ctx.opts)
    assert retained.record == first.record
    assert retained.confirmed_by == first.confirmed_by
    assert retained.inserted_at == first.inserted_at
  end

  test "only the scoped provisioner can confirm or retry and read installation", ctx do
    preparation = ctx.preparation
    other = LocalStorageFixtures.context()

    actors = [
      nil,
      SystemActor.system(:synthetic_recorder),
      ctx.qualifier,
      Map.put(ctx.provisioner, :nvr_storage_purpose, :record),
      Map.put(ctx.provisioner, :id, "invalid\nprincipal"),
      other.provisioner
    ]

    for actor <- actors do
      assert {:error, _} =
               LocalStorageBootstrapInstallation.confirm(
                 preparation.id,
                 preparation.record_sha256,
                 actor: actor
               )
    end

    assert {:ok, []} = Ash.read(LocalStorageBootstrapInstallation, ctx.opts)
    assert {:ok, []} = Ash.read(LocalStorageBootstrapInstallation, actor: other.provisioner)

    assert {:ok, first} =
             LocalStorageBootstrapInstallation.confirm(
               preparation.id,
               preparation.record_sha256,
               ctx.opts
             )

    for actor <- actors do
      assert {:error, _} =
               LocalStorageBootstrapInstallation.confirm(
                 preparation.id,
                 preparation.record_sha256,
                 actor: actor
               )
    end

    assert {:ok, []} = Ash.read(LocalStorageBootstrapInstallation, actor: other.provisioner)
    assert {:ok, []} = Ash.read(LocalStorageBootstrapInstallation, actor: ctx.qualifier)
    assert {:ok, [retained]} = Ash.read(LocalStorageBootstrapInstallation, ctx.opts)
    assert retained.record == first.record
  end
end
