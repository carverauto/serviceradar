defmodule ServiceRadar.Repo.Migrations.AddSignedNorthboundActionCallbackFields do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:northbound_action_invocation_targets, prefix: "platform") do
      add :callback_auth_mode, :text, null: false, default: "token"
      add :callback_hmac_secret_ciphertext, :text
      add :callback_hmac_algorithm, :text
      add :callback_hmac_signature_header, :text
      add :callback_hmac_timestamp_header, :text
      add :callback_hmac_timestamp_tolerance_seconds, :integer
    end
  end
end
