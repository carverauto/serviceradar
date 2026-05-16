defmodule ServiceRadar.Automation.Northbound.ActionRedactionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Northbound.ActionRedaction

  describe "redact/2" do
    test "redacts common sensitive key names recursively" do
      assert ActionRedaction.redact(%{
               "username" => "operator",
               "password" => "secret",
               "nested" => %{
                 "apiToken" => "token",
                 "safe" => "value"
               },
               "items" => [
                 %{"client_secret" => "hidden", "name" => "kept"}
               ]
             }) == %{
               "username" => "operator",
               "password" => "[REDACTED]",
               "nested" => %{
                 "apiToken" => "[REDACTED]",
                 "safe" => "value"
               },
               "items" => [
                 %{"client_secret" => "[REDACTED]", "name" => "kept"}
               ]
             }
    end

    test "redacts fields marked sensitive by descriptor schema" do
      schema = %{
        "properties" => %{
          "command" => %{"type" => "string"},
          "enable_password" => %{"type" => "string", "writeOnly" => true},
          "token_ref" => %{"type" => "string", "x-serviceradar-sensitive" => true}
        }
      }

      assert ActionRedaction.redact(
               %{
                 "command" => "show version",
                 "enable_password" => "secret",
                 "token_ref" => "abc"
               },
               schema
             ) == %{
               "command" => "show version",
               "enable_password" => "[REDACTED]",
               "token_ref" => "[REDACTED]"
             }
    end
  end

  describe "for_storage/2" do
    test "returns redacted values, stable hash, and policy version" do
      first = ActionRedaction.for_storage(%{"password" => "secret", "safe" => "value"})
      second = ActionRedaction.for_storage(%{"safe" => "value", "password" => "secret"})

      assert first.redacted == %{"password" => "[REDACTED]", "safe" => "value"}
      assert first.sha256 == second.sha256
      assert first.policy_version == ActionRedaction.policy_version()
    end
  end
end
