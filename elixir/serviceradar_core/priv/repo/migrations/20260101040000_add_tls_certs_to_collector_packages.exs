defmodule ServiceRadar.Repo.Migrations.AddTlsCertsToCollectorPackages do
  @moduledoc """
  Adds mTLS certificate fields to collector_packages table.

  Collectors require mTLS certificates to:
  - Connect to NATS server with mutual TLS authentication
  - Connect to core-elx gRPC endpoints securely
  - Validate peer certificates (verify they're from the same tenant CA)

  Certificate generation happens during provisioning via TenantCA.Generator.
  """

  use Ecto.Migration

  def up do
    alter table(:collector_packages) do
      # TLS certificate (PEM-encoded, public - not encrypted)
      add :tls_cert_pem, :text

      # TLS private key (encrypted via AshCloak)
      add :tls_key_pem_ciphertext, :binary

      # CA certificate chain (tenant CA + root CA, PEM-encoded)
      add :ca_chain_pem, :text
    end
  end

  def down do
    alter table(:collector_packages) do
      remove :tls_cert_pem
      remove :tls_key_pem_ciphertext
      remove :ca_chain_pem
    end
  end
end
