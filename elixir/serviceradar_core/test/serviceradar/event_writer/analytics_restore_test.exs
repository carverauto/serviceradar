defmodule ServiceRadar.EventWriter.AnalyticsRestoreTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.EventWriter.AnalyticsRestore

  @start ~U[2025-02-01 00:00:00Z]

  defp result(extra \\ %{}) do
    columns = Enum.map(Registry.fetch!("timeseries_metrics").columns, &elem(&1, 0))

    row =
      Map.merge(
        %{
          "timestamp" => @start,
          "gateway_id" => "synthetic-gateway",
          "series_key" => "synthetic-series",
          "value" => 12.5,
          "tags" => ~s({"test":true}),
          "metadata" => ~s({"counter_bits":64})
        },
        extra
      )

    %{columns: columns, rows: [Enum.map(columns, &Map.get(row, &1))]}
  end

  defp options(extra \\ []) do
    Keyword.merge(
      [
        config: Config.load([]),
        read: fn _, _, _ -> {:ok, result()} end,
        write: fn rows, _ -> {:ok, length(rows)} end,
        verify: fn rows, _ -> {:ok, length(rows)} end
      ],
      extra
    )
  end

  def query(sql, params, opts) do
    send(self(), {:verification_query, sql, params, opts})
    {:ok, %{rows: [[length(hd(params))]]}}
  end

  test "verification prunes chunks using actual timestamp bounds while checking every primary key" do
    early = DateTime.add(@start, 7)
    late = DateTime.add(@start, 43)

    opts =
      [
        repo: __MODULE__,
        read: fn _, _, _ ->
          first = result(%{"timestamp" => late, "gateway_id" => "synthetic-gateway-b"})
          second = result(%{"timestamp" => early, "series_key" => "synthetic-series-b"})
          {:ok, %{first | rows: first.rows ++ second.rows}}
        end,
        write: fn rows, _ ->
          assert length(rows) == 2
          {:ok, 0}
        end
      ]
      |> options()
      |> Keyword.delete(:verify)

    assert {:ok, %{scanned: 2, inserted: 0, verified: 2}} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 60), opts)

    assert_received {:verification_query, sql, [timestamps, gateways, series, ^early, ^late],
                     [timeout: 60_000, log: false]}

    assert sql =~ "WHERE t.timestamp >= $4 AND t.timestamp <= $5"
    assert sql =~ "t.timestamp = expected.timestamp AND t.gateway_id = expected.gateway_id"
    assert sql =~ "t.series_key = expected.series_key"

    assert Enum.zip([timestamps, gateways, series]) == [
             {late, "synthetic-gateway-b", "synthetic-series"},
             {early, "synthetic-gateway", "synthetic-series-b"}
           ]
  end

  test "uses half-open bounded windows and restores canonical JSON without archive writes" do
    owner = self()
    stop = DateTime.add(@start, 650, :second)

    opts =
      options(
        read: fn from, to, opts ->
          assert opts[:config].driver == :pg_duckdb
          send(owner, {:read_window, from, to})
          {:ok, result(%{"timestamp" => from})}
        end,
        write: fn [row], _ ->
          assert row.tags == %{"test" => true}
          assert row.metadata == %{"counter_bits" => 64}
          {:ok, 1}
        end
      )

    assert {:ok, %{windows: 3, scanned: 3, inserted: 3, verified: 3}} =
             AnalyticsRestore.run(@start, stop, opts)

    first = DateTime.add(@start, 300, :second)
    second = DateTime.add(@start, 600, :second)
    assert_received {:read_window, @start, ^first}
    assert_received {:read_window, ^first, ^second}
    assert_received {:read_window, ^second, ^stop}
  end

  test "deduplicates archive primary keys and accepts already-restored rows" do
    opts =
      options(
        read: fn _, _, _ ->
          result = result()
          {:ok, %{result | rows: result.rows ++ result.rows}}
        end,
        write: fn [_], _ -> {:ok, 0} end
      )

    assert {:ok, %{scanned: 2, inserted: 0, verified: 1}} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 60), opts)
  end

  test "deduplicates the same timestamp instant despite timezone and precision differences" do
    offset_timestamp = %{
      @start
      | hour: 2,
        utc_offset: 7200,
        time_zone: "Etc/GMT-2",
        zone_abbr: "UTC+02"
    }

    opts =
      options(
        read: fn _, _, _ ->
          first = result()
          second = result(%{"timestamp" => offset_timestamp})
          third = result(%{"timestamp" => %{@start | microsecond: {0, 6}}})
          {:ok, %{first | rows: first.rows ++ second.rows ++ third.rows}}
        end,
        write: fn [row], _ ->
          assert row.timestamp.time_zone == "Etc/UTC"
          assert DateTime.compare(row.timestamp, @start) == :eq
          {:ok, 1}
        end
      )

    assert {:ok, %{scanned: 3, inserted: 1, verified: 1}} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 60), opts)
  end

  test "does not advance when restored keys are missing" do
    opts = options(verify: fn _, _ -> {:ok, 0} end)

    assert {:error, %{completed: %{windows: 0}, reason: {:restore_verification_failed, 1, 0}}} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 600), opts)
  end

  test "malformed JSON fails before writing" do
    opts =
      options(
        read: fn _, _, _ -> {:ok, result(%{"metadata" => "{"})} end,
        write: fn _, _ -> flunk("invalid archive row must not be written") end
      )

    assert {:error, %{reason: :invalid_restore_json}} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 60), opts)
  end

  test "oversized windows fail instead of silently truncating" do
    opts =
      options(
        read: fn _, _, _ ->
          result = result()
          {:ok, %{result | rows: List.duplicate(hd(result.rows), 50_001)}}
        end,
        write: fn _, _ -> flunk("oversized window must not be written") end
      )

    assert {:error, %{reason: :restore_window_too_dense}} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 60), opts)
  end

  test "malformed row shapes and unexpected columns fail before writing without interning atoms" do
    unknown_column = "unknown_restore_column_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_column) end
    valid = result()

    for {input, reason} <- [
          {%{valid | rows: [tl(hd(valid.rows))]}, :invalid_restore_row_width},
          {%{valid | rows: [hd(valid.rows) ++ [nil]]}, :invalid_restore_row_width},
          {%{valid | rows: [:invalid]}, :invalid_restore_row_width},
          {%{valid | columns: [unknown_column | tl(valid.columns)]}, :unexpected_restore_columns},
          {%{columns: valid.columns, rows: nil}, :invalid_restore_result}
        ] do
      opts =
        options(
          read: fn _, _, _ -> {:ok, input} end,
          write: fn _, _ -> flunk("malformed archive result must not be written") end
        )

      assert {:error, %{reason: ^reason}} =
               AnalyticsRestore.run(@start, DateTime.add(@start, 60), opts)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_column) end
  end

  test "timestamps outside the half-open interval or without an identity fail before writing" do
    for {timestamp, reason} <- [
          {DateTime.add(@start, -1), :restore_timestamp_outside_window},
          {DateTime.add(@start, 60), :restore_timestamp_outside_window},
          {DateTime.to_naive(@start), :invalid_restore_identity}
        ] do
      opts =
        options(
          read: fn _, _, _ -> {:ok, result(%{"timestamp" => timestamp})} end,
          write: fn _, _ -> flunk("out-of-window rows must not be written") end
        )

      assert {:error, %{reason: ^reason}} =
               AnalyticsRestore.run(@start, DateTime.add(@start, 60), opts)
    end
  end

  test "failed writes stop recovery and retain the completed-window count" do
    opts = options(write: fn _, _ -> {:error, :hot_unavailable} end)

    assert {:error, %{completed: %{windows: 0}, reason: :hot_unavailable}} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 600), opts)
  end

  test "partial recovery reports only verified windows and stops at the first failure" do
    owner = self()
    first = DateTime.add(@start, 300)
    second = DateTime.add(@start, 600)

    opts =
      options(
        read: fn from, _, _ -> {:ok, result(%{"timestamp" => from})} end,
        write: fn [row], _ ->
          if DateTime.compare(row.timestamp, @start) == :eq,
            do: {:ok, 1},
            else: {:error, :hot_unavailable}
        end,
        progress: fn progress -> send(owner, {:progress, progress}) end
      )

    assert {:error,
            %{
              from: ^first,
              to: ^second,
              completed: %{windows: 1, inserted: 1, verified: 1},
              reason: :hot_unavailable
            }} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 900), opts)

    assert_received {:progress, %{through: ^first, totals: %{windows: 1}}}
    refute_received {:progress, _}
  end

  test "raised verification errors retain the failed window without advancing progress" do
    opts =
      options(
        verify: fn _, _ -> raise "verification unavailable" end,
        progress: fn _ -> flunk("unverified window must not advance") end
      )

    assert {:error,
            %{
              from: @start,
              completed: %{windows: 0},
              reason: {:restore_window_exception, %RuntimeError{}}
            }} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 60), opts)
  end

  test "invalid ranges and window sizes fail before reading" do
    assert {:error, :invalid_restore_interval} = AnalyticsRestore.run(@start, @start, options())

    assert {:error, :invalid_restore_interval} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 60), options(window_seconds: 0))

    assert {:error, :invalid_restore_interval} =
             AnalyticsRestore.run(@start, DateTime.add(@start, 600), options(window_seconds: 301))
  end
end
