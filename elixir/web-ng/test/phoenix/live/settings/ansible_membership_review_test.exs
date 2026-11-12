defmodule ServiceRadarWebNGWeb.Settings.AnsibleLive.MembershipReviewTest do
  @moduledoc """
  Database-free checks of what the Memberships tab offers for approval and what
  it submits.

  Oracles: the approval body is the exact field list documented for
  `POST /ansible-memberships/{id}/approve` in `docs/docs/ansible-provisioning-api.md`
  ("send ... with exactly controller_id, inventory_id, awx_host_id,
  canonical_device_uid, source_generation, source_fingerprint, and
  link_evidence_digest"). Only a current, single-match, enabled proposal is
  approvable; unlinked and quarantined rows state why and offer no force-link.
  A current quarantined row offers release, which submits the documented
  release body (`POST /ansible-memberships/{id}/release`: controller_id,
  inventory_id, awx_host_id, source_generation, source_fingerprint and
  link_evidence_digest, no device).
  All identifiers are invented.
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Settings.AnsibleLive.MembershipReview

  @moduletag :db_free

  @controller_id "0190c0de-0000-7000-8000-0000000000c1"
  @device_uid "sr:11111111-2222-4333-8444-555555555555"
  @fingerprint "sha256:" <> String.duplicate("a", 64)
  @digest String.duplicate("b", 64)

  defp proposal(overrides \\ %{}) do
    Map.merge(
      %{
        id: "0190c0de-0000-7000-8000-000000000001",
        controller_id: @controller_id,
        inventory_id: 7,
        awx_host_id: 1001,
        host_name: "host01.example.com",
        enabled: true,
        link_disposition: :proposed,
        canonical_device_uid: @device_uid,
        source_generation: "42",
        source_fingerprint: @fingerprint,
        link_evidence_digest: @digest,
        link_evidence: %{"kind" => "stored_awx_source_tuple", "match_count" => 1}
      },
      overrides
    )
  end

  test "approval submits exactly the documented evidence tuple from the shown row" do
    assert MembershipReview.approval_request(proposal()) == %{
             "controller_id" => @controller_id,
             "inventory_id" => 7,
             "awx_host_id" => 1001,
             "canonical_device_uid" => @device_uid,
             "source_generation" => "42",
             "source_fingerprint" => @fingerprint,
             "link_evidence_digest" => @digest
           }
  end

  test "only an enabled single-match proposal with a device and digest is approvable" do
    assert MembershipReview.approvable?(proposal())
    assert MembershipReview.needs_review?(proposal())

    for blocked <- [
          proposal(%{enabled: false}),
          proposal(%{link_evidence: %{"kind" => "stored_awx_source_tuple", "match_count" => 2}}),
          proposal(%{link_evidence_digest: nil}),
          proposal(%{canonical_device_uid: nil}),
          proposal(%{link_disposition: :approved})
        ] do
      refute MembershipReview.approvable?(blocked), "unexpectedly approvable: #{inspect(blocked)}"
      assert is_binary(MembershipReview.blocked_reason(blocked))
    end
  end

  test "unlinked rows explain the missing match and cannot be forced" do
    unlinked = proposal(%{link_disposition: :unlinked, canonical_device_uid: nil})

    refute MembershipReview.approvable?(unlinked)
    refute MembershipReview.needs_review?(unlinked)
    reason = MembershipReview.blocked_reason(unlinked)
    assert reason =~ "No ServiceRadar device matches"
    assert reason =~ "cannot be forced"
  end

  test "a quarantined row cannot be approved, offers release, and names a current ambiguity" do
    for {count, ambiguous?} <- [{nil, false}, {1, false}, {3, true}] do
      row = quarantined(%{link_evidence: %{"kind" => "stored_awx_source_tuple", "match_count" => count}})
      reason = MembershipReview.blocked_reason(row)

      refute MembershipReview.approvable?(row)
      assert MembershipReview.releasable?(row)
      assert reason =~ "cannot be approved or force-linked"
      assert reason =~ "still needs approval"
      assert String.contains?(reason, "3 devices match this AWX host now") == ambiguous?
    end

    refute MembershipReview.releasable?(quarantined(%{current: false}))
    refute MembershipReview.releasable?(proposal())
  end

  test "release submits exactly the documented six fields and never a device" do
    assert MembershipReview.release_request(quarantined()) == %{
             "controller_id" => @controller_id,
             "inventory_id" => 7,
             "awx_host_id" => 1001,
             "source_generation" => "42",
             "source_fingerprint" => @fingerprint,
             "link_evidence_digest" => @digest
           }
  end

  test "every recorded reason has its own explanation and an unrecorded cause reads as unknown" do
    reasons = [
      :ambiguous_device_match,
      :approved_device_changed,
      :approved_link_lost_match,
      :approved_membership_not_current,
      :canonical_device_deleted,
      :predates_reason_recording
    ]

    labels = Enum.map(reasons, &MembershipReview.quarantine_reason_label(quarantined(%{quarantine_reason: &1})))

    assert length(Enum.uniq(labels)) == length(reasons)

    assert MembershipReview.quarantine_reason_label(quarantined(%{quarantine_reason: :predates_reason_recording})) =~
             "Cause unknown"
  end

  defp quarantined(overrides \\ %{}) do
    proposal(
      Map.merge(
        %{
          link_disposition: :quarantined,
          canonical_device_uid: nil,
          current: true,
          quarantine_reason: :ambiguous_device_match,
          quarantined_at: ~U[2026-01-02 03:04:05.000000Z]
        },
        overrides
      )
    )
  end
end
