defmodule ServiceRadar.Edge.ContractRegistryDbTest do
  @moduledoc """
  The core-derived registry epochs against a real database: how a booting node records its
  release's catalog, what the verified reader returns, and the table's write-once guarantees.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.ContractRegistryEpoch
  alias ServiceRadar.Edge.ContractRegistryEpochDocument, as: EpochDocument
  alias ServiceRadar.Edge.DeliveryGrants
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  @key IssuerKey.from_seed(:binary.copy(<<0x31>>, 32))
  @t0 ~U[2026-11-01 00:00:00.000000Z]

  # Release catalogs A (this build), B and C: B and C bump the first contract's revision.
  defp release(:a), do: ContractBundle.derive(ContractCatalog.entries())
  defp release(:b), do: bumped(2)
  defp release(:c), do: bumped(3)

  defp bumped(revision) do
    ContractCatalog.entries()
    |> List.update_at(0, &%{&1 | projection_revision: revision})
    |> ContractBundle.derive()
  end

  defp boot(release, minutes \\ 0),
    do:
      ContractRegistry.ensure_epoch(release(release), @key, DateTime.shift(@t0, minute: minutes))

  defp rows do
    ContractRegistryEpoch
    |> Ash.Query.sort(epoch: :asc)
    |> Ash.read!(actor: SystemActor.system(:registry_test))
    |> Enum.map(&{&1.epoch, &1.state, &1.activated_at != nil})
  end

  test "the first catalog becomes epoch 1_000_000 and activates at once" do
    assert {:ok, %{role: :active, epoch: 1_000_000}} = boot(:a)
    assert [{1_000_000, :active, true}] = rows()

    assert {:ok, view} = ContractRegistry.view(@key)
    assert {:ok, active} = ContractRegistry.active_epoch(view)
    assert active.snapshot_sha256 == release(:a).snapshot_sha256
    assert active.contracts == release(:a).contracts

    # Replicas of the same release converge on the one row.
    assert {:ok, %{role: :active, epoch: 1_000_000}} = boot(:a, 1)
    assert [{1_000_000, :active, true}] = rows()
  end

  test "a newer catalog is a candidate, and a still newer one retires it unactivated" do
    {:ok, _} = boot(:a)

    assert {:ok, %{role: :candidate, epoch: 1_000_001}} = boot(:b, 1)
    assert {:ok, %{role: :candidate, epoch: 1_000_002}} = boot(:c, 2)

    assert [
             {1_000_000, :active, true},
             {1_000_001, :retired, false},
             {1_000_002, :candidate, false}
           ] = rows()

    # A node left on B cannot take the candidate back from C, and A still matches active.
    assert {:ok, %{role: :superseded, epoch: nil}} = boot(:b, 3)
    assert {:ok, %{role: :active, epoch: 1_000_000}} = boot(:a, 3)
    assert length(rows()) == 3
  end

  # What the live components hold: core nodes running `core`'s catalog, and gateways each
  # holding the listed epochs.
  defp readiness(core, gateways, unreachable \\ []) do
    %{
      core_nodes:
        Enum.map(core, fn {node, release} ->
          %{node: node, snapshot_sha256: release(release).snapshot_sha256}
        end),
      unreachable_nodes: unreachable,
      gateways:
        Enum.map(gateways, fn
          {id, nil} ->
            %{gateway_id: id, installed: nil}

          {id, held} ->
            %{
              gateway_id: id,
              installed:
                Enum.map(held, fn {epoch, release} ->
                  %{epoch: epoch, snapshot_sha256: release(release).snapshot_sha256}
                end)
            }
        end)
    }
  end

  defp evaluate(readiness, minutes),
    do:
      ContractRegistry.evaluate_transition(readiness, @key, DateTime.shift(@t0, minute: minutes))

  test "a later candidate activates only once every live core node and gateway holds it" do
    {:ok, _} = boot(:a)
    {:ok, %{role: :candidate, epoch: candidate}} = boot(:b, 1)
    holds_both = [{1_000_000, :a}, {candidate, :b}]

    # Each missing piece keeps epoch 1_000_000 active and names what blocks the candidate.
    for {not_ready, blocker} <- [
          {readiness([{"core-1", :b}, {"core-2", :a}], [{"gw-1", holds_both}]),
           {:core_node, "core-2", :other_catalog}},
          {readiness([{"core-1", :b}], [{"gw-1", holds_both}, {"gw-2", [{1_000_000, :a}]}]),
           {:gateway, "gw-2", :candidate_not_installed}},
          {readiness([{"core-1", :b}], [{"gw-1", nil}]), {:gateway, "gw-1", :no_report}},
          {readiness([{"core-1", :b}], [], ["gateway@node"]),
           {:node_unreachable, "gateway@node"}},
          {readiness([], []), :no_core_node}
        ] do
      assert {:ok, {:waiting, ^candidate, blockers}} = evaluate(not_ready, 2)
      assert blocker in blockers
      assert [{1_000_000, :active, true}, {^candidate, :candidate, false}] = rows()
    end

    assert {:ok, {:activated, ^candidate, 1_000_000}} =
             evaluate(readiness([{"core-1", :b}], [{"gw-1", holds_both}]), 3)

    assert [{1_000_000, :draining, true}, {^candidate, :active, true}] = rows()

    assert {:ok, view} = ContractRegistry.view(@key)
    assert {:ok, active} = ContractRegistry.active_epoch(view)
    assert active.snapshot_sha256 == release(:b).snapshot_sha256

    # The old epoch stays in the trust document while it drains, so its backlog is admitted.
    assert {:ok, %{"epochs" => epochs}} = ContractRegistry.trust_member(@key)

    assert Enum.map(epochs, &{&1["registry_epoch"], &1["state"]}) == [
             {1_000_000, "draining"},
             {candidate, "active"}
           ]

    # With no open sweep slot, it drains for a standing grant's lifetime plus a delivery grant's.
    drained =
      Ash.get!(ContractRegistryEpoch, 1_000_000, actor: SystemActor.system(:registry_test))

    activated_at = DateTime.shift(@t0, minute: 3)

    assert drained.drain_until ==
             DateTime.shift(
               activated_at,
               second: OutputGrants.max_lifetime_seconds() + DeliveryGrants.ttl_seconds()
             )

    minutes_to_drain = div(DateTime.diff(drained.drain_until, @t0, :second), 60)
    assert {:ok, :no_candidate} = evaluate(readiness([{"core-1", :b}], []), minutes_to_drain - 1)
    assert [{1_000_000, :draining, true}, {^candidate, :active, true}] = rows()

    assert {:ok, :no_candidate} = evaluate(readiness([{"core-1", :b}], []), minutes_to_drain + 1)
    assert [{1_000_000, :retired, true}, {^candidate, :active, true}] = rows()
  end

  test "a candidate no live core node runs is retired unactivated after a full grant window" do
    {:ok, _} = boot(:a)
    {:ok, %{epoch: candidate}} = boot(:b, 1)
    rolled_back = readiness([{"core-1", :a}], [])
    window_minutes = div(OutputGrants.max_lifetime_seconds(), 60)

    assert {:ok, {:waiting, ^candidate, _blockers}} = evaluate(rolled_back, window_minutes)
    assert [{1_000_000, :active, true}, {^candidate, :candidate, false}] = rows()

    assert {:ok, {:abandoned, ^candidate}} = evaluate(rolled_back, window_minutes + 2)
    assert [{1_000_000, :active, true}, {^candidate, :retired, false}] = rows()
  end

  test "a candidate a live core node still runs is kept past the grant window" do
    {:ok, _} = boot(:a)
    {:ok, %{epoch: candidate}} = boot(:b, 1)
    window_minutes = div(OutputGrants.max_lifetime_seconds(), 60)
    mixed = readiness([{"core-1", :a}, {"core-2", :b}], [])

    assert {:ok, {:waiting, ^candidate, _}} = evaluate(mixed, window_minutes)
    assert {:ok, {:waiting, ^candidate, _}} = evaluate(mixed, 2 * window_minutes)
    assert [{1_000_000, :active, true}, {^candidate, :candidate, false}] = rows()
  end

  test "a catalog whose candidate was abandoned is inserted again when no candidate exists" do
    {:ok, _} = boot(:a)
    {:ok, %{epoch: abandoned}} = boot(:b, 1)
    actor = SystemActor.system(:registry_test)

    ContractRegistryEpoch
    |> Ash.get!(abandoned, actor: actor)
    |> Ash.Changeset.for_update(
      :retire_unactivated,
      %{retired_at: DateTime.shift(@t0, minute: 2)},
      actor: actor
    )
    |> Ash.update!()

    assert {:ok, %{role: :candidate, epoch: 1_000_002}} = boot(:b, 3)
  end

  test "the trust member carries every verified non-retired epoch for gateways to verify" do
    {:ok, _} = boot(:a)
    {:ok, _} = boot(:b, 1)

    assert {:ok, %{"format_version" => 2, "epochs" => epochs}} =
             ContractRegistry.trust_member(@key)

    assert Enum.map(epochs, &{&1["registry_epoch"], &1["state"]}) == [
             {1_000_000, "active"},
             {1_000_001, "candidate"}
           ]

    for item <- epochs do
      assert {:ok, epoch} =
               item |> Jason.encode!() |> Jason.decode!() |> EpochDocument.from_trust()

      assert :ok == EpochDocument.verify(epoch, %{@key.key_id => @key.public_key})
    end
  end

  test "a row whose content does not match its signature is excluded, and a bad active epoch signs nothing" do
    signed = EpochDocument.sign(1_000_000, Map.values(release(:a).contracts), @key)
    [first | rest] = Map.values(signed.contracts)
    forged = [%{first | cost_model_version: first.cost_model_version + 1} | rest]
    actor = SystemActor.system(:registry_test)

    ContractRegistryEpoch
    |> Ash.Changeset.for_create(
      :insert_candidate,
      %{
        epoch: 1_000_000,
        snapshot_sha256: signed.snapshot_sha256,
        document: EpochDocument.document(forged),
        signature: signed.signature,
        signing_key_id: signed.signing_key_id,
        created_at: @t0,
        last_matched_at: @t0
      },
      actor: actor
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:activate, %{activated_at: @t0}, actor: actor)
    |> Ash.update!()

    assert {:ok, %{epochs: [], invalid: [invalid]} = view} = ContractRegistry.view(@key)

    assert invalid == %{
             epoch: 1_000_000,
             state: :active,
             reason: :registry_epoch_signature_invalid
           }

    assert {:error, {:registry_epoch_signature_invalid, 1_000_000}} =
             ContractRegistry.active_epoch(view)

    assert {:ok, %{"epochs" => []}} = ContractRegistry.trust_member(@key)
  end

  test "epoch content is write-once and state only moves forward" do
    {:ok, _} = boot(:a)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             in_savepoint(
               "UPDATE platform.edge_contract_registry_epochs SET document = '{}'::jsonb WHERE epoch = 1000000"
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             in_savepoint(
               "UPDATE platform.edge_contract_registry_epochs SET state = 'candidate', activated_at = NULL WHERE epoch = 1000000"
             )
  end

  test "a gateway's installation report reaches every core node normalized, and a malformed one is refused" do
    :ok = Phoenix.PubSub.subscribe(ServiceRadar.PubSub, ContractRegistry.reports_topic())
    snapshot = release(:a).snapshot_sha256
    gateway = "gateway-#{System.unique_integer([:positive])}"

    report = %{
      "gateway_id" => gateway,
      "installed" => [
        %{
          "registry_epoch" => 1_000_000,
          "registry_snapshot_sha256" => Base.encode16(snapshot, case: :lower)
        }
      ],
      "refused" => [
        %{
          "registry_epoch" => 1_000_001,
          "signing_key_id" => Base.encode64(@key.key_id),
          "reason" => "registry_epoch_signature_invalid"
        }
      ]
    }

    assert :ok == ContractRegistry.record_gateway_report(report, @t0)

    assert_receive {:edge_registry_gateway_report,
                    %{
                      gateway_id: ^gateway,
                      installed: [%{epoch: 1_000_000, snapshot_sha256: ^snapshot}],
                      refused: [%{epoch: 1_000_001, reason: "registry_epoch_signature_invalid"}],
                      received_at: @t0
                    }}

    for bad <- [
          Map.delete(report, "refused"),
          Map.put(report, "gateway_id", ""),
          put_in(report, ["installed"], [%{"registry_epoch" => 1_000_000}])
        ] do
      assert {:error, :invalid_gateway_report} == ContractRegistry.record_gateway_report(bad, @t0)
    end

    refute_received {:edge_registry_gateway_report, _}
  end

  defp in_savepoint(sql) do
    Repo.transaction(fn ->
      case Repo.query(sql) do
        {:ok, result} -> result
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end
end
