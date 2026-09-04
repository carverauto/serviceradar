defmodule ServiceRadar.Automation.Ansible.AwxMembershipApprovalTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxMembershipApproval

  @membership_id "01980d8e-b6f8-7c16-a998-8ad49c96f36c"
  @controller_id "01980d8e-b6f8-7c16-a998-8ad49c96f36a"
  @actor_id "01980d8e-b6f8-7c16-a998-8ad49c96f36b"
  @fingerprint "sha256:1111111111111111111111111111111111111111111111111111111111111111"
  @permission "ansible.controllers.manage"
  @now ~U[2026-07-13 08:00:00.000000Z]

  test "uses freshly loaded permissions instead of the caller's cached scope permissions" do
    membership = membership()

    cached_allow_scope = %{
      user: %{
        id: @actor_id,
        role: :admin,
        permissions: MapSet.new([@permission])
      }
    }

    assert {:error, :current_permission_denied} =
             AwxMembershipApproval.approve(
               request(membership),
               cached_allow_scope,
               dependencies: dependencies(membership, fresh_permissions: MapSet.new())
             )

    assert_received {:load_user, @actor_id}
    assert_received {:load_authority, @actor_id}
    refute_received :approve_membership

    cached_deny_scope = %{
      user: %{id: @actor_id, role: :viewer, permissions: MapSet.new()}
    }

    assert {:ok, approved} =
             AwxMembershipApproval.approve(
               request(membership),
               cached_deny_scope,
               dependencies:
                 dependencies(membership, fresh_permissions: MapSet.new([@permission]))
             )

    assert approved.link_disposition == :approved

    assert_received {:approve_membership, attrs, authorized_actor}
    assert attrs.controller_id == @controller_id
    assert attrs.inventory_id == 7
    assert attrs.awx_host_id == 100
    assert attrs.source_generation == 10
    assert attrs.source_fingerprint == @fingerprint
    assert authorized_actor.id == @actor_id
    assert authorized_actor.principal_type == :human
    assert authorized_actor.permissions == MapSet.new([@permission])
  end

  test "binds approval to the exact membership ID, controller, inventory, host, and device" do
    membership = membership()
    base_request = request(membership)

    mismatches = [
      membership_id: "01980d8e-b6f8-7c16-a998-8ad49c96f36d",
      controller_id: "01980d8e-b6f8-7c16-a998-8ad49c96f36e",
      inventory_id: 8,
      awx_host_id: 101
    ]

    for {field, value} <- mismatches do
      assert {:error, :membership_identity_changed} =
               approve(Map.put(base_request, field, value), membership)
    end

    assert {:error, :membership_identity_changed} =
             approve(Map.put(base_request, :canonical_device_uid, "different-device"), membership)
  end

  test "rejects stale generation, fingerprint, evidence digest, and non-current proposals" do
    membership = membership()
    base_request = request(membership)

    assert {:error, :membership_evidence_changed} =
             approve(Map.put(base_request, :source_generation, 9), membership)

    assert {:error, :membership_evidence_changed} =
             approve(
               Map.put(
                 base_request,
                 :source_fingerprint,
                 "sha256:2222222222222222222222222222222222222222222222222222222222222222"
               ),
               membership
             )

    assert {:error, :membership_evidence_changed} =
             approve(
               Map.put(
                 base_request,
                 :link_evidence_digest,
                 "2222222222222222222222222222222222222222222222222222222222222222"
               ),
               membership
             )

    for changed <- [
          %{membership | current: false, expired_at: @now},
          %{membership | enabled: false},
          %{membership | expired_at: @now}
        ] do
      assert {:error, :membership_not_current} = approve(request(changed), changed)
    end
  end

  test "rejects ambiguous or quarantined linkage evidence" do
    ambiguous =
      membership(
        link_evidence: %{
          "kind" => "stored_awx_source_tuple",
          "controller_id" => @controller_id,
          "inventory_id" => 7,
          "awx_host_id" => 100,
          "matching_device_uids" => ["device-100", "device-101"],
          "match_count" => 2
        }
      )

    assert {:error, :membership_link_ambiguous} = approve(request(ambiguous), ambiguous)

    quarantined = %{
      ambiguous
      | canonical_device_uid: nil,
        link_disposition: :quarantined
    }

    assert {:error, :membership_not_proposed} =
             approve(
               request(%{quarantined | canonical_device_uid: "device-100"}),
               quarantined
             )
  end

  test "system workers cannot turn a proposal into an approval" do
    membership = membership()

    assert {:error, :human_approval_required} =
             AwxMembershipApproval.approve(
               request(membership),
               SystemActor.system(:awx_membership_reconciler),
               dependencies: dependencies(membership)
             )

    refute_received {:load_user, _actor_id}
    refute_received :approve_membership

    changeset =
      membership
      |> struct_membership()
      |> Ash.Changeset.for_update(
        :approve_link,
        action_attributes(membership),
        actor: SystemActor.system(:awx_membership_reconciler)
      )

    refute changeset.valid?

    assert Enum.any?(changeset.errors, fn error ->
             Exception.message(error) =~ "requires a human principal"
           end)
  end

  test "approval action records attributable exact evidence and adds a CAS filter" do
    membership = membership()

    actor = %{
      id: @actor_id,
      role: :admin,
      principal_type: :human,
      permissions: MapSet.new([@permission])
    }

    changeset =
      membership
      |> struct_membership()
      |> Ash.Changeset.for_update(:approve_link, action_attributes(membership), actor: actor)

    assert changeset.valid?
    assert Ash.Changeset.get_attribute(changeset, :link_disposition) == :approved
    assert changeset.filter

    evidence = Ash.Changeset.get_attribute(changeset, :link_evidence)
    approval = evidence["approval"]

    assert approval["schema"] == "serviceradar.awx_membership_approval.v1"
    assert approval["principal_type"] == "human"
    assert approval["principal_id"] == @actor_id
    assert approval["controller_id"] == @controller_id
    assert approval["inventory_id"] == 7
    assert approval["awx_host_id"] == 100
    assert approval["canonical_device_uid"] == "device-100"
    assert approval["source_generation"] == 10
    assert approval["source_fingerprint"] == @fingerprint
  end

  defp approve(request, membership) do
    AwxMembershipApproval.approve(request, %{id: @actor_id, role: :admin},
      dependencies: dependencies(membership)
    )
  end

  defp dependencies(membership, opts \\ []) do
    parent = self()
    fresh_permissions = Keyword.get(opts, :fresh_permissions, MapSet.new([@permission]))

    %{
      load_user: fn actor_id ->
        send(parent, {:load_user, actor_id})
        {:ok, %{id: actor_id, role: :admin, status: :active}}
      end,
      load_authority: fn user ->
        send(parent, {:load_authority, user.id})
        {:ok, %{permissions: fresh_permissions, profile_versions: []}}
      end,
      load_membership: fn membership_id ->
        send(parent, {:load_membership, membership_id})
        {:ok, membership}
      end,
      approve_membership: fn current, attrs, actor ->
        send(parent, {:approve_membership, attrs, actor})

        {:ok,
         current
         |> Map.put(:link_disposition, :approved)
         |> Map.put(:link_evidence, Map.put(current.link_evidence, "approval", %{}))}
      end,
      now: fn -> @now end
    }
  end

  defp request(membership) do
    {:ok, evidence_digest} =
      AwxMembershipApproval.link_evidence_digest(membership.link_evidence)

    %{
      membership_id: membership.id,
      controller_id: membership.controller_id,
      inventory_id: membership.inventory_id,
      awx_host_id: membership.awx_host_id,
      canonical_device_uid: membership.canonical_device_uid,
      source_generation: membership.source_generation,
      source_fingerprint: membership.source_fingerprint,
      link_evidence_digest: evidence_digest
    }
  end

  defp action_attributes(membership) do
    request = request(membership)

    request
    |> Map.delete(:membership_id)
    |> Map.put(:expected_link_evidence, membership.link_evidence)
    |> Map.put(:approved_at, @now)
  end

  defp membership(overrides \\ []) do
    base = %{
      id: @membership_id,
      controller_id: @controller_id,
      inventory_id: 7,
      awx_host_id: 100,
      canonical_device_uid: "device-100",
      source_generation: 10,
      host_name: "node-100",
      ansible_host: "192.0.2.100",
      enabled: true,
      current: true,
      last_seen_at: @now,
      expired_at: nil,
      link_disposition: :proposed,
      link_evidence: %{
        "kind" => "stored_awx_source_tuple",
        "controller_id" => @controller_id,
        "inventory_id" => 7,
        "awx_host_id" => 100,
        "matching_device_uids" => ["device-100"],
        "match_count" => 1
      },
      source_fingerprint: @fingerprint,
      metadata: %{}
    }

    Enum.into(overrides, base)
  end

  defp struct_membership(membership), do: struct!(AwxHostMembership, membership)
end
