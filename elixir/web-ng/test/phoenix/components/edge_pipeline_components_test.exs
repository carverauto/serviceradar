defmodule ServiceRadarWebNGWeb.EdgePipelineComponentsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.EdgePipelineComponents

  @moduletag :unit
  @moduletag :db_free

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
