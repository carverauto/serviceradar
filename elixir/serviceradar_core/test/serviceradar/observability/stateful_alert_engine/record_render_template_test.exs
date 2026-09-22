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

  test "a structured source device does not mask the canonical device identity" do
    record = %{
      device: %{"uid" => "synthetic-device"},
      unmapped: %{"device" => %{"uid" => "synthetic-device"}}
    }

    assert Record.build_group(["device"], record) ==
             {:ok, "device=synthetic-device", %{"device" => "synthetic-device"}}

    assert Record.render_template("Device {device}", record) == "Device synthetic-device"
  end

  test "structured group values are unresolved instead of crashing evaluation" do
    for value <- [%{"uid" => "synthetic-device"}, ["synthetic-device"]] do
      record = %{attributes: %{"subject" => value}}
      assert Record.build_group(["subject"], record) == :error
      assert Record.render_template("Subject {subject}", record) == "Subject {subject}"
    end
  end

  test "source lookup skips objects and preserves scalar values including false" do
    record = %{
      attributes: %{"subject" => %{"name" => "ignored"}},
      resource_attributes: %{"subject" => "synthetic-subject", "active" => false, "index" => 7}
    }

    assert Record.build_group(["subject", "active", "index"], record) ==
             {:ok, "subject=synthetic-subject|active=false|index=7",
              %{"subject" => "synthetic-subject", "active" => "false", "index" => "7"}}
  end

  test "log and event source references normalize database UUIDs before JSON encoding" do
    uuid = "00000000-0000-4000-8000-0000000000dd"

    for id <- [Ecto.UUID.dump!(uuid), uuid] do
      event = Record.source_record_details(%{id: id, time: ~U[2026-01-01 00:00:00Z]})
      log = Record.source_record_details(%{id: id, timestamp: ~U[2026-01-01 00:00:00Z]})
      assert Jason.decode!(Jason.encode!(event))["source_event_id"] == uuid
      assert Jason.decode!(Jason.encode!(log))["source_log_id"] == uuid
    end
  end

  test "source references preserve existing textual and absent identifiers" do
    for id <- ["synthetic-event", nil] do
      assert Record.event_source_details(%{id: id})["source_event_id"] == to_string(id)
      assert Record.log_source_details(%{id: id})["source_log_id"] == to_string(id)
    end
  end
end
