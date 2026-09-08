defmodule ServiceRadar.Observability.Zen.NormalizerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.Zen.Normalizer
  alias ServiceRadar.Observability.Zen.NormalizerTest.RuleLoader

  setup do
    old_config = Application.get_env(:serviceradar_core, Normalizer, [])

    start_supervised!(%{
      id: __MODULE__.RuleState,
      start:
        {Agent, :start_link,
         [
           fn -> %{result: {:ok, [{"custom", ~s({"nodes":[]})}]}, calls: []} end,
           [name: __MODULE__.RuleState]
         ]}
    })

    Application.put_env(:serviceradar_core, Normalizer, runtime_rule_loader: RuleLoader)
    Normalizer.invalidate_all()

    on_exit(fn ->
      Application.put_env(:serviceradar_core, Normalizer, old_config)
      Normalizer.invalidate_all()
    end)

    :ok
  end

  test "runtime rules are authoritative and cached per normalized subject" do
    assert {:ok, [{"custom", ~s({"nodes":[]})}]} = Normalizer.rules_for_subject("logs.syslog")

    assert {:ok, [{"custom", ~s({"nodes":[]})}]} =
             Normalizer.rules_for_subject("logs.syslog.processed")

    assert calls() == ["logs.syslog"]

    Normalizer.invalidate_subject("logs.syslog")

    assert {:ok, [{"custom", ~s({"nodes":[]})}]} = Normalizer.rules_for_subject("logs.syslog")
    assert calls() == ["logs.syslog", "logs.syslog"]
  end

  test "empty runtime rule sets do not fall back to bundled defaults" do
    set_loader_result({:ok, []})

    assert {:ok, []} = Normalizer.rules_for_subject("logs.syslog")
  end

  test "runtime rule loader errors fall back to bundled rules" do
    set_loader_result({:error, :repo_unavailable})

    assert {:ok, [{"passthrough", _rule_json}]} = Normalizer.rules_for_subject("logs.otel")
  end

  defmodule RuleLoader do
    @moduledoc false
    @state ServiceRadar.Observability.Zen.NormalizerTest.RuleState

    def load_rules(subject) do
      Agent.get_and_update(@state, fn state ->
        {state.result, %{state | calls: state.calls ++ [subject]}}
      end)
    end
  end

  defp set_loader_result(result) do
    Agent.update(__MODULE__.RuleState, &%{&1 | result: result, calls: []})
  end

  defp calls do
    Agent.get(__MODULE__.RuleState, & &1.calls)
  end
end
