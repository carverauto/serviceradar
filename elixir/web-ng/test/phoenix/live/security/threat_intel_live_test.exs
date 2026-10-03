defmodule ServiceRadarWebNGWeb.Security.ThreatIntelLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.IpThreatIntelCache
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "admin can open the investigation workspace", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/security/threat-intel")

    assert html =~ "Threat Intel"
    assert html =~ "Current matches"
    assert has_element?(view, "a", "Manage feeds")
    refute html =~ "otx-liveview-secret"
  end

  test "viewer can open investigation but not settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    {:ok, _view, html} = live(conn, ~p"/security/threat-intel")
    assert html =~ "Current matches"

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/settings/networks/threat-intel")
    assert to == ~p"/settings/profile"
  end

  test "invalid ip query param is user-safe", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/security/threat-intel?ip=not-an-ip")

    assert html =~ "The selected IP address is not valid."
    refute html =~ "Postgrex"
    refute html =~ "Ash."
    refute html =~ "%{"
  end

  @tag :web_ng_shared_fixture_db
  test "loads the indicator for a current match", %{conn: conn} do
    source = unique_source("ready")
    {ip, cidr} = unique_host()
    label = "Synthetic pulse #{source}"
    seed_match!(ip, cidr, source, label, expires_in: 3600)

    {:ok, view, html} = live(conn, ~p"/security/threat-intel?#{[ip: ip, source: source]}")

    assert html =~ label
    assert has_element?(view, ~s([data-testid="threat-intel-indicator"]))
    assert has_element?(view, ~s([data-testid="threat-intel-provider-context"]))
    refute has_element?(view, ~s([data-testid="threat-intel-indicator-error"]))
    refute html =~ "Failed to load indicators."
    refute html =~ "or no active indicator still contains it"

    assert has_element?(
             view,
             ~s(#threat-intel-flow-link[href*="in%3Aflows"][href*="threat_observed_ip"][href*="time%3Alast_24h"])
           )

    assert has_element?(
             view,
             ~s(#threat-intel-attributed-flow-link[href*="in%3Aattributed_flows"][href*="threat_observed_ip"])
           )
  end

  @tag :web_ng_shared_fixture_db
  test "says when a current match has no active indicator", %{conn: conn} do
    source = unique_source("missing")
    {ip, _cidr} = unique_host()
    seed_cache!(ip, source, expires_in: 3600)

    {:ok, view, html} = live(conn, ~p"/security/threat-intel?#{[ip: ip, source: source]}")

    assert has_element?(
             view,
             ~s([data-testid="threat-intel-detail-notice"]),
             "No active indicator still contains this endpoint."
           )

    refute has_element?(view, ~s([data-testid="threat-intel-indicator-error"]))
    refute has_element?(view, ~s([data-testid="threat-intel-provider-context"]))
    refute html =~ "Failed to load indicators."
  end

  @tag :web_ng_shared_fixture_db
  test "labels an expired cache row only when stale matches are requested", %{conn: conn} do
    source = unique_source("stale")
    {ip, _cidr} = unique_host()
    seed_cache!(ip, source, expires_in: -60)

    {:ok, current_view, current_html} = live(conn, ~p"/security/threat-intel?#{[source: source]}")

    refute current_html =~ ip
    assert has_element?(current_view, ~s([data-testid="threat-intel-empty"]))

    {:ok, stale_view, stale_html} =
      live(conn, ~p"/security/threat-intel?#{[ip: ip, source: source, stale: true]}")

    assert stale_html =~ ip
    assert has_element?(stale_view, ~s([data-testid="threat-intel-row-#{ip}"]), "Stale")
    refute has_element?(stale_view, ~s([data-testid="threat-intel-indicator-error"]))
  end

  defp seed_match!(ip, cidr, source, label, expires_in: seconds) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    actor = system_actor()

    ThreatIntelIndicator
    |> Ash.Changeset.for_create(:upsert, %{
      indicator: cidr,
      indicator_type: "cidr",
      source: source,
      label: label,
      severity: 100,
      confidence: 80,
      first_seen_at: now,
      last_seen_at: now,
      expires_at: DateTime.add(now, seconds, :second)
    })
    |> Ash.create!(actor: actor)

    seed_cache!(ip, source, expires_in: seconds)
  end

  defp seed_cache!(ip, source, expires_in: seconds) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    IpThreatIntelCache
    |> Ash.Changeset.for_create(:upsert, %{
      ip: ip,
      matched: true,
      match_count: 1,
      max_severity: 4,
      sources: [source],
      looked_up_at: now,
      expires_at: DateTime.add(now, seconds, :second)
    })
    |> Ash.create!(actor: system_actor())
  end

  defp system_actor, do: SystemActor.system(:threat_intel_live_test)

  defp unique_source(kind), do: "investigation-live-#{kind}-#{System.unique_integer([:positive])}"

  defp unique_host do
    octet = rem(System.unique_integer([:positive]), 200) + 20
    ip = "198.51.100.#{octet}"
    {ip, "#{ip}/32"}
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})

    %{conn: log_in_user(conn, user), user: user}
  end
end
