defmodule ServiceRadarWebNGWeb.WebPropertyLiveTest do
  @moduledoc """
  Shared-fixture DB LiveView tests for `/websites` (`WebPropertyLive.Index`)
  and `/websites/:id` (`WebPropertyLive.Show`).
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.WebProperty
  alias ServiceRadar.Inventory.WebPropertyBinding
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadarWebNG.AccountsFixtures

  @moduletag :web_ng_shared_fixture_db

  setup do
    prev = Application.fetch_env(:serviceradar_web_ng, :otlp_onboarding)
    Application.put_env(:serviceradar_web_ng, :otlp_onboarding, http_endpoint: "https://otlp.example.com")

    on_exit(fn ->
      case prev do
        {:ok, value} -> Application.put_env(:serviceradar_web_ng, :otlp_onboarding, value)
        :error -> Application.delete_env(:serviceradar_web_ng, :otlp_onboarding)
      end
    end)

    :ok
  end

  test "redirects unauthenticated requests to sign-in" do
    conn = build_conn()
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/websites")

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/websites/#{Ash.UUID.generate()}")
  end

  test "operator can create, view, edit, rotate RUM key, manage bindings, see checks, and delete",
       %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)
    sys = SystemActor.system(:web_property_live_test)
    unique = System.unique_integer([:positive])

    {:ok, index_view, _html} = live(conn, ~p"/websites")
    assert has_element?(index_view, "#new-website-button")

    index_view |> element("#new-website-button") |> render_click()
    assert has_element?(index_view, "#create-website-form")

    origin = "https://shop-#{unique}.example.com"

    {:ok, show_view, _html} =
      index_view
      |> form("#create-website-form", %{
        web_property: %{
          name: "Shop #{unique}",
          canonical_origin: "HTTPS://Shop-#{unique}.Example.COM:443/checkout",
          environment: "production",
          rum_sample_rate: "0.5"
        }
      })
      |> render_submit()
      |> follow_redirect(conn)

    assert has_element?(show_view, "#rum-site-key-value")
    assert has_element?(show_view, "#rum-boomerang-snippet", "https://otlp.example.com/rum/v1/beacon")
    assert has_element?(show_view, "#open-web-rum-dashboard-button")

    {:ok, wp} = WebProperty.get_by_canonical_origin(origin, actor: sys)
    assert has_element?(show_view, "#rum-site-key-value", wp.rum_site_key)

    # Rotate RUM site key
    old_key = wp.rum_site_key
    show_view |> element("#rotate-rum-site-key-button") |> render_click()

    {:ok, rotated} = WebProperty.get_by_id(wp.id, actor: sys)
    assert rotated.rum_site_key != old_key
    assert has_element?(show_view, "#rum-site-key-value", rotated.rum_site_key)
    refute has_element?(show_view, "#rum-site-key-value", old_key)

    # Edit web property
    show_view |> element("#edit-website-button") |> render_click()

    show_view
    |> form("#edit-website-form", %{
      web_property: %{
        name: "Shop Renamed #{unique}",
        canonical_origin: origin,
        environment: "staging",
        rum_sample_rate: "0.75",
        trace_propagate_origins: "https://api-#{unique}.example.com"
      }
    })
    |> render_submit()

    {:ok, updated} = WebProperty.get_by_id(wp.id, actor: sys)
    assert updated.name == "Shop Renamed #{unique}"
    assert updated.environment == :staging
    assert updated.trace_propagate_origins == ["https://api-#{unique}.example.com"]
    assert has_element?(show_view, "#rum-boomerang-snippet", "https://api-#{unique}.example.com")

    # Add and remove OTel service binding
    show_view
    |> form("#add-binding-form", %{
      binding: %{
        binding_kind: "otel_service",
        otel_service_name: "shop-frontend-#{unique}"
      }
    })
    |> render_submit()

    {:ok, [binding]} = WebPropertyBinding.list_by_web_property(wp.id, actor: sys)
    assert has_element?(show_view, "#binding-#{binding.id}", "shop-frontend-#{unique}")

    show_view |> element("#delete-binding-#{binding.id}") |> render_click()
    assert {:ok, []} = WebPropertyBinding.list_by_web_property(wp.id, actor: sys)

    # Linked ServiceCheck appears on reload
    {:ok, check} =
      ServiceCheck
      |> Ash.Changeset.for_create(:create, %{
        name: "Shop Health #{unique}",
        check_type: :http,
        target: "#{origin}/health",
        device_uid: nil,
        web_property_id: wp.id
      })
      |> Ash.create(actor: sys)

    {:ok, reloaded_show, _html} = live(conn, ~p"/websites/#{wp.id}")
    assert has_element?(reloaded_show, "#service-check-#{check.id}", "Shop Health #{unique}")

    # Delete web property
    {:ok, _after_delete, _html} =
      reloaded_show
      |> element("#delete-website-button")
      |> render_click()
      |> follow_redirect(conn, ~p"/websites")

    assert {:error, _} = WebProperty.get_by_id(wp.id, actor: sys)
  end

  test "viewer can read /websites and /websites/:id but cannot mutate", %{conn: conn} do
    sys = SystemActor.system(:web_property_live_viewer_test)
    unique = System.unique_integer([:positive])

    {:ok, wp} =
      WebProperty
      |> Ash.Changeset.for_create(:create, %{
        name: "Viewer Site #{unique}",
        canonical_origin: "https://viewer-#{unique}.example.com"
      })
      |> Ash.create(actor: sys)

    viewer = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, viewer)

    {:ok, index_view, _html} = live(conn, ~p"/websites")
    refute has_element?(index_view, "#new-website-button")

    {:ok, show_view, _html} = live(conn, ~p"/websites/#{wp.id}")
    assert has_element?(show_view, "#rum-site-key-value", wp.rum_site_key)
    refute has_element?(show_view, "#edit-website-button")
    refute has_element?(show_view, "#delete-website-button")
    refute has_element?(show_view, "#rotate-rum-site-key-button")
    refute has_element?(show_view, "#add-binding-form")
  end
end
