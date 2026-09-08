defmodule ServiceRadar.Notifications.CallbackBindingTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.CallbackBinding

  @alert_id "0198f0aa-1111-7000-8000-000000000001"
  @delivery_id "0198f0aa-2222-7000-8000-000000000002"

  defp delivery(overrides \\ %{}) do
    Map.merge(
      %{
        id: @delivery_id,
        alert_id: @alert_id,
        external_correlation_id: @alert_id,
        state: :sent,
        is_test: false,
        channel: %{
          config: %{"api_app_id" => "A0123456789"},
          provider: %{provider_key: "slack"}
        }
      },
      overrides
    )
  end

  defp slack_capability(overrides \\ %{}) do
    Map.merge(
      %{
        action: :acknowledge,
        action_id: "notification_acknowledge",
        alert_id: @alert_id,
        app_id: "A0123456789",
        delivery_id: @delivery_id,
        provider_key: :slack
      },
      overrides
    )
  end

  defp pagerduty_capability(overrides \\ %{}) do
    Map.merge(
      %{
        action: :resolve,
        alert_id: @alert_id,
        app_id: "PAGERDUTY-SUBSCRIPTION-1",
        delivery_id: nil,
        provider_key: :pagerduty
      },
      overrides
    )
  end

  defp bind(capability, delivery) do
    CallbackBinding.bind(capability,
      load_delivery: fn _capability, _provider_key, _actor ->
        {:ok, delivery}
      end
    )
  end

  test "binds a Slack interaction to the delivery, alert, channel app, and provider" do
    assert {:ok, bound} = bind(slack_capability(), delivery())
    assert bound.delivery_id == @delivery_id
  end

  test "refuses a Slack value that pairs another alert with a real delivery" do
    assert {:error, :callback_delivery_mismatch} =
             bind(slack_capability(%{alert_id: Ash.UUID.generate()}), delivery())
  end

  test "refuses a Slack delivery sent through another provider" do
    wrong_provider = put_in(delivery(), [:channel, :provider, :provider_key], "pagerduty")

    assert {:error, :callback_provider_mismatch} = bind(slack_capability(), wrong_provider)
  end

  test "refuses a Slack control from a failed or test delivery" do
    assert {:error, :callback_delivery_mismatch} =
             bind(slack_capability(), delivery(%{state: :failed}))

    assert {:error, :callback_delivery_mismatch} =
             bind(slack_capability(), delivery(%{is_test: true}))
  end

  test "refuses a Slack interaction signed by an app other than the channel app" do
    assert {:error, :callback_channel_mismatch} =
             bind(slack_capability(%{app_id: "A9999999999"}), delivery())
  end

  test "refuses a Slack action id that disagrees with the signed control value" do
    assert {:error, :callback_action_mismatch} =
             bind(slack_capability(%{action_id: "notification_resolve"}), delivery())
  end

  test "resolves PagerDuty correlation to a concrete delivery and provider channel" do
    pagerduty_delivery =
      delivery(%{
        channel: %{config: %{}, provider: %{provider_key: "pagerduty"}}
      })

    assert {:ok, bound} = bind(pagerduty_capability(), pagerduty_delivery)
    assert bound.delivery_id == @delivery_id
  end

  test "refuses PagerDuty correlation that did not originate from a PagerDuty channel" do
    assert {:error, :callback_provider_mismatch} =
             bind(pagerduty_capability(), delivery())
  end

  test "refuses PagerDuty correlation to another alert" do
    assert {:error, :callback_delivery_mismatch} =
             bind(pagerduty_capability(), delivery(%{alert_id: Ash.UUID.generate()}))
  end

  test "refuses PagerDuty when the delivery correlation belongs to another incident" do
    assert {:error, :callback_delivery_mismatch} =
             bind(
               pagerduty_capability(),
               delivery(%{
                 external_correlation_id: Ash.UUID.generate(),
                 channel: %{config: %{}, provider: %{provider_key: "pagerduty"}}
               })
             )
  end
end
