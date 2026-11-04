defmodule ServiceRadar.Edge.ContractBundleGoldenTest do
  @moduledoc """
  Pins the release's contract registry: every bundle digest and the snapshot digest of
  `ServiceRadar.Edge.ContractCatalog`.

  Changing a catalog entry, its payload message definition, or its `projection_revision` fails
  this test until `test/fixtures/edge/contract_bundle_history_v1.json` records the change in the
  same commit, so every registry epoch is a reviewed decision. The history is append-only per
  `(contract_id, contract_version)`: a changed bundle needs a higher `projection_revision`, a
  revision never decreases, and no digest ever repeats.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractCatalog

  @golden_path Path.expand("../../fixtures/edge/contract_bundle_history_v1.json", __DIR__)
  @external_resource @golden_path

  setup_all do
    golden = @golden_path |> File.read!() |> Jason.decode!()

    history =
      Map.new(golden["contracts"], fn c ->
        {{c["contract_id"], c["contract_version"]},
         Enum.map(c["history"], &{&1["projection_revision"], &1["contract_bundle_sha256"]})}
      end)

    %{golden: golden, history: history, local: ContractBundle.derive(ContractCatalog.entries())}
  end

  test "every catalog bundle is the latest entry of its recorded history", ctx do
    for {ref, entry} <- ctx.local.contracts do
      digest = Base.encode16(entry.contract_bundle_sha256, case: :lower)
      revision = entry.projection_revision

      case ctx.history |> Map.get(ref, []) |> List.last() do
        {^revision, ^digest} ->
          :ok

        nil ->
          flunk("#{inspect(ref)} has no recorded history; append {#{revision}, #{digest}}")

        {^revision, recorded} ->
          flunk(
            "#{inspect(ref)} changed at projection_revision #{revision} " <>
              "(recorded #{recorded}, now #{digest}); bump projection_revision"
          )

        {recorded_revision, _recorded} when revision < recorded_revision ->
          flunk(
            "#{inspect(ref)} projection_revision decreased from #{recorded_revision} to #{revision}"
          )

        {_recorded_revision, _recorded} ->
          flunk("#{inspect(ref)} is a new bundle; append {#{revision}, #{digest}} to its history")
      end
    end
  end

  test "the recorded history only moves forward and never repeats a digest", ctx do
    for {ref, entries} <- ctx.history do
      revisions = Enum.map(entries, &elem(&1, 0))

      assert revisions == Enum.sort(Enum.uniq(revisions)),
             "#{inspect(ref)} history revisions must strictly increase: #{inspect(revisions)}"
    end

    digests = ctx.history |> Map.values() |> List.flatten() |> Enum.map(&elem(&1, 1))
    assert digests == Enum.uniq(digests), "a bundle digest repeats in the recorded history"
  end

  test "the snapshot digest is pinned", ctx do
    assert Base.encode16(ctx.local.snapshot_sha256, case: :lower) ==
             ctx.golden["registry_snapshot_sha256"]
  end

  describe "payload schema fingerprint" do
    defmodule Leaf do
      @moduledoc false
      use Protobuf, full_name: "example.fingerprint.Leaf", syntax: :proto3

      field :value, 1, type: :uint64
    end

    defmodule RenamedLeaf do
      @moduledoc false
      use Protobuf, full_name: "example.fingerprint.Leaf", syntax: :proto3

      field :amount, 1, type: :uint64
    end

    defmodule Root do
      @moduledoc false
      use Protobuf, full_name: "example.fingerprint.Root", syntax: :proto3

      field :leaf, 1, type: Leaf
    end

    defmodule RootOfRenamedLeaf do
      @moduledoc false
      use Protobuf, full_name: "example.fingerprint.Root", syntax: :proto3

      field :leaf, 1, type: RenamedLeaf
    end

    test "a change to a nested message moves the payload's fingerprint" do
      assert ContractBundle.schema_fingerprint(Root) !=
               ContractBundle.schema_fingerprint(RootOfRenamedLeaf)
    end
  end
end
