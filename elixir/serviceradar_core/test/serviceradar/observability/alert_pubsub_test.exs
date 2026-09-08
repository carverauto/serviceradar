defmodule ServiceRadar.Observability.AlertPubSubTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AlertPubSub

  setup do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if is_nil(Process.whereis(ServiceRadar.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    :ok
  end

  test "topic/0 returns the alert lifecycle topic" do
    assert AlertPubSub.topic() == "serviceradar:alerts"
  end

  test "broadcast_alert_created/1 delivers the creation event to topic subscribers" do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, AlertPubSub.topic())

    assert :ok = AlertPubSub.broadcast_alert_created(%{id: "alert-123"})
    assert_receive {:alert_created, %{id: "alert-123"}}
  end

  test "broadcast_alert_created/1 ignores empty or invalid payloads without publishing" do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, AlertPubSub.topic())

    assert :ok = AlertPubSub.broadcast_alert_created(%{id: ""})
    assert :ok = AlertPubSub.broadcast_alert_created(%{})
    assert :ok = AlertPubSub.broadcast_alert_created(nil)

    refute_received {:alert_created, _}
  end
end
