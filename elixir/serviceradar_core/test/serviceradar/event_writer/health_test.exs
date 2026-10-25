defmodule ServiceRadar.EventWriter.HealthTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Health

  describe "status/0" do
    test "returns status map when EventWriter is disabled" do
      status = Health.status()

      assert is_map(status)
      assert Map.has_key?(status, :enabled)
      assert Map.has_key?(status, :running)
      assert Map.has_key?(status, :timestamp)
      assert %DateTime{} = status.timestamp
    end
  end

  describe "check/0" do
    test "returns :ok when EventWriter is disabled" do
      # By default, EventWriter is disabled
      assert Health.check() == :ok
    end
  end

  describe "healthy?/0" do
    test "returns true when EventWriter is disabled (disabled is healthy)" do
      assert Health.healthy?() == true
    end
  end

  describe "cluster_status/1" do
    test "omits this node when it does not host workers" do
      report = Health.cluster_status()

      refute Map.has_key?(report.nodes, node())

      if Node.list() == [] do
        assert report == %{healthy: true, nodes: %{}}
      end
    end

    test "a call that does not answer is unhealthy" do
      report = Health.cluster_status(0)

      assert report.healthy == false

      assert %{
               enabled: true,
               running: false,
               healthy: false,
               reason: {:error, {:unreachable, {:erpc, :timeout}}}
             } = report.nodes[node()]
    end
  end

  describe "cluster_status result mapping" do
    @down %{
      enabled: true,
      running: true,
      healthy: false,
      reason: {:error, {:producer_not_ready, :pipeline}}
    }
    @up %{enabled: true, running: true, healthy: true, reason: :ok}

    test "a nil status or an undefined node_status/0 is not a worker host" do
      missing = {:error, {:exception, :undef, [{Health, :node_status, [], []}]}}
      arity_zero = {:error, {:exception, :undef, [{Health, :node_status, 0, []}]}}

      report =
        Health.cluster_status_from([:web@a, :old@b, :old@c], [{:ok, nil}, missing, arity_zero])

      assert report == %{healthy: true, nodes: %{}}
    end

    test "any other call result is that node unreachable, and a down host keeps its reason" do
      inner_undef =
        {:error, {:exception, :undef, [{Missing, :fun, [], []}, {Health, :node_status, 0, []}]}}

      wrong_arity = {:error, {:exception, :undef, [{Health, :node_status, 1, []}]}}
      raised = {:error, {:exception, %RuntimeError{message: "down"}, []}}
      timed_out = {:error, {:erpc, :timeout}}
      died = {:exit, {:exception, {:signal, :killed}}}
      thrown = {:throw, :nope}

      report =
        Health.cluster_status_from(
          [:core@a, :core@b, :core@c, :core@d, :core@e, :core@f, :core@g, :core@h, :web@i],
          [
            {:ok, @up},
            {:ok, @down},
            inner_undef,
            wrong_arity,
            raised,
            timed_out,
            died,
            thrown,
            {:ok, nil}
          ]
        )

      assert report.healthy == false
      assert report.nodes[:core@a] == @up
      assert report.nodes[:core@b] == @down
      refute Map.has_key?(report.nodes, :web@i)
      assert unreachable?(report.nodes[:core@c], elem(inner_undef, 1))
      assert unreachable?(report.nodes[:core@d], elem(wrong_arity, 1))
      assert unreachable?(report.nodes[:core@e], elem(raised, 1))
      assert unreachable?(report.nodes[:core@f], elem(timed_out, 1))
      assert unreachable?(report.nodes[:core@g], died)
      assert unreachable?(report.nodes[:core@h], thrown)
    end
  end

  defp unreachable?(status, reason) do
    status == %{
      enabled: true,
      running: false,
      healthy: false,
      reason: {:error, {:unreachable, reason}}
    }
  end
end
