defmodule ServiceRadar.Observability.OtelPubSubTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.OtelPubSub

  setup do
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if is_nil(Process.whereis(ServiceRadar.PubSub)) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    :ok
  end

  test "topic/0 returns the OTel ingestion topic" do
    assert OtelPubSub.topic() == "serviceradar:otel"
  end

  test "broadcast_traces/1 delivers the ingestion event to topic subscribers" do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, OtelPubSub.topic())

    assert :ok = OtelPubSub.broadcast_traces(%{count: 3})
    assert_receive {:otel_traces_ingested, %{count: 3}}
  end

  test "broadcast_metrics/1 delivers the ingestion event to topic subscribers" do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, OtelPubSub.topic())

    assert :ok = OtelPubSub.broadcast_metrics(%{count: 7})
    assert_receive {:otel_metrics_ingested, %{count: 7}}
  end

  test "broadcast_trace_summaries/1 delivers the refresh event to topic subscribers" do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, OtelPubSub.topic())

    assert :ok = OtelPubSub.broadcast_trace_summaries(%{count: 4})
    assert_receive {:otel_trace_summaries_refreshed, %{count: 4}}
  end

  test "broadcasts ignore empty or invalid payloads without publishing" do
    Phoenix.PubSub.subscribe(ServiceRadar.PubSub, OtelPubSub.topic())

    assert :ok = OtelPubSub.broadcast_traces(%{count: 0})
    assert :ok = OtelPubSub.broadcast_traces(%{})
    assert :ok = OtelPubSub.broadcast_traces(nil)
    assert :ok = OtelPubSub.broadcast_metrics(%{count: 0})
    assert :ok = OtelPubSub.broadcast_metrics(%{})
    assert :ok = OtelPubSub.broadcast_metrics(nil)
    assert :ok = OtelPubSub.broadcast_trace_summaries(%{count: 0})
    assert :ok = OtelPubSub.broadcast_trace_summaries(%{})
    assert :ok = OtelPubSub.broadcast_trace_summaries(nil)

    refute_received {:otel_traces_ingested, _}
    refute_received {:otel_metrics_ingested, _}
    refute_received {:otel_trace_summaries_refreshed, _}
  end
end
