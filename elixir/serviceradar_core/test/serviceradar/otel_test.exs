defmodule ServiceRadar.OtelTest do
  # async: false — depends on the globally started :opentelemetry SDK tracer.
  use ExUnit.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer

  setup_all do
    # The SDK is in extra_applications and normally already running; make it
    # explicit so the with_span tracer below is the real (recording) one.
    {:ok, _apps} = Application.ensure_all_started(:opentelemetry)
    :ok
  end

  test "standalone core disables trace export by default" do
    assert Application.fetch_env!(:opentelemetry, :traces_exporter) == :none
  end

  describe "span/3" do
    test "returns the function result" do
      assert ServiceRadar.Otel.span("test.span", %{}, fn -> {:ok, 42} end) == {:ok, 42}
    end

    test "activates a span context inside the function" do
      outside = Tracer.current_span_ctx()

      inside =
        ServiceRadar.Otel.span("test.span", %{kind: :internal}, fn ->
          Tracer.current_span_ctx()
        end)

      assert inside != :undefined
      assert inside != outside
      # Context is restored after the span block.
      assert Tracer.current_span_ctx() == outside
    end

    test "accepts keyword start opts" do
      assert ServiceRadar.Otel.span("test.span", [kind: :producer], fn -> :ok end) == :ok
    end

    test "re-raises exceptions after recording them" do
      assert_raise RuntimeError, "boom", fn ->
        ServiceRadar.Otel.span("test.span", %{}, fn -> raise "boom" end)
      end

      # Context must not leak after the failed span.
      assert Tracer.current_span_ctx() == :undefined
    end

    test "re-throws thrown values" do
      assert catch_throw(ServiceRadar.Otel.span("test.span", %{}, fn -> throw(:ball) end)) ==
               :ball
    end

    test "propagates exits" do
      assert catch_exit(ServiceRadar.Otel.span("test.span", %{}, fn -> exit(:shutdown) end)) ==
               :shutdown
    end
  end

  describe "set_error/1" do
    test "is a no-op :ok outside of a span" do
      assert ServiceRadar.Otel.set_error(:nats_not_connected) == :ok
    end

    test "returns :ok inside a span for binary and term reasons" do
      ServiceRadar.Otel.span("test.span", %{}, fn ->
        assert ServiceRadar.Otel.set_error("publish failed") == :ok
        assert ServiceRadar.Otel.set_error({:error, :timeout}) == :ok
      end)
    end
  end
end
