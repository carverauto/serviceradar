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

  test "a payload is superseded only when every aggregate is older than its recorded generation" do
    first = {:stale_awx_membership_generation, "11111111-2222-4333-8444-555555555555", 9, 10}
    second = {:stale_awx_membership_generation, "66666666-7777-4888-8999-aaaaaaaaaaaa", 4, 7}

    assert :ok = Fence.admission([{:ok, :advance}, {:ok, :replay}])
    assert {:superseded, [^first, ^second]} = Fence.admission([{:error, first}, {:error, second}])

    # Beside an aggregate that would be applied, a superseded one stays a failure:
    # acknowledging the payload would drop the other aggregate unapplied.
    assert {:error, ^first} = Fence.admission([{:ok, :advance}, {:error, first}])
  end

  test "same-generation authority, completeness, and provenance conflicts are rejected" do
    aggregate = aggregate()
    current = %{source_generation: 10, observation_digest: Fence.digest(aggregate)}

    changes = [
      %{aggregate | complete: false},
      %{aggregate | hosts: []},
      %{aggregate | source_fingerprint: "sha256:" <> String.duplicate("2", 64)},
      %{aggregate | collection_id: "different-observation"},
      %{aggregate | observed_at: DateTime.shift(aggregate.observed_at, second: 1)},
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

  test "already-superseded observations short-circuit before opening a transaction or waiting on the controller advisory lock" do
    stale = %{aggregate() | source_generation: 9}

    recorded = %{
      source_generation: 20,
      observation_digest: "sha256:" <> String.duplicate("9", 64)
    }

    assert {:ok,
            {:superseded,
             [{:stale_awx_membership_generation, "11111111-2222-4333-8444-555555555555", 9, 20}]}} =
             Fence.with_locks(
               [stale],
               fn -> flunk("superseded observation must not execute callback") end,
               read: fn "11111111-2222-4333-8444-555555555555" -> {:ok, recorded} end,
               lock: fn _controller_id ->
                 flunk(
                   "already-superseded observation must not block on controller advisory lock"
                 )
               end,
               transaction: fn _tx_fun ->
                 flunk("already-superseded observation must not open lock transaction")
               end
             )

    # A non-superseded aggregate must still acquire the controller advisory lock inside the transaction.
    fresh = %{aggregate() | source_generation: 21}
    parent = self()

    assert {:ok, :applied} =
             Fence.with_locks(
               [fresh],
               fn -> {:ok, :applied} end,
               read: fn "11111111-2222-4333-8444-555555555555" -> {:ok, recorded} end,
               lock: fn controller_id ->
                 send(parent, {:locked, controller_id})
                 :ok
               end,
               transaction: fn tx_fun -> {:ok, tx_fun.()} end
             )

    assert_received {:locked, "11111111-2222-4333-8444-555555555555"}

    # Mixed superseded + fresh aggregates must NOT short-circuit as superseded:
    # they must enter the locked transaction and reject the mixed batch.
    second_controller = "66666666-7777-4888-8999-aaaaaaaaaaaa"
    mixed_fresh = %{aggregate() | controller_id: second_controller, source_generation: 21}

    assert {:error,
            {:stale_awx_membership_generation, "11111111-2222-4333-8444-555555555555", 9, 20}} =
             Fence.with_locks(
               [mixed_fresh, stale],
               fn -> flunk("mixed superseded batch must not execute callback") end,
               read: fn
                 "11111111-2222-4333-8444-555555555555" -> {:ok, recorded}
                 ^second_controller -> {:ok, recorded}
               end,
               lock: fn controller_id ->
                 send(parent, {:mixed_locked, controller_id})
                 :ok
               end,
               rollback: fn reason -> throw({:rolled_back, reason}) end,
               transaction: fn tx_fun ->
                 try do
                   {:ok, tx_fun.()}
                 catch
                   {:rolled_back, reason} -> {:error, reason}
                 end
               end
             )

    assert_received {:mixed_locked, "11111111-2222-4333-8444-555555555555"}
    assert_received {:mixed_locked, ^second_controller}
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
