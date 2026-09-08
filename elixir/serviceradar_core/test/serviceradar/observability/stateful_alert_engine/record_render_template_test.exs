defmodule ServiceRadar.Observability.StatefulAlertEngine.RecordRenderTemplateTest do
  @moduledoc """
  A rule names its subject in the alert title through `event["message"]`, not
  through `group_by`.

  `build_group/2` renders the group key an open incident is matched by, and
  `StateMachine.recover_event/3` looks that key up verbatim. Putting a mutable
  label such as `node.role` in `group_by` is therefore how the recovery event
  stops matching: relabel a node while it is NotReady and the clear computes a
  different key, the lookup misses, and the incident stays open. Rendering the
  same value into the message instead keeps the identity stable while the page
  still reads like a sentence, so both halves are pinned here.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.StatefulAlertEngine.Record

  # `LogPromotion.build_event/2` emits no `:attributes` key; the source log's
  # attributes arrive under `unmapped.log_attributes`, which is the source
  # `Record.group_sources/1` reads for a `signal: :event` rule.
  defp node_event(role) do
    %{
      unmapped: %{
        log_attributes: %{
          "event_type" => "node.not_ready",
          "cluster_id" => "cluster-a",
          "node" => "node-worker-1.example.com",
          "node.role" => role
        }
      }
    }
  end

  test "renders the seeded node rule's message from the triggering record" do
    template = "Kubernetes {node.role} node {node} is NotReady in cluster {cluster_id}"

    assert Record.render_template(template, node_event("worker")) ==
             "Kubernetes worker node node-worker-1.example.com is NotReady in cluster cluster-a"

    assert Record.render_template(template, node_event("control-plane")) ==
             "Kubernetes control-plane node node-worker-1.example.com is NotReady in cluster cluster-a"
  end

  test "a role change does not change the incident identity it renders alongside" do
    keys = ["cluster_id", "node"]

    assert {:ok, opened_key, _} = Record.build_group(keys, node_event("worker"))
    assert {:ok, recovered_key, _} = Record.build_group(keys, node_event("control-plane"))

    assert opened_key == recovered_key
    assert opened_key == "cluster_id=cluster-a|node=node-worker-1.example.com"
  end

  test "an unresolvable placeholder is left as written rather than blanked" do
    assert Record.render_template("node {node} rack {rack}", node_event("worker")) ==
             "node node-worker-1.example.com rack {rack}"
  end

  test "a template with no placeholders is returned unchanged" do
    assert Record.render_template("Kubernetes node is NotReady", node_event("worker")) ==
             "Kubernetes node is NotReady"
  end
end
