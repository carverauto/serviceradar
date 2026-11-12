defmodule ServiceRadar.Repo.Migrations.RecordAwxMembershipQuarantineReasonAndRelease do
  @moduledoc """
  Records why an AWX host membership is quarantined, and keeps an append-only
  record of each human release from quarantine.

  Every writer that quarantines a membership now sets `quarantine_reason` and
  `quarantined_at`: the reconciliation rules in `AwxMembershipReconciler` and the
  deleted-device trigger replaced below. The check constraints make a quarantine
  without a reason unwritable, so a future writer cannot reintroduce an
  unexplained row.

  Rows quarantined before this migration never stored their cause. They are
  marked `predates_reason_recording` with no time. No reason is inferred from
  their evidence: part of it was written by a writer that no longer exists.

  `ansible_awx_membership_quarantine_releases` holds no foreign key to the
  membership, so release history survives a controller deletion that cascades
  the memberships. The application writes it only through a create action.
  """

  use Ecto.Migration

  @prefix "platform"
  @table "ansible_awx_host_memberships"

  @reasons ~w(
    ambiguous_device_match
    approved_device_changed
    approved_link_lost_match
    approved_membership_not_current
    canonical_device_deleted
    predates_reason_recording
  )

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(@table, prefix: @prefix) do
      add(:quarantine_reason, :text)
      add(:quarantined_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE #{@prefix}.#{@table}
    SET quarantine_reason = 'predates_reason_recording'
    WHERE link_disposition = 'quarantined'
    """)

    create(
      constraint(@table, :ansible_awx_host_memberships_quarantine_reason_valid,
        prefix: @prefix,
        check: "quarantine_reason IS NULL OR quarantine_reason IN (#{reason_list()})"
      )
    )

    create(
      constraint(@table, :ansible_awx_host_memberships_quarantine_recorded,
        prefix: @prefix,
        check: "(link_disposition = 'quarantined') = (quarantine_reason IS NOT NULL)"
      )
    )

    create(
      constraint(@table, :ansible_awx_host_memberships_quarantined_at_recorded,
        prefix: @prefix,
        check: """
        (quarantined_at IS NOT NULL) =
          (quarantine_reason IS NOT NULL AND quarantine_reason <> 'predates_reason_recording')
        """
      )
    )

    execute(device_deleted_trigger(:recording_reason))

    create table(:ansible_awx_membership_quarantine_releases, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, primary_key: true)
      add(:membership_id, :uuid, null: false)
      add(:controller_id, :uuid, null: false)
      add(:inventory_id, :integer, null: false)
      add(:awx_host_id, :integer, null: false)
      add(:released_by_principal_id, :text, null: false)
      add(:released_at, :utc_datetime_usec, null: false)
      add(:prior_quarantine_reason, :text, null: false)
      add(:prior_quarantined_at, :utc_datetime_usec)
      add(:prior_link_evidence, :map, null: false)
      add(:source_generation, :bigint, null: false)
      add(:source_fingerprint, :text, null: false)
      add(:released_link_disposition, :text, null: false)
      add(:released_canonical_device_uid, :text)
      add(:released_link_evidence, :map, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      constraint(
        :ansible_awx_membership_quarantine_releases,
        :ansible_awx_membership_quarantine_releases_prior_reason_valid,
        prefix: @prefix,
        check: "prior_quarantine_reason IN (#{reason_list()})"
      )
    )

    create(
      constraint(
        :ansible_awx_membership_quarantine_releases,
        :ansible_awx_membership_quarantine_releases_result_valid,
        prefix: @prefix,
        check: """
        (released_link_disposition = 'proposed' AND released_canonical_device_uid IS NOT NULL)
          OR (released_link_disposition = 'unlinked' AND released_canonical_device_uid IS NULL)
        """
      )
    )

    create(
      index(:ansible_awx_membership_quarantine_releases, [:membership_id, :released_at],
        name: "ansible_awx_membership_quarantine_releases_membership_idx",
        prefix: @prefix
      )
    )

    create(
      index(:ansible_awx_membership_quarantine_releases, [:controller_id, :released_at],
        name: "ansible_awx_membership_quarantine_releases_controller_idx",
        prefix: @prefix
      )
    )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    drop_if_exists(
      table(:ansible_awx_membership_quarantine_releases, prefix: @prefix)
    )

    execute(device_deleted_trigger(:without_reason))

    drop_if_exists(
      constraint(@table, :ansible_awx_host_memberships_quarantined_at_recorded, prefix: @prefix)
    )

    drop_if_exists(
      constraint(@table, :ansible_awx_host_memberships_quarantine_recorded, prefix: @prefix)
    )

    drop_if_exists(
      constraint(@table, :ansible_awx_host_memberships_quarantine_reason_valid, prefix: @prefix)
    )

    alter table(@table, prefix: @prefix) do
      remove(:quarantined_at)
      remove(:quarantine_reason)
    end
  end

  defp reason_list, do: Enum.map_join(@reasons, ", ", &"'#{&1}'")

  # The trigger body last written by 20261016040000_generalize_fleet_identity_dictionaries,
  # with the reason and time added when recording.
  defp device_deleted_trigger(mode) do
    recording =
      case mode do
        :recording_reason ->
          """
              NEW.quarantine_reason := 'canonical_device_deleted';
              NEW.quarantined_at := now() AT TIME ZONE 'utc';
          """

        :without_reason ->
          ""
      end

    """
    CREATE OR REPLACE FUNCTION #{@prefix}.trg_ansible_awx_membership_device_deleted()
    RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM #{@prefix}.ocsf_devices
        WHERE uid = OLD.canonical_device_uid AND identity_purged_at IS NULL
      ) THEN
        NEW.link_disposition := 'quarantined';
    #{recording}    NEW.link_evidence := NEW.link_evidence || jsonb_build_object(
          'canonical_device_deleted', jsonb_build_object(
            'device_uid', OLD.canonical_device_uid,
            'deleted_at', now() AT TIME ZONE 'utc'
          )
        );
        NEW.updated_at := now() AT TIME ZONE 'utc';
      END IF;
      RETURN NEW;
    END;
    $$
    """
  end
end
