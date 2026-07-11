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

  test "array cardinality constraints are validated and enforced" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "controllers" => %{
          "type" => "array",
          "items" => %{"type" => "object"},
          "minItems" => 1,
          "maxItems" => 2,
          "uniqueItems" => true
        }
      }
    }

    assert :ok = ConfigSchema.validate_schema(schema)
    assert :ok = ConfigSchema.validate_params(schema, %{"controllers" => [%{"id" => "awx"}]})

    assert {:error, _errors} = ConfigSchema.validate_params(schema, %{"controllers" => []})

    assert {:error, _errors} =
             ConfigSchema.validate_params(schema, %{
               "controllers" => [%{"id" => "awx"}, %{"id" => "awx"}]
             })
  end

  test "array cardinality declarations reject invalid shapes" do
    invalid_schema = fn constraints ->
      %{
        "type" => "object",
        "properties" => %{
          "controllers" =>
            Map.merge(
              %{"type" => "array", "items" => %{"type" => "object"}},
              constraints
            )
        }
      }
    end

    for {constraints, expected} <- [
          {%{"minItems" => -1}, "minItems must be a non-negative integer"},
          {%{"maxItems" => "two"}, "maxItems must be a non-negative integer"},
          {%{"uniqueItems" => "true"}, "uniqueItems must be a boolean"},
          {%{"minItems" => 2, "maxItems" => 1}, "minItems must be less than or equal to maxItems"}
        ] do
      assert {:error, errors} = ConfigSchema.validate_schema(invalid_schema.(constraints))
      assert Enum.any?(errors, &String.contains?(&1, expected))
    end
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

  describe "coerce_params/2 (delivery-path coercion, fj#4381)" do
    @netprobe_style_schema %{
      "type" => "object",
      "properties" => %{
        "enabled" => %{"type" => "boolean", "default" => false},
        "capture_interfaces" => %{
          "type" => "array",
          "items" => %{"type" => "string", "minLength" => 1}
        },
        "flow_table_max_entries" => %{"type" => "integer", "minimum" => 0, "default" => 0}
      }
    }

    test "coerces a scalar string into a single-element list for array properties" do
      params = %{"enabled" => true, "capture_interfaces" => "ens18"}

      assert %{"enabled" => true, "capture_interfaces" => ["ens18"]} =
               ConfigSchema.coerce_params(@netprobe_style_schema, params)
    end

    test "splits comma/newline scalar strings and trims entries like author-time coercion" do
      params = %{"capture_interfaces" => " ens18 , eth0 \n eth1 "}

      assert %{"capture_interfaces" => ["ens18", "eth0", "eth1"]} =
               ConfigSchema.coerce_params(@netprobe_style_schema, params)
    end

    test "casts stringly-typed scalars to their declared types" do
      params = %{"enabled" => "true", "flow_table_max_entries" => "131072"}

      assert %{"enabled" => true, "flow_table_max_entries" => 131_072} =
               ConfigSchema.coerce_params(@netprobe_style_schema, params)
    end

    test "does not inject defaults, drop unknown keys, or touch nil values" do
      params = %{"capture_interfaces" => nil, "custom_key" => "kept"}

      assert ConfigSchema.coerce_params(@netprobe_style_schema, params) == params
    end

    test "returns already-valid params unchanged" do
      params = %{
        "enabled" => true,
        "capture_interfaces" => ["ens18", "eth0"],
        "flow_table_max_entries" => 131_072,
        "custom_key" => %{"nested" => ["kept"]}
      }

      assert ConfigSchema.coerce_params(@netprobe_style_schema, params) == params
    end

    test "passes params through unchanged for nil, empty, or property-less schemas" do
      params = %{"capture_interfaces" => "ens18"}

      assert ConfigSchema.coerce_params(nil, params) == params
      assert ConfigSchema.coerce_params(%{}, params) == params
      assert ConfigSchema.coerce_params(%{"type" => "object"}, params) == params
    end
  end
end
