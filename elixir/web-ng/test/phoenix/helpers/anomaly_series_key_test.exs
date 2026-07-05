defmodule ServiceRadarWebNGWeb.AnomalySeriesKeyTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.AnomalySeriesKey

  @moduletag :db_free

  test "decodes central v2 anomaly series keys" do
    key =
      Enum.join(
        [
          "v2",
          component("partition", "demo"),
          component("class", "sysmon"),
          component("family", "cpu"),
          component("identity", "sr:ns03"),
          component("if_index", "4"),
          tag_component("label", "CPU20"),
          tag_component("core_id", "20")
        ],
        ":"
      )

    assert %{
             components: %{
               "partition" => "demo",
               "class" => "sysmon",
               "family" => "cpu",
               "identity" => "sr:ns03",
               "if_index" => "4"
             },
             tags: %{"label" => "CPU20", "core_id" => "20"}
           } = AnomalySeriesKey.decode(key)

    assert AnomalySeriesKey.display(key) ==
             "demo | sysmon/cpu | sr:ns03 | ifIndex 4 | core_id=20 | label=CPU20"
  end

  test "decodes edge pipe-delimited producer hint keys" do
    key =
      Enum.join(
        [
          "v2",
          component("partition", "demo"),
          component("identity", "sr:ns03"),
          component("metric", "cpu.usage_percent"),
          tag_component("core_id", "3")
        ],
        "|"
      )

    assert AnomalySeriesKey.display(key) ==
             "demo | sr:ns03 | metric cpu.usage_percent | core_id=3"
  end

  test "returns nil for legacy or malformed series keys" do
    assert AnomalySeriesKey.decode("partition:agent:cpu0") == nil
    assert AnomalySeriesKey.display("partition:agent:cpu0") == nil
    assert AnomalySeriesKey.decode("v2:not-a-component") == nil
  end

  defp component(name, value), do: "#{name}=#{hex(value)}"
  defp tag_component(name, value), do: "tag_#{hex(name)}=#{hex(value)}"
  defp hex(value), do: value |> to_string() |> Base.encode16(case: :lower)
end
