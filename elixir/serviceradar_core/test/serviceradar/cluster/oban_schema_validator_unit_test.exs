defmodule ServiceRadar.Oban.SchemaValidatorUnitTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Oban.SchemaValidator

  test "accepts the exact runtime schema version and infinity marker" do
    assert :ok = SchemaValidator.migration_version_status(14, 14)
    assert :ok = SchemaValidator.migration_version_status(:infinity, 14)
  end

  test "reads the runtime migration version without an Ecto migration runner" do
    assert SchemaValidator.required_migration_version() == 14
  end

  test "rejects a database schema older than the runtime" do
    assert {:error, message} = SchemaValidator.migration_version_status(13, 14)
    assert message =~ "schema in platform is version 13"
    assert message =~ "runtime requires version 14"
  end

  test "rejects a database schema newer than the runtime" do
    assert {:error, message} = SchemaValidator.migration_version_status(15, 14)
    assert message =~ "schema in platform is version 15"
    assert message =~ "runtime supports version 14"
  end
end
