defmodule ServiceRadarAgentGateway.K8sPublicEndpointsPublisherTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.K8sPublicEndpointsPublisher

  defmodule FakeNATS do
    @moduledoc false
    def publish(subject, payload, opts) do
      send(self(), {:published, subject, payload, opts})
      :ok
    end
  end

  defmodule FailingNATS do
    @moduledoc false
    def publish(_subject, _payload, _opts), do: {:error, :nats_down}
  end

  setup do
    previous = Application.get_env(:serviceradar_agent_gateway, :k8s_public_endpoints_publisher, [])

    on_exit(fn ->
      Application.put_env(:serviceradar_agent_gateway, :k8s_public_endpoints_publisher, previous)
    end)

    :ok
  end

  test "ignores unrelated statuses" do
    assert :not_k8s_public_endpoints =
             K8sPublicEndpointsPublisher.publish(%{
               service_type: "sweep",
               agent_id: "a1",
               message: "{}"
             })
  end

  test "publishes inventory JSON to JetStream subject with agent headers" do
    Application.put_env(:serviceradar_agent_gateway, :k8s_public_endpoints_publisher,
      enabled: true,
      connection: FakeNATS,
      subject: "inventory.k8s.public_endpoints"
    )

    payload = ~s({"cluster_id":"acme","endpoints":[]})

    assert :ok =
             K8sPublicEndpointsPublisher.publish(%{
               service_type: "k8s_public_endpoints",
               service_name: "k8s-public-endpoints",
               agent_id: "edge-1",
               partition: "prod",
               gateway_id: "gw-1",
               message: payload
             })

    assert_receive {:published, "inventory.k8s.public_endpoints", ^payload, opts}
    headers = Keyword.get(opts, :headers, [])
    assert {"Sr-Agent-Id", "edge-1"} in headers
    assert {"Sr-Partition", "prod"} in headers
    assert {"Sr-Service-Type", "k8s_public_endpoints"} in headers
  end

  test "rejects oversized payloads" do
    Application.put_env(:serviceradar_agent_gateway, :k8s_public_endpoints_publisher,
      enabled: true,
      connection: FakeNATS
    )

    huge = :binary.copy("x", 4 * 1024 * 1024 + 1)

    assert {:error, :inventory_payload_too_large} =
             K8sPublicEndpointsPublisher.publish(%{
               service_type: "k8s_public_endpoints",
               agent_id: "a1",
               message: huge
             })

    refute_receive {:published, _subject, _payload, _opts}
  end

  test "surfaces NATS publish failures" do
    Application.put_env(:serviceradar_agent_gateway, :k8s_public_endpoints_publisher,
      enabled: true,
      connection: FailingNATS
    )

    assert {:error, :nats_down} =
             K8sPublicEndpointsPublisher.publish(%{
               service_type: "k8s_public_endpoints",
               agent_id: "a1",
               message: "{}"
             })
  end
end
