defmodule ServiceRadar.Repo.Migrations.AddAnsibleProvisioningRequests do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:ansible_provisioning_requests, primary_key: false, prefix: "platform") do
      add(:id, :text, primary_key: true, null: false)
      add(:initiator_id, :uuid, null: false)
      add(:operation, :text, null: false)
      add(:key_ciphertext, :binary, null: false)
      add(:request_mac, :binary, null: false)
      add(:resource_id, :uuid, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:ansible_provisioning_requests, :ansible_provisioning_request_identity_length,
        check: "length(id) = 64",
        prefix: "platform"
      )
    )

    create(
      constraint(:ansible_provisioning_requests, :ansible_provisioning_request_mac_length,
        check: "octet_length(request_mac) = 32",
        prefix: "platform"
      )
    )
  end
end
