defmodule ServiceRadar.Repo.Migrations.AddComponentCertificateSubject do
  @moduledoc """
  Stores the subject of a recorded component certificate.

  Rows recorded before this migration keep a null subject: the certificate
  itself was never stored, so the subject cannot be recovered from the row.
  """

  use Ecto.Migration

  def up do
    alter table(:component_certificates, prefix: "platform") do
      add(:subject, :text)
    end

    # A hash index: lookups are by equality, and a B-tree entry cannot hold a
    # very long subject.
    create(index(:component_certificates, [:subject], prefix: "platform", using: "hash"))
  end

  def down do
    drop_if_exists(index(:component_certificates, [:subject], prefix: "platform"))

    alter table(:component_certificates, prefix: "platform") do
      remove(:subject)
    end
  end
end
