defmodule ServiceRadar.EventWriter.Processors.EventsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.EventWriter.Processors.Events

  defmodule ExistingTimeRepo do
    def query(_sql, [ids]) do
      text_ids =
        Enum.map(ids, fn
          <<_::128>> = bin -> Ecto.UUID.load!(bin)
          text when is_binary(text) -> text
        end)

      rows =
        Enum.flat_map(text_ids, fn id ->
          case Process.get({:existing_ocsf_time, id}) do
            %DateTime{} = time -> [[id, time]]
            _ -> []
          end
        end)

      {:ok, %{rows: rows}}
    end
  end

  describe "table_name/0" do
    test "returns correct table name" do
      assert Events.table_name() == "ocsf_events"
    end
  end

  describe "parse_message/1" do
    test "parses OCSF event payloads" do
      payload = %{
        "id" => Ecto.UUID.generate(),
        "time" => "2024-01-01T00:00:00Z",
        "class_uid" => 1008,
        "category_uid" => 1,
        "type_uid" => 100_801,
        "activity_id" => 1,
        "severity_id" => 5,
        "message" => "gateway offline",
        "metadata" => %{"version" => "1.7.0"}
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "events.ocsf.processed"}}

      row = Events.parse_message(message)

      assert is_binary(row.id)
      assert row.class_uid == 1008
      assert row.category_uid == 1
      assert row.activity_id == 1
      assert row.type_uid == 100_801
      assert row.message == "gateway offline"
      assert row.severity_id == 5
      assert row.severity == "Critical"
      assert row.log_name == "events.ocsf.processed"
      assert row.metadata["version"] == "1.7.0"
      assert %DateTime{} = row.time
      assert is_binary(row.raw_data)
    end

    test "returns nil when required fields are missing" do
      payload = %{
        "time" => "2024-01-01T00:00:00Z",
        "class_uid" => 1008
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "events.ocsf.processed"}}

      row = Events.parse_message(message)

      assert row == nil
    end

    test "rejects a metric payload mis-routed to the OCSF events stream" do
      payload = %{
        "schema" => "serviceradar.metric.v1",
        "metric_name" => "cpu",
        "value" => 1.0,
        "temporality" => "cumulative"
      }

      message = %{data: Jason.encode!(payload), metadata: %{subject: "events.ocsf.processed"}}

      assert Events.parse_message(message) == nil
    end
  end

  describe "fields a producer leaves to EventWriter" do
    @event %{
      "id" => "0b7f6a2e-3f7d-4c55-9f1d-1f4b5f7c2a10",
      "class_uid" => 1008,
      "category_uid" => 1,
      "type_uid" => 100_801,
      "activity_id" => 1
    }

    test "an absent log_name and raw_data take the subject and the raw payload" do
      data = Jason.encode!(@event)
      row = Events.parse_message(%{data: data, metadata: %{subject: "events.ocsf.processed"}})

      assert row.log_name == "events.ocsf.processed"
      assert row.raw_data == data
    end

    # Core's publisher sends every field; a null it sends is a null it means.
    test "an explicit null log_name and raw_data are stored as null" do
      data = Jason.encode!(Map.merge(@event, %{"log_name" => nil, "raw_data" => nil}))
      row = Events.parse_message(%{data: data, metadata: %{subject: "events.internal.jobs"}})

      assert row.log_name == nil
      assert row.raw_data == nil
    end
  end

  describe "build_rows/1" do
    test "deduplicates and sorts OCSF event rows in deterministic (time, id) order when built from a map above 32 keys" do
      base_time = ~U[2026-06-12 12:00:00Z]

      messages_by_key =
        Map.new(64..1//-1, fn index ->
          id =
            "00000000-0000-4000-8000-~12..0B"
            |> :io_lib.format([index])
            |> IO.iodata_to_binary()

          time = DateTime.shift(base_time, second: rem(index, 8))

          payload = %{
            "id" => id,
            "time" => DateTime.to_iso8601(time),
            "class_uid" => 1008,
            "category_uid" => 1,
            "type_uid" => 100_801,
            "activity_id" => 1,
            "severity_id" => 3,
            "message" => "event-#{index}"
          }

          {"event-#{index}",
           %{data: Jason.encode!(payload), metadata: %{subject: "events.ocsf.processed"}}}
        end)

      rows = Events.build_rows(Map.values(messages_by_key))

      assert length(rows) == 64

      keys =
        Enum.map(rows, fn row ->
          {DateTime.to_unix(row.time, :microsecond), Ecto.UUID.load!(row.id)}
        end)

      assert keys == Enum.sort(keys)
    end

    test "AnalyticsSignals.align_existing_ocsf_event_times/2 deduplicates and sorts OCSF event rows in deterministic (time, id) order when built from a map above 32 keys" do
      base_time = ~U[2026-06-12 12:00:00Z]

      rows_by_key =
        Map.new(64..1//-1, fn index ->
          id =
            "00000000-0000-4000-8000-~12..0B"
            |> :io_lib.format([index])
            |> IO.iodata_to_binary()

          time = DateTime.shift(base_time, second: rem(index, 8))

          {"finding-#{index}",
           %{
             id: id,
             time: time,
             class_uid: 2004,
             metadata: %{"signal_type" => "prediction", "event_type" => "capacity_forecast"},
             unmapped: %{}
           }}
        end)

      aligned =
        AnalyticsSignals.align_existing_ocsf_event_times(
          Map.values(rows_by_key),
          ExistingTimeRepo
        )

      assert length(aligned) == 64

      keys =
        Enum.map(aligned, fn row ->
          {DateTime.to_unix(row.time, :microsecond), row.id}
        end)

      assert keys == Enum.sort(keys)
    end
  end

  describe "process_batch/1 error logging" do
    test "logs the first failing statement error and SQLSTATE instead of 25P02 in_failed_sql_transaction" do
      first_error = %Postgrex.Error{
        postgres: %{
          code: :deadlock_detected,
          pg_code: "40P01",
          message: "deadlock detected"
        }
      }

      aborted_tx_error = %Postgrex.Error{
        postgres: %{
          code: :in_failed_sql_transaction,
          pg_code: "25P02",
          message:
            "current transaction is aborted, commands ignored until end of transaction block"
        }
      }

      messages =
        Stream.resource(
          fn -> :init end,
          fn :init ->
            :telemetry.execute(
              [:service_radar, :repo, :query],
              %{total_time: 1},
              %{
                result: {:error, first_error},
                query: "INSERT INTO platform.ocsf_events VALUES ($1)"
              }
            )

            raise aborted_tx_error
          end,
          fn _ -> :ok end
        )

      log =
        capture_log(fn ->
          assert {:error, _} = Events.process_batch(messages)
        end)

      assert log =~ "OCSF events batch insert failed"
      assert log =~ "sqlstate=40P01"
      assert log =~ "deadlock_detected"
      refute log =~ "25P02"
      refute log =~ "in_failed_sql_transaction"
    end

    test "AnalyticsSignals.process_batch/1 logs the first failing statement error and SQLSTATE instead of 25P02 in_failed_sql_transaction" do
      first_error = %Postgrex.Error{
        postgres: %{
          code: :deadlock_detected,
          pg_code: "40P01",
          message: "deadlock detected"
        }
      }

      aborted_tx_error = %Postgrex.Error{
        postgres: %{
          code: :in_failed_sql_transaction,
          pg_code: "25P02",
          message:
            "current transaction is aborted, commands ignored until end of transaction block"
        }
      }

      messages =
        Stream.resource(
          fn -> :init end,
          fn :init ->
            :telemetry.execute(
              [:service_radar, :repo, :query],
              %{total_time: 1},
              %{
                result: {:error, first_error},
                query: "SELECT id::text, min(time) FROM platform.ocsf_events"
              }
            )

            raise aborted_tx_error
          end,
          fn _ -> :ok end
        )

      log =
        capture_log(fn ->
          assert {:error, _} = AnalyticsSignals.process_batch(messages)
        end)

      assert log =~ "Causal signals batch insert failed"
      assert log =~ "sqlstate=40P01"
      assert log =~ "deadlock_detected"
      refute log =~ "25P02"
      refute log =~ "in_failed_sql_transaction"
    end
  end
end
