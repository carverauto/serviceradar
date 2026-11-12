defmodule ServiceRadar.Automation.Ansible.AwxMembershipQuarantineReleaseIntegrationTest do
  @moduledoc """
  Owns the storage contract of releasing an AWX membership from quarantine:
  each outcome against real device inventory, the release record, the
  follow-up approval, and the constraint that a quarantine carries a reason.
  Fixtures are synthetic and live in the rollback-only sandbox.
  """
  use ServiceRadar.DataCase, async: true

  alias Ash.Seed
  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Automation.Ansible.AwxMembershipApproval
  alias ServiceRadar.Automation.Ansible.AwxMembershipQuarantineRelease
  alias ServiceRadar.Automation.Ansible.AwxMembershipQuarantineReleaseRecord
  alias ServiceRadar.Automation.Ansible.AwxMembershipReviewer
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration
  @fingerprint "sha256:" <> String.duplicate("a", 64)
  @quarantined_at ~U[2026-07-01 08:00:00.000000Z]

  setup do
    suffix = System.unique_integer([:positive])

    controller =
      Seed.seed!(Controller, %{
        name: "quarantine-release-#{suffix}",
        base_url: "https://awx.test.invalid",
        agent_id: "quarantine-release-agent-#{suffix}",
        credential_secret_id: CredentialIntegrationFixtures.secret_id!()
      })

    %{
      controller_id: controller.id,
      prefix: "sr:quarantine-release-#{suffix}",
      reviewer: %{id: Ecto.UUID.generate(), role: :admin}
    }
  end

  test "one current match releases to proposed, is recorded, and still needs approval", ctx do
    device = insert_device!(ctx, "a", 100)
    membership = quarantined!(ctx, 100, ["#{ctx.prefix}-a", "#{ctx.prefix}-b"])

    assert {:ok, released} = release(membership, ctx)

    assert {:ok, stored} = AwxHostMembership.get_by_id(membership.id, actor: store_actor())

    for row <- [released, stored] do
      assert row.link_disposition == :proposed
      assert row.canonical_device_uid == device
      assert is_nil(row.quarantine_reason) and is_nil(row.quarantined_at)
      assert row.source_generation == membership.source_generation
      assert row.link_evidence == evidence(ctx, 100, [device])
    end

    assert {:ok, [record]} =
             AwxMembershipQuarantineReleaseRecord.list_for_membership(membership.id,
               actor: store_actor()
             )

    assert record.released_by_principal_id == ctx.reviewer.id
    assert record.prior_quarantine_reason == :approved_device_changed
    assert DateTime.compare(record.prior_quarantined_at, @quarantined_at) == :eq
    assert record.prior_link_evidence == membership.link_evidence
    assert record.released_link_disposition == :proposed
    assert record.released_canonical_device_uid == device
    assert record.released_link_evidence == stored.link_evidence

    # A release is not an approval: the proposal goes through the normal gate.
    {:ok, digest} = AwxMembershipReviewer.link_evidence_digest(stored.link_evidence)

    assert {:ok, approved} =
             AwxMembershipApproval.approve(
               %{
                 membership_id: stored.id,
                 controller_id: stored.controller_id,
                 inventory_id: stored.inventory_id,
                 awx_host_id: stored.awx_host_id,
                 canonical_device_uid: device,
                 source_generation: stored.source_generation,
                 source_fingerprint: stored.source_fingerprint,
                 link_evidence_digest: digest
               },
               ctx.reviewer,
               dependencies: reviewer_dependencies()
             )

    assert approved.link_disposition == :approved
  end

  test "no current match releases to unlinked", ctx do
    membership = quarantined!(ctx, 101, [])

    assert {:ok, released} = release(membership, ctx)
    assert released.link_disposition == :unlinked
    assert is_nil(released.canonical_device_uid)
    assert released.link_evidence == evidence(ctx, 101, [])

    assert {:ok, [%{released_link_disposition: :unlinked}]} =
             AwxMembershipQuarantineReleaseRecord.list_for_membership(membership.id,
               actor: store_actor()
             )
  end

  test "several current matches refuse the release and leave the quarantine untouched", ctx do
    first = insert_device!(ctx, "a", 102)
    second = insert_device!(ctx, "b", 102)
    membership = quarantined!(ctx, 102, [first])

    assert {:error, {:membership_link_ambiguous, matches}} = release(membership, ctx)
    assert matches == Enum.sort([first, second])

    assert {:ok, stored} = AwxHostMembership.get_by_id(membership.id, actor: store_actor())
    assert stored.link_disposition == :quarantined
    assert stored.quarantine_reason == :approved_device_changed
    assert stored.link_evidence == membership.link_evidence

    assert {:ok, []} =
             AwxMembershipQuarantineReleaseRecord.list_for_membership(membership.id,
               actor: store_actor()
             )
  end

  test "storage refuses a quarantine without a reason and a reason without a quarantine", ctx do
    membership = quarantined!(ctx, 103, [])

    for {sql, constraint} <- [
          {"SET quarantine_reason = NULL, quarantined_at = NULL",
           "ansible_awx_host_memberships_quarantine_recorded"},
          {"SET quarantine_reason = 'predates_reason_recording'",
           "ansible_awx_host_memberships_quarantined_at_recorded"},
          {"SET link_disposition = 'unlinked'",
           "ansible_awx_host_memberships_quarantine_recorded"}
        ] do
      assert_raise Postgrex.Error, ~r/#{constraint}/, fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "UPDATE platform.ansible_awx_host_memberships #{sql} WHERE id = $1",
            [Ecto.UUID.dump!(membership.id)]
          )
        end)
      end
    end
  end

  defp release(membership, ctx) do
    {:ok, digest} = AwxMembershipReviewer.link_evidence_digest(membership.link_evidence)

    AwxMembershipQuarantineRelease.release(
      %{
        "membership_id" => membership.id,
        "controller_id" => membership.controller_id,
        "inventory_id" => membership.inventory_id,
        "awx_host_id" => membership.awx_host_id,
        "source_generation" => Integer.to_string(membership.source_generation),
        "source_fingerprint" => membership.source_fingerprint,
        "link_evidence_digest" => digest
      },
      ctx.reviewer,
      dependencies: reviewer_dependencies()
    )
  end

  # The reviewing user and its authority come from the identity store in
  # production; here they are fixed so the test owns only the membership side.
  defp reviewer_dependencies do
    %{
      load_user: fn id -> {:ok, %{id: id, role: :admin, status: :active}} end,
      load_authority: fn _user ->
        {:ok, %{permissions: MapSet.new(["ansible.controllers.manage"]), profile_versions: []}}
      end
    }
  end

  # A quarantined membership as synchronization leaves it: evidence merged with
  # an earlier marker, which release moves to its record.
  defp quarantined!(ctx, awx_host_id, last_matches) do
    Seed.seed!(AwxHostMembership, %{
      controller_id: ctx.controller_id,
      inventory_id: 7,
      awx_host_id: awx_host_id,
      source_generation: 4,
      host_name: "host#{awx_host_id}.example.com",
      ansible_host: "192.0.2.#{rem(awx_host_id, 200) + 1}",
      enabled: true,
      current: true,
      last_seen_at: @quarantined_at,
      link_disposition: :quarantined,
      quarantine_reason: :approved_device_changed,
      quarantined_at: @quarantined_at,
      link_evidence:
        ctx
        |> evidence(awx_host_id, last_matches)
        |> Map.put("approval", %{"principal_id" => "synthetic-earlier-reviewer"}),
      source_fingerprint: @fingerprint,
      metadata: %{}
    })
  end

  defp insert_device!(ctx, suffix, awx_host_id) do
    uid = "#{ctx.prefix}-#{suffix}"

    Repo.query!(
      "INSERT INTO platform.ocsf_devices (uid, metadata) VALUES ($1, $2)",
      [
        uid,
        %{
          "awx" => %{
            "controller_id" => ctx.controller_id,
            "inventory_id" => 7,
            "host_id" => awx_host_id
          }
        }
      ]
    )

    uid
  end

  defp evidence(ctx, awx_host_id, device_uids) do
    %{
      "kind" => "stored_awx_source_tuple",
      "controller_id" => ctx.controller_id,
      "inventory_id" => 7,
      "awx_host_id" => awx_host_id,
      "matching_device_uids" => Enum.sort(device_uids),
      "match_count" => length(device_uids)
    }
  end

  defp store_actor, do: AwxMembershipReviewer.store_actor()
end
