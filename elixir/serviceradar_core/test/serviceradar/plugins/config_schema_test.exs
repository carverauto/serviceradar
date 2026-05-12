defmodule ServiceRadar.Plugins.ConfigSchemaTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.ConfigSchema

  test "assignment validation ignores runtime-injected hidden required fields" do
    schema = %{
      "type" => "object",
      "required" => ["credential_broker", "credential_rule_id", "timeout_ms"],
      "properties" => %{
        "credential_broker" => %{"type" => "object", "x-serviceradar-ui-hidden" => true},
        "credential_rule_id" => %{"type" => "string", "x-serviceradar-ui-hidden" => true},
        "timeout_ms" => %{"type" => "integer"}
      }
    }

    assert :ok = ConfigSchema.validate_params(schema, %{"timeout_ms" => 30_000})

    assert {:error, errors} = ConfigSchema.validate_params(schema, %{})
    assert Enum.any?(errors, &String.contains?(&1, "timeout_ms"))
    refute Enum.any?(errors, &String.contains?(&1, "credential_broker"))
    refute Enum.any?(errors, &String.contains?(&1, "credential_rule_id"))
  end
end
