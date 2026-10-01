defmodule ServiceRadarWebNGWeb.Settings.AuditEventsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Security.SecurityEvent
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.SRQL

  @moduletag :web_ng_shared_fixture_db

  @filter_defaults %{
    "kind" => "",
    "severity" => "",
    "actor_id" => "",
    "ip" => "",
    "route" => "",
    "correlation_id" => "",
    "search" => "",
    "time" => "last_24h",
    "from" => "",
    "to" => ""
  }

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()
    at = DateTime.add(DateTime.utc_now(), -60, :second)
    marker = "invented-audit-#{System.unique_integer([:positive])}"
    events = for _ <- 1..28, do: record(at, marker)
    events = Enum.sort_by(events, & &1.id, :desc)
    %{conn: log_in_user(conn, user), events: events, marker: marker, at: at}
  end

  test "keyset paging preserves filters and ignores live events on older pages", %{
    conn: conn,
    events: events,
    marker: marker
  } do
    {:ok, view, _} = live(conn, "/settings/audit/events")
    filter(view, %{"actor_id" => marker})
    assert row_ids(view) == Enum.map(Enum.take(events, 25), & &1.id)
    assert has_element?(view, "#audit-events-previous[disabled]")
    refute has_element?(view, "#audit-events-next[disabled]")

    view |> element("#audit-events-next") |> render_click()
    assert row_ids(view) == Enum.map(Enum.drop(events, 25), & &1.id)
    assert has_element?(view, "#audit-events-next[disabled]")
    assert has_element?(view, "#filters_actor_id[value='#{marker}']")

    latest = record(DateTime.utc_now(), marker)
    send(view.pid, {:security_event, latest})
    assert row_ids(view) == Enum.map(Enum.drop(events, 25), & &1.id)

    view |> element("#audit-events-previous") |> render_click()
    assert hd(row_ids(view)) == latest.id
    live_event = record(DateTime.add(DateTime.utc_now(), 1, :second), marker)
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:service_radar, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == view.pid and String.contains?(metadata.query, "security_events") do
          send(test_pid, :audit_read)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for _ <- 1..50, do: send(view.pid, {:security_event, live_event})
    assert_receive :audit_read, 1_000
    assert hd(row_ids(view)) == live_event.id
    refute_receive :audit_read, 350

    send(view.pid, {:security_event, latest})
    assert_receive :audit_read, 1_000
    assert Enum.count(row_ids(view), &(&1 == latest.id)) == 1

    send(view.pid, {:security_event, live_event})
    view |> element("#audit-events-next") |> render_click()
    assert_receive :audit_read
    assert row_ids(view) == Enum.map(Enum.drop(events, 23), & &1.id)
    refute_receive :audit_read, 350

    filter(view, %{"time" => "custom", "from" => "2001-01-01T00:00", "to" => "2001-01-02T00:00"})
    assert_receive :audit_read
    for _ <- 1..50, do: send(view.pid, {:security_event, live_event})
    assert row_ids(view) == []
    refute_receive :audit_read, 350
  end

  test "combined filters, literal search and time changes reset paging; clear restores defaults",
       %{conn: conn, marker: marker, at: at} do
    target =
      record(DateTime.add(at, 10, :second), marker, %{
        route: "/invented/%literal",
        correlation_id: "invented-correlation",
        severity: :critical
      })

    {:ok, view, _} = live(conn, "/settings/audit/events")
    filter(view, %{"actor_id" => marker})
    view |> element("#audit-events-next") |> render_click()

    filter(view, %{
      "actor_id" => marker,
      "kind" => "login_failed",
      "severity" => "critical",
      "ip" => "192.0.2.8",
      "route" => target.route,
      "correlation_id" => target.correlation_id,
      "search" => "%LITERAL"
    })

    assert row_ids(view) == [target.id]
    assert has_element?(view, "#audit-events-previous[disabled]")
    assert has_element?(view, "#audit-events-next[disabled]")

    nullable = record(at, marker, %{route: "/invented/%nullable", ip: nil, correlation_id: nil})
    filter(view, %{"actor_id" => marker, "search" => "%NULLABLE"})
    assert row_ids(view) == [nullable.id]

    filter(view, %{"time" => "custom"})
    filter(view, %{"time" => "custom", "from" => "2001-01-01T00:00", "to" => "2001-01-02T00:00"})
    assert row_ids(view) == []
    filter(view, %{"time" => "custom", "from" => "", "to" => ""})
    assert has_element?(view, "#audit-events-error")

    view |> element("#audit-events-clear") |> render_click()
    assert has_element?(view, "#filters_actor_id[value='']")
    assert has_element?(view, "#filters_time option[value='last_24h'][selected]")
    assert has_element?(view, "#audit-events-previous[disabled]")
    refute has_element?(view, "#audit-events-error")
  end

  test "SRQL reads the audit rows with the same filters and denies an ordinary events reader", %{
    marker: marker,
    events: events
  } do
    auditor = %Scope{permissions: MapSet.new(["settings.audit.view"])}
    reader = %Scope{permissions: MapSet.new(["observability.events.view"])}

    query =
      "in:security_events actor_id:#{marker} ip:192.0.2.8 route:/invented/login kind:login_failed severity:warning correlation_id:invented-trace time:last_1h sort:occurred_at:desc limit:2"

    assert {:error, :forbidden} = SRQL.query(query, %{scope: reader})
    assert {:ok, %{"results" => rows}} = SRQL.query(query, %{scope: auditor})
    assert Enum.map(rows, & &1["id"]) == Enum.map(Enum.take(events, 2), & &1.id)

    literal = record(DateTime.utc_now(), marker, %{route: "/invented/%literal"})

    assert {:ok, %{"results" => [row]}} =
             SRQL.query("in:security_events actor_id:#{marker} search:%literal", %{scope: auditor})

    assert row["id"] == literal.id

    for query <- [
          "search:(%literal,absent-invented-text)",
          "!search:(login,absent-invented-text)",
          "!route:%login%",
          "!route:(/invented/login,/invented/absent)"
        ] do
      assert {:ok, %{"results" => [row]}} =
               SRQL.query("in:security_events actor_id:#{marker} #{query}", %{scope: auditor})

      assert row["id"] == literal.id
    end

    assert {:ok, %{"results" => []}} =
             SRQL.query("in:security_events actor_id:#{marker} search:absent-invented-text", %{
               scope: auditor
             })

    missing = record(DateTime.utc_now(), nil, %{ip: nil, route: nil, correlation_id: nil})

    [first, second, retained] =
      for index <- 1..3 do
        record(DateTime.utc_now(), "invented-exclusion-#{index}", %{
          ip: "192.0.2.#{index}",
          route: "/invented/exclusion/#{index}",
          correlation_id: "invented-exclusion-trace-#{index}"
        })
      end

    ids = Enum.map_join([missing, first, second, retained], ",", & &1.id)

    for field <- [:actor_id, :ip, :route, :correlation_id] do
      first_value = Map.fetch!(first, field)
      second_value = Map.fetch!(second, field)

      for {filter, expected} <- [
            {"!#{field}:#{first_value}", [missing.id, second.id, retained.id]},
            {"!#{field}:(#{first_value})", [missing.id, second.id, retained.id]},
            {"!#{field}:#{first_value} !#{field}:#{second_value}", [missing.id, retained.id]},
            {"!#{field}:(#{first_value},#{second_value})", [missing.id, retained.id]},
            {"#{field}:(#{first_value},#{second_value})", [first.id, second.id]}
          ] do
        query = "in:security_events id:(#{ids}) #{filter} limit:10"
        assert {:ok, %{"results" => rows}} = SRQL.query(query, %{scope: auditor})
        assert Enum.sort(Enum.map(rows, & &1["id"])) == Enum.sort(expected), query
      end
    end
  end

  defp filter(view, values) do
    filters = Map.merge(@filter_defaults, values)
    view |> element("#audit-event-filters") |> render_change(%{"filters" => filters})
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#audit-events-rows tr[id]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "audit-event-", ""))
  end

  defp record(at, actor, attrs \\ %{}) do
    SecurityEvent
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          occurred_at: at,
          actor_id: actor,
          kind: :login_failed,
          severity: :warning,
          ip: "192.0.2.8",
          route: "/invented/login",
          correlation_id: "invented-trace"
        },
        attrs
      )
    )
    |> Ash.create!(actor: AshTestHelpers.system_actor())
  end
end
