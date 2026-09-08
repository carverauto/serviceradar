defmodule ServiceRadar.PrefixTags.ManualTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.PrefixTags.Changes.BroadcastManualInvalidation
  alias ServiceRadar.PrefixTags.Manual
  alias ServiceRadar.PrefixTags.PrefixTag
  alias ServiceRadar.PrefixTags.Snapshot

  @manager %{
    id: "prefix-tag-manager",
    role: :operator,
    permissions: MapSet.new(["settings.prefix_tags.manage"])
  }
  @system SystemActor.system(:prefix_tags_manual_test)

  describe "parse_tags_input/1" do
    test "splits on commas, whitespace, and newlines" do
      assert Manual.parse_tags_input("site:hq, role:wifi\nzone:dmz  tenant:acme") == [
               "site:hq",
               "role:wifi",
               "zone:dmz",
               "tenant:acme"
             ]
    end

    test "dedupes and drops blanks" do
      assert Manual.parse_tags_input(["site:hq", " site:hq ", "", "role:wifi"]) == [
               "site:hq",
               "role:wifi"
             ]
    end

    test "nil and unknown return empty" do
      assert Manual.parse_tags_input(nil) == []
      assert Manual.parse_tags_input(123) == []
    end
  end

  describe "merge_structured_tags/1" do
    test "builds tags from site and role when the freeform box is empty" do
      assert Manual.merge_structured_tags(%{"site" => "hq", "role" => "wifi", "tags" => ""})[
               "tags"
             ] == ["site:hq", "role:wifi"]
    end

    test "keeps extra tags and lets structured fields win on the same key" do
      attrs =
        Manual.merge_structured_tags(%{
          "site" => "austin",
          "tags" => "site:hq zone:dmz"
        })

      assert attrs["tags"] == ["site:austin", "zone:dmz"]
    end
  end

  test "source_name is manual" do
    assert Manual.source_name() == "manual"
  end

  @tag :requires_app
  test "generic create is importer-only while managers use create_manual" do
    refute Ash.can?({PrefixTag, :create}, @manager)
    assert Ash.can?({PrefixTag, :create}, @system)
    assert Ash.can?({PrefixTag, :create_manual}, @manager)
  end

  test "trie rebuild action is unpaginated without weakening the UI read" do
    ui_action = Info.action(PrefixTag, :list_active)
    rebuild_action = Info.action(PrefixTag, :list_active_for_rebuild)

    assert ui_action.pagination.required?
    assert ui_action.pagination.max_page_size == 250
    refute rebuild_action.pagination
  end

  test "invalidation derives a destroy source from changeset data without a result record" do
    snapshot = %Snapshot{id: Ash.UUID.generate(), source: "netbox"}

    changeset = Ash.Changeset.new(%PrefixTag{snapshot_id: snapshot.id, snapshot: snapshot})

    assert BroadcastManualInvalidation.source_for_invalidation(changeset, nil) == "netbox"
  end

  test "invalidation does not guess manual when no source evidence exists" do
    changeset = Ash.Changeset.new(%PrefixTag{})

    assert BroadcastManualInvalidation.source_for_invalidation(changeset, nil) == nil
  end
end
