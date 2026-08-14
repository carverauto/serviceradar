defmodule ServiceRadarWebNGWeb.Settings.CompositeChecksVisualCaptureTest do
  @moduledoc """
  Captures the composite check builder's rendered HTML for visual review.

  Not an assertion suite — it exists so a human (or an agent with eyes) can look
  at the page. HTML assertions pass on a layout nobody can read, and the rule
  table and preview panel are the densest things in this feature.

  Tagged `:visual` and excluded from normal runs; the capture path is only
  written when `COMPOSITE_VISUAL_CAPTURE_DIR` is set.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.CompositeChecks.CompositeCheck
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadarWebNG.AccountsFixtures

  @moduletag :visual

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, user), gateway: gateway_fixture()}
  end

  defp availability(device_uid, agent_id, is_available) do
    DeviceAgentAvailability
    |> Ash.Changeset.for_create(
      :create,
      %{
        device_uid: device_uid,
        agent_id: agent_id,
        is_available: is_available,
        checked_at: DateTime.add(DateTime.utc_now(), -90, :second)
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end

  defp capture(name, html) do
    case System.get_env("COMPOSITE_VISUAL_CAPTURE_DIR") do
      dir when is_binary(dir) and dir != "" ->
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, name), html)

      _unset ->
        :ok
    end
  end

  test "captures a fully populated builder", %{conn: conn, gateway: gateway} do
    tag = "vis#{System.unique_integer([:positive])}"

    witness = agent_fixture(gateway, %{name: "edge-agent-dmz"})
    probe = agent_fixture(gateway, %{name: "core-agent-trusted"})

    # A scope with a mix of verdicts, so the preview and rollup have something
    # real to render rather than a single row.
    isolated = device_fixture(%{hostname: "#{tag}-db-01.corp.local"})
    reachable = device_fixture(%{hostname: "#{tag}-db-02.corp.local"})
    dark = device_fixture(%{hostname: "#{tag}-db-03.corp.local"})
    partial = device_fixture(%{hostname: "#{tag}-db-04.corp.local"})

    availability(isolated.uid, witness.uid, true)
    availability(isolated.uid, probe.uid, false)
    availability(reachable.uid, witness.uid, true)
    availability(reachable.uid, probe.uid, true)
    availability(dark.uid, witness.uid, false)
    availability(dark.uid, probe.uid, false)
    availability(partial.uid, witness.uid, true)

    SweepGroup
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "DMZ TCP sweep",
        partition: "default",
        agent_id: witness.uid,
        ports: [22, 443, 3389, 5432],
        sweep_modes: ["tcp", "icmp"],
        interval: "15m"
      },
      actor: system_actor()
    )
    |> Ash.create!()

    {:ok, live, _html} = live(conn, "/settings/networks/composite-checks/new")

    live |> element("button", "Add vantage point") |> render_click()
    live |> element("button", "Add vantage point") |> render_click()

    live
    |> form("#composite-check-form", %{
      "form" => %{
        "name" => "DMZ database isolation",
        "description" => "Database tier must be unreachable from the trusted core network",
        "scope_query" => "in:devices hostname:#{tag}%",
        "evaluation_interval_seconds" => "300"
      },
      "vantage_points" => %{
        "0" => %{"agent_id" => witness.uid, "expected" => "available"},
        "1" => %{"agent_id" => probe.uid, "expected" => "blocked"}
      }
    })
    |> render_submit()

    check = check_named!("DMZ database isolation")

    {:ok, live, _html} = live(conn, "/settings/networks/composite-checks/#{check.id}/edit")

    live |> element("button", "Generate from expectations") |> render_click()
    live |> element("button", "Run preview") |> render_click()
    html = live |> element("button", "Check readiness") |> render_click()

    capture("builder.html", html)

    {:ok, _index, index_html} = live(conn, "/settings/networks/composite-checks")
    capture("index.html", index_html)

    assert html =~ "isolated_verified"
  end

  defp check_named!(name) do
    require Ash.Query

    {:ok, [check]} =
      CompositeCheck
      |> Ash.Query.filter(name == ^name)
      |> Ash.read(actor: system_actor())

    check
  end
end
