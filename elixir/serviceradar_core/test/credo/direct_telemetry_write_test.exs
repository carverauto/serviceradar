defmodule ServiceRadar.Credo.Check.Warning.DirectTelemetryWriteTest do
  use Credo.Test.Case

  alias ServiceRadar.Credo.Check.Warning.DirectTelemetryWrite

  # The check lives outside `lib/`, so it is compiled here. Not at file load:
  # `use Credo.Check` reads the Mix project, and the integration selection
  # tooling loads every test file without running Mix or any test.
  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)

    if !Code.ensure_loaded?(DirectTelemetryWrite) do
      Code.require_file("../../credo/check/warning/direct_telemetry_write.ex", __DIR__)
    end

    :ok
  end

  defp issues(source, filename \\ "lib/serviceradar/inventory/example.ex") do
    source
    |> to_source_file(filename)
    |> run_check(DirectTelemetryWrite)
  end

  describe "writes to the event and log tables" do
    test "flags an insert_all into ocsf_events" do
      """
      defmodule Example do
        def store(rows), do: Repo.insert_all("ocsf_events", rows, on_conflict: :nothing)
      end
      """
      |> issues()
      |> assert_issue(&assert(&1.trigger == "insert_all"))
    end

    test "flags an insert into logs through a local helper and a source tuple" do
      """
      defmodule Example do
        def store(rows) do
          insert_all_count("logs", rows)
          BulkInsert.insert_all({"logs", Row}, rows)
        end
      end
      """
      |> issues()
      |> assert_issues(&assert(length(&1) == 2))
    end

    test "flags the schema modules, aliased and as a struct literal" do
      """
      defmodule Example do
        alias ServiceRadar.Monitoring.OcsfEvent
        alias ServiceRadar.Observability, as: Obs

        def store(rows) do
          Repo.insert_all(OcsfEvent, rows)
        end

        def store_one(attrs) do
          Repo.insert!(%Obs.Log{message: attrs.message})
        end
      end
      """
      |> issues()
      |> assert_issues(&assert(length(&1) == 2))
    end

    test "flags an Ash create of either resource, piped or called" do
      """
      defmodule Example do
        alias ServiceRadar.Monitoring.OcsfEvent
        alias ServiceRadar.Observability.Log

        def record(attrs, actor) do
          OcsfEvent
          |> Ash.Changeset.for_create(:record, attrs, actor: actor)
          |> Ash.create()
        end

        def log(attrs), do: Ash.Changeset.for_create(Log, :create, attrs)
        def many(inputs), do: Ash.bulk_create(inputs, OcsfEvent, :record)
        def seed(attrs), do: Ash.Seed.seed!(Log, attrs)
      end
      """
      |> issues()
      |> assert_issues(&assert(length(&1) == 4))
    end

    test "flags an Ecto.Multi insert naming the table" do
      """
      defmodule Example do
        def store(multi, rows), do: Ecto.Multi.insert_all(multi, :events, "ocsf_events", rows)
      end
      """
      |> issues()
      |> assert_issue()
    end

    test "does not flag reads, deletes or inserts into other tables" do
      """
      defmodule Example do
        import Ecto.Query

        def work(rows) do
          Repo.all(from(e in "ocsf_events", select: e.id))
          Repo.delete_all(from(l in "logs"))
          Repo.insert_all("alerts", rows)
          Repo.insert_all(ServiceRadar.Monitoring.Alert, rows)
        end
      end
      """
      |> issues()
      |> refute_issues()
    end
  end

  describe "in-process EventWriter processor calls" do
    test "flags process_batch on a processor named directly or through an alias" do
      """
      defmodule Example do
        alias ServiceRadar.EventWriter.Processors
        alias ServiceRadar.EventWriter.Processors.{AnalyticsSignals, Events}

        def emit(messages) do
          ServiceRadar.EventWriter.Processors.Logs.process_batch(messages)
          Processors.Logs.process_batch(messages)
          AnalyticsSignals.process_batch(messages)
          Events.process_batch(messages)
        end
      end
      """
      |> issues()
      |> assert_issues(&assert(length(&1) == 4))
    end

    test "flags a processor handed around as a value" do
      """
      defmodule Example do
        alias ServiceRadar.EventWriter.Processors.AnalyticsSignals

        def emit(message, opts) do
          processor = Keyword.get(opts, :processor, AnalyticsSignals)
          processor.process_batch([message])
        end
      end
      """
      |> issues()
      |> assert_issue(&assert(&1.trigger == "AnalyticsSignals"))
    end

    test "does not flag other processor functions, other modules, or the alias itself" do
      """
      defmodule Example do
        alias ServiceRadar.EventWriter.Processors.AnalyticsSignals

        def run(processor, batch, message) do
          AnalyticsSignals.parse_message(message)
          SyncIngestor.process_batch(batch)
          processor.process_batch(batch)
        end
      end
      """
      |> issues()
      |> refute_issues()
    end
  end

  describe "exempt files" do
    @write """
    defmodule Example do
      def store(rows, messages) do
        Repo.insert_all("ocsf_events", rows)
        ServiceRadar.EventWriter.Processors.Logs.process_batch(messages)
      end
    end
    """

    test "EventWriter and log promotion may write" do
      refute_issues(issues(@write, "lib/serviceradar/event_writer/processors/events.ex"))
      refute_issues(issues(@write, "lib/serviceradar/event_writer/pipeline.ex"))
      refute_issues(issues(@write, "lib/serviceradar/observability/log_promotion.ex"))
    end

    test "test files may write" do
      refute_issues(issues(@write, "test/support/inline_event_writer_publisher.ex"))
      refute_issues(issues(@write, "apps/core/test/example_test.exs"))
    end

    test "an allowed path configured by param replaces the defaults" do
      source_file = to_source_file(@write, "lib/serviceradar/event_writer/processors/events.ex")

      source_file
      |> run_check(DirectTelemetryWrite, allowed_paths: ["lib/other/"])
      |> assert_issues(&assert(length(&1) == 2))
    end
  end
end
