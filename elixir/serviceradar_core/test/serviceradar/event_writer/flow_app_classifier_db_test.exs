defmodule ServiceRadar.EventWriter.FlowAppClassifierDbTest do
  @moduledoc """
  Operator classification rules loaded from CNPG reach the ingest classifier.

  The classification logic itself is covered without a database in
  `flow_app_classifier_test.exs`; this module owns the rule load, which once
  failed on every batch and silently degraded classification to the baseline.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.FlowAppClassifier
  alias ServiceRadar.Observability.NetflowAppClassificationRule

  defp create_rule!(attrs) do
    NetflowAppClassificationRule
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: SystemActor.system(:flow_app_classifier_db_test))
  end

  test "enabled rules override the baseline and disabled rules are ignored" do
    suffix = System.unique_integer([:positive])
    enabled_label = "enabled-app-#{suffix}"
    disabled_label = "disabled-app-#{suffix}"

    create_rule!(%{
      priority: 1_000_000,
      protocol_num: 6,
      dst_port: 443,
      dst_cidr: "192.0.2.0/24",
      app_label: enabled_label
    })

    create_rule!(%{
      enabled: false,
      priority: 1_000_000,
      protocol_num: 6,
      dst_port: 22,
      dst_cidr: "192.0.2.0/24",
      app_label: disabled_label
    })

    rules = FlowAppClassifier.batch_rules()
    labels = Enum.map(rules, & &1.app_label)

    assert enabled_label in labels
    refute disabled_label in labels

    https_flow = %{protocol_num: 6, dst_port: 443, dst_ip: "192.0.2.10"}
    ssh_flow = %{protocol_num: 6, dst_port: 22, dst_ip: "192.0.2.10"}

    assert FlowAppClassifier.classify(https_flow, rules) == enabled_label
    assert FlowAppClassifier.classify(ssh_flow, rules) == "ssh"
  end
end
