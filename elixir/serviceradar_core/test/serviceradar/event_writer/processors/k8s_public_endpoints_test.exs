defmodule ServiceRadar.EventWriter.Processors.K8sPublicEndpointsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.K8sPublicEndpoints

  # `parse_message/1` is the pure half of this processor: decode, validate, normalize. The
  # DB-touching half is `process_batch/1`, which belongs to the integration tier. Testing
  # the pure half here is what makes the 300-odd lines of normalization actually covered.
  defp message(payload) do
    %{
      data: Jason.encode!(payload),
      metadata: %{subject: "inventory.k8s.public_endpoints"}
    }
  end

  defp snapshot(endpoint_overrides \\ %{}) do
    endpoint =
      Map.merge(
        %{
          "cluster_id" => "demo",
          "ip" => "23.138.124.7",
          "port" => 22,
          "protocol" => "tcp",
          "exposure_class" => "LoadBalancer",
          "namespace" => "envoy-gateway-system",
          "service_name" => "envoy-forgejo",
          "service_target_port" => 10_022,
          "observed_at" => "2026-08-05T16:59:00Z",
          "endpoint_targets" => [
            %{"ip" => "10.42.221.140", "port" => 10_022, "pod_name" => "envoy-pod"}
          ],
          "annotations" => %{"metallb.io/loadBalancerIPs" => "23.138.124.7"}
        },
        endpoint_overrides
      )

    %{
      "cluster_id" => "demo",
      "generated_at" => "2026-08-05T17:00:00Z",
      "endpoints" => [endpoint],
      "correlation_hints" => []
    }
  end

  test "parse_message builds endpoint rows from inventory snapshot" do
    assert %{cluster_id: "demo", snapshot_at: snapshot_at, endpoints: [row]} =
             K8sPublicEndpoints.parse_message(message(snapshot()))

    assert snapshot_at == ~U[2026-08-05 17:00:00Z]

    assert row.cluster_id == "demo"
    assert row.ip == "23.138.124.7"
    assert row.port == 22
    assert row.namespace == "envoy-gateway-system"
    assert row.service_name == "envoy-forgejo"
    # Protocol is upcased on the way in, so "tcp" and "TCP" cannot produce two rows for the
    # same listener -- endpoint_key is derived from it.
    assert row.protocol == "TCP"
    assert is_binary(row.endpoint_key) and row.endpoint_key != ""
    # The endpoint carries its own observed_at, and it wins over the snapshot's timestamp --
    # one snapshot can report endpoints seen at different moments.
    assert row.observed_at == ~U[2026-08-05 16:59:00Z]
    refute row.observed_at == snapshot_at
    # Rows are stamped with the snapshot they arrived in, which is what soft-deletion of
    # endpoints missing from a later snapshot compares against.
    assert row.snapshot_at == snapshot_at
  end

  test "parse_message falls back to now when an endpoint has no observed_at" do
    before = DateTime.truncate(DateTime.utc_now(), :second)

    %{endpoints: [row]} =
      K8sPublicEndpoints.parse_message(message(snapshot(%{"observed_at" => nil})))

    # Worth pinning because it is surprising: a missing observed_at does NOT inherit
    # snapshot_at, it becomes wall-clock now. A replayed or backfilled snapshot therefore
    # looks freshly observed. Asserting it keeps the behaviour deliberate rather than
    # accidental -- change the assertion if the fallback ever changes.
    assert DateTime.compare(row.observed_at, before) in [:eq, :gt]
    assert row.snapshot_at == ~U[2026-08-05 17:00:00Z]
  end

  test "parse_message defaults a missing protocol to TCP and keeps endpoint_key stable" do
    %{endpoints: [defaulted]} =
      K8sPublicEndpoints.parse_message(message(snapshot(%{"protocol" => nil})))

    %{endpoints: [explicit]} =
      K8sPublicEndpoints.parse_message(message(snapshot(%{"protocol" => "TCP"})))

    assert defaulted.protocol == "TCP"
    assert defaulted.endpoint_key == explicit.endpoint_key
  end

  test "parse_message rejects a snapshot with no cluster_id" do
    payload = Map.delete(snapshot(), "cluster_id")
    assert K8sPublicEndpoints.parse_message(message(payload)) == nil
  end

  test "parse_message rejects data that is not JSON" do
    assert K8sPublicEndpoints.parse_message(%{data: "not json", metadata: %{}}) == nil
  end

  test "implements the EventWriter processor behaviour" do
    # Code.ensure_loaded! first: function_exported?/3 answers from the module's loaded
    # export table and returns false for a module that simply has not been loaded yet, so
    # asserting on it directly passes or fails on load order rather than on the module.
    Code.ensure_loaded!(K8sPublicEndpoints)

    assert function_exported?(K8sPublicEndpoints, :process_batch, 1)
    assert function_exported?(K8sPublicEndpoints, :parse_message, 1)
    assert function_exported?(K8sPublicEndpoints, :table_name, 0)
    assert K8sPublicEndpoints.table_name() == "public_endpoints_current"
  end
end
