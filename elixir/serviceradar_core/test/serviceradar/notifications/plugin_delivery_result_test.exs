defmodule ServiceRadar.Notifications.PluginDeliveryResultTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.PluginDeliveryResult

  @delivery_id "11111111-1111-1111-1111-111111111111"
  @command_id "22222222-2222-2222-2222-222222222222"
  @schema "serviceradar.notification_delivery_result.v1"

  defp command(payload), do: %{id: @command_id, result_payload: payload}

  defp payload(status, extra \\ %{}) do
    Map.merge(
      %{"schema" => @schema, "status" => status, "delivery_id" => @delivery_id},
      extra
    )
  end

  test "delivered maps to the sent disposition with provider correlation" do
    result =
      PluginDeliveryResult.from_command(
        command(
          payload("delivered", %{
            "external_correlation_id" => "post-42",
            "result_summary" => %{"destination" => "mattermost"}
          })
        ),
        @delivery_id
      )

    assert result.disposition == :delivered
    assert result.external_correlation_id == "post-42"
    assert result.result_summary["destination"] == "mattermost"
    assert result.result_summary["command_id"] == @command_id
  end

  test "a missing provider correlation is not replaced with the agent command id" do
    result =
      PluginDeliveryResult.from_command(
        command(payload("delivered")),
        @delivery_id
      )

    assert result.disposition == :delivered
    assert is_nil(result.external_correlation_id)
    assert result.result_summary["command_id"] == @command_id
  end

  test "retryable remains retryable even when the outer command completed" do
    result =
      PluginDeliveryResult.from_command(
        command(
          payload("retryable", %{
            "error_class" => "upstream_503",
            "error_message" => "try later",
            "retry_after_seconds" => 17
          })
        ),
        @delivery_id
      )

    assert result.disposition == :retryable_failure
    assert result.error_class == "upstream_503"
    assert result.error_message == "try later"
    assert result.retry_after_ms == 17_000
  end

  test "an SDK failed result is permanent" do
    result =
      PluginDeliveryResult.from_command(
        command(payload("failed", %{"error_class" => "config_invalid"})),
        @delivery_id
      )

    assert result.disposition == :permanent_failure
    assert result.error_class == "config_invalid"
  end

  test "a malformed guest failure class is replaced before persistence" do
    for error_class <- [
          "Authorization: Bearer do-not-persist",
          "token=do-not-persist",
          "bad\nclass",
          String.duplicate("x", 129)
        ] do
      result =
        PluginDeliveryResult.from_command(
          command(payload("failed", %{"error_class" => error_class})),
          @delivery_id
        )

      assert result.disposition == :permanent_failure
      assert result.error_class == "notification_failed"
      refute inspect(result) =~ "do-not-persist"
    end
  end

  test "an agent-synthesized failure spends the retry budget" do
    result =
      PluginDeliveryResult.from_command(
        command(payload("failed", %{"error" => "plugin_manager_unavailable"})),
        @delivery_id
      )

    assert result.disposition == :retryable_failure
    assert result.error_class == "plugin_manager_unavailable"
  end

  test "a malformed agent failure class is replaced before persistence" do
    for error <- [
          "Authorization: Bearer do-not-persist",
          "bad\nclass",
          String.duplicate("x", 129)
        ] do
      result =
        PluginDeliveryResult.from_command(
          command(payload("failed", %{"error" => error})),
          @delivery_id
        )

      assert result.disposition == :retryable_failure
      assert result.error_class == "agent_command_failed"
      refute inspect(result) =~ "do-not-persist"
    end
  end

  test "wrong correlation fails closed instead of settling another delivery" do
    result =
      PluginDeliveryResult.from_command(
        command(Map.put(payload("delivered"), "delivery_id", "some-other-delivery")),
        @delivery_id
      )

    assert result.disposition == :retryable_failure
    assert result.error_class == "notification_result_invalid"
    assert result.error_message =~ "delivery_id mismatch"
  end

  test "guest result summaries are redacted before persistence" do
    result =
      PluginDeliveryResult.from_command(
        command(
          payload("delivered", %{
            "result_summary" => %{"authorization" => "Bearer do-not-persist"}
          })
        ),
        @delivery_id
      )

    assert result.result_summary["authorization"] == "[REDACTED]"
  end

  test "guest-controlled error text and summary values are content-redacted" do
    result =
      PluginDeliveryResult.from_command(
        command(
          payload("retryable", %{
            "error_class" => "provider_busy",
            "error_message" =>
              "Authorization: Bearer do-not-persist token=also-secret " <>
                "https://sr.example/notifications/actions/resolve?token=capability",
            "result_summary" => %{
              "detail" => "Bearer nested-secret",
              "ref" => "secretref:opaque-but-not-for-errors"
            }
          })
        ),
        @delivery_id
      )

    encoded = inspect(result)
    refute encoded =~ "do-not-persist"
    refute encoded =~ "also-secret"
    refute encoded =~ "capability"
    refute encoded =~ "nested-secret"
    refute encoded =~ "opaque-but-not-for-errors"
    assert result.error_message =~ "[REDACTED]"
  end

  test "an explicitly unsupported notifier contract major fails permanently" do
    result =
      PluginDeliveryResult.from_command(
        command(payload("delivered", %{"sdk_contract_version" => "2.0.0"})),
        @delivery_id
      )

    assert result.disposition == :permanent_failure
    assert result.error_class == "sdk_contract_mismatch"
    assert result.result_summary["sdk_contract_version"] == "2.0.0"
  end

  test "the supported notifier contract major remains compatible across minor versions" do
    result =
      PluginDeliveryResult.from_command(
        command(payload("delivered", %{"sdk_contract_version" => "1.7.3"})),
        @delivery_id
      )

    assert result.disposition == :delivered
  end

  test "unknown status and schema are invalid retryable receipts" do
    for invalid <- [payload("succeeded"), Map.put(payload("delivered"), "schema", "other")] do
      result = PluginDeliveryResult.from_command(command(invalid), @delivery_id)
      assert result.disposition == :retryable_failure
      assert result.error_class == "notification_result_invalid"
    end
  end
end
