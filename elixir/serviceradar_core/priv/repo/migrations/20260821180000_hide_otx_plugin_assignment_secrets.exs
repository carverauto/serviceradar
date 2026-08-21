defmodule ServiceRadar.Repo.Migrations.HideOtxPluginAssignmentSecrets do
  @moduledoc """
  Mark the AlienVault OTX API-key field as credential-materialized on already
  imported packages.

  The assignment form never collects `api_key_secret_ref` (secrets live on
  credential rules / the Threat Intel settings page). The imported schema still
  required the field, so PluginAssignment.create failed with
  "Required property api_key_secret_ref was not present". Source schema is
  corrected in go/cmd/wasm-plugins/alienvault-otx; this rewrites existing
  platform.plugin_packages rows so operators do not have to re-import.
  """
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - bounded rewrite of a small
    # control-plane table. One UPDATE, no hypertable, idempotent via the WHERE.
    execute("""
    UPDATE platform.plugin_packages
    SET config_schema = (
          SELECT jsonb_set(
                   config_schema::jsonb,
                   '{properties}',
                   (
                     SELECT jsonb_object_agg(
                              key,
                              CASE
                                WHEN key = 'api_key_secret_ref'
                                  THEN value
                                       || '{"credentialKind": "api_token", "x-serviceradar-ui-hidden": true, "x-serviceradar-credential-materialized": true}'::jsonb
                                ELSE value
                              END
                            )
                     FROM jsonb_each(config_schema::jsonb -> 'properties')
                   ),
                   true
                 )
        ),
        updated_at = now()
    WHERE plugin_id = 'alienvault-otx-threat-intel'
      AND config_schema::jsonb -> 'properties' ? 'api_key_secret_ref'
    """)
  end

  def down do
    # No-op: we will not re-expose secrets on assignment forms.
    :ok
  end
end
