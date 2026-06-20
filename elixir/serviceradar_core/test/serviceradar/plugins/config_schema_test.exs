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

  test "assignment validation accepts draft 2020-12 schema declarations" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "enabled" => %{"type" => "boolean", "default" => true},
        "listen_addr" => %{"type" => "string", "default" => "127.0.0.1:6000"},
        "batch_queue_size" => %{"type" => "integer", "minimum" => 16, "default" => 1024}
      }
    }

    assert %{
             "enabled" => true,
             "listen_addr" => "127.0.0.1:6000",
             "batch_queue_size" => 1024
           } = ConfigSchema.normalize_params(schema, %{})

    assert :ok =
             ConfigSchema.validate_params(schema, %{"enabled" => true, "batch_queue_size" => 1024})
  end

  test "blank numeric form values are omitted instead of persisted as strings or defaults" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "window_size" => %{"type" => "integer", "default" => 300},
        "n_sigma" => %{"type" => "number", "default" => 3.0},
        "enabled" => %{"type" => "boolean", "default" => true},
        "label" => %{"type" => "string", "default" => "default label"}
      }
    }

    assert %{"window_size" => 300, "n_sigma" => 3.0} =
             ConfigSchema.normalize_params(schema, %{})

    normalized =
      ConfigSchema.normalize_params(schema, %{
        "window_size" => "",
        "n_sigma" => nil,
        "enabled" => "",
        "label" => ""
      })

    refute Map.has_key?(normalized, "window_size")
    refute Map.has_key?(normalized, "n_sigma")
    assert normalized["enabled"] == true
    assert normalized["label"] == "default label"
  end
end
