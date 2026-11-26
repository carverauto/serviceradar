defmodule ServiceRadarWebNGWeb.CameraIndexSemanticSearchUnitTest do
  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.CameraLive.Index, as: CameraIndex

  @moduletag :unit
  @moduletag :db_free

  @camera_id "00000000-0000-4000-8000-000000000801"
  @frame_id "00000000-0000-4000-8000-000000000802"
  @entry_id "00000000-0000-4000-8000-000000000803"
  @hit_ts_us 1_763_164_800_000_000

  test "renders styled Search/Clear controls and high-craft semantic result cards with thumbnails, captions, and timeline link" do
    scope = synthetic_scope()

    search_opts = [
      authorize_fn: fn s -> {:ok, s} end,
      search_fn: fn _params, _opts ->
        {:ok,
         %{
           results: [
             %{
               camera_source_id: @camera_id,
               camera_display_name: "Synthetic Front Entry",
               visual_frame_id: @frame_id,
               catalog_entry_id: @entry_id,
               best_timeline_ts_us: @hit_ts_us,
               clip_start_us: @hit_ts_us - 2_000_000,
               clip_end_us: @hit_ts_us + 2_000_000,
               time_basis: :received,
               score: 0.78,
               region_kind: "crop",
               object_class: "person",
               dominant_colors: ["blue", "white"],
               action_tags: ["walking"],
               caption_text: "A person in a blue jacket walking past the front entry.",
               has_block_thumbnail: true
             },
             %{
               camera_source_id: @camera_id,
               camera_display_name: "Synthetic Side Gate",
               visual_frame_id: nil,
               catalog_entry_id: nil,
               best_timeline_ts_us: @hit_ts_us - 60_000_000,
               clip_start_us: @hit_ts_us - 62_000_000,
               clip_end_us: @hit_ts_us - 58_000_000,
               time_basis: :received,
               score: 0.42,
               region_kind: "scene",
               object_class: "vehicle",
               dominant_colors: [],
               caption_text: nil,
               has_block_thumbnail: false
             }
           ]
         }}
      end
    ]

    {:ok, mounted} = CameraIndex.mount(%{}, %{}, base_socket(scope, search_opts))

    # Before search: Search button is rendered with primary button styling, Clear is hidden
    initial_doc = render_doc(mounted)
    assert initial_doc |> LazyHTML.query("#camera-fleet-semantic-submit") |> Enum.count() == 1
    assert initial_doc |> LazyHTML.query("#camera-fleet-semantic-clear") |> Enum.count() == 0

    {:noreply, searched} =
      CameraIndex.handle_event(
        "semantic_search",
        %{"search" => %{"q" => "person in blue jacket", "object_class" => "person", "range" => "24h"}},
        mounted
      )

    doc = render_doc(searched)

    # Controls: styled Search + visible Clear button + result count badge
    assert doc |> LazyHTML.query("#camera-fleet-semantic-submit") |> LazyHTML.text() =~ "Search"
    assert doc |> LazyHTML.query("#camera-fleet-semantic-clear") |> LazyHTML.text() =~ "Clear"
    assert doc |> LazyHTML.query("#camera-fleet-semantic-count") |> LazyHTML.text() =~ "2 clips"

    # Two result cards rendered
    cards = LazyHTML.query(doc, "[data-role='semantic-search-result-card']")
    assert Enum.count(cards) == 2

    # First card: block thumbnail + caption + score pill + camera badge + timeline link
    first_thumb = LazyHTML.query(doc, "[data-role='semantic-hit-thumbnail']")
    assert Enum.count(first_thumb) == 1

    assert LazyHTML.attribute(first_thumb, "src") == [
             "/api/cameras/#{@camera_id}/timeline/thumbnails/block/#{@entry_id}.jpg"
           ]

    assert [onerror] = LazyHTML.attribute(first_thumb, "onerror")
    assert onerror =~ "display='none'"

    score_pills = LazyHTML.query(doc, "[data-role='semantic-hit-score-pill']")
    assert Enum.count(score_pills) == 2
    assert LazyHTML.text(score_pills) =~ "Person"
    assert LazyHTML.text(score_pills) =~ "78%"
    assert LazyHTML.text(score_pills) =~ "Vehicle"
    assert LazyHTML.text(score_pills) =~ "42%"

    camera_badges = LazyHTML.query(doc, "[data-role='semantic-hit-camera-badge']")
    assert LazyHTML.text(camera_badges) =~ "Synthetic Front Entry"
    assert LazyHTML.text(camera_badges) =~ "Synthetic Side Gate"

    captions = LazyHTML.query(doc, "[data-role='semantic-hit-caption']")
    assert Enum.count(captions) == 1
    assert LazyHTML.text(captions) =~ "A person in a blue jacket walking past the front entry."

    # Fallback dark icon container is always present for cards without thumbnails
    fallbacks = LazyHTML.query(doc, "[data-role='semantic-hit-thumbnail-fallback']")
    assert Enum.count(fallbacks) == 2

    timeline_links = LazyHTML.query(doc, "[data-role='open-in-timeline-link']")
    assert Enum.count(timeline_links) == 2
    assert LazyHTML.text(timeline_links) =~ "Open in Timeline"

    assert Enum.any?(
             LazyHTML.attribute(timeline_links, "href"),
             &String.contains?(&1, "/cameras/#{@camera_id}/recordings?mode=timeline")
           )

    # Clearing resets state, marks stream for reset, hides results grid and Clear button
    {:noreply, cleared} = CameraIndex.handle_event("clear_semantic_search", %{}, searched)
    assert cleared.assigns.semantic_search_executed? == false
    assert cleared.assigns.semantic_search_count == 0
    assert cleared.assigns.streams.semantic_search_results.reset? == true

    cleared_doc = render_doc(cleared)
    assert cleared_doc |> LazyHTML.query("#camera-fleet-semantic-clear") |> Enum.count() == 0

    assert [results_class] =
             cleared_doc |> LazyHTML.query("#camera-fleet-semantic-results") |> LazyHTML.attribute("class")

    assert results_class =~ "hidden"
  end

  defp render_doc(socket) do
    socket.assigns
    |> CameraIndex.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end

  defp synthetic_scope do
    %Scope{
      user: %{
        id: "00000000-0000-4000-8000-000000000899",
        email: "vantage-search-test@example.test",
        role: :admin,
        timezone: "Etc/UTC"
      },
      permissions: MapSet.new(["devices.view", "devices.cameras.view", "devices.cameras.recordings.view"])
    }
  end

  defp base_socket(scope, search_opts) do
    %Socket{
      endpoint: ServiceRadarWebNGWeb.Endpoint,
      router: ServiceRadarWebNGWeb.Router,
      private: %{
        lifecycle: %Phoenix.LiveView.Lifecycle{},
        live_temp: %{}
      },
      assigns: %{
        __changed__: %{},
        flash: %{},
        live_action: :index,
        current_scope: scope,
        camera_semantic_search_opts: search_opts
      }
    }
  end
end
