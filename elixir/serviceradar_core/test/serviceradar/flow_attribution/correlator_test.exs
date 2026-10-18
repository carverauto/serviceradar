defmodule ServiceRadar.FlowAttribution.CorrelatorTest do
  # Mutates the correlator interval in the application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.FlowAttribution.Correlator

  @moduletag :db_free

  @interval_ms 20

  setup do
    previous = Application.fetch_env(:serviceradar_core, :flow_attribution_correlator_interval_ms)

    Application.put_env(
      :serviceradar_core,
      :flow_attribution_correlator_interval_ms,
      @interval_ms
    )

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:serviceradar_core, :flow_attribution_correlator_interval_ms, value)

        :error ->
          Application.delete_env(:serviceradar_core, :flow_attribution_correlator_interval_ms)
      end
    end)
  end

  test "a failing pass backs off and is reported once per failure streak" do
    parent = self()
    outcomes = start_supervised!({Agent, fn -> [:fail, :fail, :fail, :ok, :fail] end})

    warehouse = fn _sql ->
      outcome =
        Agent.get_and_update(outcomes, fn
          [next | rest] -> {next, rest}
          [] -> {:ok, []}
        end)

      send(parent, {:pass, outcome, System.monotonic_time(:millisecond)})

      case outcome do
        :fail -> {:error, {:starrocks_mysql, "memory limit exceeded"}}
        :ok -> {:ok, %{columns: [], rows: []}}
      end
    end

    log =
      capture_log(fn ->
        correlator =
          start_supervised!(
            {Correlator,
             name: :flow_attribution_correlator_test,
             pass_opts: [
               enabled: true,
               repo_query: fn _sql, _params -> {:ok, %{rows: []}} end,
               query: warehouse
             ],
             report_opts: [
               query: fn _sql -> {:error, :unavailable} end,
               publish: fn _subject, _body -> :ok end
             ]}
          )

        send(correlator, :correlate)

        passes = for _ <- 1..5, do: assert_receive({:pass, _outcome, _at}, 2_000)
        [t1, t2, t3, t4, _t5] = Enum.map(passes, fn {:pass, _outcome, at} -> at end)

        # Each consecutive failure doubles the wait, starting from twice the
        # interval.
        assert t2 - t1 >= 2 * @interval_ms
        assert t3 - t2 >= 4 * @interval_ms
        assert t4 - t3 >= 8 * @interval_ms

        # Lets the fifth pass finish logging before the capture ends.
        :sys.get_state(correlator)
      end)

    # Three failures in a row are one streak; the failure after the recovery
    # starts a second, so the success cleared the failing state.
    assert length(Regex.scan(~r/correlate failed/, log)) == 2
  end
end
