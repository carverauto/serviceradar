defmodule ServiceRadar.Automation.Ansible.AwxInventoryObservationFenceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AwxInventoryObservationFence, as: Fence

  test "the observation watermark orders retries independently of membership revisions" do
    aggregate = aggregate()
    current = %{source_generation: 10, observation_digest: Fence.digest(aggregate)}

    assert {:ok, :initial} = Fence.disposition(aggregate, nil)
    assert {:ok, :replay} = Fence.disposition(aggregate, current)
    assert {:ok, :advance} = Fence.disposition(%{aggregate | source_generation: 11}, current)

    assert {:error, {:stale_awx_membership_generation, _, 9, 10}} =
             Fence.disposition(%{aggregate | source_generation: 9}, current)
  end

  test "same-generation authority, completeness, and provenance conflicts are rejected" do
    aggregate = aggregate()
    current = %{source_generation: 10, observation_digest: Fence.digest(aggregate)}

    changes = [
      %{aggregate | complete: false},
      %{aggregate | hosts: []},
      %{aggregate | source_fingerprint: "sha256:" <> String.duplicate("2", 64)},
      %{aggregate | collection_id: "different-observation"},
      %{aggregate | observed_at: DateTime.add(aggregate.observed_at, 1, :second)},
      put_in(aggregate, [:hosts, Access.at(0), :ansible_host], "192.0.2.20")
    ]

    for changed <- changes do
      assert {:error, {:conflicting_awx_inventory_observation, _, 10}} =
               Fence.disposition(changed, current)
    end
  end

  test "host ordering is canonical, including empty partial and complete snapshots" do
    aggregate = aggregate()
    second = %{hd(aggregate.hosts) | inventory_id: 8, awx_host_id: 20}
    first = %{aggregate | hosts: aggregate.hosts ++ [second]}
    assert Fence.digest(first) == Fence.digest(%{first | hosts: Enum.reverse(first.hosts)})

    empty = %{aggregate | hosts: []}
    refute Fence.digest(empty) == Fence.digest(%{empty | complete: false})
  end

  defp aggregate do
    %{
      controller_id: "11111111-2222-4333-8444-555555555555",
      source_generation: 10,
      source_fingerprint: "sha256:" <> String.duplicate("1", 64),
      collection_id: "synthetic-observation-10",
      observed_at: ~U[2031-01-02 03:04:05.000000Z],
      complete: true,
      hosts: [
        %{
          inventory_id: 7,
          awx_host_id: 10,
          host_name: "host01.example.com",
          ansible_host: "192.0.2.10",
          enabled: true,
          metadata: %{"inventory_name" => "Example inventory", "collection_source" => "awx"}
        }
      ]
    }
  end
end
