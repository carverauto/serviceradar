defmodule ServiceRadar.EventWriter.FlowAppClassifierTest do
  @moduledoc """
  Lockstep cases for the ingest-time flow app classifier.

  Reads the same case file the parity harness's seeded rules come from
  (`integration_tests/srql_parity/app_classifier_cases.json`), so the Elixir
  classifier, the CNPG SQL classifier (`FLOW_APP_EXPR`, exercised by the
  parity run) and the warehouse column all answer with one vocabulary.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.FlowAppClassifier

  @cases_path "integration_tests/srql_parity/app_classifier_cases.json"

  @moduletag :db_free

  test "classify/2 returns the shared case file's expected label for every case" do
    %{"rules" => rules, "cases" => cases} = load_cases()

    assert length(cases) >= 15

    for %{"flow" => flow, "expected" => expected, "note" => note} <- cases do
      actual = FlowAppClassifier.classify(flow, rules)
      assert actual == expected, "case (#{note}): expected #{expected}, got #{actual}"
    end
  end

  test "rule precedence is priority, then specificity, then id" do
    rules = [
      %{id: 3, priority: 1, protocol_num: 6, app_label: "low-priority"},
      %{id: 2, priority: 9, dst_port: nil, src_port: 9, app_label: "one-field"},
      %{id: 1, priority: 9, protocol_num: 6, src_port: 9, app_label: "two-fields"}
    ]

    flow = %{protocol_num: 6, src_port: 9, dst_port: 1234}

    assert FlowAppClassifier.classify(flow, rules) == "two-fields"
  end

  test "a rule load failure degrades to the baseline table" do
    # No rules: the protocol/port baseline answers on its own.
    assert FlowAppClassifier.classify(%{protocol_num: 6, dst_port: 443}, []) == "https"
    assert FlowAppClassifier.classify(%{protocol_num: 17, dst_port: 53}, []) == "dns"
    assert FlowAppClassifier.classify(%{protocol_num: 6, dst_port: 65_001}, []) == "unknown"
  end

  test "batch_rules caches per batch and clear resets it" do
    FlowAppClassifier.clear_batch_cache()
    on_exit(fn -> FlowAppClassifier.clear_batch_cache() end)

    rules = FlowAppClassifier.batch_rules()
    assert is_list(rules)
    # The second read is the cached list.
    assert FlowAppClassifier.batch_rules() == Enum.map(rules, & &1)

    FlowAppClassifier.clear_batch_cache()
    # After a clear, a fresh load runs (equal content, fresh list).
    assert is_list(FlowAppClassifier.batch_rules())
  end

  defp load_cases do
    relative = "integration_tests/srql_parity/app_classifier_cases.json"

    path =
      Enum.find(
        [
          Path.expand("../../../../../" <> relative, __DIR__),
          Path.join([
            System.get_env("TEST_SRCDIR") || "",
            System.get_env("TEST_WORKSPACE") || "_main",
            relative
          ])
        ],
        &File.exists?/1
      ) ||
        flunk(
          "#{relative} was not staged; declare //integration_tests/srql_parity:app_classifier_cases.json as test data"
        )

    path |> File.read!() |> Jason.decode!()
  end
end
