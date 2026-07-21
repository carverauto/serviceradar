defmodule ServiceRadar.Automation.Ansible.ControllerProvenance do
  @moduledoc """
  Reads bounded AWX object identity through the assigned edge plugin.

  Core never resolves an AWX bearer or opens a network connection to AWX. Every
  production read is issued through `AwxClient` and `AgentCommandBus` to the
  controller agent frozen into the launch snapshot. This module forces the
  frozen partition, waits for the durable `AgentCommand`, and accepts a result
  only after its command ID, agent, partition, type, status, request payload,
  and secret-free response projection all match the server-selected query.

  The assigned agent and AWX plugin are therefore an explicit transport trust
  boundary. These checks prevent result-selected authority and cross-agent or
  cross-partition substitution; they do not claim cryptographic independence
  from a hostile agent that is itself assigned to the controller.

  Unit tests may inject the AWX client, command reader, clock, and sleeper. The
  production defaults remain the edge command path; there is deliberately no
  direct HTTP or bearer-resolution adapter.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.AwxLaunchContract
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.AgentCommand

  @job_fields ~w(
    id name status created modified started finished canceled_on launch_type
    job_template inventory project scm_revision execution_environment job_type
    diff_mode verbosity forks job_slice_count job_slice_number timeout limit
    job_tags skip_tags instance_group failed
  )
  @marker_keys ~w(serviceradar_dispatch_id serviceradar_snapshot_digest)
  @max_job_id 2_147_483_647
  @max_page_size 100
  @max_recent_candidates 5_000
  @max_callback_credentials 5_000
  @default_await_timeout_ms 60_000
  @max_await_timeout_ms 60_000
  @default_poll_interval_ms 100
  @max_poll_interval_ms 1_000
  @active_statuses [:queued, :sent, :acknowledged, :running]
  @terminal_failure_statuses [:failed, :expired, :canceled, :offline]
  @command_payload_keys ~w(
    schema verb args base_url controller_id controller_name insecure_skip_verify
    credential_broker
  )
  @command_context_keys ~w(controller_id controller_name verb)

  @type recent_result :: %{required(:jobs) => [map()], required(:complete?) => boolean()}
  @type credential_result :: %{
          required(:credentials) => [map()],
          required(:complete?) => boolean()
        }

  @doc "Returns a bounded, secret-free projection of one controller-observed job."
  @spec verify_job(map() | struct(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_job(controller, job_id, opts \\ [])

  def verify_job(controller, job_id, opts)
      when is_map(controller) and is_integer(job_id) and job_id in 1..@max_job_id and
             is_list(opts) do
    args = %{"job_id" => job_id}

    with {:ok, boundary} <- verify_security_boundary(controller, opts),
         {:ok, payload} <-
           dispatch_and_await(controller, "awx.fetch_job", args, boundary, opts) do
      verified_job_payload(payload, job_id)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :controller_job_provenance_unavailable}
    end
  end

  def verify_job(_controller, _job_id, _opts),
    do: {:error, :invalid_controller_job_provenance_request}

  @doc "Lists the complete server-scoped recent-job set, bounded to 5,000 candidates."
  @spec list_recent_jobs(map() | struct(), map(), keyword()) ::
          {:ok, recent_result()} | {:error, term()}
  def list_recent_jobs(controller, request, opts \\ [])

  def list_recent_jobs(controller, request, opts)
      when is_map(controller) and is_map(request) and is_list(opts) do
    with {:ok, boundary} <- verify_security_boundary(controller, opts),
         {:ok, exact} <- normalize_recent_request(request),
         args = recent_query_args(exact),
         {:ok, payload} <-
           dispatch_and_await(controller, "awx.list_recent_jobs", args, boundary, opts) do
      verified_recent_jobs_payload(payload, exact)
    end
  end

  def list_recent_jobs(_controller, _request, _opts),
    do: {:error, :invalid_controller_recent_jobs_request}

  @doc "Verifies one server-selected callback credential and its exact immutable scope."
  @spec verify_callback_credential(map() | struct(), pos_integer(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_callback_credential(controller, credential_id, expected, opts \\ [])

  def verify_callback_credential(controller, credential_id, expected, opts)
      when is_map(controller) and is_integer(credential_id) and credential_id in 1..@max_job_id and
             is_map(expected) and
             is_list(opts) do
    with {:ok, boundary} <- verify_security_boundary(controller, opts),
         {:ok, expected} <- normalize_credential_request(expected),
         args = credential_query_args(expected, credential_id),
         {:ok, payload} <-
           dispatch_and_await(
             controller,
             "awx.verify_callback_credential",
             args,
             boundary,
             opts
           ) do
      verified_credential_payload(payload, credential_id, expected)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :controller_credential_provenance_unavailable}
    end
  end

  def verify_callback_credential(_controller, _credential_id, _expected, _opts),
    do: {:error, :invalid_controller_credential_provenance_request}

  @doc "Lists every exact callback credential match through a bounded edge read."
  @spec find_callback_credentials(map() | struct(), map(), keyword()) ::
          {:ok, credential_result()} | {:error, term()}
  def find_callback_credentials(controller, expected, opts \\ [])

  def find_callback_credentials(controller, expected, opts)
      when is_map(controller) and is_map(expected) and is_list(opts) do
    with {:ok, boundary} <- verify_security_boundary(controller, opts),
         {:ok, expected} <- normalize_credential_request(expected),
         args = callback_credential_list_args(expected),
         {:ok, payload} <-
           dispatch_and_await(
             controller,
             "awx.list_callback_credentials",
             args,
             boundary,
             opts
           ) do
      verified_credential_list_payload(payload, expected)
    end
  end

  def find_callback_credentials(_controller, _expected, _opts),
    do: {:error, :invalid_controller_credential_lookup_request}

  @doc """
  Fetches and verifies one exact, read-only AWX launch preflight through the
  controller's frozen edge principal.

  The returned command ID is the durable `AgentCommand` identity used by the
  independent preflight-evidence record. It is deliberately retained only
  after the persisted command payload, partition, agent, controller boundary,
  and redacted result all match the server-built request.
  """
  @spec fetch_launch_preflight(map() | struct(), map(), keyword()) ::
          {:ok,
           %{
             required(:command_id) => String.t(),
             required(:preflight) => map(),
             required(:request_digest) => String.t(),
             required(:preflight_digest) => String.t(),
             required(:command_result_digest) => String.t()
           }}
          | {:error, term()}
  def fetch_launch_preflight(controller, request, opts \\ [])

  def fetch_launch_preflight(controller, request, opts)
      when is_map(controller) and is_map(request) and is_list(opts) do
    with {:ok, boundary} <- verify_security_boundary(controller, opts),
         {:ok, request} <- AwxLaunchContract.validate_request(request),
         :ok <- exact_preflight_request_boundary(request, boundary),
         {:ok, %{command_id: command_id, payload: payload}} <-
           dispatch_and_await_with_command(
             controller,
             "awx.fetch_launch_preflight",
             request,
             boundary,
             opts
           ),
         {:ok, result} <- AwxLaunchContract.verify_plugin_result(payload, request),
         {:ok, command_result_digest} <- AwxLaunchContract.result_digest(payload) do
      result
      |> Map.put(:command_id, command_id)
      |> Map.put(:command_result_digest, command_result_digest)
      |> then(&{:ok, &1})
    else
      {:error, _reason} = error -> error
      _ -> {:error, :controller_launch_preflight_unavailable}
    end
  end

  def fetch_launch_preflight(_controller, _request, _opts),
    do: {:error, :invalid_controller_launch_preflight_request}

  @doc false
  @spec sanitize_job(map()) :: {:ok, map()} | {:error, term()}
  def sanitize_job(raw) when is_map(raw) do
    source = stringify(raw)

    with id when is_integer(id) and id in 1..@max_job_id <- source["id"],
         {:ok, markers} <- dispatch_markers(job_markers(source)),
         {:ok, credentials} <- credential_summaries(job_credentials(source)),
         {:ok, labels, label_count} <- label_summary(source) do
      job = Map.take(source, @job_fields)

      job =
        case launched_by(source["launched_by"]) do
          nil -> job
          launched_by -> Map.put(job, "launched_by", launched_by)
        end

      job =
        job
        |> Map.put("credentials", credentials)
        |> Map.put("labels", labels)
        |> Map.put("label_count", label_count)

      job = if markers == %{}, do: job, else: Map.put(job, "dispatch_markers", markers)
      {:ok, job}
    else
      _ -> {:error, :invalid_controller_job_projection}
    end
  end

  def sanitize_job(_raw), do: {:error, :invalid_controller_job_projection}

  @doc false
  @spec sanitize_credential(map()) :: {:ok, map()} | {:error, term()}
  def sanitize_credential(raw) when is_map(raw) do
    raw = stringify(raw)
    id = raw["id"]
    name = raw["name"]
    credential_type_id = raw["credential_type_id"] || related_id(raw["credential_type"])
    organization_id = raw["organization_id"] || related_id(raw["organization"])

    with true <- positive_id?(id),
         true <- is_binary(name) and name != "" and byte_size(name) <= 512,
         true <- positive_id?(credential_type_id),
         true <- positive_id?(organization_id) do
      {:ok,
       %{
         "id" => id,
         "name" => name,
         "credential_type_id" => credential_type_id,
         "organization_id" => organization_id
       }}
    else
      _ -> {:error, :invalid_controller_credential_projection}
    end
  end

  def sanitize_credential(_raw), do: {:error, :invalid_controller_credential_projection}

  defp verified_job_payload(raw, job_id) do
    payload = stringify(raw)

    with :ok <- exact_keys(payload, ~w(verb ok job_id job)),
         true <- payload["verb"] == "awx.fetch_job",
         true <- payload["ok"] == true,
         true <- payload["job_id"] == job_id,
         job when is_map(job) <- payload["job"],
         {:ok, job} <- sanitize_job(job),
         true <- job["id"] == job_id do
      {:ok, job}
    else
      false -> {:error, :controller_job_id_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :controller_job_provenance_unavailable}
    end
  end

  defp verified_recent_jobs_payload(raw, request) do
    payload = stringify(raw)

    with :ok <-
           exact_keys(
             payload,
             ~w(
               verb ok template_id inventory_id created_by_id created_after page_size
               max_candidates count complete jobs
             )
           ),
         true <- payload["verb"] == "awx.list_recent_jobs",
         true <- payload["ok"] == true,
         true <- payload["template_id"] == request.template_id,
         true <- payload["inventory_id"] == request.inventory_id,
         true <- payload["created_by_id"] == request.created_by_id,
         true <- payload["created_after"] == request.created_after,
         true <- payload["page_size"] == request.page_size,
         true <- payload["max_candidates"] == @max_recent_candidates,
         count when is_integer(count) and count in 0..@max_recent_candidates <- payload["count"],
         true <- payload["complete"] == true,
         jobs when is_list(jobs) and length(jobs) == count <- payload["jobs"],
         {:ok, jobs} <- sanitize_recent_jobs(jobs, request),
         true <- unique_ids?(jobs) do
      {:ok, %{jobs: jobs, complete?: true}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :controller_recent_jobs_result_mismatch}
    end
  end

  defp verified_credential_payload(raw, credential_id, expected) do
    payload = stringify(raw)

    with :ok <- exact_keys(payload, ~w(verb ok credential_id credential)),
         true <- payload["verb"] == "awx.verify_callback_credential",
         true <- payload["ok"] == true,
         true <- payload["credential_id"] == credential_id,
         credential when is_map(credential) <- payload["credential"],
         {:ok, credential} <- sanitize_credential(credential),
         true <- credential["id"] == credential_id,
         :ok <- exact_credential_scope(credential, expected) do
      {:ok, credential}
    else
      false -> {:error, :controller_credential_id_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :controller_credential_provenance_unavailable}
    end
  end

  defp verified_credential_list_payload(raw, expected) do
    payload = stringify(raw)

    with :ok <-
           exact_keys(
             payload,
             ~w(
               verb ok credential_type_id organization_id credential_name max_credentials
               count complete credentials
             )
           ),
         true <- payload["verb"] == "awx.list_callback_credentials",
         true <- payload["ok"] == true,
         true <- payload["credential_type_id"] == expected.credential_type_id,
         true <- payload["organization_id"] == expected.organization_id,
         true <- payload["credential_name"] == expected.credential_name,
         true <- payload["max_credentials"] == @max_callback_credentials,
         count when is_integer(count) and count in 0..@max_callback_credentials <-
           payload["count"],
         true <- payload["complete"] == true,
         credentials when is_list(credentials) and length(credentials) == count <-
           payload["credentials"],
         {:ok, credentials} <- sanitize_credentials(credentials, expected),
         true <- sorted_unique_ids?(credentials) do
      {:ok, %{credentials: credentials, complete?: true}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :controller_credential_lookup_result_mismatch}
    end
  end

  defp dispatch_and_await(controller, verb, args, boundary, opts) do
    with {:ok, %{payload: payload}} <-
           dispatch_and_await_with_command(controller, verb, args, boundary, opts) do
      {:ok, payload}
    end
  end

  # The live launch-preflight gate must record the exact durable AgentCommand
  # that produced its attestation. Existing provenance reads intentionally
  # expose only their projected payload, so retain the command ID internally
  # without weakening their public return shapes.
  defp dispatch_and_await_with_command(controller, verb, args, boundary, opts) do
    with {:ok, dispatched} <- dispatch_read(controller, verb, args, boundary, opts),
         {:ok, command_id} <- dispatched_command_id(dispatched),
         {:ok, deadline} <- await_deadline(opts),
         {:ok, payload} <-
           await_persisted_command(command_id, verb, args, boundary, deadline, opts) do
      {:ok, %{command_id: command_id, payload: payload}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :controller_provenance_dispatch_failed}
    end
  end

  defp dispatched_command_id(command_id) when is_binary(command_id) and command_id != "",
    do: {:ok, command_id}

  defp dispatched_command_id(command) when is_map(command) do
    case value(command, :id) do
      command_id when is_binary(command_id) and command_id != "" -> {:ok, command_id}
      _ -> {:error, :controller_provenance_dispatch_failed}
    end
  end

  defp dispatched_command_id(_dispatched), do: {:error, :controller_provenance_dispatch_failed}

  defp dispatch_read(controller, verb, args, boundary, opts) do
    client = Keyword.get(opts, :awx_client, AwxClient)
    client_opts = awx_client_opts(boundary, opts)

    case verb do
      "awx.fetch_job" ->
        client.fetch_job(controller, args["job_id"], client_opts)

      "awx.list_recent_jobs" ->
        client.list_recent_jobs(controller, args, client_opts)

      "awx.verify_callback_credential" ->
        client.verify_callback_credential(controller, args, client_opts)

      "awx.list_callback_credentials" ->
        client.list_callback_credentials(controller, args, client_opts)

      "awx.fetch_launch_preflight" ->
        client.fetch_launch_preflight(controller, args, client_opts)

      _unsupported ->
        {:error, :controller_provenance_query_unsupported}
    end
  rescue
    _ -> {:error, :controller_provenance_dispatch_failed}
  catch
    _, _ -> {:error, :controller_provenance_dispatch_failed}
  end

  defp awx_client_opts(boundary, opts) do
    opts
    |> Keyword.get(:awx_client_opts, [])
    |> case do
      values when is_list(values) -> Keyword.take(values, [:command_bus, :grant_issuer])
      _ -> []
    end
    |> Keyword.put(:required_partition, boundary.partition_id)
  end

  defp exact_preflight_request_boundary(request, boundary) when is_map(request) do
    if request["controller_id"] == boundary.controller_id,
      do: :ok,
      else: {:error, :controller_launch_preflight_controller_mismatch}
  end

  defp exact_preflight_request_boundary(_request, _boundary),
    do: {:error, :controller_launch_preflight_request_mismatch}

  defp await_deadline(opts) do
    with {:ok, now} <- monotonic_now(opts) do
      {:ok, now + await_timeout_ms(opts)}
    end
  end

  defp await_persisted_command(command_id, verb, args, boundary, deadline, opts) do
    with {:ok, command} <- read_command(command_id, opts),
         :ok <- exact_persisted_command(command, command_id, verb, args, boundary) do
      case value(command, :status) do
        :completed ->
          case value(command, :result_payload) do
            payload when is_map(payload) -> {:ok, payload}
            _ -> {:error, :controller_provenance_result_missing}
          end

        status when status in @active_statuses ->
          poll_again(command_id, verb, args, boundary, deadline, opts)

        status when status in @terminal_failure_statuses ->
          {:error, :controller_provenance_command_failed}

        _ ->
          {:error, :controller_provenance_command_mismatch}
      end
    end
  end

  defp poll_again(command_id, verb, args, boundary, deadline, opts) do
    with {:ok, now} <- monotonic_now(opts) do
      if now >= deadline do
        {:error, :controller_provenance_timeout}
      else
        sleep(opts, min(poll_interval_ms(opts), deadline - now))
        await_persisted_command(command_id, verb, args, boundary, deadline, opts)
      end
    end
  end

  defp exact_persisted_command(command, command_id, verb, args, boundary) when is_map(command) do
    payload = stringify(value(command, :payload) || %{})
    context = stringify(value(command, :context) || %{})

    with true <- value(command, :id) == command_id,
         true <- value(command, :agent_id) == boundary.agent_id,
         true <- value(command, :partition_id) == boundary.partition_id,
         true <- value(command, :command_type) == verb,
         true <-
           value(command, :status) in [
             :queued,
             :sent,
             :acknowledged,
             :running,
             :completed,
             :failed,
             :expired,
             :canceled,
             :offline
           ],
         :ok <- exact_command_context(context, verb, boundary),
         :ok <- exact_command_payload(payload, verb, args, boundary) do
      :ok
    else
      _ -> {:error, :controller_provenance_command_mismatch}
    end
  end

  defp exact_persisted_command(_command, _command_id, _verb, _args, _boundary),
    do: {:error, :controller_provenance_command_mismatch}

  defp exact_command_context(context, verb, boundary) do
    with :ok <- exact_keys(context, @command_context_keys),
         true <- context["controller_id"] == boundary.controller_id,
         true <- context["controller_name"] == boundary.controller_name,
         true <- context["verb"] == verb do
      :ok
    else
      _ -> {:error, :controller_provenance_command_mismatch}
    end
  end

  defp exact_command_payload(payload, verb, args, boundary) do
    broker = payload["credential_broker"]
    consumer = value(broker, :consumer) || %{}
    target = value(broker, :target) || %{}

    with :ok <- exact_keys(payload, @command_payload_keys),
         true <- payload["schema"] == "serviceradar.awx_command.v1",
         true <- payload["verb"] == verb,
         true <- payload["args"] == stringify(args),
         true <- payload["base_url"] == boundary.base_url,
         true <- payload["controller_id"] == boundary.controller_id,
         true <- payload["controller_name"] == boundary.controller_name,
         true <- payload["insecure_skip_verify"] == boundary.insecure_skip_verify,
         true <- is_map(broker),
         true <- value(consumer, :kind) == "ansible",
         true <- value(consumer, :id) == boundary.controller_id,
         true <- value(consumer, :purpose) == verb,
         true <- value(target, :kind) == "awx_controller",
         true <- value(target, :id) == boundary.controller_id,
         true <- value(target, :agent_id) == boundary.agent_id,
         true <- value(broker, :resolution_location) == "agent",
         {:ok, scope} <- AwxClient.broker_scope(boundary.base_url, verb, stringify(args)),
         true <- stringify(value(broker, :allow) || %{}) == stringify(scope.allow),
         true <- CredentialRedactor.redact(payload) == payload do
      :ok
    else
      _ -> {:error, :controller_provenance_command_mismatch}
    end
  end

  defp read_command(command_id, opts) do
    reader = Keyword.get(opts, :command_reader, &read_persisted_command/1)

    case reader.(command_id) do
      {:ok, command} when is_map(command) -> {:ok, command}
      {:error, _reason} = error -> error
      _ -> {:error, :controller_provenance_command_unavailable}
    end
  rescue
    _ -> {:error, :controller_provenance_command_unavailable}
  catch
    _, _ -> {:error, :controller_provenance_command_unavailable}
  end

  defp read_persisted_command(command_id) do
    AgentCommand.get_by_id(command_id, actor: SystemActor.system(:controller_provenance))
  end

  defp monotonic_now(opts) do
    clock = Keyword.get(opts, :monotonic_time, fn -> System.monotonic_time(:millisecond) end)

    case clock.() do
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, :controller_provenance_clock_unavailable}
    end
  rescue
    _ -> {:error, :controller_provenance_clock_unavailable}
  end

  defp sleep(opts, milliseconds) when is_integer(milliseconds) and milliseconds > 0 do
    sleeper = Keyword.get(opts, :sleep, &Process.sleep/1)
    sleeper.(milliseconds)
  end

  defp sleep(_opts, _milliseconds), do: :ok

  defp await_timeout_ms(opts) do
    case Keyword.get(opts, :await_timeout_ms, @default_await_timeout_ms) do
      value when is_integer(value) and value in 1..@max_await_timeout_ms -> value
      _ -> @default_await_timeout_ms
    end
  end

  defp poll_interval_ms(opts) do
    case Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms) do
      value when is_integer(value) and value in 1..@max_poll_interval_ms -> value
      _ -> @default_poll_interval_ms
    end
  end

  defp verify_security_boundary(controller, opts) do
    expected_snapshot = Keyword.get(opts, :expected_controller_snapshot)
    expected_partition_id = Keyword.get(opts, :expected_partition_id)

    with true <- valid_partition_id?(expected_partition_id),
         :ok <- ControllerSecuritySnapshot.verify(controller, expected_snapshot),
         snapshot when is_map(snapshot) <- stringify(expected_snapshot),
         agent_id when is_binary(agent_id) and agent_id != "" <- snapshot["agent_id"],
         controller_id when is_binary(controller_id) and controller_id != "" <-
           snapshot["controller_id"],
         controller_name when is_binary(controller_name) and controller_name != "" <-
           snapshot["name"],
         base_url when is_binary(base_url) and base_url != "" <- snapshot["base_url"],
         insecure_skip_verify when is_boolean(insecure_skip_verify) <-
           snapshot["insecure_skip_verify"] do
      {:ok,
       %{
         partition_id: expected_partition_id,
         agent_id: agent_id,
         controller_id: controller_id,
         controller_name: controller_name,
         base_url: base_url,
         insecure_skip_verify: insecure_skip_verify
       }}
    else
      false -> {:error, :controller_dispatch_partition_required}
      {:error, _reason} = error -> error
      _ -> {:error, :controller_security_snapshot_required}
    end
  end

  defp valid_partition_id?(value) when is_binary(value) do
    value != "" and String.trim(value) == value and byte_size(value) <= 255
  end

  defp valid_partition_id?(_value), do: false

  defp recent_query_args(request) do
    %{
      "template_id" => request.template_id,
      "inventory_id" => request.inventory_id,
      "created_by_id" => request.created_by_id,
      "created_after" => request.created_after,
      "page_size" => request.page_size,
      "max_candidates" => @max_recent_candidates
    }
  end

  defp credential_query_args(expected, credential_id) do
    expected
    |> callback_credential_args()
    |> Map.put("credential_id", credential_id)
  end

  defp callback_credential_list_args(expected) do
    expected
    |> callback_credential_args()
    |> Map.put("max_credentials", @max_callback_credentials)
  end

  defp callback_credential_args(expected) do
    %{
      "credential_name" => expected.credential_name,
      "credential_type_id" => expected.credential_type_id,
      "organization_id" => expected.organization_id
    }
  end

  defp sanitize_credentials(values, expected) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, credentials} ->
      with {:ok, credential} <- sanitize_credential(raw),
           :ok <- exact_credential_scope(credential, expected) do
        {:cont, {:ok, [credential | credentials]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, credentials} -> {:ok, Enum.reverse(credentials)}
      {:error, _reason} = error -> error
    end
  end

  defp sanitize_credentials(_values, _expected),
    do: {:error, :controller_credential_lookup_result_mismatch}

  defp normalize_credential_request(request) do
    request = stringify(request)
    name = request["credential_name"] || request["name"]
    credential_type_id = request["credential_type_id"]
    organization_id = request["organization_id"]

    with true <- is_binary(name) and name != "" and byte_size(name) <= 512,
         true <- positive_id?(credential_type_id),
         true <- positive_id?(organization_id) do
      {:ok,
       %{
         credential_name: name,
         credential_type_id: credential_type_id,
         organization_id: organization_id
       }}
    else
      _ -> {:error, :invalid_controller_credential_lookup_request}
    end
  end

  defp exact_credential_scope(credential, expected) do
    if credential["name"] == expected.credential_name and
         credential["credential_type_id"] == expected.credential_type_id and
         credential["organization_id"] == expected.organization_id,
       do: :ok,
       else: {:error, :controller_credential_scope_mismatch}
  end

  defp sanitize_recent_jobs(results, request) do
    results
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, jobs} ->
      with {:ok, job} <- sanitize_job(raw),
           :ok <- exact_recent_scope(job, request) do
        {:cont, {:ok, [job | jobs]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, _reason} = error -> error
    end
  end

  defp exact_recent_scope(job, request) do
    with true <- value(job, :job_template) == request.template_id,
         true <- value(job, :inventory) == request.inventory_id,
         true <- value(value(job, :launched_by) || %{}, :id) == request.created_by_id,
         {:ok, created} <- parse_datetime(value(job, :created)),
         true <- DateTime.compare(created, request.created_after_datetime) in [:eq, :gt] do
      :ok
    else
      _ -> {:error, :controller_recent_job_scope_mismatch}
    end
  end

  defp normalize_recent_request(request) do
    template_id = value(request, :template_id)
    inventory_id = value(request, :inventory_id)
    created_by_id = value(request, :created_by_id)
    created_after = value(request, :created_after)
    page_size = value(request, :page_size)
    max_candidates = value(request, :max_candidates)

    with true <- positive_id?(template_id),
         true <- positive_id?(inventory_id),
         true <- positive_id?(created_by_id),
         true <- is_integer(page_size) and page_size in 1..@max_page_size,
         true <- max_candidates == @max_recent_candidates,
         {:ok, created_after_datetime} <- parse_datetime(created_after) do
      {:ok,
       %{
         template_id: template_id,
         inventory_id: inventory_id,
         created_by_id: created_by_id,
         created_after: DateTime.to_iso8601(created_after_datetime),
         created_after_datetime: created_after_datetime,
         page_size: page_size
       }}
    else
      _ -> {:error, :invalid_controller_recent_jobs_request}
    end
  end

  defp dispatch_markers(nil), do: {:ok, %{}}
  defp dispatch_markers(""), do: {:ok, %{}}

  defp dispatch_markers(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> dispatch_markers(decoded)
      _ -> {:error, :invalid_controller_job_markers}
    end
  end

  defp dispatch_markers(raw) when is_map(raw) do
    raw = stringify(raw)

    Enum.reduce_while(@marker_keys, {:ok, %{}}, fn key, {:ok, markers} ->
      case Map.fetch(raw, key) do
        :error ->
          {:cont, {:ok, markers}}

        {:ok, value} when is_binary(value) and value != "" and byte_size(value) <= 512 ->
          {:cont, {:ok, Map.put(markers, key, value)}}

        {:ok, _value} ->
          {:halt, {:error, :invalid_controller_job_markers}}
      end
    end)
  end

  defp dispatch_markers(_raw), do: {:error, :invalid_controller_job_markers}

  defp job_markers(source) do
    if Map.has_key?(source, "dispatch_markers"),
      do: source["dispatch_markers"],
      else: source["extra_vars"]
  end

  defp job_credentials(source) do
    if Map.has_key?(source, "credentials"),
      do: source["credentials"],
      else: get_in(source, ["summary_fields", "credentials"])
  end

  defp credential_summaries(nil), do: {:ok, []}

  defp credential_summaries(values) when is_list(values) and length(values) <= 128 do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, credentials} ->
      value = stringify(value)

      case {value["id"], value["kind"]} do
        {id, kind}
        when is_integer(id) and id in 1..@max_job_id and is_binary(kind) and kind != "" and
               byte_size(kind) <= 64 ->
          {:cont, {:ok, [%{"id" => id, "kind" => kind} | credentials]}}

        _ ->
          {:halt, {:error, :invalid_controller_job_credentials}}
      end
    end)
    |> case do
      {:ok, credentials} -> {:ok, Enum.reverse(credentials)}
      {:error, _reason} = error -> error
    end
  end

  defp credential_summaries(_values), do: {:error, :invalid_controller_job_credentials}

  defp label_summary(source) when is_map(source) do
    source = stringify(source)

    {results, count} =
      if Map.has_key?(source, "labels") or Map.has_key?(source, "label_count") do
        {source["labels"], source["label_count"]}
      else
        case get_in(source, ["summary_fields", "labels"]) do
          summary when is_map(summary) -> {summary["results"] || [], summary["count"] || 0}
          _ -> {[], 0}
        end
      end

    ids =
      case results do
        values when is_list(values) ->
          Enum.map(values, fn
            item when is_integer(item) -> item
            item -> value(item, :id)
          end)

        _ ->
          nil
      end

    with true <- is_list(ids) and length(ids) <= 128,
         true <- is_integer(count) and count >= length(ids),
         true <- Enum.all?(ids, &positive_id?/1),
         true <- Enum.uniq(ids) == ids do
      {:ok, ids, count}
    else
      _ -> {:error, :invalid_controller_job_labels}
    end
  end

  defp label_summary(_raw), do: {:error, :invalid_controller_job_labels}

  defp launched_by(raw) when is_map(raw) do
    raw = stringify(raw)
    Map.take(raw, ~w(id type))
  end

  defp launched_by(_raw), do: nil

  defp parse_datetime(%DateTime{} = value), do: {:ok, value}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_controller_job_timestamp}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_controller_job_timestamp}

  defp related_id(value) when is_integer(value), do: value
  defp related_id(value) when is_map(value), do: value(value, :id)
  defp related_id(_value), do: nil

  defp positive_id?(value), do: is_integer(value) and value in 1..@max_job_id

  defp unique_ids?(values) when is_list(values) do
    ids = Enum.map(values, &value(&1, :id))
    Enum.all?(ids, &positive_id?/1) and Enum.uniq(ids) == ids
  end

  defp sorted_unique_ids?(values) when is_list(values) do
    ids = Enum.map(values, &value(&1, :id))
    Enum.all?(ids, &positive_id?/1) and Enum.uniq(ids) == ids and Enum.sort(ids) == ids
  end

  defp exact_keys(map, keys) when is_map(map) do
    if MapSet.new(Map.keys(map)) == MapSet.new(keys),
      do: :ok,
      else: {:error, :controller_provenance_result_mismatch}
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(values) when is_list(values), do: Enum.map(values, &stringify/1)
  defp stringify(value), do: value

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil
end
