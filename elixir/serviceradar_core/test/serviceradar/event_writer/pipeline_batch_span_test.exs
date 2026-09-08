defmodule ServiceRadar.EventWriter.PipelineBatchSpanTest do
  # async: false — sets the global text-map propagator and restarts the
  # OpenTelemetry SDK with a pid exporter to capture finished spans.
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.Otel

  require Record

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @span_fields)

  @link_fields Record.extract(:link, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:link, @link_fields)

  @status_fields Record.extract(:status,
                   from_lib: "opentelemetry_api/include/opentelemetry.hrl"
                 )
  Record.defrecordp(:status, @status_fields)

  @event_fields Record.extract(:event, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:event, @event_fields)

  @trace_id_a 0x0AF7651916CD43DD8448EB211C80319C
  @trace_id_b 0x1AF7651916CD43DD8448EB211C80319C
  @traceparent_a "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  @traceparent_b "00-1af7651916cd43dd8448eb211c80319c-c7ad6b7169203331-01"

  setup do
    old_injector = :opentelemetry.get_text_map_injector()
    old_extractor = :opentelemetry.get_text_map_extractor()

    old_otel_env =
      Map.new([:traces_exporter, :processors, :sampler], fn key ->
        {key, Application.fetch_env(:opentelemetry, key)}
      end)

    :opentelemetry.set_text_map_propagator(:otel_propagator_trace_context)

    # Ensure the application-scoped tracer cache contains the pre-restart
    # provider. The SDK does not invalidate this cache when it restarts.
    _stale_tracer = :opentelemetry.get_application_tracer(Pipeline)

    # Restart the SDK with a synchronous pid exporter so finished spans are
    # delivered to the test process as {:span, span_record} messages.
    restart_otel_with_pid_exporter(self())

    on_exit(fn ->
      Application.stop(:opentelemetry)

      Enum.each(old_otel_env, fn {key, value} ->
        restore_application_env(key, value)
      end)

      {:ok, _} = Application.ensure_all_started(:opentelemetry)

      :opentelemetry.set_text_map_injector(old_injector)
      :opentelemetry.set_text_map_extractor(old_extractor)
    end)

    :ok
  end

  defp restore_application_env(key, {:ok, value}),
    do: Application.put_env(:opentelemetry, key, value)

  defp restore_application_env(key, :error), do: Application.delete_env(:opentelemetry, key)

  defp message(headers) do
    %{metadata: %{subject: "events.poller.status", headers: headers}}
  end

  defp message_without_headers do
    %{metadata: %{subject: "events.poller.status"}}
  end

  describe "telemetry_subject?/1" do
    test "true for OTel and log telemetry subjects" do
      assert Pipeline.telemetry_subject?("otel.traces.raw")
      assert Pipeline.telemetry_subject?("otel.metrics.raw")
      assert Pipeline.telemetry_subject?("otel.logs")
      assert Pipeline.telemetry_subject?("logs.otel")
      assert Pipeline.telemetry_subject?("logs.syslog.processed")
      assert Pipeline.telemetry_subject?("metrics.sysmon.cpu")
      assert Pipeline.telemetry_subject?("metrics.snmp.interface")
    end

    test "false for event-style subjects" do
      refute Pipeline.telemetry_subject?("events.poller.status")
      refute Pipeline.telemetry_subject?("falco.logs")
      refute Pipeline.telemetry_subject?("pdns.ocsf")
      refute Pipeline.telemetry_subject?("trivy.report.host")
      refute Pipeline.telemetry_subject?("sweep.results")
      refute Pipeline.telemetry_subject?(nil)
      refute Pipeline.telemetry_subject?("")
    end
  end

  describe "batch_links/1" do
    test "extracts one link per distinct upstream trace context" do
      messages = [
        message([{"traceparent", @traceparent_a}]),
        message([{"traceparent", @traceparent_b}]),
        message_without_headers()
      ]

      links = Pipeline.batch_links(messages)

      assert [%{trace_id: @trace_id_a}, %{trace_id: @trace_id_b}] = links
    end

    test "deduplicates identical trace contexts" do
      messages = [
        message([{"traceparent", @traceparent_a}]),
        message([{"traceparent", @traceparent_a}])
      ]

      assert [%{trace_id: @trace_id_a}] = Pipeline.batch_links(messages)
    end

    test "caps links at eight distinct contexts" do
      messages =
        for n <- 1..12 do
          trace_id = String.pad_leading(Integer.to_string(n, 16), 32, "0")
          message([{"traceparent", "00-#{trace_id}-b7ad6b7169203331-01"}])
        end

      assert length(Pipeline.batch_links(messages)) == 8
    end

    test "messages without headers produce no links" do
      assert Pipeline.batch_links([message_without_headers()]) == []
      assert Pipeline.batch_links([message([{"Nats-Msg-Id", "abc"}])]) == []
      assert Pipeline.batch_links([]) == []
    end
  end

  describe "with_batch_span/3" do
    test "wraps non-telemetry batches in a consumer span with upstream links" do
      messages = [
        message([{"traceparent", @traceparent_a}]),
        message([{"traceparent", @traceparent_b}]),
        message_without_headers()
      ]

      result =
        Pipeline.with_batch_span("events.poller.status", messages, fn ->
          assert OpenTelemetry.Tracer.current_span_ctx() != :undefined
          :batch_done
        end)

      assert result == :batch_done

      assert_receive {:span,
                      span(name: "event_writer.process_batch", links: links, attributes: attrs)},
                     1_000

      link_trace_ids = links |> :otel_links.list() |> Enum.map(&link(&1, :trace_id))
      assert Enum.sort(link_trace_ids) == Enum.sort([@trace_id_a, @trace_id_b])

      attributes = :otel_attributes.map(attrs)
      assert attributes["messaging.system"] == "nats"
      assert attributes["messaging.operation.name"] == "process"
      assert attributes["messaging.destination.name"] == "events.poller.status"
      assert attributes["messaging.batch.message_count"] == 3
    end

    test "creates no span for telemetry subjects" do
      messages = [message([{"traceparent", @traceparent_a}])]

      for subject <- ["otel.traces.raw", "otel.metrics.raw", "logs.otel", "metrics.sysmon.cpu"] do
        result =
          Pipeline.with_batch_span(subject, messages, fn ->
            assert OpenTelemetry.Tracer.current_span_ctx() == :undefined
            :batch_done
          end)

        assert result == :batch_done
      end

      refute_receive {:span, _span}, 200
    end

    test "batches without headers get a span with no links" do
      result =
        Pipeline.with_batch_span("events.poller.status", [message_without_headers()], fn ->
          :batch_done
        end)

      assert result == :batch_done

      assert_receive {:span, span(name: "event_writer.process_batch", links: links)}, 1_000
      assert :otel_links.list(links) == []
    end

    test "refreshes the batch tracer when the OpenTelemetry SDK restarts" do
      first_provider = Otel.provider_identity()
      assert is_pid(first_provider)

      assert :first =
               Pipeline.with_batch_span("events.poller.status", [message_without_headers()], fn ->
                 :first
               end)

      assert_receive {:span, span(name: "event_writer.process_batch")}, 1_000

      restart_otel_with_pid_exporter(self(), :always_off)
      always_off_provider = Otel.provider_identity()
      assert is_pid(always_off_provider)
      refute always_off_provider == first_provider

      assert :second =
               Pipeline.with_batch_span("events.poller.status", [message_without_headers()], fn ->
                 :second
               end)

      # A stale tracer retains the first provider's always-on sampler and would
      # still export through the re-registered global simple processor.
      refute_receive {:span, span(name: "event_writer.process_batch")}, 200

      restart_otel_with_pid_exporter(self(), :always_on)
      always_on_provider = Otel.provider_identity()
      assert is_pid(always_on_provider)
      refute always_on_provider == always_off_provider

      assert :third =
               Pipeline.with_batch_span("events.poller.status", [message_without_headers()], fn ->
                 :third
               end)

      assert_receive {:span, span(name: "event_writer.process_batch")}, 1_000
    end
  end

  describe "dynamic tracer lifecycle" do
    test "uses a noop tracer while no provider is registered" do
      # Warm the SDK application cache so this detects accidental fallback to
      # the stale persistent_term tracer after the provider stops.
      assert {:otel_tracer_default, _config} = :opentelemetry.get_application_tracer(Pipeline)
      assert :ok = Application.stop(:opentelemetry)
      assert Otel.provider_identity() == nil

      assert {nil, {:otel_tracer_noop, []}} = Otel.tracer_snapshot(Pipeline, nil)
      assert {:otel_tracer_noop, []} = Otel.tracer_for_application(Pipeline, nil)

      assert :batch_done =
               Pipeline.with_batch_span(
                 "events.poller.status",
                 [message_without_headers()],
                 fn -> :batch_done end
               )

      refute_receive {:span, _span}, 200
    end

    test "retries once when the sampled provider exits during lookup" do
      current_provider = Otel.provider_identity()
      assert is_pid(current_provider)

      exiting_provider =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, {:get_tracer, _name, _version, _schema_url}} ->
              exit(:shutdown)
          end
        end)

      assert {^current_provider, {:otel_tracer_default, _config} = tracer} =
               Otel.tracer_snapshot(Pipeline, exiting_provider)

      assert Otel.provider_identity() == current_provider
      assert :ok = Otel.span_with_tracer(tracer, "provider.retry", %{}, fn -> :ok end)
      assert_receive {:span, span(name: "provider.retry")}, 1_000
    end
  end

  describe "Otel.span_with_tracer/4" do
    test "exports error status and an exception event before re-raising" do
      tracer = Otel.tracer_for_application(Pipeline)

      assert_raise RuntimeError, "boom", fn ->
        Otel.span_with_tracer(tracer, "manual.failure", %{kind: :internal}, fn ->
          raise "boom"
        end)
      end

      assert OpenTelemetry.Tracer.current_span_ctx() == :undefined

      assert_receive {:span, span(name: "manual.failure", status: span_status, events: events)},
                     1_000

      assert status(span_status, :code) == :error
      assert status(span_status, :message) == "boom"

      assert [exception_event] = :otel_events.list(events)
      assert event(exception_event, :name) == :exception

      exception_attributes =
        exception_event
        |> event(:attributes)
        |> :otel_attributes.map()

      assert exception_attributes[:"exception.type"] =~ "RuntimeError"
      assert exception_attributes[:"exception.stacktrace"] =~ "pipeline_batch_span_test.exs"
    end
  end

  defp restart_otel_with_pid_exporter(owner, sampler \\ :always_on) do
    Application.stop(:opentelemetry)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :processors, [{:otel_simple_processor, %{}}])
    Application.put_env(:opentelemetry, :sampler, sampler)
    {:ok, _} = Application.ensure_all_started(:opentelemetry)
    :otel_simple_processor.set_exporter(:otel_exporter_pid, owner)
  end
end
