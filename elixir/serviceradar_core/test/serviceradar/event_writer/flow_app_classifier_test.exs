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

<<<<<<< HEAD
    atom_rules = Enum.map(rules, &atomize_rule/1)

    for %{"flow" => flow, "expected" => expected, "note" => note} <- cases do
      actual = FlowAppClassifier.classify(atomize_flow(flow), atom_rules)
=======
    for %{"flow" => flow, "expected" => expected, "note" => note} <- cases do
      actual = FlowAppClassifier.classify(flow, rules)
>>>>>>> 730b3c49f1
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

<<<<<<< HEAD
  test "uuid string ids tie-break deterministically without raising" do
    rules = [
      %{
        id: "018f9b2c-0000-7000-8000-000000000002",
        priority: 5,
        dst_port: 8080,
        app_label: "second"
      },
      %{
        id: "018f9b2c-0000-7000-8000-000000000001",
        priority: 5,
        dst_port: 8080,
        app_label: "first"
      }
    ]

    flow = %{partition: "default", protocol_num: 6, dst_port: 8080}

    assert FlowAppClassifier.classify(flow, rules) == "first"
  end

=======
>>>>>>> 730b3c49f1
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
<<<<<<< HEAD

  @rule_keys ~w(id partition priority protocol_num dst_port src_port src_cidr dst_cidr app_label)
  @flow_keys ~w(partition protocol_num dst_port src_port src_ip dst_ip)

  defp atomize_rule(rule) when is_map(rule) do
    Map.new(rule, fn {key, value} -> {atomize_key(key, @rule_keys), value} end)
  end

  defp atomize_flow(flow) when is_map(flow) do
    Map.new(flow, fn {key, value} -> {atomize_key(key, @flow_keys), value} end)
  end

  defp atomize_key(key, _known) when is_atom(key), do: key

  defp atomize_key(key, known) when is_binary(key) do
    if key in known, do: String.to_existing_atom(key), else: key
  end
=======
>>>>>>> 730b3c49f1
end
