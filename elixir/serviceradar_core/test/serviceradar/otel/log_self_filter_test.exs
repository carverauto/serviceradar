defmodule ServiceRadar.Otel.LogSelfFilterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Otel.LogSelfFilter

  test "stops records from the OTLP log exporter and handler" do
    assert :stop =
             LogSelfFilter.filter(
               %{level: :warning, meta: %{mfa: {:otel_exporter_logs_otlp, :export, 3}}},
               :no_arg
             )

    assert :stop =
             LogSelfFilter.filter(
               %{level: :warning, meta: %{mfa: {:serviceradar_otel_log_handler_v2, :export, 4}}},
               :no_arg
             )
  end

  test "ignores records from every other module so later filters still run" do
    assert :ignore =
             LogSelfFilter.filter(
               %{level: :warning, meta: %{mfa: {ServiceRadar.GatewayRegistry, :count, 0}}},
               :no_arg
             )

    assert :ignore = LogSelfFilter.filter(%{level: :warning, meta: %{}}, :no_arg)
  end
end
