defmodule ServiceRadar.Repo.Migrations.AddCredentialRuleTrustMaterial do
  @moduledoc """
  Adds operator-supplied TLS trust material to network credential rules.

  A provider may mandate `verify` while the appliance it targets presents a
  privately-issued certificate - Proxmox VE inventory enrichment is the case
  that forced this. Before these columns the requirement was unsatisfiable and
  the only way to reach such a node was to weaken the policy.

  Both columns are plain text rather than encrypted: a CA certificate and a
  leaf fingerprint are trust anchors, not authenticators, and an operator has
  to be able to read back what a rule trusts.
  """
  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:network_credential_rules, prefix: @prefix) do
      add(:ca_bundle_pem, :text)
      add(:server_cert_fingerprint, :text)
    end

    create(
      constraint(
        :network_credential_rules,
        :network_credential_rules_single_trust_material,
        check: "ca_bundle_pem IS NULL OR server_cert_fingerprint IS NULL",
        prefix: @prefix
      )
    )
  end

  def down do
    drop(
      constraint(
        :network_credential_rules,
        :network_credential_rules_single_trust_material,
        prefix: @prefix
      )
    )

    alter table(:network_credential_rules, prefix: @prefix) do
      remove(:ca_bundle_pem)
      remove(:server_cert_fingerprint)
    end
  end
end
