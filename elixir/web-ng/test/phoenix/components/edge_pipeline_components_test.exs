defmodule ServiceRadarWebNGWeb.EdgePipelineComponentsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.EdgePipelineComponents

  @moduletag :unit
  @moduletag :db_free

  test "a gateway that has not installed the active epoch names the gateway and epoch" do
    condition = %{reason: :no_live_gateway_on_active_epoch, detail: %{epoch: 1_000_007, gateway_id: "gw-1"}}

    explanation = EdgePipelineComponents.explanation(condition)

    assert explanation =~ "gw-1"
    assert explanation =~ "1000007"
    assert explanation =~ "cannot be admitted"
  end

  test "an oversized summary names the service and its size, and does not call the build old" do
    condition = %{
      reason: :oversized_summary,
      detail: %{count: 35, summaries: %{"snmp" => %{bytes: 4_812, limit: 4_096}}, last_refused_at: nil}
    }

    explanation = EdgePipelineComponents.explanation(condition)

    assert explanation =~ "refused 35 status summaries over its size limit"
    assert explanation =~ "snmp (4812 bytes, limit 4096)"
    refute explanation =~ "cutover"
  end
end
