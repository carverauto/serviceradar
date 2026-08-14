defmodule ServiceRadar.Repo.Migrations.HideCameraPluginAssignmentSecrets do
  @moduledoc """
  Hide credential-shaped fields on already-imported camera plugin packages.

  UniFi Protect and Axis assignment forms were collecting username, password,
  API key, and cookie because those keys still lived in config_schema as
  ordinary strings. Secrets belong on a credential rule. Source schemas are
  corrected in the plugin trees; this rewrites imported platform.plugin_packages
  rows so operators do not have to re-import to drop the password inputs.
  """
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - bounded rewrite of a small
    # control-plane table. One UPDATE, no hypertable, idempotent via the
    # WHERE (only rows that still expose a secret-shaped property).
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
                                WHEN key IN (
                                  'password',
                                  'api_key',
                                  'cookie',
                                  'username',
                                  'password_secret_ref',
                                  'api_key_secret_ref'
                                )
                                  THEN value
                                       || '{"x-serviceradar-ui-hidden": true, "x-serviceradar-credential-materialized": true}'::jsonb
                                ELSE value
                              END
                            )
                     FROM jsonb_each(config_schema::jsonb -> 'properties')
                   ),
                   true
                 )
        ),
        updated_at = now()
    WHERE plugin_id IN (
            'unifi-protect-camera',
            'unifi-protect-camera-stream',
            'axis-camera',
            'axis-camera-stream'
          )
      AND config_schema::jsonb -> 'properties' ?| ARRAY[
            'password',
            'api_key',
            'cookie',
            'username',
            'password_secret_ref',
            'api_key_secret_ref'
          ]
    """)
  end

  def down do
    # No-op: we will not re-expose secrets on assignment forms.
    :ok
  end
end
