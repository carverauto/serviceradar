defmodule ServiceRadarWebNGWeb.ReportImportLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadarWebNG.ReportSourceStub, as: Stub

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db

  @sha String.duplicate("d", 40)
  @release "v0.0.1"
  @dir "elixir/web-ng/priv/dashboards"

  setup %{conn: conn} do
    marker = "rptlv#{System.unique_integer([:positive])}"
    %{conn: log_in_user(conn, admin_user_fixture()), marker: marker}
  end

  defp load(slug) do
    AuthoredDashboard
    |> Ash.Query.for_read(:by_slug, %{slug: slug})
    |> Ash.read_one!(actor: SystemActor.system(:report_import_live_test))
  end

  test "an operator loads a release's reports and imports one", %{conn: conn, marker: marker} do
    slug = "#{marker}-fleet"

    on_exit(
      Stub.install(%{
        Stub.commit_url("carverauto", "serviceradar", @release) => Stub.commit_body(@sha, true),
        Stub.raw_url("carverauto", "serviceradar", @sha, "#{@dir}/index.json") =>
          Stub.index([{slug, "#{slug}.json", false}]),
        Stub.raw_url("carverauto", "serviceradar", @sha, "#{@dir}/#{slug}.json") => Stub.definition(slug)
      })
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboards/reports/import")
    _ = render_async(lv)

    lv
    |> form("#first-party-release-form", %{"release" => %{"release_tag" => @release}})
    |> render_submit()

    html = render_async(lv)
    assert html =~ "Report #{slug}"
    refute has_element?(lv, "#first-party-report-#{slug}", "Installed")

    lv
    |> element("#first-party-report-#{slug} button", "Import")
    |> render_click()

    html = render_async(lv)
    assert html =~ ~s(Imported &quot;Report #{slug}&quot;)
    assert has_element?(lv, "#first-party-report-#{slug}", "Installed")

    assert %{source_type: :first_party, source_release_tag: @release, source_commit: @sha} = load(slug)
  end

  test "an operator imports an uploaded definition", %{conn: conn, marker: marker} do
    slug = "#{marker}-upload"
    on_exit(Stub.install(%{}))

    {:ok, lv, _html} = live(conn, ~p"/dashboards/reports/import")
    _ = render_async(lv)

    lv |> element("button[phx-value-source='upload']") |> render_click()

    upload =
      file_input(lv, "#upload-report-form", :definition, [
        %{name: "#{slug}.json", content: Stub.definition(slug), type: "application/json"}
      ])

    render_upload(upload, "#{slug}.json")

    lv |> form("#upload-report-form") |> render_submit()

    assert render_async(lv) =~ ~s(Imported &quot;Report #{slug}&quot;)
    assert %{source_type: :upload} = load(slug)
  end

  test "a user who cannot create dashboards is sent back to the library", %{conn: conn} do
    conn = log_in_user(conn, viewer_user_fixture())

    assert {:error, {:live_redirect, %{to: "/dashboards"}}} = live(conn, ~p"/dashboards/reports/import")
  end
end
