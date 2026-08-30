defmodule ServiceRadar.Repo.Migrations.CreatePluginRepositories do
  @moduledoc """
  Plugin catalog sources become records instead of one configuration value.

  Before this, `:first_party_plugin_import` `:repo_url` was the only source a
  deployment could import Wasm plugins from, and the "catalog repository" field
  on Settings -> Agents -> Plugins was view-local state that reset on remount
  while the background sync worker kept reading config.

  The built-in `carverauto/serviceradar` source is seeded here rather than left
  in configuration so that every import -- foreground and background -- resolves
  a row through one code path. The seed is keyed on `repo_url`, so an
  installation that already pointed `SERVICERADAR_FIRST_PARTY_PLUGIN_REPO_URL`
  somewhere else does not gain a duplicate, and re-running is harmless.
  """

  use Ecto.Migration

  @prefix "platform"

  # Byte-identical to the `trusted_upload_signing_keys` defaults in
  # elixir/web-ng/config/config.exs. Public verification keys, not secrets.
  @first_party_key_id "serviceradar-first-party-v2"
  @first_party_public_key "2KMsaqvof357MV3RQl4/0DNXfF6+eIMQ+qjDJfL/N8I="
  @first_party_repo_url "https://github.com/carverauto/serviceradar"
  @first_party_index_asset "serviceradar-wasm-plugin-index.json"

  def up do
    create table(:plugin_repositories, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      add(:name, :text, null: false)
      add(:repo_url, :text, null: false)

      # Present from the start so the native add-on catalog can adopt this table
      # without a migration. Every row is a Wasm plugin source today.
      add(:artifact_kind, :text, null: false, default: "wasm_plugin")
      add(:index_asset_name, :text, null: false)

      # A repository with no trusted key cannot verify anything it publishes, so
      # these are NOT NULL: the failure belongs at repository-create time, in
      # front of a human, not at import time inside a background job.
      add(:signing_key_id, :text, null: false)
      add(:signing_public_key, :text, null: false)

      add(
        :credential_secret_id,
        references(:network_credential_secrets,
          type: :uuid,
          prefix: @prefix,
          on_delete: :nilify_all
        )
      )

      add(:enabled, :boolean, null: false, default: true)
      add(:builtin, :boolean, null: false, default: false)
      add(:is_default, :boolean, null: false, default: false)

      add(:last_sync_at, :utc_datetime_usec)
      add(:last_sync_error, :text)

      add(
        :created_by_id,
        references(:ng_users, type: :uuid, prefix: @prefix, on_delete: :nilify_all)
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:plugin_repositories, [:repo_url], prefix: @prefix))

    # At most one default. Partial so the many non-default rows do not collide.
    create(
      unique_index(:plugin_repositories, [:is_default],
        where: "is_default",
        name: :plugin_repositories_single_default_index,
        prefix: @prefix
      )
    )

    create(index(:plugin_repositories, [:enabled], prefix: @prefix))
    create(index(:plugin_repositories, [:credential_secret_id], prefix: @prefix))

    execute("""
    INSERT INTO #{@prefix}.plugin_repositories
      (id, name, repo_url, artifact_kind, index_asset_name,
       signing_key_id, signing_public_key, enabled, builtin, is_default,
       inserted_at, updated_at)
    VALUES
      (gen_random_uuid(), 'ServiceRadar', '#{@first_party_repo_url}', 'wasm_plugin',
       '#{@first_party_index_asset}', '#{@first_party_key_id}', '#{@first_party_public_key}',
       true, true, true, now(), now())
    ON CONFLICT (repo_url) DO NOTHING
    """)

    # A deployment with no default row would silently import from nothing, so
    # prove the seed landed rather than assuming the INSERT did what it says.
    execute("""
    DO $$
    DECLARE
      defaults integer;
    BEGIN
      SELECT count(*) INTO defaults
      FROM #{@prefix}.plugin_repositories
      WHERE is_default;

      IF defaults <> 1 THEN
        RAISE EXCEPTION
          'plugin_repositories seed left % default row(s), expected exactly 1', defaults;
      END IF;
    END
    $$;
    """)
  end

  def down do
    drop(table(:plugin_repositories, prefix: @prefix))
  end
end
