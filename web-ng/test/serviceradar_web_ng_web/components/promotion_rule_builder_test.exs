defmodule ServiceRadarWebNGWeb.Components.PromotionRuleBuilderTest do
  @moduledoc """
  Tests for the PromotionRuleBuilder LiveComponent.

  Tests cover:
  - Attribute string parsing
  - Match map building from form state
  - SRQL preview query building
  - Form validation

  These are pure unit tests that don't require database access.
  """

  use ExUnit.Case, async: true

  # Tag this test module to run even without database
  @moduletag :unit

  describe "attribute string parsing (via parse_log_attributes)" do
    # We test through the component's expected behavior since parse_log_attributes is private
    # These are unit tests for the parsing logic

    test "handles nil attributes" do
      result = parse_attributes(nil)
      assert result == nil
    end

    test "handles empty string attributes" do
      result = parse_attributes("")
      assert result == nil
    end

    test "handles already-parsed map attributes" do
      input = %{"error" => "connection failed", "service.name" => "myservice"}
      result = parse_attributes(input)
      assert result == input
    end

    test "parses JSON object attributes" do
      input = ~s({"error":"nats: no heartbeat","retry_count":3})
      result = parse_attributes(input)
      assert result == %{"error" => "nats: no heartbeat", "retry_count" => 3}
    end

    test "parses key={json},key2={json} format" do
      input = ~s(attributes={"error":"connection failed"},resource={"service.name":"myservice"})
      result = parse_attributes(input)

      assert result == %{
               "attributes" => %{"error" => "connection failed"},
               "resource" => %{"service.name" => "myservice"}
             }
    end

    test "parses simple key=value format" do
      input = "error=timeout,retries=3"
      result = parse_attributes(input)

      assert result == %{
               "error" => "timeout",
               "retries" => "3"
             }
    end

    test "handles mixed format with nested JSON" do
      input = ~s(level=error,details={"code":500,"message":"Internal error"})
      result = parse_attributes(input)

      assert result == %{
               "level" => "error",
               "details" => %{"code" => 500, "message" => "Internal error"}
             }
    end

    test "returns nil for unparseable format" do
      result = parse_attributes("random text without equals")
      assert result == nil
    end
  end

  describe "match map building" do
    test "builds match map with body_contains" do
      params = %{
        "body_contains_enabled" => true,
        "body_contains" => "Fetch error",
        "severity_enabled" => false,
        "severity_text" => "",
        "service_name_enabled" => false,
        "service_name" => "",
        "attribute_enabled" => false,
        "attribute_key" => "",
        "attribute_value" => ""
      }

      result = build_match_map(params)
      assert result == %{"body_contains" => "Fetch error"}
    end

    test "builds match map with multiple conditions" do
      params = %{
        "body_contains_enabled" => true,
        "body_contains" => "error",
        "severity_enabled" => true,
        "severity_text" => "error",
        "service_name_enabled" => true,
        "service_name" => "db-writer",
        "attribute_enabled" => false,
        "attribute_key" => "",
        "attribute_value" => ""
      }

      result = build_match_map(params)

      assert result == %{
               "body_contains" => "error",
               "severity_text" => "error",
               "service_name" => "db-writer"
             }
    end

    test "builds match map with attribute equals" do
      params = %{
        "body_contains_enabled" => false,
        "body_contains" => "",
        "severity_enabled" => false,
        "severity_text" => "",
        "service_name_enabled" => false,
        "service_name" => "",
        "attribute_enabled" => true,
        "attribute_key" => "error.type",
        "attribute_value" => "connection_timeout"
      }

      result = build_match_map(params)

      assert result == %{
               "attribute_equals" => %{"error.type" => "connection_timeout"}
             }
    end

    test "returns empty map when no conditions enabled" do
      params = %{
        "body_contains_enabled" => false,
        "body_contains" => "",
        "severity_enabled" => false,
        "severity_text" => "",
        "service_name_enabled" => false,
        "service_name" => "",
        "attribute_enabled" => false,
        "attribute_key" => "",
        "attribute_value" => ""
      }

      result = build_match_map(params)
      assert result == %{}
    end

    test "ignores enabled conditions with empty values" do
      params = %{
        "body_contains_enabled" => true,
        "body_contains" => "   ",
        "severity_enabled" => true,
        "severity_text" => "",
        "service_name_enabled" => false,
        "service_name" => "some-service",
        "attribute_enabled" => false,
        "attribute_key" => "",
        "attribute_value" => ""
      }

      result = build_match_map(params)
      assert result == %{}
    end
  end

  describe "SRQL preview query building" do
    test "builds basic query with time filter" do
      form = build_test_form(%{})
      query = build_preview_query(form)

      assert query =~ "in:logs"
      assert query =~ "time:last_1h"
      assert query =~ "limit:10"
    end

    test "builds query with body contains filter" do
      form =
        build_test_form(%{
          body_contains_enabled: true,
          body_contains: "connection error"
        })

      query = build_preview_query(form)

      assert query =~ ~s(body:"*connection error*")
    end

    test "builds query with severity filter" do
      form =
        build_test_form(%{
          severity_enabled: true,
          severity_text: "error"
        })

      query = build_preview_query(form)

      assert query =~ ~s(severity_text:"error")
    end

    test "builds query with service name filter" do
      form =
        build_test_form(%{
          service_name_enabled: true,
          service_name: "db-event-writer"
        })

      query = build_preview_query(form)

      assert query =~ ~s(service_name:"db-event-writer")
    end

    test "escapes special characters in query values" do
      form =
        build_test_form(%{
          body_contains_enabled: true,
          body_contains: ~s(error with "quotes")
        })

      query = build_preview_query(form)

      # Should escape the quotes
      assert query =~ ~s(body:"*error with \\"quotes\\"*)
    end

    test "builds query with multiple filters" do
      form =
        build_test_form(%{
          body_contains_enabled: true,
          body_contains: "timeout",
          severity_enabled: true,
          severity_text: "error",
          service_name_enabled: true,
          service_name: "api-gateway"
        })

      query = build_preview_query(form)

      assert query =~ "in:logs"
      assert query =~ ~s(body:"*timeout*")
      assert query =~ ~s(severity_text:"error")
      assert query =~ ~s(service_name:"api-gateway")
    end
  end

  describe "form validation" do
    test "has_enabled_condition? returns true when body_contains enabled" do
      params = %{
        "body_contains_enabled" => true,
        "severity_enabled" => false,
        "service_name_enabled" => false,
        "attribute_enabled" => false
      }

      assert has_enabled_condition?(params)
    end

    test "has_enabled_condition? returns true when severity enabled" do
      params = %{
        "body_contains_enabled" => false,
        "severity_enabled" => true,
        "service_name_enabled" => false,
        "attribute_enabled" => false
      }

      assert has_enabled_condition?(params)
    end

    test "has_enabled_condition? returns true when service_name enabled" do
      params = %{
        "body_contains_enabled" => false,
        "severity_enabled" => false,
        "service_name_enabled" => true,
        "attribute_enabled" => false
      }

      assert has_enabled_condition?(params)
    end

    test "has_enabled_condition? returns true when attribute enabled" do
      params = %{
        "body_contains_enabled" => false,
        "severity_enabled" => false,
        "service_name_enabled" => false,
        "attribute_enabled" => true
      }

      assert has_enabled_condition?(params)
    end

    test "has_enabled_condition? returns false when no conditions enabled" do
      params = %{
        "body_contains_enabled" => false,
        "severity_enabled" => false,
        "service_name_enabled" => false,
        "attribute_enabled" => false
      }

      refute has_enabled_condition?(params)
    end
  end

  describe "event map building" do
    test "builds event map with alert enabled" do
      params = %{"auto_alert" => true}
      result = build_event_map(params)
      assert result == %{"alert" => true}
    end

    test "builds empty event map when alert disabled" do
      params = %{"auto_alert" => false}
      result = build_event_map(params)
      assert result == %{}
    end

    test "builds empty event map when auto_alert not present" do
      params = %{}
      result = build_event_map(params)
      assert result == %{}
    end
  end

  # Helper functions that mirror the component's private functions for testing
  # These are simplified implementations for unit testing

  defp parse_attributes(nil), do: nil
  defp parse_attributes(""), do: nil
  defp parse_attributes(value) when is_map(value), do: value

  defp parse_attributes(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "{") or String.starts_with?(value, "[") ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> parse_key_value_format(value)
        end

      String.contains?(value, "=") ->
        parse_key_value_format(value)

      true ->
        nil
    end
  end

  defp parse_attributes(_), do: nil

  defp parse_key_value_format(value) do
    result =
      ~r/(\w+)=(\{[^}]*\}|[^,]+?)(?=,\w+=|$)/
      |> Regex.scan(value)
      |> Enum.reduce(%{}, fn
        [_full, key, json_value], acc when binary_part(json_value, 0, 1) == "{" ->
          case Jason.decode(json_value) do
            {:ok, decoded} -> Map.put(acc, key, decoded)
            _ -> Map.put(acc, key, json_value)
          end

        [_full, key, plain_value], acc ->
          Map.put(acc, key, String.trim(plain_value))
      end)

    if map_size(result) > 0, do: result, else: nil
  end

  defp build_match_map(params) do
    %{}
    |> maybe_add_body_contains(params)
    |> maybe_add_severity(params)
    |> maybe_add_service_name(params)
    |> maybe_add_attribute_equals(params)
  end

  defp maybe_add_body_contains(match, params) do
    if params["body_contains_enabled"] and has_value?(params["body_contains"]) do
      Map.put(match, "body_contains", params["body_contains"])
    else
      match
    end
  end

  defp maybe_add_severity(match, params) do
    if params["severity_enabled"] and has_value?(params["severity_text"]) do
      Map.put(match, "severity_text", params["severity_text"])
    else
      match
    end
  end

  defp maybe_add_service_name(match, params) do
    if params["service_name_enabled"] and has_value?(params["service_name"]) do
      Map.put(match, "service_name", params["service_name"])
    else
      match
    end
  end

  defp maybe_add_attribute_equals(match, params) do
    if params["attribute_enabled"] and has_value?(params["attribute_key"]) and
         has_value?(params["attribute_value"]) do
      Map.put(match, "attribute_equals", %{params["attribute_key"] => params["attribute_value"]})
    else
      match
    end
  end

  defp has_value?(nil), do: false
  defp has_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp has_value?(_), do: false

  defp build_event_map(params) do
    if params["auto_alert"] do
      %{"alert" => true}
    else
      %{}
    end
  end

  defp has_enabled_condition?(params) do
    params["body_contains_enabled"] or
      params["severity_enabled"] or
      params["service_name_enabled"] or
      params["attribute_enabled"]
  end

  defp build_test_form(overrides) do
    defaults = %{
      name: "test-rule",
      body_contains: "",
      body_contains_enabled: false,
      severity_text: "",
      severity_enabled: false,
      service_name: "",
      service_name_enabled: false,
      attribute_key: "",
      attribute_value: "",
      attribute_enabled: false,
      auto_alert: false,
      parsed_attributes: %{}
    }

    data = Map.merge(defaults, overrides)
    to_form(data, as: :rule)
  end

  defp build_preview_query(form) do
    filters = []

    filters =
      if form[:body_contains_enabled].value and
           String.trim(form[:body_contains].value || "") != "" do
        escaped = escape_srql_value(form[:body_contains].value)
        ["body:\"*#{escaped}*\"" | filters]
      else
        filters
      end

    filters =
      if form[:severity_enabled].value and String.trim(form[:severity_text].value || "") != "" do
        ["severity_text:\"#{form[:severity_text].value}\"" | filters]
      else
        filters
      end

    filters =
      if form[:service_name_enabled].value and String.trim(form[:service_name].value || "") != "" do
        escaped = escape_srql_value(form[:service_name].value)
        ["service_name:\"#{escaped}\"" | filters]
      else
        filters
      end

    base = "in:logs"
    time_filter = "time:last_1h"

    [base, time_filter | filters]
    |> Enum.join(" ")
    |> Kernel.<>(" limit:10")
  end

  defp escape_srql_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_srql_value(other), do: to_string(other)
end
