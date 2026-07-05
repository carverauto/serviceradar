defmodule ServiceRadar.Automation.Ansible.AwxClient do
  @moduledoc """
  Issues AWX REST verbs as `AgentCommandBus` dispatches.

  The client is **not** an HTTP client. It speaks no AWX protocol. Every
  function builds a `CommandRequest` payload (with a credential broker
  grant carrying a `credential_secret_ref` -- never a plaintext token)
  and dispatches it to the agent that hosts the target controller. The
  agent's `awx` WASM plugin makes the actual HTTP call. Results come
  back asynchronously and update the corresponding `AgentCommand` row;
  callers either poll that row or subscribe to the existing
  command-result PubSub stream.

  See openspec change `add-ansible-integration` -- design.md decision 3
  ("WASM plugin is the network bridge to AWX") and decision 5
  ("AWX API token lives in the credential broker").
  """

  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins.SecretRefs

  @payload_schema "serviceradar.awx_command.v1"
  @grant_type "awx_oauth2_token"
  @default_grant_ttl_seconds 300
  @default_command_ttl_seconds 60
  @default_capability "http"

  @typedoc "A `(job_id, since_id)` pair for `fetch_events_for_jobs/3`."
  @type job_event_pair :: %{required(:job_id) => integer(), required(:since_id) => integer()}

  @typedoc "Optional launch parameters for `launch_job/4`."
  @type launch_opts :: %{
          optional(:extra_vars) => map(),
          optional(:host_limit) => String.t() | nil,
          optional(:inventory_id) => integer() | nil
        }

  @doc """
  GET /api/v2/ping/. Used by the controller health worker.
  """
  @spec ping(Controller.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def ping(controller, opts \\ []), do: dispatch_verb(controller, "awx.ping", %{}, opts)

  @spec list_inventories(Controller.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def list_inventories(controller, opts \\ []),
    do: dispatch_verb(controller, "awx.list_inventories", %{}, opts)

  @spec list_hosts(Controller.t(), integer(), keyword()) :: {:ok, struct()} | {:error, term()}
  def list_hosts(controller, inventory_id, opts \\ []) when is_integer(inventory_id) do
    dispatch_verb(controller, "awx.list_hosts", %{"inventory_id" => inventory_id}, opts)
  end

  @spec list_projects(Controller.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def list_projects(controller, opts \\ []),
    do: dispatch_verb(controller, "awx.list_projects", %{}, opts)

  @spec list_templates(Controller.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def list_templates(controller, opts \\ []),
    do: dispatch_verb(controller, "awx.list_templates", %{}, opts)

  @spec fetch_template(Controller.t(), integer(), keyword()) :: {:ok, struct()} | {:error, term()}
  def fetch_template(controller, template_id, opts \\ []) when is_integer(template_id) do
    dispatch_verb(controller, "awx.fetch_template", %{"template_id" => template_id}, opts)
  end

  @doc """
  Launch a Job Template. `launch_opts` may include `:extra_vars` (map),
  `:host_limit` (comma-joined AWX host names), and `:inventory_id`. Empty
  optional values are omitted from the payload so the AWX plugin doesn't
  send empty `limit:` etc.
  """
  @spec launch_job(Controller.t(), integer(), launch_opts(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def launch_job(controller, template_id, launch_opts \\ %{}, opts \\ [])
      when is_integer(template_id) and is_map(launch_opts) do
    args =
      %{"template_id" => template_id}
      |> maybe_put("extra_vars", Map.get(launch_opts, :extra_vars))
      |> maybe_put("host_limit", Map.get(launch_opts, :host_limit))
      |> maybe_put("inventory_id", Map.get(launch_opts, :inventory_id))

    dispatch_verb(controller, "awx.launch_job", args, opts)
  end

  @spec fetch_job(Controller.t(), integer(), keyword()) :: {:ok, struct()} | {:error, term()}
  def fetch_job(controller, job_id, opts \\ []) when is_integer(job_id) do
    dispatch_verb(controller, "awx.fetch_job", %{"job_id" => job_id}, opts)
  end

  @spec cancel_job(Controller.t(), integer(), keyword()) :: {:ok, struct()} | {:error, term()}
  def cancel_job(controller, job_id, opts \\ []) when is_integer(job_id) do
    dispatch_verb(controller, "awx.cancel_job", %{"job_id" => job_id}, opts)
  end

  @doc """
  Bulk fetch new events for one or more active jobs.

  This is the verb `RunPulseWorker` ticks against — one tick, one
  command, all of a controller's active runs in one AWX round-trip. See
  `add-ansible-integration` design.md decision 6.
  """
  @spec fetch_events_for_jobs(Controller.t(), [job_event_pair()], keyword()) ::
          {:ok, struct()} | {:error, term()}
  def fetch_events_for_jobs(controller, pairs, opts \\ []) when is_list(pairs) do
    normalized =
      Enum.map(pairs, fn pair ->
        %{
          "job_id" => fetch_int!(pair, :job_id),
          "since_id" => fetch_int!(pair, :since_id)
        }
      end)

    dispatch_verb(controller, "awx.fetch_events_for_jobs", %{"pairs" => normalized}, opts)
  end

  @doc """
  Builds the stable broker-grant template stored on the scheduled
  `awx-inventory-sync` plugin assignment.

  The returned payload intentionally omits `grant_id` and `expires_at`. Agent
  config delivery re-mints a short-lived persisted grant from the template so
  reconciles do not churn assignments just because a grant clock changed.
  """
  @spec inventory_sync_grant_template(Controller.t()) :: {:ok, map()} | {:error, term()}
  def inventory_sync_grant_template(%Controller{} = controller) do
    with :ok <- ensure_controller_dispatchable(controller) do
      controller
      |> credential_broker_grant_attrs("awx.inventory_sync")
      |> CredentialBrokerGrant.to_payload()
      |> Map.drop(["grant_id", "expires_at"])
      |> then(&{:ok, &1})
    end
  end

  ## Internals

  defp dispatch_verb(%Controller{} = controller, verb, args, opts) do
    with :ok <- ensure_controller_dispatchable(controller),
         {:ok, payload} <- build_payload(controller, verb, args, opts) do
      {bus, opts} = Keyword.pop(opts, :command_bus, AgentCommandBus)
      {_grant_issuer, opts} = Keyword.pop(opts, :grant_issuer)
      payload = CredentialRedactor.redact(payload)

      bus.dispatch(
        controller.agent_id,
        verb,
        payload,
        Keyword.merge(
          [
            ttl_seconds: @default_command_ttl_seconds,
            required_capability: @default_capability,
            source: :automation,
            context: %{
              "controller_id" => controller.id,
              "controller_name" => controller.name,
              "verb" => verb
            }
          ],
          opts
        )
      )
    end
  end

  defp ensure_controller_dispatchable(%Controller{} = controller) do
    cond do
      blank?(controller.agent_id) -> {:error, :controller_agent_id_missing}
      is_nil(controller.credential_secret_id) -> {:error, :controller_credential_missing}
      blank?(controller.base_url) -> {:error, :controller_base_url_missing}
      true -> :ok
    end
  end

  defp build_payload(%Controller{} = controller, verb, args, opts) do
    with {:ok, grant} <- credential_broker_grant(controller, verb, opts) do
      {:ok,
       %{
         "schema" => @payload_schema,
         "verb" => verb,
         "args" => args,
         "base_url" => controller.base_url,
         "controller_id" => controller.id,
         "controller_name" => controller.name,
         "insecure_skip_verify" => insecure_skip_verify?(controller),
         "credential_broker" => grant
       }}
    end
  end

  defp credential_broker_grant(%Controller{} = controller, verb, opts) do
    attrs = credential_broker_grant_attrs(controller, verb)
    issuer = Keyword.get(opts, :grant_issuer, &issue_persisted_grant/1)
    issuer.(attrs)
  end

  defp credential_broker_grant_attrs(%Controller{} = controller, verb) do
    inject = %{
      "type" => "http_header",
      "name" => "Authorization",
      "scheme" => "Bearer"
    }

    inject =
      if insecure_skip_verify?(controller) do
        Map.put(inject, "allow_insecure_tls", "true")
      else
        inject
      end

    %{
      secret_id: controller.credential_secret_id,
      secret_ref: SecretRefs.network_credential_ref(controller.credential_secret_id),
      grant_type: @grant_type,
      consumer_kind: :ansible,
      consumer_id: controller.id,
      purpose: verb,
      target_kind: "awx_controller",
      target_id: controller.id,
      agent_id: controller.agent_id,
      resolution_location: :agent,
      inject: inject,
      allowed_methods: allowed_methods_for(verb),
      allowed_hosts: allowed_hosts_for(controller.base_url),
      allowed_paths: ["/api/v2/"],
      ttl_seconds: @default_grant_ttl_seconds
    }
  end

  defp issue_persisted_grant(attrs) do
    attrs
    |> CredentialBrokerGrant.issue_attrs()
    |> CredentialBrokerGrant.issue_grant(
      actor: ServiceRadar.Actors.SystemActor.system(:awx_client)
    )
    |> case do
      {:ok, grant} -> {:ok, CredentialBrokerGrant.to_payload(grant)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp allowed_methods_for("awx.launch_job"), do: ["POST"]
  defp allowed_methods_for("awx.cancel_job"), do: ["POST"]
  defp allowed_methods_for(_), do: ["GET"]

  defp allowed_hosts_for(base_url) do
    case URI.parse(to_string(base_url)) do
      %URI{host: host} when is_binary(host) and host != "" -> [host]
      _ -> []
    end
  end

  defp insecure_skip_verify?(%Controller{metadata: meta}) when is_map(meta) do
    if Map.get(meta, "insecure_skip_verify") do
      true
    else
      false
    end
  end

  defp insecure_skip_verify?(_), do: false

  defp maybe_put(map, _key, value) when value in [nil, "", %{}, []], do: map

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_int!(map, key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      v when is_integer(v) -> v
      v -> raise ArgumentError, "expected integer at #{inspect(key)}, got #{inspect(v)}"
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
