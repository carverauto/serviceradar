defmodule ServiceRadar.Repo.Migrations.AddAutomationLaunchEnvelopes do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:automation_launch_envelopes, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:reference_verifier, :binary, null: false)
      add(:tenant_id, :text, null: false)
      add(:command_id, :uuid, null: false)

      add(
        :child_execution_id,
        references(:ansible_automation_executions,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :callback_grant_id,
        references(:automation_callback_grants,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(
        :controller_id,
        references(:ansible_controllers,
          type: :uuid,
          on_delete: :restrict,
          prefix: @prefix
        ),
        null: false
      )

      add(:inventory_id, :bigint, null: false)
      add(:job_template_id, :bigint, null: false)
      add(:dispatch_agent_id, :text, null: false)
      add(:context_digest, :binary, null: false)
      add(:ciphertext, :binary, null: false)
      add(:cipher_version, :text, null: false)
      add(:cipher_key_id, :text, null: false)
      add(:state, :text, null: false, default: "sealed")
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:resolved_at, :utc_datetime_usec)
      add(:resolved_by_agent_id, :text)
      add(:expired_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: utc_now())
      add(:updated_at, :utc_datetime_usec, null: false, default: utc_now())
    end

    create(
      unique_index(:automation_launch_envelopes, [:reference_verifier],
        name: "automation_launch_envelopes_reference_verifier_uidx",
        prefix: @prefix
      )
    )

    create(
      unique_index(:automation_launch_envelopes, [:command_id],
        name: "automation_launch_envelopes_command_uidx",
        prefix: @prefix
      )
    )

    create(
      index(:automation_launch_envelopes, [:callback_grant_id],
        name: "automation_launch_envelopes_grant_idx",
        prefix: @prefix
      )
    )

    create(
      index(:automation_launch_envelopes, [:state, :expires_at],
        name: "automation_launch_envelopes_state_expiry_idx",
        prefix: @prefix
      )
    )

    create constraint(:automation_launch_envelopes, :automation_launch_envelopes_crypto,
             prefix: @prefix,
             check:
               "octet_length(reference_verifier) = 32 AND " <>
                 "octet_length(context_digest) = 32 AND " <>
                 "octet_length(ciphertext) BETWEEN 29 AND 4096 AND " <>
                 "cipher_version = 'aes-256-gcm-hkdf-sha256-v1' AND " <>
                 "cipher_key_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'"
           )

    create constraint(:automation_launch_envelopes, :automation_launch_envelopes_context,
             prefix: @prefix,
             check:
               "char_length(tenant_id) BETWEEN 1 AND 128 AND " <>
                 "char_length(dispatch_agent_id) BETWEEN 1 AND 255 AND " <>
                 "inventory_id > 0 AND job_template_id > 0"
           )

    create constraint(:automation_launch_envelopes, :automation_launch_envelopes_expiry,
             prefix: @prefix,
             check:
               "expires_at > issued_at AND " <>
                 "expires_at <= issued_at + INTERVAL '600 seconds'"
           )

    create constraint(:automation_launch_envelopes, :automation_launch_envelopes_lifecycle,
             prefix: @prefix,
             check:
               "(state = 'sealed' AND resolved_at IS NULL AND " <>
                 "resolved_by_agent_id IS NULL AND expired_at IS NULL) OR " <>
                 "(state = 'resolved' AND resolved_at IS NOT NULL AND " <>
                 "resolved_by_agent_id IS NOT NULL AND expired_at IS NULL) OR " <>
                 "(state = 'expired' AND resolved_at IS NULL AND " <>
                 "resolved_by_agent_id IS NULL AND expired_at IS NOT NULL)"
           )
  end

  def down do
    drop_if_exists(table(:automation_launch_envelopes, prefix: @prefix))
  end

  defp utc_now do
    fragment("(now() AT TIME ZONE 'utc')")
  end
end
