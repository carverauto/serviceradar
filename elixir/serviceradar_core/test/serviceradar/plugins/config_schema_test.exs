defmodule ServiceRadar.Plugins.ConfigSchemaTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.ConfigSchema

  test "a credential-materialized secretRef is not required on the assignment form" do
    # The AlienVault OTX shape. The API key is materialized from a credential
    # rule, so the assignment form never collects it -- but the plugin schema
    # still lists it in `required`, which is what made OTX unassignable.
    #
    # Note this turns on the markers, NOT on `secretRef` alone: notification
    # providers legitimately require a secretRef field, because they validate
    # config merged with the public part of secret_refs and the reference
    # string is what satisfies it (see ProviderSeederTest).
    schema = %{
      "type" => "object",
      "required" => ["api_key_secret_ref", "base_url"],
      "properties" => %{
        "api_key_secret_ref" => %{
          "type" => "string",
          "secretRef" => true,
          "credentialKind" => "api_token",
          "x-serviceradar-ui-hidden" => true,
          "x-serviceradar-credential-materialized" => true,
          "description" => "AlienVault OTX API key"
        },
        "base_url" => %{"type" => "string"}
      }
    }

    assert :ok =
             ConfigSchema.validate_params(schema, %{
               "base_url" => "https://otx.alienvault.com"
             })

    assert {:error, errors} = ConfigSchema.validate_params(schema, %{})
    assert Enum.any?(errors, &String.contains?(&1, "base_url"))
    refute Enum.any?(errors, &String.contains?(&1, "api_key_secret_ref"))
  end

  test "a bare secretRef stays required" do
    # Guards the regression that a broader "any secretRef is runtime-injected"
    # rule would introduce: it would admit a Discord channel with no webhook URL.
    schema = %{
      "type" => "object",
      "required" => ["webhook_url"],
      "properties" => %{
        "webhook_url" => %{"type" => "string", "secretRef" => true}
      }
    }

    assert {:error, _errors} = ConfigSchema.validate_params(schema, %{})
  end

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

  test "validates and normalizes package-owned object arrays with local definitions" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["queries"],
      "properties" => %{
        "queries" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 8,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["name", "parameters"],
            "properties" => %{
              "name" => %{"type" => "string"},
              "parameters" => %{"$ref" => "#/$defs/queryParameters"}
            }
          }
        }
      },
      "$defs" => %{
        "queryParameters" => %{
          "type" => "object",
          "minProperties" => 1,
          "maxProperties" => 4,
          "additionalProperties" => false,
          "properties" => %{
            "type" => %{"type" => "string"},
            "ip" => %{"type" => "string"},
            "context" => %{"type" => "string"}
          },
          "dependentRequired" => %{"context" => ["ip"]}
        }
      }
    }

    assert :ok = ConfigSchema.validate_schema(schema)

    params = %{
      "queries" => Jason.encode!([%{"name" => "switches", "parameters" => %{"type" => "Switch"}}])
    }

    assert %{
             "queries" => [
               %{"name" => "switches", "parameters" => %{"type" => "Switch"}}
             ]
           } = ConfigSchema.normalize_params(schema, params)

    assert :ok =
             ConfigSchema.validate_params(schema, ConfigSchema.normalize_params(schema, params))

    assert {:error, _errors} =
             ConfigSchema.validate_params(schema, %{
               "queries" => [
                 %{"name" => "context", "parameters" => %{"context" => "child"}}
               ]
             })
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

  test "author-time normalization drops Phoenix unused-input keys" do
    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["webhook_url"],
      "properties" => %{
        "webhook_url" => %{"type" => "string"},
        "thread_id" => %{"type" => "string"},
        "wait" => %{"type" => "boolean", "default" => true},
        "username" => %{"type" => "string"},
        "avatar_url" => %{"type" => "string", "format" => "uri"}
      }
    }

    params = %{
      "webhook_url" => "https://discord.com/api/webhooks/1/token",
      "thread_id" => "",
      "username" => "",
      "avatar_url" => "",
      "wait" => "false",
      "_unused_avatar_url" => "",
      "_unused_thread_id" => "",
      "_unused_username" => "",
      "_unused_wait" => "",
      "_unused_webhook_url" => ""
    }

    normalized = ConfigSchema.normalize_params(schema, params)

    refute Enum.any?(Map.keys(normalized), &String.starts_with?(&1, "_unused_"))
    assert normalized["webhook_url"] == "https://discord.com/api/webhooks/1/token"
    assert normalized["wait"] == false
    assert :ok = ConfigSchema.validate_params(schema, normalized)
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

  describe "credentialKind" do
    # Optional hint naming which credential primitive belongs in a secretRef
    # field, so the settings UI can offer only credentials that will work there.
    # Without it the UI has nothing to filter on and must offer everything,
    # which lets an SSH key be bound to an API-token field and fail when the
    # plugin runs -- reported as a credential resolution failure, which points
    # at the credential rather than at the binding.

    defp schema_with(prop) do
      %{
        "type" => "object",
        "properties" => %{"api_key_secret_ref" => prop}
      }
    end

    test "a known kind on a secretRef field is accepted" do
      for kind <- ~w(api_token username_password ssh_private_key certificate snmp opaque) do
        assert :ok =
                 ConfigSchema.validate_schema(
                   schema_with(%{
                     "type" => "string",
                     "secretRef" => true,
                     "credentialKind" => kind
                   })
                 )
      end
    end

    test "the 17 packages already shipping secretRef without it stay valid" do
      assert :ok =
               ConfigSchema.validate_schema(
                 schema_with(%{"type" => "string", "secretRef" => true})
               )
    end

    test "an unknown kind is rejected rather than silently unfilterable" do
      # A kind accepted here but unknown to NetworkCredentialSecret would match
      # no credential in the inventory, leaving a field that can never be filled.
      assert {:error, errors} =
               ConfigSchema.validate_schema(
                 schema_with(%{
                   "type" => "string",
                   "secretRef" => true,
                   "credentialKind" => "totally_made_up"
                 })
               )

      assert Enum.any?(errors, &String.contains?(&1, "credentialKind"))
    end

    test "it is rejected on a field that is not a secret reference" do
      # Otherwise the field reads as credential-backed while nothing treats it
      # that way.
      assert {:error, errors} =
               ConfigSchema.validate_schema(
                 schema_with(%{"type" => "string", "credentialKind" => "api_token"})
               )

      assert Enum.any?(errors, &String.contains?(&1, "requires secretRef"))

      assert {:error, _} =
               ConfigSchema.validate_schema(
                 schema_with(%{
                   "type" => "string",
                   "secretRef" => false,
                   "credentialKind" => "api_token"
                 })
               )
    end

    test "a non-string kind is rejected" do
      assert {:error, errors} =
               ConfigSchema.validate_schema(
                 schema_with(%{"type" => "string", "secretRef" => true, "credentialKind" => 42})
               )

      assert Enum.any?(errors, &String.contains?(&1, "credentialKind"))
    end
  end
end
