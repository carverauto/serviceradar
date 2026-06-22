defmodule ServiceRadarWebNG.Dashboards.AuthoredVisualsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Dashboards.Authored.Visuals

  @moduletag :db_free

  test "normalizes rows and infers compatible visual metadata" do
    rows =
      Visuals.normalize_rows([
        %{
          timestamp: "2026-05-22T00:00:00Z",
          service: "core",
          value: "42",
          status: "ok",
          details: %{"owner" => "noc", "region" => "iah"}
        },
        %{
          timestamp: "2026-05-22T00:01:00Z",
          service: "web-ng",
          value: 12,
          status: "warning",
          details: %{"owner" => "noc", "region" => "ord"}
        }
      ])

    fields = Visuals.infer_fields(rows)

    assert Enum.find(fields, &(&1.name == "timestamp")).type == :datetime
    assert Enum.find(fields, &(&1.name == "value")).type == :number
    assert Enum.find(fields, &(&1.name == "details")).json_paths == ["owner", "region"]

    compatible = Visuals.compatible_visuals(rows, fields)

    assert :table in compatible
    assert :line in compatible
    assert :bar in compatible
    assert :category in compatible
    assert :status_list in compatible
  end

  test "uses viz column metadata before row inference" do
    rows = [%{"ts" => "2026-05-22T00:00:00Z", "rate" => 25.5}]

    fields =
      Visuals.infer_fields(rows, %{
        columns: [
          %{name: "rate", type: "float"},
          %{name: "ts", type: "timestamptz"}
        ]
      })

    assert Enum.map(fields, & &1.name) == ["rate", "ts"]
    assert Enum.map(fields, & &1.type) == [:number, :datetime]
  end

  test "recognizes grouped availability bindings" do
    fields = [
      %{name: "is_available", type: :boolean},
      %{name: "count", type: :number}
    ]

    assert Visuals.grouped_availability_binding?(
             %{"label_field" => "is_available", "value_field" => "count"},
             fields
           )

    refute Visuals.grouped_availability_binding?(
             %{"label_field" => "site", "value_field" => "count"},
             fields
           )
  end
end
