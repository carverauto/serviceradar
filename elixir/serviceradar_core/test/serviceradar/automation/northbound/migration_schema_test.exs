defmodule ServiceRadar.Automation.Northbound.MigrationSchemaTest do
  use ExUnit.Case, async: true

  @migration_dir Path.expand("../../../../priv/repo/migrations", __DIR__)
  @northbound_migrations [
    "20260515193000_create_northbound_action_tables.exs",
    "20260516193717_add_deferred_northbound_action_fields.exs",
    "20260516201407_add_northbound_action_callback_fields.exs"
  ]

  test "northbound action migrations create and alter platform schema objects only" do
    Enum.each(@northbound_migrations, fn migration ->
      path = Path.join(@migration_dir, migration)
      source = File.read!(path)

      uses_platform_prefix? =
        source =~ ~s(prefix: "platform") or
          (source =~ ~s(@prefix "platform") and source =~ ~s(prefix: @prefix))

      assert uses_platform_prefix?,
             "#{migration} must explicitly use the platform schema"

      refute source =~ ~s(prefix: "public"),
             "#{migration} must not create or alter objects in public"

      refute Regex.match?(~r/table\([^,\n)]+?\)/, source),
             "#{migration} must pass prefix: \"platform\" to table/2"

      refute Regex.match?(~r/create\s+index\([^,\n)]+?\)/, source),
             "#{migration} must pass prefix: \"platform\" to index/2"
    end)
  end
end
