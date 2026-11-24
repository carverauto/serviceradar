defmodule ServiceRadarWebNGWeb.VantageBrandingTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.CameraLive.Index, as: CameraIndex
  alias ServiceRadarWebNGWeb.CameraLive.Recordings
  alias ServiceRadarWebNGWeb.CameraLive.RecordingsComponents
  alias ServiceRadarWebNGWeb.CoreComponents
  alias ServiceRadarWebNGWeb.Layouts

  @moduletag :unit
  @moduletag :db_free

  @camera_id "00000000-0000-4000-8000-000000000701"

  test "vantage_logo renders ServiceRadar Vantage PNG mark with data-role" do
    doc =
      (&CoreComponents.vantage_logo/1)
      |> render_component(id: "logo-a", class: "size-6")
      |> LazyHTML.from_fragment()

    logo = LazyHTML.query(doc, "img#logo-a[data-role='vantage-logo']")

    assert LazyHTML.attribute(logo, "src") == ["/images/vantage-mark.png"]
    assert LazyHTML.attribute(logo, "alt") == ["ServiceRadar Vantage"]
    assert LazyHTML.attribute(logo, "width") == ["32"]
    assert LazyHTML.attribute(logo, "height") == ["32"]
    assert LazyHTML.attribute(logo, "class") == ["object-contain shrink-0 size-6"]
  end

  test "static vantage-mark.png asset exists as a valid PNG and replaces vantage-logo.svg" do
    png_path = Application.app_dir(:serviceradar_web_ng, "priv/static/images/vantage-mark.png")
    svg_path = Application.app_dir(:serviceradar_web_ng, "priv/static/images/vantage-logo.svg")

    assert File.exists?(png_path)
    assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> = File.read!(png_path)
    refute File.exists?(svg_path)
  end

  test "Layouts.app renders Vantage branding and logo in ops topbar on /cameras and /cameras/:id/recordings" do
    scope = synthetic_scope()

    for path <- ["/cameras", "/cameras/#{@camera_id}/recordings"] do
      doc =
        (&Layouts.app/1)
        |> render_component(
          flash: %{},
          current_scope: scope,
          current_path: path,
          shell: :operations,
          inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "body" end}]
        )
        |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#ops-topbar .sr-ops-page-title") |> LazyHTML.text() =~ "Vantage"
      refute doc |> LazyHTML.query("#ops-topbar .sr-ops-page-title") |> LazyHTML.text() =~ "Camera Recordings"
      assert doc |> LazyHTML.query("#ops-topbar #vantage-topbar-logo[data-role='vantage-logo']") |> Enum.count() == 1
    end

    dashboard_doc =
      (&Layouts.app/1)
      |> render_component(
        flash: %{},
        current_scope: scope,
        current_path: "/dashboard",
        shell: :operations,
        inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "body" end}]
      )
      |> LazyHTML.from_fragment()

    assert dashboard_doc |> LazyHTML.query("#ops-topbar #vantage-topbar-logo") |> Enum.count() == 0
  end

  test "CameraLive.Index mounts with Vantage page_title and renders ServiceRadar Vantage header with Vantage logo" do
    {:ok, socket} = CameraIndex.mount(%{}, %{}, base_socket(synthetic_scope()))

    assert socket.assigns.page_title == "Vantage"

    doc =
      socket.assigns
      |> CameraIndex.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert doc |> LazyHTML.query("#ops-topbar #vantage-topbar-logo[data-role='vantage-logo']") |> Enum.count() == 1

    assert doc
           |> LazyHTML.query(".sr-camera-toolbar #vantage-multiview-logo[data-role='vantage-logo']")
           |> Enum.count() == 1

    assert doc |> LazyHTML.query(".sr-camera-toolbar h2") |> LazyHTML.text() =~ "ServiceRadar Vantage"
    assert doc |> LazyHTML.query(".sr-camera-toolbar p") |> LazyHTML.text() =~ "IP Camera VMS & Visual Intelligence"
  end

  test "CameraLive.Recordings mounts with Vantage page_title and RecordingsComponents renders Vantage logo cleanly" do
    {:ok, socket} = Recordings.mount(%{"camera_source_id" => @camera_id}, %{}, base_socket(synthetic_scope()))

    assert socket.assigns.page_title == "Vantage"

    doc =
      (&RecordingsComponents.recordings/1)
      |> render_component(
        source: %{
          id: @camera_id,
          device_uid: "sr:synthetic-camera-vantage",
          display_name: "Front Door"
        },
        items: [],
        timezone: "Etc/UTC",
        mode: :timeline,
        live_mode?: true
      )
      |> LazyHTML.from_fragment()

    assert doc |> LazyHTML.query("#vantage-recordings-logo[data-role='vantage-logo']") |> Enum.count() == 1
    assert doc |> LazyHTML.query("#camera-recordings header h1") |> LazyHTML.text() =~ "Front Door"
    assert doc |> LazyHTML.query("#camera-header-live-badge") |> LazyHTML.text() =~ "LIVE"

    fallback_doc =
      (&RecordingsComponents.recordings/1)
      |> render_component(source: nil, items: [], timezone: "Etc/UTC")
      |> LazyHTML.from_fragment()

    assert fallback_doc |> LazyHTML.query("#camera-recordings header h1") |> LazyHTML.text() =~ "ServiceRadar Vantage"
  end

  defp synthetic_scope do
    %Scope{
      user: %{
        id: "00000000-0000-4000-8000-000000000799",
        email: "vantage-test@example.test",
        role: :admin,
        timezone: "Etc/UTC"
      },
      permissions: MapSet.new(["devices.view", "devices.cameras.view", "devices.cameras.recordings.view"])
    }
  end

  defp base_socket(scope) do
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
        current_scope: scope
      }
    }
  end
end
