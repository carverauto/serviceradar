defmodule ServiceRadar.Edge.Workers.ProvisionAgentWorkerTest do
  @moduledoc """
  ExUnit coverage for `ProvisionAgentWorker.perform/1`.

  This file covers Pass 15 / Pass 16 task §20.16 (B-5 sub-issue 4): every
  `:discard` branch of `perform/1`.

  ## Scope

  Plain-`perform/1` unit tests cover every branch that resolves before the
  worker reaches `ServiceRadar.NATS.AccountClient.generate_user_credentials/5`:

    * `:package_not_found`
    * `:not_agent_package`
    * `:invalid_agent_id`
    * `:nats_not_configured`
    * `:account_seed_not_found`

  The remaining branches (`{:grpc_error, _}`, `:not_connected`, catch-all
  `{:error, _}`) require either a live datasvc gRPC channel or an injection
  seam in `mint_credentials/3` that the worker source does not currently
  expose. Those are deferred per the recon brief and tracked back to
  Pass 15 — adding them needs either (a) a `:account_client` keyword
  option on `mint_credentials/3`, mirroring the `:awx_client` pattern in
  `controller_health_worker.ex`, or (b) datasvc-up integration tests.

  ## Why no `use Oban.Testing`

  The repo-wide convention (see e.g.
  `test/serviceradar/jobs/prune_stale_agents_worker_test.exs` and
  `test/serviceradar/automation/ansible/controller_health_worker_test.exs`)
  is to invoke the worker module's `perform/1` directly with a hand-rolled
  `%Oban.Job{}`. That keeps these tests free of Oban repo round-trips
  while still exercising the exact code path Oban would execute. The
  `Oban` instance is, however, run in `testing: :manual` mode (see
  `config/test.exs`) so that resource after-actions which call
  `ProvisionAgentWorker.enqueue/1` (e.g.
  `ServiceRadar.Edge.OnboardingPackage`'s `:create` action when
  `component_type == :agent`) do not crash.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Edge.Workers.ProvisionAgentWorker
  alias ServiceRadar.Repo

  @moduletag :database

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    # Each test gets its own sandboxed connection so DB writes are rolled
    # back at the end of the test.
    :ok = Sandbox.checkout(Repo)

    prior_account_name = Application.get_env(:serviceradar, :nats_account_name)
    prior_account_seed = Application.get_env(:serviceradar, :nats_account_seed)

    on_exit(fn ->
      restore_env(:nats_account_name, prior_account_name)
      restore_env(:nats_account_seed, prior_account_seed)
    end)

    %{
      actor: SystemActor.system(:test),
      unique_id: :erlang.unique_integer([:positive])
    }
  end

  # --- :package_not_found ---------------------------------------------------

  describe "perform/1 :package_not_found branch" do
    test "discards when the referenced OnboardingPackage does not exist" do
      job = build_job(Ash.UUID.generate())

      assert {:discard, :package_not_found} = ProvisionAgentWorker.perform(job)
    end
  end

  # --- :not_agent_package ---------------------------------------------------

  describe "perform/1 :not_agent_package branch" do
    test "discards when the package's component_type is not :agent", %{
      actor: actor,
      unique_id: u
    } do
      pkg = create_gateway_package!(actor, u)

      assert {:discard, :not_agent_package} =
               ProvisionAgentWorker.perform(build_job(pkg.id))
    end
  end

  # --- :invalid_agent_id ----------------------------------------------------

  describe "perform/1 :invalid_agent_id branch" do
    test "discards when component_id contains chars unsafe as a NATS subject token", %{
      actor: actor,
      unique_id: u
    } do
      pkg = create_gateway_package!(actor, u)

      # Mutate via raw SQL so we bypass the `:create` after-action that
      # enqueues ProvisionAgentWorker whenever component_type == :agent.
      # `bad.id.with.dots` has '.' which AgentFlowCollectorPermissions
      # rejects in `safe_subject_token?/1`.
      force_agent_component!(pkg.id, "bad.id.with.dots")

      assert {:discard, :invalid_agent_id} =
               ProvisionAgentWorker.perform(build_job(pkg.id))
    end

    test "discards when component_id is empty", %{actor: actor, unique_id: u} do
      pkg = create_gateway_package!(actor, u)
      force_agent_component!(pkg.id, "")

      assert {:discard, :invalid_agent_id} =
               ProvisionAgentWorker.perform(build_job(pkg.id))
    end
  end

  # --- :nats_not_configured -------------------------------------------------

  describe "perform/1 :nats_not_configured branch" do
    test "discards when nats_account_name is missing", %{actor: actor, unique_id: u} do
      Application.delete_env(:serviceradar, :nats_account_name)
      Application.put_env(:serviceradar, :nats_account_seed, "SEED_PLACEHOLDER")

      pkg = create_gateway_package!(actor, u)
      force_agent_component!(pkg.id, "agent_#{u}")

      assert {:discard, :nats_not_configured} =
               ProvisionAgentWorker.perform(build_job(pkg.id))
    end

    test "discards when nats_account_name is empty string", %{actor: actor, unique_id: u} do
      Application.put_env(:serviceradar, :nats_account_name, "")
      Application.put_env(:serviceradar, :nats_account_seed, "SEED_PLACEHOLDER")

      pkg = create_gateway_package!(actor, u)
      force_agent_component!(pkg.id, "agent_#{u}")

      assert {:discard, :nats_not_configured} =
               ProvisionAgentWorker.perform(build_job(pkg.id))
    end
  end

  # --- :account_seed_not_found ----------------------------------------------

  describe "perform/1 :account_seed_not_found branch" do
    test "discards when nats_account_seed is missing", %{actor: actor, unique_id: u} do
      Application.put_env(:serviceradar, :nats_account_name, "TEST_ACCOUNT")
      Application.delete_env(:serviceradar, :nats_account_seed)

      pkg = create_gateway_package!(actor, u)
      force_agent_component!(pkg.id, "agent_#{u}")

      assert {:discard, :account_seed_not_found} =
               ProvisionAgentWorker.perform(build_job(pkg.id))
    end

    test "discards when nats_account_seed is empty string", %{actor: actor, unique_id: u} do
      Application.put_env(:serviceradar, :nats_account_name, "TEST_ACCOUNT")
      Application.put_env(:serviceradar, :nats_account_seed, "")

      pkg = create_gateway_package!(actor, u)
      force_agent_component!(pkg.id, "agent_#{u}")

      assert {:discard, :account_seed_not_found} =
               ProvisionAgentWorker.perform(build_job(pkg.id))
    end
  end

  # --- helpers --------------------------------------------------------------

  defp build_job(package_id) do
    %Oban.Job{
      args: %{"package_id" => package_id},
      attempt: 1,
      max_attempts: 5
    }
  end

  defp create_gateway_package!(actor, unique_id) do
    # We deliberately seed packages as :gateway so the OnboardingPackage
    # :create after-action does NOT call ProvisionAgentWorker.enqueue/1.
    # Tests that need an :agent row reach in via raw SQL afterwards.
    OnboardingPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        label: "test-pkg-#{unique_id}",
        component_id: "gw-#{unique_id}",
        component_type: :gateway,
        partition_id: "p-#{unique_id}",
        site: "s-#{unique_id}",
        security_mode: :mtls
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp force_agent_component!(package_id, component_id) do
    # Bypass the :create after-action by writing directly to the table.
    # Column names mirror priv/repo/migrations/20260117090000_rebuild_schema.exs:
    # primary key column is `package_id`, not `id`.
    {:ok, uuid_bin} = Ecto.UUID.dump(package_id)

    Repo.query!(
      """
      UPDATE platform.edge_onboarding_packages
         SET component_type = 'agent',
             component_id = $1
       WHERE package_id = $2
      """,
      [component_id, uuid_bin]
    )

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar, key, value)
end
