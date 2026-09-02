defmodule ServiceRadarWebNG.TimezoneMigrationDbTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Repo

  @moduletag :web_ng_shared_fixture_db

  test "adding the timezone column backfills existing rows and defaults new rows" do
    Repo.query!("""
    CREATE TEMPORARY TABLE user_timezone_migration_fixture (
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      email text NOT NULL
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    INSERT INTO user_timezone_migration_fixture (email)
    VALUES ('existing@example.test')
    """)

    Repo.query!("""
    ALTER TABLE user_timezone_migration_fixture
    ADD COLUMN timezone text DEFAULT 'Etc/UTC' NOT NULL
    """)

    assert %{rows: [["Etc/UTC"]]} =
             Repo.query!("""
             SELECT timezone
             FROM user_timezone_migration_fixture
             WHERE email = 'existing@example.test'
             """)

    Repo.query!("""
    INSERT INTO user_timezone_migration_fixture (email)
    VALUES ('new@example.test')
    """)

    assert %{rows: [["Etc/UTC"]]} =
             Repo.query!("""
             SELECT timezone
             FROM user_timezone_migration_fixture
             WHERE email = 'new@example.test'
             """)
  end
end
