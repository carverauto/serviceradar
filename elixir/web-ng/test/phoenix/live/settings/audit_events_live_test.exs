defmodule ServiceRadarWebNGWeb.Settings.AuditEventsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Security.SecurityEvent
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.SRQL

  require Logger

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
    at = DateTime.shift(DateTime.utc_now(), minute: -1)
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
    live_event = record(DateTime.shift(DateTime.utc_now(), second: 1), marker)
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()
    # Test-only timing probe for the 250ms debounce vs the 1000ms window
    # below: a monotonic send stamp plus side-channel numeric observations
    # scoped strictly to view.pid. No waits, ordering, timeout, or assertion
    # changes; diagnostics log even when the original assertion fails.
    diag_t0_ms = System.monotonic_time(:millisecond)

    :telemetry.attach(
      handler_id,
      [:service_radar, :repo, :query],
      fn _event, measurements, metadata, _config ->
        if self() == view.pid and String.contains?(metadata.query, "security_events") do
          send(test_pid, :audit_read)

          send(
            test_pid,
            {:audit_diag, audit_diag_elapsed(diag_t0_ms), measurements}
          )
        end
      end,
      nil
    )

    diag_tracer = start_audit_diag_tracer(view.pid, test_pid, diag_t0_ms)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      :erlang.trace(view.pid, false, [:receive])
      send(diag_tracer, :audit_diag_stop)
    end)

    for _ <- 1..50, do: send(view.pid, {:security_event, live_event})

    try do
      assert_receive :audit_read, 1_000
    after
      log_audit_diag(diag_t0_ms)
      :erlang.trace(view.pid, false, [:receive])
    end

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
      record(DateTime.shift(at, second: 10), marker, %{
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

  # --- Test-only timing diagnostics (keyset-paging debounce probe) ------------
  # Helpers for the single instrumented assert above. They record monotonic
  # millisecond offsets scoped to view.pid and log one compact numeric line.
  # Missing stages report -1. No HTML, mailbox, SQL, or payload contents.
  defp audit_diag_elapsed(t0_ms), do: System.monotonic_time(:millisecond) - t0_ms

  defp start_audit_diag_tracer(view_pid, test_pid, t0_ms) do
    tracer = spawn(fn -> audit_diag_trace_loop(view_pid, test_pid, t0_ms, %{}) end)
    :erlang.trace(view_pid, true, [{:tracer, tracer}, :receive])
    tracer
  end

  defp audit_diag_trace_loop(view_pid, test_pid, t0_ms, seen) do
    receive do
      {:trace, ^view_pid, :receive, :refresh_events} ->
        if Map.has_key?(seen, :refresh_recv) do
          audit_diag_trace_loop(view_pid, test_pid, t0_ms, seen)
        else
          now_ms = audit_diag_elapsed(t0_ms)
          send(test_pid, {:audit_trace, :refresh_recv, now_ms})
          audit_diag_trace_loop(view_pid, test_pid, t0_ms, Map.put(seen, :refresh_recv, now_ms))
        end

      {:trace, ^view_pid, :receive, {:security_event, _}} ->
        if Map.has_key?(seen, :first_recv) do
          audit_diag_trace_loop(view_pid, test_pid, t0_ms, seen)
        else
          now_ms = audit_diag_elapsed(t0_ms)
          send(test_pid, {:audit_trace, :first_recv, now_ms})
          audit_diag_trace_loop(view_pid, test_pid, t0_ms, Map.put(seen, :first_recv, now_ms))
        end

      {:trace, _, :receive, _} ->
        audit_diag_trace_loop(view_pid, test_pid, t0_ms, seen)

      :audit_diag_stop ->
        :ok
    end
  end

  defp log_audit_diag(t0_ms) do
    window_ms = audit_diag_elapsed(t0_ms)

    acc = %{
      query_done: 0,
      first_recv_ms: -1,
      refresh_recv_ms: -1,
      queue_ms: -1,
      query_ms: -1,
      decode_ms: -1,
      total_ms: -1
    }

    acc = drain_audit_diag(acc)

    Logger.info(
      "audit_diag window_ms=#{window_ms} query_done=#{acc.query_done} " <>
        "first_recv_ms=#{acc.first_recv_ms} refresh_recv_ms=#{acc.refresh_recv_ms} " <>
        "queue_ms=#{acc.queue_ms} query_ms=#{acc.query_ms} " <>
        "decode_ms=#{acc.decode_ms} total_ms=#{acc.total_ms}"
    )
  end

  defp drain_audit_diag(acc) do
    receive do
      {:audit_diag, _elapsed_ms, measurements} when is_map(measurements) ->
        drain_audit_diag(%{
          acc
          | query_done: 1,
            queue_ms: diag_native_ms(measurements, :queue_time),
            query_ms: diag_native_ms(measurements, :query_time),
            decode_ms: diag_native_ms(measurements, :decode_time),
            total_ms: diag_native_ms(measurements, :total_time)
        })

      {:audit_trace, :first_recv, ms} when is_integer(ms) ->
        drain_audit_diag(%{acc | first_recv_ms: ms})

      {:audit_trace, :refresh_recv, ms} when is_integer(ms) ->
        drain_audit_diag(%{acc | refresh_recv_ms: ms})
    after
      0 -> acc
    end
  end

  defp diag_native_ms(measurements, key) do
    case Map.fetch(measurements, key) do
      {:ok, value} when is_integer(value) ->
        System.convert_time_unit(value, :native, :millisecond)

      _ ->
        -1
    end
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
