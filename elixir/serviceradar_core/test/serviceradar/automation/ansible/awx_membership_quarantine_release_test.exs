defmodule ServiceRadar.Automation.Ansible.AwxMembershipQuarantineReleaseTest do
  @moduledoc """
  Release refusals that do not need storage: request binding, reviewer
  authority, the membership's state, and the action's own guard. The storage
  outcomes (proposed, unlinked, ambiguous, the release record) are owned by
  `AwxMembershipQuarantineReleaseIntegrationTest`.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxMembershipQuarantineRelease
  alias ServiceRadar.Automation.Ansible.AwxMembershipReconciler
  alias ServiceRadar.Automation.Ansible.AwxMembershipReviewer

  @membership_id "01980d8e-b6f8-7c16-a998-8ad49c96f36c"
  @controller_id "01980d8e-b6f8-7c16-a998-8ad49c96f36a"
  @actor_id "01980d8e-b6f8-7c16-a998-8ad49c96f36b"
  @fingerprint "sha256:1111111111111111111111111111111111111111111111111111111111111111"
  @permission "ansible.controllers.manage"
  @now ~U[2026-07-13 08:00:00.000000Z]

  test "takes the controller lock before reading the membership it releases" do
    membership = membership()
    assert {:ok, _released} = release(request(membership), membership)

    {:messages, messages} = Process.info(self(), :messages)

    assert [{:lock_controller, @controller_id}, {:load_membership, @membership_id}] ==
             Enum.filter(
               messages,
               &match?({tag, _} when tag in [:lock_controller, :load_membership], &1)
             )
  end

  test "refuses stale evidence, a state other than quarantined, and an expired row" do
    membership = membership()

    stale = [
      {%{request(membership) | source_generation: 9}, membership, :membership_evidence_changed},
      {%{request(membership) | link_evidence_digest: String.duplicate("2", 64)}, membership,
       :membership_evidence_changed},
      {%{request(membership) | awx_host_id: 101}, membership, :membership_identity_changed}
    ]

    proposed = membership(link_disposition: :proposed, quarantine_reason: nil)
    expired = membership(current: false, expired_at: @now)

    for {request, current, reason} <-
          stale ++
            [
              {request(proposed), proposed, :membership_not_quarantined},
              {request(expired), expired, :membership_not_current}
            ] do
      assert {:error, ^reason} = release(request, current)
    end

    refute_received {:release_membership, _, _}
    refute_received {:record_release, _}
  end

  test "rejects a request that names a device or omits a field before reading authority" do
    membership = membership()

    for request <- [
          Map.put(request(membership), :canonical_device_uid, "device-100"),
          Map.delete(request(membership), :link_evidence_digest)
        ] do
      assert {:error, :invalid_release_request} = release(request, membership)
    end

    refute_received {:load_user, _}
  end

  test "system actors and users without current permission cannot release" do
    membership = membership()

    assert {:error, :human_approval_required} =
             AwxMembershipQuarantineRelease.release(
               request(membership),
               SystemActor.system(:awx_membership_reconciler),
               dependencies: dependencies(membership)
             )

    refute_received {:load_user, _}

    assert {:error, :current_permission_denied} =
             AwxMembershipQuarantineRelease.release(
               request(membership),
               %{user: %{id: @actor_id, role: :admin, permissions: MapSet.new([@permission])}},
               dependencies: dependencies(membership, fresh_permissions: MapSet.new())
             )

    refute_received {:lock_controller, _}
  end

  test "the release action refuses a system actor and any outcome other than proposed or unlinked" do
    membership = struct!(AwxHostMembership, membership())
    tuple = {@controller_id, 7, 100}

    human = %{id: @actor_id, role: :admin, principal_type: :human, permissions: MapSet.new()}

    proposed = action_arguments(membership, :proposed, "device-100", ["device-100"])

    assert changeset(membership, proposed, human).valid?

    refute changeset(membership, proposed, SystemActor.system(:awx_membership_reconciler)).valid?

    for arguments <- [
          %{proposed | released_link_disposition: :approved},
          %{proposed | canonical_device_uid: nil},
          %{
            proposed
            | released_link_evidence:
                AwxMembershipReconciler.source_tuple_evidence(tuple, ["device-100", "device-101"])
          },
          action_arguments(membership, :unlinked, "device-100", [])
        ] do
      refute changeset(membership, arguments, human).valid?
    end
  end

  defp changeset(membership, arguments, actor) do
    Ash.Changeset.for_update(membership, :release_quarantine, arguments, actor: actor)
  end

  defp action_arguments(membership, disposition, device_uid, matches) do
    %{
      controller_id: membership.controller_id,
      inventory_id: membership.inventory_id,
      awx_host_id: membership.awx_host_id,
      source_generation: membership.source_generation,
      source_fingerprint: membership.source_fingerprint,
      expected_link_evidence: membership.link_evidence,
      released_link_disposition: disposition,
      canonical_device_uid: device_uid,
      released_link_evidence:
        AwxMembershipReconciler.source_tuple_evidence({@controller_id, 7, 100}, matches)
    }
  end

  defp release(request, membership) do
    AwxMembershipQuarantineRelease.release(request, %{id: @actor_id, role: :admin},
      dependencies: dependencies(membership)
    )
  end

  defp dependencies(membership, opts \\ []) do
    parent = self()
    fresh_permissions = Keyword.get(opts, :fresh_permissions, MapSet.new([@permission]))

    %{
      transaction: & &1.(),
      lock_controller: fn controller_id ->
        send(parent, {:lock_controller, controller_id})
        :ok
      end,
      load_user: fn actor_id ->
        send(parent, {:load_user, actor_id})
        {:ok, %{id: actor_id, role: :admin, status: :active}}
      end,
      load_authority: fn _user ->
        {:ok, %{permissions: fresh_permissions, profile_versions: []}}
      end,
      load_membership: fn membership_id ->
        send(parent, {:load_membership, membership_id})
        {:ok, membership}
      end,
      current_matches: fn _tuple, _actor -> {:ok, ["device-100"]} end,
      release_membership: fn current, attrs, actor ->
        send(parent, {:release_membership, attrs, actor})
        {:ok, %{current | link_disposition: attrs.released_link_disposition}}
      end,
      record_release: fn attrs ->
        send(parent, {:record_release, attrs})
        {:ok, attrs}
      end,
      now: fn -> @now end
    }
  end

  defp request(membership) do
    {:ok, digest} = AwxMembershipReviewer.link_evidence_digest(membership.link_evidence)

    %{
      membership_id: membership.id,
      controller_id: membership.controller_id,
      inventory_id: membership.inventory_id,
      awx_host_id: membership.awx_host_id,
      source_generation: membership.source_generation,
      source_fingerprint: membership.source_fingerprint,
      link_evidence_digest: digest
    }
  end

  defp membership(overrides \\ []) do
    base = %{
      id: @membership_id,
      controller_id: @controller_id,
      inventory_id: 7,
      awx_host_id: 100,
      canonical_device_uid: nil,
      source_generation: 10,
      host_name: "host01.example.com",
      ansible_host: "192.0.2.100",
      enabled: true,
      current: true,
      last_seen_at: @now,
      expired_at: nil,
      link_disposition: :quarantined,
      quarantine_reason: :ambiguous_device_match,
      quarantined_at: @now,
      link_evidence: %{
        "kind" => "stored_awx_source_tuple",
        "controller_id" => @controller_id,
        "inventory_id" => 7,
        "awx_host_id" => 100,
        "matching_device_uids" => ["device-100", "device-101"],
        "match_count" => 2
      },
      source_fingerprint: @fingerprint,
      metadata: %{}
    }

    Enum.into(overrides, base)
  end
end
