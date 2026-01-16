defmodule ServiceRadar.NATS.Workers.CreateAccountWorkerTest do
  @moduledoc """
  Tests for the CreateAccountWorker Oban job.

  Tests the async NATS account creation flow including:
  - Job creation and configuration
  - Worker module configuration
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.NATS.Workers.CreateAccountWorker

  describe "new/1 job creation" do
    test "creates valid job changeset" do
      changeset = CreateAccountWorker.new(%{})

      assert changeset.valid?
      assert changeset.changes.args == %{}
    end

    test "job uses nats_accounts queue" do
      changeset = CreateAccountWorker.new(%{})

      # Queue can be either atom or string depending on Oban version
      assert changeset.changes.queue in [:nats_accounts, "nats_accounts"]
    end

    test "job has max_attempts of 5" do
      changeset = CreateAccountWorker.new(%{})

      assert changeset.changes.max_attempts == 5
    end

    test "creates job with scheduled_at option" do
      scheduled = DateTime.add(DateTime.utc_now(), 60, :second)

      changeset = CreateAccountWorker.new(%{}, scheduled_at: scheduled)

      assert changeset.valid?
      assert changeset.changes.scheduled_at == scheduled
    end

    test "creates job with priority option" do
      changeset = CreateAccountWorker.new(%{}, priority: 1)

      assert changeset.valid?
      assert changeset.changes.priority == 1
    end
  end

  describe "worker behavior" do
    test "implements Oban.Worker behaviour" do
      # Verify the module uses Oban.Worker
      behaviours = CreateAccountWorker.__info__(:attributes)[:behaviour] || []
      assert Oban.Worker in behaviours
    end

    test "defines perform function" do
      # Check if the perform callback is defined
      functions = CreateAccountWorker.__info__(:functions)
      assert {:perform, 1} in functions
    end

    test "defines new function for job creation" do
      # new/1 and new/2 are defined by Oban.Worker
      functions = CreateAccountWorker.__info__(:functions)
      function_names = Enum.map(functions, fn {name, _arity} -> name end)
      assert :new in function_names
    end

    test "defines enqueue function" do
      functions = CreateAccountWorker.__info__(:functions)
      function_names = Enum.map(functions, fn {name, _arity} -> name end)
      assert :enqueue in function_names
    end
  end
end
