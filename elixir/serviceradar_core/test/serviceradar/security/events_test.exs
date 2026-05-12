defmodule ServiceRadar.Security.EventsTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Security.Events

  setup do
    # Drain anything in flight from earlier tests so we start clean.
    _ = Events.flush()
    :ok
  end

  describe "record/1" do
    test "accepts a minimal event and returns :ok immediately" do
      assert :ok = Events.record(%{kind: :rate_limit_denied})
    end

    test "is non-blocking even when the recorder is busy" do
      # Fire a burst — the cast queue should accept them quickly.
      for _ <- 1..50 do
        assert :ok = Events.record(%{kind: :rate_limit_denied, ip: "203.0.113.1"})
      end
    end
  end

  describe "overflow" do
    @tag :capture_log
    test "drops events once the bounded queue is full and increments telemetry" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:serviceradar, :security, :events, :dropped],
        fn _event, measurements, _meta, _config ->
          send(parent, {ref, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      # Block the recorder by holding flush via a synchronous call from
      # a separate process — the cast queue then fills up. Easier: send
      # more events than max_queue between flushes.
      max = Events.__default_max_queue__()

      # Pause the recorder by suspending it briefly so the queue fills.
      :sys.suspend(Events)

      try do
        for _ <- 1..(max + 5) do
          Events.record(%{kind: :rate_limit_denied})
        end
      after
        :sys.resume(Events)
      end

      # At least 1 drop event should have been recorded.
      assert_receive {^ref, %{count: 1}}, 500
    end
  end

  describe "kinds/0 and severities/0" do
    test "expose the supported kinds and severities for callers/UI" do
      kinds = ServiceRadar.Security.SecurityEvent.kinds()
      severities = ServiceRadar.Security.SecurityEvent.severities()

      assert :rate_limit_denied in kinds
      assert :csp_violation in kinds
      assert :signature_invalid in kinds
      assert severities == [:info, :warning, :critical]
    end
  end
end
