defmodule ServiceRadar.Edge.Workers.ProvisionCollectorWorkerTest do
  @moduledoc """
  ExUnit coverage for `ProvisionCollectorWorker.perform/1` persistence.

  The datasvc transport is faked at the existing public
  `GRPC.Client.Adapter` contract: the supervised `DataService.Client`
  carries a test-only adapter channel, so the real `AccountClient`
  request building, protobuf encoding and response mapping run
  unchanged. The fake only returns synthetic RPC responses and
  arranges request/release ordering; persisted cleanup is asserted
  against real Ash state.
  """

  use ServiceRadar.DataCase, async: false

  alias GRPC.Client.Stream
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DataService.Client
  alias ServiceRadar.Edge.CollectorPackage
  alias ServiceRadar.Edge.NatsCredential
  alias ServiceRadar.Edge.Workers.ProvisionCollectorWorker
  alias ServiceRadar.Repo

  @moduletag :database

  defmodule FakeDatasvcAdapter do
    @moduledoc false

    @behaviour GRPC.Client.Adapter

    @impl true
    def connect(channel, _opts), do: {:ok, channel}

    @impl true
    def disconnect(channel), do: {:ok, channel}

    @impl true
    def send_request(%Stream{} = stream, contents, _opts) do
      coordinator =
        Application.fetch_env!(:serviceradar_core, :provision_collector_worker_test_coordinator)

      request = Proto.GenerateUserCredentialsRequest.decode(IO.iodata_to_binary(contents))
      send(coordinator, {:datasvc_generate_user_credentials, self(), request})

      receive do
        {:datasvc_release, plan} -> Stream.put_payload(stream, :test_plan, plan)
      after
        15_000 -> Stream.put_payload(stream, :test_plan, {:error, :fake_release_timeout})
      end
    end

    @impl true
    def receive_data(%Stream{payload: %{test_plan: plan}}, _opts) do
      case plan do
        {:respond, response} -> {:ok, decode_response(response)}
        {:error, reason} -> {:error, reason}
      end
    end

    defp decode_response(response) do
      response
      |> Proto.GenerateUserCredentialsResponse.encode()
      |> IO.iodata_to_binary()
      |> Proto.GenerateUserCredentialsResponse.decode()
    end

    @impl true
    def send_headers(stream, _opts), do: stream

    @impl true
    def send_data(stream, _message, _opts), do: stream

    @impl true
    def end_stream(stream), do: stream

    @impl true
    def cancel(_stream), do: :ok
  end

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    prior_account_name = Application.get_env(:serviceradar, :nats_account_name)
    prior_account_seed = Application.get_env(:serviceradar, :nats_account_seed)

    prior_coordinator =
      Application.get_env(:serviceradar_core, :provision_collector_worker_test_coordinator)

    Application.put_env(:serviceradar, :nats_account_name, "TEST_ACCOUNT")
    Application.put_env(:serviceradar, :nats_account_seed, "SEED_PLACEHOLDER")
    Application.put_env(:serviceradar_core, :provision_collector_worker_test_coordinator, self())

    on_exit(fn ->
      restore_env(:serviceradar, :nats_account_name, prior_account_name)
      restore_env(:serviceradar, :nats_account_seed, prior_account_seed)

      restore_env(
        :serviceradar_core,
        :provision_collector_worker_test_coordinator,
        prior_coordinator
      )
    end)

    client_started? =
      case start_supervised(
             {Client,
              host: "127.0.0.1",
              port: 1,
              sec_mode: "plaintext",
              connect_timeout_ms: 10,
              reconnect_base_ms: 60_000,
              reconnect_max_ms: 60_000}
           ) do
        {:ok, _pid} -> true
        {:error, {:already_started, _pid}} -> false
      end

    prior_channel =
      if !client_started? do
        Client |> :sys.get_state(15_000) |> Map.take([:channel, :connect_task])
      end

    on_exit(fn ->
      if !client_started? do
        :sys.replace_state(Client, fn state -> Map.merge(state, prior_channel) end, 15_000)
      end
    end)

    :sys.replace_state(
      Client,
      fn state ->
        %{state | channel: %GRPC.Channel{adapter: FakeDatasvcAdapter}, connect_task: nil}
      end,
      15_000
    )

    %{
      actor: SystemActor.system(:provision_collector_worker_test),
      unique_id: :erlang.unique_integer([:positive])
    }
  end

  describe "perform/1 normal provisioning" do
    test "attaches exactly one active credential and stores private contents", %{
      actor: actor,
      unique_id: u
    } do
      package = create_package!(actor, u)
      public_key = "U9TESTCOLLECTOR#{u}"
      task = start_perform_task(package.id)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, request}, 10_000

      assert request.account_name == "TEST_ACCOUNT"
      assert request.account_seed == "SEED_PLACEHOLDER"
      assert request.user_name == package.user_name
      assert request.credential_type == :USER_CREDENTIAL_TYPE_COLLECTOR
      assert request.permissions.publish_allow == ["logs.syslog.>"]

      send(adapter_pid, {:datasvc_release, {:respond, credential_response(public_key, u)}})
      assert :ok = Task.await(task, 30_000)

      ready = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert ready.status == :ready
      assert is_binary(ready.nats_credential_id)

      credential =
        NatsCredential
        |> Ash.Query.for_read(:by_user_name, %{user_name: package.user_name})
        |> Ash.read_one!(actor: actor)

      assert credential.id == ready.nats_credential_id
      assert credential.status == :active
      assert credential.user_public_key == public_key
      assert credential.credential_type == :collector

      assert count_credentials(actor) == 1
      assert stored_creds_ciphertext(package.id)
    end
  end

  describe "perform/1 revoke during generation" do
    test "leaves a terminal package without any new credential or private contents", %{
      actor: actor,
      unique_id: u
    } do
      package = create_package!(actor, u)
      public_key = "U9TESTCOLLECTOR#{u}"
      task = start_perform_task(package.id)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      revoked =
        package
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_argument(:reason, "revoked during provisioning")
        |> Ash.Changeset.for_update(:revoke, %{}, actor: actor)
        |> Ash.update!()

      assert revoked.status == :revoked

      send(adapter_pid, {:datasvc_release, {:respond, credential_response(public_key, u)}})
      assert :ok = Task.await(task, 30_000)

      terminal = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert terminal.status == :revoked
      assert is_nil(terminal.nats_credential_id)

      assert {:ok, nil} =
               NatsCredential
               |> Ash.Query.for_read(:by_user_name, %{user_name: package.user_name})
               |> Ash.read_one(actor: actor)

      assert count_credentials(actor) == 0
      assert stored_creds_ciphertext(package.id) == nil
    end
  end

  describe "perform/1 malformed datasvc response" do
    test "rolls back the credential write instead of attaching", %{actor: actor, unique_id: u} do
      package = create_package!(actor, u)
      public_key = "U9TESTCOLLECTOR#{u}"
      task = start_perform_task(package.id)

      assert_receive {:datasvc_generate_user_credentials, adapter_pid, _request}, 10_000

      malformed = %{credential_response(public_key, u) | creds_file_content: ""}
      send(adapter_pid, {:datasvc_release, {:respond, malformed}})
      assert {:error, _reason} = Task.await(task, 30_000)

      stalled = Ash.get!(CollectorPackage, package.id, actor: actor)
      assert stalled.status == :provisioning
      assert is_nil(stalled.nats_credential_id)

      assert {:ok, nil} =
               NatsCredential
               |> Ash.Query.for_read(:by_user_name, %{user_name: package.user_name})
               |> Ash.read_one(actor: actor)

      assert count_credentials(actor) == 0
      assert stored_creds_ciphertext(package.id) == nil
    end
  end

  defp start_perform_task(package_id) do
    task =
      Task.async(fn ->
        receive do
          :go -> :ok
        after
          10_000 -> exit(:no_go)
        end

        ProvisionCollectorWorker.perform(build_job(package_id))
      end)

    # Serial tests run under a shared sandbox owner (DataCase, async: false), so every
    # process already uses the test's connection and Sandbox.allow/3 reports :not_found.
    # Only async (unshared) owners need DataCase.allow_sandbox/1 for test-owned children.
    send(task.pid, :go)
    task
  end

  defp build_job(package_id) do
    %Oban.Job{
      args: %{"package_id" => package_id},
      attempt: 1,
      max_attempts: 5
    }
  end

  defp create_package!(actor, unique_id) do
    CollectorPackage
    |> Ash.Changeset.for_create(
      :create,
      %{
        collector_type: :flowgger,
        site: "collector-race-#{unique_id}",
        hostname: "collector-#{unique_id}.example.com"
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp credential_response(public_key, unique_id) do
    %Proto.GenerateUserCredentialsResponse{
      user_public_key: public_key,
      user_jwt: "test-user-jwt-#{unique_id}",
      creds_file_content:
        "-----BEGIN NATS USER JWT-----\ntest-user-jwt-#{unique_id}\n------END NATS USER JWT------",
      expires_at_unix: 0
    }
  end

  defp count_credentials(actor) do
    NatsCredential |> Ash.Query.for_read(:read) |> Ash.read!(actor: actor) |> length()
  end

  defp stored_creds_ciphertext(package_id) do
    {:ok, uuid_bin} = Ecto.UUID.dump(package_id)

    %{rows: [[ciphertext]]} =
      Repo.query!(
        "SELECT encrypted_nats_creds_ciphertext FROM platform.collector_packages WHERE id = $1",
        [uuid_bin]
      )

    ciphertext
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
