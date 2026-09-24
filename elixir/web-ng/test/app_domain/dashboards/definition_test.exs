defmodule ServiceRadarWebNG.Dashboards.DefinitionTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Dashboards.Definition
  alias ServiceRadarWebNG.Dashboards.DefinitionLoader
  alias ServiceRadarWebNG.Dashboards.SystemReports

  @moduletag :db_free

  # Every assertion below exercises Definition.validate/2 or
  # Definition.selects_field?/2 -- the production rules -- rather than
  # recomputing them here. A test that reimplements the rule it is checking
  # passes even when the two have drifted, which is how three earlier tests in
  # this work managed to assert nothing.

  defp panel(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "A panel",
        "srql_query" => "in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by addr limit:20",
        "visual_type" => "bar",
        "data_binding" => %{"label_field" => "addr", "value_field" => "loss"},
        "layout" => %{"x" => 0, "y" => 0, "w" => 6, "h" => 5},
        "position" => 0
      },
      overrides
    )
  end

  defp definition(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "slug" => "example",
        "title" => "Example",
        "panels" => [panel()]
      },
      overrides
    )
  end

  describe "version handling" do
    test "accepts a supported version" do
      assert {:ok, parsed} = Definition.validate(definition(), "example.json")
      assert parsed.version == 1
      assert parsed.slug == "example"
    end

    test "refuses an unrecognised version and names the file" do
      # A refusal, never a skip: a definition the loader ignores is
      # indistinguishable from one that was never shipped.
      assert {:error, message} =
               Definition.validate(definition(%{"version" => 99}), "future.json")

      assert message =~ "future.json"
      assert message =~ "99"
    end

    test "refuses a missing version" do
      raw = Map.delete(definition(), "version")
      assert {:error, message} = Definition.validate(raw, "nover.json")
      assert message =~ "version"
    end

    test "refuses a non-object definition" do
      assert {:error, message} = Definition.validate(%{}, "empty.json")
      assert message =~ "empty.json"
    end
  end

  describe "layout rules" do
    test "refuses a panel with no layout" do
      # The defect this prevents shipped once: panels that all omit layout
      # default to the same grid cell and only one renders, while the builder
      # canvas still shows them spread out.
      raw = definition(%{"panels" => [Map.delete(panel(), "layout")]})

      assert {:error, message} = Definition.validate(raw, "nolayout.json")
      assert message =~ "layout"
      assert message =~ "same"
    end

    test "refuses a layout missing integer dimensions" do
      raw = definition(%{"panels" => [panel(%{"layout" => %{"x" => 0, "y" => 0, "w" => "6"}})]})

      assert {:error, message} = Definition.validate(raw, "badlayout.json")
      assert message =~ "integer"
    end

    test "refuses a layout that overflows the grid" do
      raw = definition(%{"panels" => [panel(%{"layout" => %{"x" => 8, "y" => 0, "w" => 6, "h" => 4}})]})

      assert {:error, message} = Definition.validate(raw, "overflow.json")
      assert message =~ "overflow"
    end

    test "refuses panels that occupy the same grid cell" do
      same = %{"x" => 0, "y" => 0, "w" => 6, "h" => 4}

      raw =
        definition(%{
          "panels" => [
            panel(%{"layout" => same, "position" => 0}),
            panel(%{"layout" => same, "position" => 1})
          ]
        })

      assert {:error, message} = Definition.validate(raw, "overlap.json")
      assert message =~ "overlap"
    end

    test "accepts panels tiled without overlap" do
      raw =
        definition(%{
          "panels" => [
            panel(%{"layout" => %{"x" => 0, "y" => 0, "w" => 6, "h" => 5}, "position" => 0}),
            panel(%{"layout" => %{"x" => 6, "y" => 0, "w" => 6, "h" => 5}, "position" => 1})
          ]
        })

      assert {:ok, parsed} = Definition.validate(raw, "tiled.json")
      assert length(parsed.panels) == 2
    end
  end

  describe "visual type" do
    test "refuses a type the panel resource would not accept" do
      raw = definition(%{"panels" => [panel(%{"visual_type" => "sunburst"})]})

      assert {:error, message} = Definition.validate(raw, "badvisual.json")
      assert message =~ "sunburst"
    end

    test "resolves a known type to the resource's own atom without creating one" do
      assert {:ok, parsed} = Definition.validate(definition(), "ok.json")
      assert hd(parsed.panels).visual_type in Definition.allowed_visual_types()
    end

    test "the allowed list comes from the resource, not a local copy" do
      # If the resource gains or loses a visual type, this follows it.
      assert :table in Definition.allowed_visual_types()
      assert :bar in Definition.allowed_visual_types()
    end
  end

  describe "selects_field?/2" do
    test "recognises a stats alias" do
      query = "in:mtr_hops stats:loss_ratio(sent, received) as loss by addr limit:20"
      assert Definition.selects_field?(query, "loss")
    end

    test "does not match a field that is merely a substring of a function name" do
      # The precise trap: "loss" is a substring of "loss_ratio", so a naive
      # substring check passes even when no `as loss` alias exists.
      query = "in:mtr_hops stats:loss_ratio(sent, received) as packet_loss by addr limit:20"
      refute Definition.selects_field?(query, "loss")
      assert Definition.selects_field?(query, "packet_loss")
    end

    test "recognises a bare group dimension" do
      query = "in:mtr_hops stats:count() as n by addr limit:10"
      assert Definition.selects_field?(query, "addr")
    end

    test "recognises a group dimension in a multi-dimension clause" do
      query = "in:mtr_hops stats:count() as n by addr,hop_number limit:10"
      assert Definition.selects_field?(query, "addr")
      assert Definition.selects_field?(query, "hop_number")
    end

    test "recognises the implicit bucket only when a time dimension exists" do
      bucketed = "in:mtr_hops stats:count() as n by time:1h limit:100"
      plain = "in:mtr_hops stats:count() as n by addr limit:100"

      assert Definition.selects_field?(bucketed, "bucket")
      refute Definition.selects_field?(plain, "bucket")
    end

    test "recognises a dimension at the end of a quoted stats expression" do
      # A multi-aggregation projection is quoted, so the by clause ends at a
      # closing quote rather than whitespace. Splitting naively yields
      # `hop_number"` and the dimension silently fails to match its binding.
      # The shipped MTR definition caught this before any test did.
      query =
        "in:mtr_hops time:last_24h stats:\"loss_ratio(sent, received) as loss, " <>
          "count() as samples by hop_number\" sort:hop_number:asc limit:40"

      assert Definition.selects_field?(query, "hop_number")
      assert Definition.selects_field?(query, "loss")
      assert Definition.selects_field?(query, "samples")
    end

    test "does not treat sort or limit tokens as dimensions" do
      query = "in:mtr_hops stats:count() as n by addr sort:n:desc limit:10"
      refute Definition.selects_field?(query, "sort")
      refute Definition.selects_field?(query, "limit")
    end
  end

  describe "data bindings" do
    test "refuses a binding naming a field the query does not select" do
      raw =
        definition(%{
          "panels" => [panel(%{"data_binding" => %{"value_field" => "nonexistent"}})]
        })

      assert {:error, message} = Definition.validate(raw, "badbind.json")
      assert message =~ "nonexistent"
    end

    test "accepts an empty binding" do
      raw = definition(%{"panels" => [panel(%{"data_binding" => %{}})]})
      assert {:ok, _} = Definition.validate(raw, "nobind.json")
    end
  end

  describe "shipped definitions" do
    test "every definition that ships with the product validates" do
      # The definitions are data, so nothing else would catch a malformed one
      # until a dashboard failed to appear in the library with no explanation.
      assert SystemReports.definition_errors() == []
    end

    test "the shipped set includes both built-in dashboards" do
      slugs = Enum.map(SystemReports.dashboard_specs(), & &1.slug)

      assert SystemReports.new_devices_slug() in slugs
      assert SystemReports.mtr_path_analytics_slug() in slugs
    end

    test "the new-devices query is still derived from its definition" do
      # Callers outside this module read this; it used to be a module constant.
      assert SystemReports.new_devices_query() =~ "in:devices"
      assert SystemReports.new_devices_query() =~ "first_seen:last_30d"
    end

    test "the loader reports a bad file rather than skipping it" do
      dir = Path.join(System.tmp_dir!(), "sr_defs_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "broken.json"), ~s({"version": 1, "slug": "x"}))

      try do
        assert %{definitions: [], errors: [error]} = DefinitionLoader.load_all(dir)
        assert error =~ "broken.json"
      after
        File.rm_rf!(dir)
      end
    end

    test "an unreadable directory yields no definitions and no crash" do
      assert %{definitions: [], errors: []} =
               DefinitionLoader.load_all(Path.join(System.tmp_dir!(), "sr_defs_absent"))
    end
  end
end
