defmodule ServiceRadar.Edge.Workers.ProvisionAgentWorkerTest do
  @moduledoc """
  ExUnit coverage for `ProvisionAgentWorker.perform/1`.

  This file covers Pass 15 / Pass 16 task §20.16 (B-5 sub-issue 4): the
  success path, retryable account-client failures, and every `:discard`
  branch of `perform/1`.

  ## Scope

  Plain-`perform/1` unit tests cover every branch that resolves before the
  worker reaches `ServiceRadar.NATS.AccountClient.generate_user_credentials/5`:

    * `:package_not_found`
    * `:not_agent_package`
    * `:invalid_agent_id`
    * `:nats_not_configured`
    * `:account_seed_not_found`

  `perform/2` accepts an `:account_client` test seam, mirroring the
  `:awx_client` pattern in `controller_health_worker.ex`, so the tests can
  exercise the happy path and retryable account-client errors without a live
  datasvc gRPC channel.

  ## Why no `use Oban.Testing`

  The repo-wide convention (see e.g.
  `test/serviceradar/jobs/prune_stale_agents_worker_test.exs` and
  `test/serviceradar/automation/ansible/controller_health_worker_test.exs`)
  is to invoke the worker module's `perform/1` directly with a hand-rolled
  `%Oban.Job{}`. That keeps these tests free of Oban repo round-trips
  while still exercising the exact code path Oban would execute. The
  `Oban` instance is, however, run in `testing: :manual` mode (see
  `config/test.exs`) so worker behavior remains deterministic without a
  live queue.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Edge.Workers.ProvisionAgentWorker
  alias ServiceRadar.Repo

  @moduletag :database

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
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

      # Mutate via raw SQL so the test can construct the legacy agent row
      # shape without exercising package creation.
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

  # --- mint + persist branches ---------------------------------------------

  describe "perform/2 account-client branch coverage" do
    test "mints credentials, creates a credential row, and attaches encrypted creds", %{
      actor: actor,
      unique_id: u
    } do
      configure_nats!()

      pkg = create_gateway_package!(actor, u)
      force_agent_component!(pkg.id, "agent_#{u}")

      assert :ok =
               ProvisionAgentWorker.perform(build_job(pkg.id),
                 account_client: __MODULE__.SuccessfulAccountClient
               )

      expected_user_name = "flow-collector-agent_#{u}"

      assert_receive {:generate_user_credentials, "TEST_ACCOUNT", "SEED_PLACEHOLDER",
                      ^expected_user_name, opts}

      assert opts[:expiration_seconds] == 30 * 24 * 60 * 60
      assert opts[:permissions]

      package = Ash.get!(OnboardingPackage, pkg.id, actor: actor)
      assert package.nats_credential_id
      assert encrypted_nats_creds_present?(package.id)

      credential = Ash.get!(NatsCredential, package.nats_credential_id, actor: actor)
      assert credential.user_name == expected_user_name
      assert credential.credential_type == :service
      assert credential.status == :active
      assert metadata_value(credential.metadata, "agent_id") == "agent_#{u}"
      assert metadata_value(credential.metadata, "partition_id") == "p-#{u}"
      assert metadata_value(credential.metadata, "site") == "s-#{u}"
    end

    test "returns grpc errors so Oban can retry", %{actor: actor, unique_id: u} do
      configure_nats!()

      pkg = create_gateway_package!(actor, u)
      force_agent_component!(pkg.id, "agent_#{u}")

      assert {:error, {:grpc_error, "datasvc unavailable"}} =
               ProvisionAgentWorker.perform(build_job(pkg.id),
                 account_client: __MODULE__.GrpcErrorAccountClient
               )
    end

    test "returns not_connected so Oban can retry", %{actor: actor, unique_id: u} do
      configure_nats!()

      pkg = create_gateway_package!(actor, u)
      force_agent_component!(pkg.id, "agent_#{u}")

      assert {:error, :not_connected} =
               ProvisionAgentWorker.perform(build_job(pkg.id),
                 account_client: __MODULE__.NotConnectedAccountClient
               )
    end

    test "returns unexpected account-client errors so Oban can retry", %{
      actor: actor,
      unique_id: u
    } do
      configure_nats!()

      pkg = create_gateway_package!(actor, u)
      force_agent_component!(pkg.id, "agent_#{u}")

      assert {:error, :unexpected_account_error} =
               ProvisionAgentWorker.perform(build_job(pkg.id),
                 account_client: __MODULE__.UnexpectedErrorAccountClient
               )
    end
  end

  # --- helpers --------------------------------------------------------------

  defmodule SuccessfulAccountClient do
    @moduledoc false

    def generate_user_credentials(account_name, account_seed, user_name, :service, opts) do
      send(self(), {:generate_user_credentials, account_name, account_seed, user_name, opts})

      {:ok,
       %{
         user_public_key: "U#{System.unique_integer([:positive])}",
         user_jwt: "test-user-jwt",
         creds_file_content:
           "-----BEGIN NATS USER JWT-----\ntest-user-jwt\n------END NATS USER JWT------",
         expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
       }}
    end
  end

  defmodule GrpcErrorAccountClient do
    @moduledoc false

    def generate_user_credentials(_account_name, _account_seed, _user_name, :service, _opts),
      do: {:error, {:grpc_error, "datasvc unavailable"}}
  end

  defmodule NotConnectedAccountClient do
    @moduledoc false

    def generate_user_credentials(_account_name, _account_seed, _user_name, :service, _opts),
      do: {:error, :not_connected}
  end

  defmodule UnexpectedErrorAccountClient do
    @moduledoc false

    def generate_user_credentials(_account_name, _account_seed, _user_name, :service, _opts),
      do: {:error, :unexpected_account_error}
  end

  defp configure_nats! do
    Application.put_env(:serviceradar, :nats_account_name, "TEST_ACCOUNT")
    Application.put_env(:serviceradar, :nats_account_seed, "SEED_PLACEHOLDER")
  end

  defp metadata_value(metadata, "agent_id"),
    do: Map.get(metadata, "agent_id") || Map.get(metadata, :agent_id)

  defp metadata_value(metadata, "partition_id"),
    do: Map.get(metadata, "partition_id") || Map.get(metadata, :partition_id)

  defp metadata_value(metadata, "site"), do: Map.get(metadata, "site") || Map.get(metadata, :site)

  defp encrypted_nats_creds_present?(package_id) do
    {:ok, uuid_bin} = Ecto.UUID.dump(package_id)

    %{rows: [[ciphertext]]} =
      Repo.query!(
        """
        SELECT encrypted_nats_creds_ciphertext
          FROM platform.edge_onboarding_packages
         WHERE package_id = $1
        """,
        [uuid_bin]
      )

    is_binary(ciphertext) and byte_size(ciphertext) > 0
  end

  defp build_job(package_id) do
    %Oban.Job{
      args: %{"package_id" => package_id},
      attempt: 1,
      max_attempts: 5
    }
  end

  defp create_gateway_package!(actor, unique_id) do
    # We deliberately seed packages as :gateway so the OnboardingPackage
    # Agent package creation no longer enqueues this legacy worker.
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
    # Construct the legacy agent row directly so this worker test remains
    # independent from package creation.
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
