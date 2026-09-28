defmodule ServiceRadar.TestSupport.ScriptedStatefulAlertEngine do
  @moduledoc """
  Stands in for `ServiceRadar.Observability.StatefulAlertEngine` through the
  `:stateful_alert_engine` config. Each call sends `{:evaluated, events}` to
  the test process and answers with the next scripted reply (`:ok` once the
  script is exhausted).

  Not for `async: true` tests: the config is application-wide.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @keys [:stateful_alert_engine, :scripted_engine_replies, :scripted_engine_test_pid]

  @doc "Routes evaluation to this engine for the calling test, with `replies` scripted."
  def use_in_test(replies \\ []) when is_list(replies) do
    previous = Map.new(@keys, &{&1, Application.get_env(:serviceradar_core, &1)})

    Application.put_env(:serviceradar_core, :stateful_alert_engine, __MODULE__)
    Application.put_env(:serviceradar_core, :scripted_engine_replies, replies)
    Application.put_env(:serviceradar_core, :scripted_engine_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:serviceradar_core, key)
        {key, value} -> Application.put_env(:serviceradar_core, key, value)
      end)
    end)
  end

  def evaluate_events(events) do
    test_pid = Application.fetch_env!(:serviceradar_core, :scripted_engine_test_pid)
    send(test_pid, {:evaluated, events})

    case Application.get_env(:serviceradar_core, :scripted_engine_replies, []) do
      [reply | rest] ->
        Application.put_env(:serviceradar_core, :scripted_engine_replies, rest)
        reply

      [] ->
        :ok
    end
  end
end
