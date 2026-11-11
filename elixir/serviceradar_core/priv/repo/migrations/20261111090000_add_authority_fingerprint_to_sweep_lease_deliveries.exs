defmodule ServiceRadar.Repo.Migrations.AddAuthorityFingerprintToSweepLeaseDeliveries do
  @moduledoc """
  Records the authority that signed a sweep lease push so a session re-issue
  can prove the recorded window is still valid without re-signing. NULL means
  unknown and never matches: pre-existing rows rebuild once and record the
  fingerprint on their next push.
  """

  use Ecto.Migration

  def up do
    alter table(:sweep_lease_deliveries, prefix: "platform") do
      add(:authority_fingerprint, :string)
    end
  end

  def down do
    alter table(:sweep_lease_deliveries, prefix: "platform") do
      remove(:authority_fingerprint)
    end
  end
end
