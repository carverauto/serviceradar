defmodule ServiceRadarWebNG.OtelServicesAccessDbTest do
  @moduledoc """
  An admitted `in:otel_services` query is narrowed to the caller's permitted
  signals end to end: the web-ng gate computes the set, `SRQL.query/2` hands
  it to translate, and the rows never disclose activity in another signal.

  The refusals are covered without a database in
  `test/phoenix/srql/otel_services_access_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.SRQL

  @moduletag :web_ng_shared_fixture_db

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    now = DateTime.utc_now()
    hour_ago = DateTime.add(now, -3600, :second)

    # `svc-0001` logged an hour ago and traced a minute ago; `svc-0002` only traced.
    rows = [
      {"svc-0001", hour_ago, DateTime.add(now, -60, :second), nil},
      {"svc-0002", nil, DateTime.add(now, -30, :second), nil}
    ]

    for {name, logs_at, traces_at, metrics_at} <- rows do
      last_seen = [logs_at, traces_at, metrics_at] |> Enum.reject(&is_nil/1) |> Enum.max(DateTime)

      SQL.query!(
        Repo,
        """
        INSERT INTO platform.otel_service_catalog
          (service_name, logs_last_seen_at, traces_last_seen_at, metrics_last_seen_at, last_seen_at)
        VALUES ($1, $2, $3, $4, $5)
        """,
        [name, logs_at, traces_at, metrics_at, last_seen]
      )
    end

    %{hour_ago: hour_ago}
  end

  test "a logs-only caller sees only logs activity", %{hour_ago: hour_ago} do
    scope = %Scope{user: nil, permissions: MapSet.new(["observability.logs.view"])}

    assert {:ok, %{"results" => [row]}} =
             SRQL.query("in:otel_services time:last_2h", %{scope: scope})

    assert row["service_name"] == "svc-0001"
    assert row["signals"] == ["logs"]
    assert is_nil(row["traces_last_seen"])

    {:ok, last_seen, _offset} = DateTime.from_iso8601(row["last_seen"])
    assert abs(DateTime.diff(last_seen, hour_ago, :second)) <= 1
  end

  test "a caller holding every signal sees every service" do
    scope = %Scope{
      user: nil,
      permissions: MapSet.new(["observability.logs.view", "observability.traces.view", "observability.metrics.view"])
    }

    assert {:ok, %{"results" => rows}} = SRQL.query("in:otel_services sort:service_name:asc", %{scope: scope})
    assert Enum.map(rows, & &1["service_name"]) == ["svc-0001", "svc-0002"]

    assert {:ok, %{"results" => [%{"total" => 2}]}} =
             SRQL.query(~s|in:otel_services signal:traces stats:"count() as total"|, %{scope: scope})
  end
end
