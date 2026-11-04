defmodule ServiceRadar.Edge.IssuerKeyDbTest do
  @moduledoc """
  The edge issuer key core generates on first use and stores in CNPG: one row, the seed
  encrypted at rest, and a key that never changes once stored.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.EdgeIssuerKeyRecord
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Repo

  @moduletag :integration

  test "core stores one key with its seed encrypted, and reads the same key back" do
    assert {:ok, key} = IssuerKey.ensure_stored()
    assert {:ok, ^key} = IssuerKey.ensure_stored()

    assert {:ok, %{rows: [[public_key, encrypted_seed]]}} =
             Repo.query("SELECT public_key, encrypted_seed FROM platform.edge_issuer_key")

    assert Base.decode64!(public_key) == key.public_key
    assert :binary.match(encrypted_seed, key.seed) == :nomatch
    assert :binary.match(encrypted_seed, Base.encode64(key.seed)) == :nomatch
  end

  test "an insert that loses the race to a stored key leaves that key in place" do
    assert {:ok, stored} = IssuerKey.ensure_stored()
    other = IssuerKey.from_seed(:binary.copy(<<0x24>>, 32))

    EdgeIssuerKeyRecord
    |> Ash.Changeset.for_create(
      :generate,
      %{public_key: Base.encode64(other.public_key), seed: Base.encode64(other.seed)},
      actor: SystemActor.system(:edge_issuer_key_test)
    )
    |> Ash.create()

    assert {:ok, ^stored} = IssuerKey.ensure_stored()

    assert {:ok, %{rows: [[1]]}} = Repo.query("SELECT count(*) FROM platform.edge_issuer_key")
  end
end
