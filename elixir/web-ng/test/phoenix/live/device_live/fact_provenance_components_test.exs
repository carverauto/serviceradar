defmodule ServiceRadarWebNGWeb.DeviceLive.FactProvenanceComponentsTest do
  # Pure function-component rendering — no database required.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.FactProvenanceComponents

  @moduletag :db_free

  defp render_section(metadata) do
    render_component(&FactProvenanceComponents.fact_provenance_section/1,
      device_row: %{"uid" => "sr:device-1", "metadata" => metadata},
      timezone: "Etc/UTC"
    )
  end

  test "shows each fact's value, writer and update time without expanding anything" do
    html =
      render_section(%{
        "patch_compliant" => true,
        "owner_team" => "platform",
        "vendor_name" => "Example Networks",
        "__fact_provenance" => %{
          "patch_compliant" => %{
            "source" => "compliance-bot",
            "updated_at" => "2026-09-30T12:00:00.000000+00:00"
          },
          "owner_team" => %{"source" => "cmdb-sync", "updated_at" => "2026-09-29T08:15:00Z"}
        }
      })

    assert html =~ ~s(id="device-fact-provenance")
    refute html =~ "<details"
    assert html =~ "2 facts"

    facts =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#device-fact-provenance tbody tr")
      |> Enum.map(fn row ->
        row |> LazyHTML.query("td") |> Enum.map(&String.trim(LazyHTML.text(&1)))
      end)

    # Sorted by key; plain metadata without provenance ("vendor_name") is not a fact.
    assert facts == [
             ["owner_team", "platform", "cmdb-sync", "2026-09-29T08:15:00Z"],
             ["patch_compliant", "true", "compliance-bot", "2026-09-30T12:00:00.000000Z"]
           ]
  end

  test "renders nothing when the device has no fact provenance" do
    assert String.trim(render_section(%{"vendor_name" => "Example Networks"})) == ""
    assert String.trim(render_section(%{"__fact_provenance" => %{}})) == ""
  end
end
