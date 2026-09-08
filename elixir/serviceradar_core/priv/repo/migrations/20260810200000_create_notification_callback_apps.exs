defmodule ServiceRadar.Repo.Migrations.CreateNotificationCallbackApps do
  @moduledoc """
  Creates the registry of provider applications whose signatures authorise an
  inbound notification callback (task 4.3.1a), backing
  `ServiceRadar.Notifications.NotificationCallbackApp`.

  One row per Slack app (later, per Discord application), holding the key
  material its inbound interactions are verified against.

  ## Why not a column on `notification_channels`

  The secret belongs to the provider **app**, not to a channel. Ten channels
  backed by one Slack app would hold ten copies, and a rotation would mean ten
  edits with no way to tell whether one was missed. More decisively, the callback
  could not use a channel-scoped copy: an inbound interaction names
  `api_app_id` and the workspace and carries nothing identifying which
  ServiceRadar channel produced the message, so resolution must start from the
  app id. That is what the unique index below indexes.

  ## Ciphertext, not a digest

  Unlike `notification_action_tokens`, which stores only a sha256, this stores an
  `ServiceRadar.Edge.Crypto`-encrypted secret. That is not a weaker choice made
  for convenience: verifying an HMAC requires the secret itself, so one-way
  hashing is unavailable and encryption at rest is the protection that exists.
  The column is `text`, matching `callback_hmac_secret_ciphertext` on the
  northbound action tables.

  Note: this migration is hand-written, matching
  `20260809120000_create_notification_platform_tables.exs`.
  `priv/resource_snapshots/` is gitignored and every migration in this tree is
  authored by hand, so `mix ash.codegen` emits a whole-application migration
  rather than a scoped one.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:notification_callback_apps, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)

      add(:provider_key, :text, null: false)
      add(:external_app_id, :text, null: false)
      add(:label, :text)
      add(:signing_secret_ciphertext, :text, null: false)

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    # The resolution the callback performs on every inbound request, and the
    # constraint that stops one app being registered twice with different
    # secrets - which would make verification depend on row order.
    create(
      unique_index(:notification_callback_apps, [:provider_key, :external_app_id],
        name: :notification_callback_apps_external_app_uidx,
        prefix: @prefix
      )
    )

    # A closed provider list at the database level as well as in the resource. A
    # row with an unrecognised provider_key is one nothing can ever resolve,
    # written by a typo, and it would sit in a credential table unnoticed.
    create(
      constraint(:notification_callback_apps, :notification_callback_apps_provider_key,
        check: "provider_key IN ('slack')",
        prefix: @prefix
      )
    )

    create(
      constraint(:notification_callback_apps, :notification_callback_apps_secret_present,
        check: "length(btrim(signing_secret_ciphertext)) > 0",
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:notification_callback_apps, prefix: @prefix))
  end
end
