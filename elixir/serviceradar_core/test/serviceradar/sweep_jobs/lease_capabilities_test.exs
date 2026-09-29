defmodule ServiceRadar.SweepJobs.LeaseCapabilitiesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.SweepPlan
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseCapabilities
  alias ServiceRadar.SweepJobs.SweepExecutionSlot
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  @key IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
  @targets ["192.0.2.0/28", "198.51.100.7"]
  @check_set :crypto.hash(:sha256, "checks")
  @issued_at ~U[2026-10-01 11:58:00Z]

  @contract %{
    contract_id: "serviceradar.sweep.observation",
    contract_version: 1,
    contract_bundle_sha256: :crypto.hash(:sha256, "bundle"),
    registry_epoch: 1,
    registry_snapshot_sha256: :crypto.hash(:sha256, "snapshot"),
    effective_grant_sha256: :crypto.hash(:sha256, "grant"),
    cost_model_version: 1,
    max_projected_row_count: 10_000,
    max_projected_write_bytes: 16_777_216
  }

  setup do
    assignment = %SweepProducerAssignment{
      id: Ecto.UUID.generate(),
      sweep_group_id: Ecto.UUID.generate(),
      agent_id: "agent-01",
      network_scope_id: Ecto.UUID.generate(),
      run_shard: 0,
      authority_epoch: 3,
      state: :active
    }

    lease_id = Ecto.UUID.generate()

    slots =
      for start <- [~U[2026-10-01 12:00:00Z], ~U[2026-10-01 12:15:00Z]] do
        slot(assignment, lease_id, start, DateTime.add(start, 900, :second))
      end

    {:ok, assignment: assignment, slots: slots, lease_id: lease_id}
  end

  describe "source_authorizations/3" do
    test "one signed SCHEDULED_SWEEP authorization per range, bound to the execution and range",
         ctx do
      [slot | _] = ctx.slots
      assert {:ok, auths} = LeaseCapabilities.source_authorizations(ctx.assignment, slot, @key)

      ranges = Enum.flat_map(slot.plan_pages, &ScheduledPlanPageV1.decode(&1).ranges)
      assert length(auths) == length(@targets)

      for {auth, range} <- Enum.zip(auths, ranges) do
        cap = auth.capability
        {:source, claims} = cap.claims

        assert :ok == CapabilitySigning.validate(cap, :source)
        assert CapabilitySigning.verify(cap, :source, @key.public_key)

        # The wrapper repeats the claims, as the record validator requires.
        assert auth.kind == :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP
        assert claims.kind == auth.kind

        assert {auth.context_id, auth.scope_id, auth.scope_sha256} ==
                 {claims.context_id, claims.scope_id, claims.scope_sha256}

        # The sweep join: execution, range identity and digests, plan.
        assert claims.context_id == Ecto.UUID.dump!(slot.id)
        assert claims.scope_id == range.range_id
        assert claims.scope_sha256 == range.range_sha256
        assert claims.target_range_sha256 == range.range_sha256
        assert claims.execution_plan_sha256 == slot.plan_sha256
        refute claims.target_range_sha256 == claims.execution_plan_sha256

        # The collection window is the slot and sits inside the signed window.
        assert claims.collection_not_before_unix_nano ==
                 DateTime.to_unix(slot.slot_start, :nanosecond)

        assert claims.collection_expires_unix_nano ==
                 DateTime.to_unix(slot.collection_expires, :nanosecond)

        assert cap.not_before_unix_nano <= claims.collection_not_before_unix_nano
        assert cap.expires_at_unix_nano >= claims.collection_expires_unix_nano

        # The lease and the producer it names.
        assert claims.producer_assignment_id == Ecto.UUID.dump!(ctx.assignment.id)
        assert claims.run_id == Ecto.UUID.dump!(ctx.lease_id)
        assert claims.authority_epoch == 3
        assert claims.network_scope_id == Ecto.UUID.dump!(ctx.assignment.network_scope_id)
        assert claims.origin_principal_id == "agent-01"
        assert claims.producer_instance_id == "agent-01"
      end
    end

    test "a slot planned under another epoch or assignment is refused", ctx do
      slot = hd(ctx.slots)
      stale_epoch = %{ctx.assignment | authority_epoch: 4}
      other_assignment = %{slot | producer_assignment_id: Ecto.UUID.generate()}

      assert {:error, :stale_slot} =
               LeaseCapabilities.source_authorizations(stale_epoch, slot, @key)

      assert {:error, :stale_slot} =
               LeaseCapabilities.source_authorizations(ctx.assignment, other_assignment, @key)
    end
  end

  describe "production_capability/5" do
    test "one signed capability that covers every slot of the lease", ctx do
      assert {:ok, cap} =
               LeaseCapabilities.production_capability(
                 ctx.assignment,
                 ctx.slots,
                 @contract,
                 @key,
                 @issued_at
               )

      {:production, claims} = cap.claims

      assert :ok == CapabilitySigning.validate(cap, :production)
      assert CapabilitySigning.verify(cap, :production, @key.public_key)

      assert cap.not_before_unix_nano == DateTime.to_unix(@issued_at, :nanosecond)
      assert cap.expires_at_unix_nano == DateTime.to_unix(~U[2026-10-01 12:30:00Z], :nanosecond)

      assert claims.run_id == Ecto.UUID.dump!(ctx.lease_id)
      assert claims.authority_epoch == 3
      assert claims.scope_id == Ecto.UUID.dump!(ctx.assignment.sweep_group_id)

      assert claims.scope_sha256 ==
               LeaseCapabilities.lease_scope_sha256(
                 ctx.assignment.sweep_group_id,
                 @check_set,
                 ["192.0.2.0/28", "198.51.100.7/32"]
               )

      assert claims.package_id == "serviceradar.agent.sweep"

      assert claims.package_sha256 ==
               :crypto.hash(:sha256, "serviceradar.agent.sweep.package.v1")

      assert claims.contract_id == @contract.contract_id
      assert claims.effective_grant_sha256 == @contract.effective_grant_sha256
      assert claims.origin_principal_id == "agent-01"
    end

    test "the lease scope digest changes with the group, the checks or any range", ctx do
      base =
        LeaseCapabilities.lease_scope_sha256(ctx.assignment.sweep_group_id, @check_set, ["a"])

      refute base ==
               LeaseCapabilities.lease_scope_sha256(Ecto.UUID.generate(), @check_set, ["a"])

      refute base ==
               LeaseCapabilities.lease_scope_sha256(
                 ctx.assignment.sweep_group_id,
                 :crypto.hash(:sha256, "other"),
                 ["a"]
               )

      refute base ==
               LeaseCapabilities.lease_scope_sha256(ctx.assignment.sweep_group_id, @check_set, [
                 "a",
                 "b"
               ])
    end

    test "slots of different leases, stale slots, no slots and a bad contract are refused", ctx do
      [first, second] = ctx.slots
      other_lease = %{second | lease_id: Ecto.UUID.generate()}
      prod = &LeaseCapabilities.production_capability(ctx.assignment, &1, &2, @key, @issued_at)

      assert {:error, :mixed_lease} = prod.([first, other_lease], @contract)
      assert {:error, :stale_slot} = prod.([%{first | authority_epoch: 2}], @contract)

      assert {:error, :stale_slot} =
               prod.([%{first | producer_assignment_id: Ecto.UUID.generate()}], @contract)

      assert {:error, :invalid_plan} = prod.([%{first | plan_pages: []}], @contract)
      assert {:error, :no_slots} = prod.([], @contract)

      assert {:error, {:invalid_contract, :contract_bundle_sha256}} =
               prod.(ctx.slots, %{@contract | contract_bundle_sha256: "short"})

      assert {:error, {:invalid_contract, :cost_model_version}} =
               prod.(ctx.slots, Map.delete(@contract, :cost_model_version))
    end
  end

  # The slot row ExecutionSlots.schedule/4 stores, built in memory from the same plan builder.
  defp slot(assignment, lease_id, start, expires) do
    {:ok, %{header: header, pages: pages}} =
      SweepPlan.build(@targets,
        plan_id: start |> ExecutionSlots.mint_id() |> Ecto.UUID.dump!(),
        network_scope_id: Ecto.UUID.dump!(assignment.network_scope_id),
        check_set_sha256: @check_set
      )

    %SweepExecutionSlot{
      id: ExecutionSlots.mint_id(start),
      sweep_group_id: assignment.sweep_group_id,
      agent_id: assignment.agent_id,
      producer_assignment_id: assignment.id,
      network_scope_id: assignment.network_scope_id,
      authority_epoch: assignment.authority_epoch,
      lease_id: lease_id,
      slot_start: start,
      collection_expires: expires,
      plan_sha256: header.execution_plan_sha256,
      check_set_sha256: @check_set,
      plan_pages: Enum.map(pages, &ScheduledPlanPageV1.encode/1),
      state: :scheduled
    }
  end
end
