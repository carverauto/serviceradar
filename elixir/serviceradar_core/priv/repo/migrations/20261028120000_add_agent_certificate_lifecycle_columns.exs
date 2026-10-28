defmodule ServiceRadar.Repo.Migrations.AddAgentCertificateLifecycleColumns do
  @moduledoc """
  Adds leaf mTLS certificate lifecycle columns and expiry index to `platform.ocsf_agents`.
  """

  use Ecto.Migration

  def up do
    alter table(:ocsf_agents, prefix: "platform") do
      add_if_not_exists(:cert_not_before, :utc_datetime_usec)
      add_if_not_exists(:cert_expires_at, :utc_datetime_usec)
      add_if_not_exists(:cert_serial, :text)
      add_if_not_exists(:cert_fingerprint_sha256, :text)
      add_if_not_exists(:cert_renewed_at, :utc_datetime_usec)
    end

    create_if_not_exists(
      index(:ocsf_agents, [:cert_expires_at],
        prefix: "platform",
        name: :ocsf_agents_cert_expires_at_idx
      )
    )
  end

  def down do
    drop_if_exists(
      index(:ocsf_agents, [:cert_expires_at],
        prefix: "platform",
        name: :ocsf_agents_cert_expires_at_idx
      )
    )

    alter table(:ocsf_agents, prefix: "platform") do
      remove_if_exists(:cert_renewed_at, :utc_datetime_usec)
      remove_if_exists(:cert_fingerprint_sha256, :text)
      remove_if_exists(:cert_serial, :text)
      remove_if_exists(:cert_expires_at, :utc_datetime_usec)
      remove_if_exists(:cert_not_before, :utc_datetime_usec)
    end
  end
end
