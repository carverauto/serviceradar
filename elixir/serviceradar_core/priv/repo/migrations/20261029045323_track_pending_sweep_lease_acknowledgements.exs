defmodule ServiceRadar.Repo.Migrations.TrackPendingSweepLeaseAcknowledgements do
  @moduledoc """
  Records when a lease delivery's acknowledgement became pending and when its lease was
  revoked. A delivery whose ack does not match its last push starts pending at
  `delivered_at`.

  serviceradar:allow-startup-maintenance - the one UPDATE touches the sweep lease delivery
  control table, which holds at most one row per sweep group and agent.
  """

  use Ecto.Migration

  def up do
    alter table(:sweep_lease_deliveries, prefix: "platform") do
      add(:ack_pending_since, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
    end

    execute("""
    UPDATE platform.sweep_lease_deliveries
    SET ack_pending_since = delivered_at
    WHERE acked_payload_sha256 IS DISTINCT FROM delivered_payload_sha256
    """)
  end

  def down do
    alter table(:sweep_lease_deliveries, prefix: "platform") do
      remove(:ack_pending_since)
      remove(:revoked_at)
    end
  end
end
