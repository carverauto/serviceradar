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
  # AWX verbs run inside the awx WASM plugin, which reaches AWX through the
  # plugin runtime's `http_request` host function — not a raw agent session
  # capability. The command is dispatched to the controller's explicitly-bound
  # agent (which carries the awx plugin assignment), so gating on a session
  # capability the agent never advertises (agents advertise check types like
  # icmp/snmp, not plugin host functions) would reject every launch. nil skips
  # the session-capability gate; delivery still targets that specific agent.
  @default_capability nil

  @callback_binding_schema "serviceradar.awx_callback_credential_binding.v1"
  @callback_cleanup_binding_schema "serviceradar.awx_callback_credential_cleanup_binding.v1"
  @callback_credential_slot "ssh_ca_callback"
  @callback_credential_name_prefix "sr-callback-"
  @callback_common_binding_keys MapSet.new([
                                  "child_execution_id",
                                  "inventory_id",
                                  "job_template_id",
                                  "credential_type_id",
                                  "organization_id",
                                  "credential_slot",
                                  "injector_sha256"
                                ])
  @callback_create_binding_keys MapSet.put(@callback_common_binding_keys, "envelope_ref")
  @sha256_hex ~r/\A[a-f0-9]{64}\z/

  @typedoc "A `(job_id, since_id)` pair for `fetch_events_for_jobs/3`."
  @type job_event_pair :: %{required(:job_id) => integer(), required(:since_id) => integer()}

  @typedoc "Optional launch parameters for `launch_job/4`."
  @type launch_opts :: %{
          optional(:extra_vars) => map(),
          optional(:host_limit) => String.t() | nil,
          optional(:inventory_id) => integer() | nil,
          optional(:credential_ids) => [integer()],
          optional(:execution_environment_id) => integer() | nil,
          optional(:job_type) => String.t() | nil,
          optional(:diff_mode) => boolean() | nil,
          optional(:verbosity) => non_neg_integer() | nil,
          optional(:forks) => pos_integer() | nil,
          optional(:job_slice_count) => pos_integer() | nil,
          optional(:timeout) => pos_integer() | nil,
          optional(:job_tags) => String.t() | nil,
          optional(:skip_tags) => String.t() | nil,
          optional(:labels) => [integer()],
          optional(:instance_group_ids) => [integer()]
        }

  @typedoc "Non-secret binding for one single-resolution callback credential envelope."
  @type callback_credential_binding :: %{
          required(:envelope_ref) => String.t(),
          required(:child_execution_id) => String.t(),
          required(:inventory_id) => pos_integer(),
          required(:job_template_id) => pos_integer(),
          required(:credential_type_id) => pos_integer(),
          required(:organization_id) => pos_integer(),
          required(:credential_slot) => String.t(),
          required(:injector_sha256) => String.t()
        }

  @typedoc "Non-secret binding used only to delete one callback credential."
  @type callback_credential_cleanup_binding :: %{
          required(:child_execution_id) => String.t(),
          required(:inventory_id) => pos_integer(),
          required(:job_template_id) => pos_integer(),
          required(:credential_type_id) => pos_integer(),
          required(:organization_id) => pos_integer(),
          required(:credential_slot) => String.t(),
          required(:injector_sha256) => String.t()
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

  @spec list_inventory_groups(Controller.t(), integer(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def list_inventory_groups(controller, inventory_id, opts \\ []) when is_integer(inventory_id) do
    dispatch_verb(
      controller,
      "awx.list_inventory_groups",
      %{"inventory_id" => inventory_id},
      opts
    )
  end

  @spec current_user(Controller.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def current_user(controller, opts \\ []),
    do: dispatch_verb(controller, "awx.current_user", %{}, opts)

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
      |> maybe_put("credential_ids", Map.get(launch_opts, :credential_ids))
      |> maybe_put("execution_environment_id", Map.get(launch_opts, :execution_environment_id))
      |> maybe_put("job_type", Map.get(launch_opts, :job_type))
      |> maybe_put("diff_mode", Map.get(launch_opts, :diff_mode))
      |> maybe_put("verbosity", Map.get(launch_opts, :verbosity))
      |> maybe_put("forks", Map.get(launch_opts, :forks))
      |> maybe_put("job_slice_count", Map.get(launch_opts, :job_slice_count))
      |> maybe_put("timeout", Map.get(launch_opts, :timeout))
      |> maybe_put("job_tags", Map.get(launch_opts, :job_tags))
      |> maybe_put("skip_tags", Map.get(launch_opts, :skip_tags))
      |> maybe_put("labels", Map.get(launch_opts, :labels))
      |> maybe_put("instance_group_ids", Map.get(launch_opts, :instance_group_ids))

    dispatch_verb(controller, "awx.launch_job", args, opts)
  end

  @doc """
  Creates one reviewed ephemeral callback custom credential through the
  selected agent. The durable command carries only an opaque envelope
  reference and non-secret binding metadata. The callback bearer and
  idempotency key are resolved in memory by the agent and never enter this
  client, command payload, ordinary launch variables, or plugin config.

  Callers must preallocate `opts[:command_id]` before sealing the envelope. The
  selected agent supplies that actual `AgentCommand` ID to the resolver, which
  must reject an envelope sealed for any other command (especially the later
  `awx.launch_job` command).

  `organization_id` is mandatory integration metadata. Callers must snapshot
  the reviewed AWX organization alongside the custom credential type; this
  client never guesses or defaults it.
  """
  @spec create_callback_credential(
          Controller.t(),
          callback_credential_binding(),
          keyword()
        ) :: {:ok, struct()} | {:error, term()}
  def create_callback_credential(controller, binding, opts \\ []) when is_map(binding) do
    with {:ok, _command_id} <- preallocated_callback_command_id(opts),
         {:ok, binding, args} <- normalize_callback_credential_create_binding(controller, binding) do
      dispatch_verb(
        controller,
        "awx.create_callback_credential",
        args,
        Keyword.put(opts, :callback_credential_binding, binding)
      )
    end
  end

  @doc """
  Deletes one previously bound ephemeral callback credential. The AWX plugin
  first verifies the credential ID's deterministic name, custom type, and
  organization, and treats an already absent credential as successful cleanup.

  Deletion uses a dedicated cleanup-only binding with no launch-envelope
  reference. The selected agent validates this separate schema and never calls
  the credential-material resolver for the delete verb.
  """
  @spec delete_callback_credential(
          Controller.t(),
          pos_integer(),
          callback_credential_cleanup_binding(),
          keyword()
        ) :: {:ok, struct()} | {:error, term()}
  def delete_callback_credential(controller, credential_id, binding, opts \\ [])
      when is_integer(credential_id) and credential_id > 0 and is_map(binding) do
    with {:ok, binding, args} <-
           normalize_callback_credential_cleanup_binding(controller, binding) do
      dispatch_verb(
        controller,
        "awx.delete_callback_credential",
        args
        |> Map.delete("injector_sha256")
        |> Map.put("credential_id", credential_id),
        Keyword.put(opts, :callback_credential_binding, binding)
      )
    end
  end

  @doc "Fetches the deterministic callback credential without creating or mutating it."
  @spec fetch_callback_credential(Controller.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def fetch_callback_credential(controller, request, opts \\ []) when is_map(request) do
    args = %{
      "credential_type_id" => fetch_positive_int!(request, :credential_type_id),
      "organization_id" => fetch_positive_int!(request, :organization_id),
      "credential_name" => fetch_nonempty_string!(request, :credential_name)
    }

    dispatch_verb(controller, "awx.fetch_callback_credential", args, opts)
  end

  @spec fetch_job(Controller.t(), integer(), keyword()) :: {:ok, struct()} | {:error, term()}
  def fetch_job(controller, job_id, opts \\ []) when is_integer(job_id) do
    dispatch_verb(controller, "awx.fetch_job", %{"job_id" => job_id}, opts)
  end

  @spec fetch_job_host_summaries(Controller.t(), integer(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def fetch_job_host_summaries(controller, job_id, opts \\ []) when is_integer(job_id) do
    fetch_job_host_summaries(controller, job_id, 1_000, opts)
  end

  @spec fetch_job_host_summaries(Controller.t(), integer(), pos_integer(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def fetch_job_host_summaries(controller, job_id, max_hosts, opts)
      when is_integer(job_id) and is_integer(max_hosts) and max_hosts >= 1 and max_hosts <= 10_000 do
    dispatch_verb(
      controller,
      "awx.fetch_job_host_summaries",
      %{"job_id" => job_id, "max_hosts" => max_hosts},
      opts
    )
  end

  @doc """
  Enumerates a bounded AWX job window for dispatch-timeout reconciliation.

  The plugin does not claim server-side marker filtering. Callers must fetch
  and compare the retained `serviceradar_dispatch_id` and snapshot digest on
  each returned candidate. The AWX integration user ID is mandatory so a
  different AWX actor cannot be reconciled into the child execution.
  """
  @spec list_recent_jobs(Controller.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def list_recent_jobs(controller, filters, opts \\ []) when is_map(filters) do
    args = %{
      "template_id" => fetch_positive_int!(filters, :template_id),
      "inventory_id" => fetch_positive_int!(filters, :inventory_id),
      "created_by_id" => fetch_positive_int!(filters, :created_by_id),
      "created_after" => fetch_nonempty_string!(filters, :created_after),
      "page_size" => bounded_page_size(filters)
    }

    dispatch_verb(controller, "awx.list_recent_jobs", args, opts)
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
    {callback_credential_binding, dispatch_opts} =
      Keyword.pop(opts, :callback_credential_binding)

    with :ok <- ensure_controller_dispatchable(controller),
         {:ok, payload} <-
           build_payload(controller, verb, args, callback_credential_binding, dispatch_opts) do
      {bus, dispatch_opts} = Keyword.pop(dispatch_opts, :command_bus, AgentCommandBus)
      {_grant_issuer, dispatch_opts} = Keyword.pop(dispatch_opts, :grant_issuer)
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
          dispatch_opts
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

  defp build_payload(%Controller{} = controller, verb, args, callback_binding, opts) do
    with {:ok, grant} <- credential_broker_grant(controller, verb, args, opts) do
      {:ok,
       maybe_put(
         %{
           "schema" => @payload_schema,
           "verb" => verb,
           "args" => args,
           "base_url" => controller.base_url,
           "controller_id" => controller.id,
           "controller_name" => controller.name,
           "insecure_skip_verify" => insecure_skip_verify?(controller),
           "credential_broker" => grant
         },
         "callback_credential_binding",
         callback_binding
       )}
    end
  end

  defp credential_broker_grant(%Controller{} = controller, verb, args, opts) do
    attrs = credential_broker_grant_attrs(controller, verb, args)
    issuer = Keyword.get(opts, :grant_issuer, &issue_persisted_grant/1)
    issuer.(attrs)
  end

  defp credential_broker_grant_attrs(%Controller{} = controller, verb, args \\ %{}) do
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
      allowed_paths: allowed_paths_for(verb, args),
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
  defp allowed_methods_for("awx.create_callback_credential"), do: ["GET", "POST"]
  defp allowed_methods_for("awx.delete_callback_credential"), do: ["GET", "DELETE"]
  defp allowed_methods_for(_), do: ["GET"]

  defp allowed_paths_for("awx.create_callback_credential", args) do
    case Map.get(args, "credential_type_id") do
      credential_type_id when is_integer(credential_type_id) and credential_type_id > 0 ->
        ["=/api/v2/credential_types/#{credential_type_id}/", "=/api/v2/credentials/"]

      _ ->
        []
    end
  end

  defp allowed_paths_for("awx.delete_callback_credential", args) do
    case Map.get(args, "credential_id") do
      credential_id when is_integer(credential_id) and credential_id > 0 ->
        ["=/api/v2/credentials/#{credential_id}/"]

      _ ->
        []
    end
  end

  defp allowed_paths_for(_verb, _args), do: ["/api/v2/"]

  defp allowed_hosts_for(base_url) do
    case host_from_base_url(base_url) do
      host when is_binary(host) and host != "" -> [host]
      _ -> []
    end
  end

  # A base_url without a scheme (e.g. "awx.example.com") parses with host: nil
  # (the value lands in :path), which would yield an EMPTY allowed_hosts and a
  # host-unscoped grant. Re-parse with a default scheme so the grant stays
  # pinned to the controller host.
  defp host_from_base_url(base_url) do
    url = String.trim(to_string(base_url))

    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host

      _ when url != "" ->
        case URI.parse("https://" <> url) do
          %URI{host: host} when is_binary(host) and host != "" -> host
          _ -> nil
        end

      _ ->
        nil
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

  defp normalize_callback_credential_create_binding(%Controller{} = controller, binding) do
    with {:ok, binding} <-
           stringify_exact_callback_binding(binding, @callback_create_binding_keys),
         {:ok, child_execution_id} <- cast_uuid(binding["child_execution_id"]),
         {:ok, envelope_ref} <- opaque_envelope_ref(binding["envelope_ref"]),
         {:ok, common} <- normalize_callback_credential_common(binding, child_execution_id) do
      command_binding =
        common.command_binding
        |> Map.put("schema", @callback_binding_schema)
        |> Map.put("envelope_ref", envelope_ref)
        |> Map.put("dispatch_agent_id", controller.agent_id)
        |> Map.put("controller_id", controller.id)

      {:ok, command_binding, common.args}
    else
      {:error, _reason} -> {:error, :invalid_callback_credential_binding}
    end
  end

  defp normalize_callback_credential_cleanup_binding(%Controller{} = controller, binding) do
    with {:ok, binding} <-
           stringify_exact_callback_binding(binding, @callback_common_binding_keys),
         {:ok, child_execution_id} <- cast_uuid(binding["child_execution_id"]),
         {:ok, common} <- normalize_callback_credential_common(binding, child_execution_id) do
      command_binding =
        common.command_binding
        |> Map.put("schema", @callback_cleanup_binding_schema)
        |> Map.put("dispatch_agent_id", controller.agent_id)
        |> Map.put("controller_id", controller.id)

      {:ok, command_binding, common.args}
    else
      {:error, _reason} -> {:error, :invalid_callback_credential_binding}
    end
  end

  defp normalize_callback_credential_common(binding, child_execution_id) do
    with {:ok, inventory_id} <- positive_integer(binding["inventory_id"]),
         {:ok, job_template_id} <- positive_integer(binding["job_template_id"]),
         {:ok, credential_type_id} <- positive_integer(binding["credential_type_id"]),
         {:ok, organization_id} <- positive_integer(binding["organization_id"]),
         :ok <- exact_callback_slot(binding["credential_slot"]),
         :ok <- injector_sha256(binding["injector_sha256"]) do
      credential_name = @callback_credential_name_prefix <> child_execution_id

      args = %{
        "credential_type_id" => credential_type_id,
        "organization_id" => organization_id,
        "credential_name" => credential_name,
        "injector_sha256" => binding["injector_sha256"]
      }

      {:ok,
       %{
         command_binding: %{
           "child_execution_id" => child_execution_id,
           "inventory_id" => inventory_id,
           "job_template_id" => job_template_id,
           "credential_type_id" => credential_type_id,
           "organization_id" => organization_id,
           "credential_name" => credential_name,
           "credential_slot" => @callback_credential_slot,
           "injector_sha256" => binding["injector_sha256"]
         },
         args: args
       }}
    end
  end

  defp stringify_exact_callback_binding(binding, expected_keys) when is_map(binding) do
    keys = Enum.map(Map.keys(binding), &to_string/1)

    if length(keys) == MapSet.size(MapSet.new(keys)) and
         MapSet.new(keys) == expected_keys do
      {:ok, Map.new(binding, fn {key, value} -> {to_string(key), value} end)}
    else
      {:error, :unexpected_callback_binding_field}
    end
  end

  defp stringify_exact_callback_binding(_binding, _expected_keys),
    do: {:error, :invalid_callback_binding}

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_child_execution_id}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_child_execution_id}

  defp opaque_envelope_ref(value) when is_binary(value) and byte_size(value) in 16..512 do
    if Regex.match?(~r/\A[A-Za-z0-9._~:-]+\z/, value),
      do: {:ok, value},
      else: {:error, :invalid_envelope_ref}
  end

  defp opaque_envelope_ref(_value), do: {:error, :invalid_envelope_ref}

  defp positive_integer(value) when is_integer(value) and value > 0 and value <= 2_147_483_647,
    do: {:ok, value}

  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp exact_callback_slot(@callback_credential_slot), do: :ok
  defp exact_callback_slot(_slot), do: {:error, :invalid_callback_credential_slot}

  defp injector_sha256(value) when is_binary(value) do
    if Regex.match?(@sha256_hex, value),
      do: :ok,
      else: {:error, :invalid_callback_injector_sha256}
  end

  defp injector_sha256(_value), do: {:error, :invalid_callback_injector_sha256}

  defp preallocated_callback_command_id(opts) do
    case Keyword.get(opts, :command_id) do
      command_id when is_binary(command_id) ->
        case Ecto.UUID.cast(command_id) do
          {:ok, normalized} -> {:ok, normalized}
          :error -> {:error, :invalid_preallocated_callback_command_id}
        end

      _ ->
        {:error, :preallocated_callback_command_id_required}
    end
  end

  defp maybe_put(map, _key, value) when value in [nil, "", %{}, []], do: map

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_int!(map, key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      v when is_integer(v) -> v
      v -> raise ArgumentError, "expected integer at #{inspect(key)}, got #{inspect(v)}"
    end
  end

  defp fetch_positive_int!(map, key) do
    case fetch_int!(map, key) do
      value when value > 0 ->
        value

      value ->
        raise ArgumentError, "expected positive integer at #{inspect(key)}, got #{inspect(value)}"
    end
  end

  defp fetch_nonempty_string!(map, key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          raise ArgumentError, "expected non-empty string at #{inspect(key)}"
        else
          value
        end

      value ->
        raise ArgumentError, "expected string at #{inspect(key)}, got #{inspect(value)}"
    end
  end

  defp bounded_page_size(map) do
    case Map.get(map, :page_size) || Map.get(map, "page_size") || 50 do
      value when is_integer(value) and value in 1..100 -> value
      value -> raise ArgumentError, "expected page_size in 1..100, got #{inspect(value)}"
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
