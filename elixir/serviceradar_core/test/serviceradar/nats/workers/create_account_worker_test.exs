defmodule ServiceRadar.NATS.Workers.CreateAccountWorkerTest do
  @moduledoc """
  Tests for the CreateAccountWorker Oban job.

  Tests the async NATS account creation flow including:
  - Job creation and configuration
  - Worker module configuration
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.NATS.Workers.CreateAccountWorker

  describe "new/2 job creation" do
    test "creates valid job changeset with tenant_id" do
      tenant_id = Ash.UUID.generate()

      changeset = CreateAccountWorker.new(%{"tenant_id" => tenant_id})

      assert changeset.valid?
      assert changeset.changes.args == %{"tenant_id" => tenant_id}
    end

    test "job uses nats_accounts queue" do
      tenant_id = Ash.UUID.generate()

      changeset = CreateAccountWorker.new(%{"tenant_id" => tenant_id})

      # Queue can be either atom or string depending on Oban version
      assert changeset.changes.queue in [:nats_accounts, "nats_accounts"]
    end

    test "job has max_attempts of 5" do
      tenant_id = Ash.UUID.generate()

      changeset = CreateAccountWorker.new(%{"tenant_id" => tenant_id})

      assert changeset.changes.max_attempts == 5
    end

    test "creates job with scheduled_at option" do
      tenant_id = Ash.UUID.generate()
      scheduled = DateTime.add(DateTime.utc_now(), 60, :second)

      changeset = CreateAccountWorker.new(%{"tenant_id" => tenant_id}, scheduled_at: scheduled)

      assert changeset.valid?
      assert changeset.changes.scheduled_at == scheduled
    end

    test "creates job with priority option" do
      tenant_id = Ash.UUID.generate()

      changeset = CreateAccountWorker.new(%{"tenant_id" => tenant_id}, priority: 1)

      assert changeset.valid?
      assert changeset.changes.priority == 1
    end

    test "job has uniqueness configured" do
      tenant_id = Ash.UUID.generate()

      changeset = CreateAccountWorker.new(%{"tenant_id" => tenant_id})

      # Worker is configured with unique: [period: 60, keys: [:tenant_id]]
      assert changeset.changes.unique != nil
    end
  end

  describe "job args structure" do
    test "args contain tenant_id as string key" do
      tenant_id = Ash.UUID.generate()

      changeset = CreateAccountWorker.new(%{"tenant_id" => tenant_id})

      # Oban serializes args to JSON, so keys should be strings
      assert Map.has_key?(changeset.changes.args, "tenant_id")
      assert changeset.changes.args["tenant_id"] == tenant_id
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
  end
end
