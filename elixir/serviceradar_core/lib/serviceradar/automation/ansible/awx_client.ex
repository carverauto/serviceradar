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
  alias ServiceRadar.Automation.Ansible.VariableSchema
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Credentials.RequestBodyPolicy
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Plugins.SecretRefs

  @payload_schema "serviceradar.awx_command.v1"
  @grant_type "awx_oauth2_token"
  @default_grant_ttl_seconds 300
  @default_command_ttl_seconds 60
  @max_authorized_request_body_bytes 256 * 1024
  @max_launch_input_string_bytes 16 * 1024
  @max_launch_input_list_items 128
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

  @launch_arg_keys MapSet.new([
                     "template_id",
                     "extra_vars",
                     "host_limit",
                     "inventory_id",
                     "credential_ids",
                     "execution_environment_id",
                     "job_type",
                     "diff_mode",
                     "verbosity",
                     "forks",
                     "job_slice_count",
                     "timeout",
                     "job_tags",
                     "skip_tags",
                     "labels",
                     "instance_group_ids"
                   ])
  @launch_preflight_schema "serviceradar.awx_launch_preflight_request.v1"
  @launch_preflight_arg_keys MapSet.new([
                               "schema",
                               "controller_id",
                               "template_id",
                               "project_id",
                               "inventory_id",
                               "credential_ids",
                               "execution_environment_id",
                               "selected_hosts"
                             ])
  @launch_preflight_target_keys MapSet.new([
                                  "membership_id",
                                  "controller_id",
                                  "inventory_id",
                                  "awx_host_id",
                                  "canonical_device_uid",
                                  "host_name",
                                  "ansible_host",
                                  "enabled",
                                  "membership_generation",
                                  "source_fingerprint"
                                ])
  @max_launch_preflight_targets 128
  @max_launch_preflight_credentials 128
  @canonical_positive_decimal ~r/\A[1-9][0-9]{0,9}\z/
  @source_fingerprint ~r/\Asha256:[0-9a-f]{64}\z/
  @launch_body_key_map %{
    "extra_vars" => "extra_vars",
    "host_limit" => "limit",
    "inventory_id" => "inventory",
    "credential_ids" => "credentials",
    "execution_environment_id" => "execution_environment",
    "job_type" => "job_type",
    "diff_mode" => "diff_mode",
    "verbosity" => "verbosity",
    "forks" => "forks",
    "job_slice_count" => "job_slice_count",
    "timeout" => "timeout",
    "job_tags" => "job_tags",
    "skip_tags" => "skip_tags",
    "labels" => "labels",
    "instance_group_ids" => "instance_groups"
  }
  @callback_create_arg_keys MapSet.new(
                              ~w(credential_type_id organization_id credential_name injector_sha256)
                            )
  @callback_fetch_arg_keys MapSet.new(~w(credential_type_id organization_id credential_name))
  @callback_verify_arg_keys MapSet.new(
                              ~w(credential_id credential_type_id organization_id credential_name)
                            )
  @callback_list_arg_keys MapSet.new(
                            ~w(credential_type_id organization_id credential_name max_credentials)
                          )
  @callback_delete_arg_keys MapSet.new(
                              ~w(credential_id credential_type_id organization_id credential_name)
                            )
  @recent_job_arg_keys MapSet.new(
                         ~w(template_id inventory_id created_by_id created_after page_size max_candidates)
                       )
  @max_recent_job_candidates 5_000
  @max_callback_credentials 5_000
  @event_pair_keys MapSet.new(~w(job_id since_id))
  @max_event_batch_size 10
  @reserved_dispatch_vars ~w(serviceradar_dispatch_id serviceradar_snapshot_digest)

  @sync_verbs MapSet.new([
                "awx.ping",
                "awx.list_inventories",
                "awx.list_hosts",
                "awx.list_inventory_groups",
                "awx.current_user",
                "awx.list_projects",
                "awx.list_templates",
                "awx.fetch_template",
                "awx.inventory_sync"
              ])
  @execution_verbs MapSet.new([
                     "awx.fetch_launch_preflight",
                     "awx.launch_job",
                     "awx.fetch_job",
                     "awx.fetch_job_host_summaries",
                     "awx.list_recent_jobs",
                     "awx.cancel_job",
                     "awx.fetch_events_for_jobs"
                   ])
  @callback_verbs MapSet.new([
                    "awx.create_callback_credential",
                    "awx.fetch_callback_credential",
                    "awx.verify_callback_credential",
                    "awx.list_callback_credentials",
                    "awx.delete_callback_credential"
                  ])

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

  @doc """
  Resolves the numeric AWX identity of the execution principal.

  This is the only API allowed to run the sanitized `awx.current_user` verb
  with a non-sync credential. It is used when review evidence must pin the
  exact principal that will launch a job. The broker grant remains limited to
  `GET /api/v2/me/`; callers cannot supply a general credential-purpose
  override.
  """
  @spec current_execution_user(Controller.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def current_execution_user(controller, opts \\ []),
    do: dispatch_verb_for_purpose(controller, "awx.current_user", %{}, :execution, opts)

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
  Fetches one bounded, redacted AWX launch preflight through the controller's
  assigned edge agent.

  `request` is an internal, server-built contract. It contains only reviewed
  selectors and exact current membership identity; it never accepts an AWX
  credential, arbitrary controller path, or result-selected host identity.
  Numeric AWX IDs remain canonical decimal strings so the contract can be
  canonically digested without JSON number-format ambiguity.
  """
  @spec fetch_launch_preflight(Controller.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def fetch_launch_preflight(controller, request, opts \\ [])

  def fetch_launch_preflight(controller, request, opts) when is_map(request) do
    with {:ok, args} <- normalize_launch_preflight_request(request),
         :ok <- exact_preflight_controller(controller, args["controller_id"]) do
      dispatch_verb(controller, "awx.fetch_launch_preflight", args, opts)
    end
  end

  def fetch_launch_preflight(_controller, _request, _opts),
    do: {:error, :invalid_awx_launch_preflight_request}

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

  @doc "Verifies one controller-observed callback credential by exact ID and immutable scope."
  @spec verify_callback_credential(Controller.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def verify_callback_credential(controller, request, opts \\ []) when is_map(request) do
    args = %{
      "credential_id" => fetch_positive_int!(request, :credential_id),
      "credential_type_id" => fetch_positive_int!(request, :credential_type_id),
      "organization_id" => fetch_positive_int!(request, :organization_id),
      "credential_name" => fetch_nonempty_string!(request, :credential_name)
    }

    dispatch_verb(controller, "awx.verify_callback_credential", args, opts)
  end

  @doc "Lists the complete bounded set in one exact deterministic callback credential scope."
  @spec list_callback_credentials(Controller.t(), map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def list_callback_credentials(controller, request, opts \\ []) when is_map(request) do
    args = %{
      "credential_type_id" => fetch_positive_int!(request, :credential_type_id),
      "organization_id" => fetch_positive_int!(request, :organization_id),
      "credential_name" => fetch_nonempty_string!(request, :credential_name),
      "max_credentials" =>
        fetch_bounded_positive_int!(request, :max_credentials, @max_callback_credentials)
    }

    dispatch_verb(controller, "awx.list_callback_credentials", args, opts)
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
      "page_size" => bounded_page_size(filters),
      "max_candidates" => durable_recent_job_bound(filters)
    }

    dispatch_verb(controller, "awx.list_recent_jobs", args, opts)
  end

  @spec cancel_job(Controller.t(), integer(), keyword()) :: {:ok, struct()} | {:error, term()}
  def cancel_job(controller, job_id, opts \\ []) when is_integer(job_id) do
    dispatch_verb(controller, "awx.cancel_job", %{"job_id" => job_id}, opts)
  end

  @doc """
  Bulk fetch new events for one or more active jobs.

  This is the verb `RunPulseWorker` ticks against. Each command accepts at
  most #{@max_event_batch_size} jobs; the worker chunks larger active-run
  sets into multiple bounded commands. See `add-ansible-integration`
  design.md decision 6.
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
    with {:ok, secret_id} <- dispatch_credential(controller, "awx.inventory_sync", nil),
         {:ok, scope} <- broker_scope(controller.base_url, "awx.inventory_sync", %{}) do
      controller
      |> credential_broker_grant_attrs("awx.inventory_sync", secret_id, scope)
      |> CredentialBrokerGrant.to_payload()
      |> Map.drop(["grant_id", "expires_at"])
      |> then(&{:ok, &1})
    end
  end

  @doc """
  Returns the normalized controller endpoint and fail-closed HTTP scope for a
  supported AWX verb.

  This is public because the durable callback-command verifier must derive the
  exact same boundary as command issuance. A controller URL must be an
  origin-only HTTP(S) URL: credentials, paths, queries, fragments, unknown
  schemes, empty hosts, and ports outside `1..65535` are rejected. The
  effective port is always explicit in the returned grant scope (443 for HTTPS
  and 80 for HTTP when omitted by the operator).
  """
  @spec broker_scope(String.t(), String.t(), map()) ::
          {:ok,
           %{
             base_url: String.t(),
             allow: map(),
             allowed_hosts: [String.t()],
             allowed_schemes: [String.t()],
             allowed_methods: [String.t()],
             allowed_paths: [String.t()],
             allowed_ports: [pos_integer()],
             request_body_policy: map(),
             authorized_request_body_b64: String.t() | nil
           }}
          | {:error, :invalid_controller_base_url | :invalid_awx_broker_scope}
  def broker_scope(base_url, verb, args) when is_binary(verb) and is_map(args) do
    with {:ok, endpoint} <- normalize_controller_endpoint(base_url),
         [_ | _] = methods <- allowed_methods_for(verb),
         [_ | _] = paths <- allowed_paths_for(verb, args),
         {:ok, body_binding} <- request_body_binding_for(verb, args) do
      allow =
        maybe_put(
          %{
            "methods" => methods,
            "paths" => paths,
            "hosts" => [endpoint.host],
            "ports" => [endpoint.port],
            "schemes" => [endpoint.scheme]
          },
          "request_body",
          body_binding.policy
        )

      {:ok,
       %{
         base_url: endpoint.base_url,
         allow: allow,
         allowed_methods: methods,
         allowed_paths: paths,
         allowed_hosts: [endpoint.host],
         allowed_ports: [endpoint.port],
         allowed_schemes: [endpoint.scheme],
         request_body_policy: body_binding.policy,
         authorized_request_body_b64: body_binding.authorized_request_body_b64
       }}
    else
      [] -> {:error, :invalid_awx_broker_scope}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_awx_broker_scope}
    end
  end

  def broker_scope(_base_url, _verb, _args), do: {:error, :invalid_awx_broker_scope}

  @doc "Returns the explicit purpose assigned to a supported AWX verb."
  @spec credential_purpose_for_verb(String.t()) ::
          {:ok, Controller.credential_purpose()} | {:error, :unsupported_awx_verb}
  def credential_purpose_for_verb(verb) when is_binary(verb) do
    cond do
      MapSet.member?(@sync_verbs, verb) -> {:ok, :sync}
      MapSet.member?(@execution_verbs, verb) -> {:ok, :execution}
      MapSet.member?(@callback_verbs, verb) -> {:ok, :callback}
      true -> {:error, :unsupported_awx_verb}
    end
  end

  def credential_purpose_for_verb(_verb), do: {:error, :unsupported_awx_verb}

  @doc "Returns the controller secret selected for an exact supported AWX verb."
  @spec credential_secret_id_for_verb(map(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def credential_secret_id_for_verb(controller, verb)
      when is_map(controller) and is_binary(verb) do
    with {:ok, purpose} <- credential_purpose_for_verb(verb) do
      Controller.credential_secret_id_for(controller, purpose)
    end
  end

  def credential_secret_id_for_verb(_controller, _verb), do: {:error, :unsupported_awx_verb}

  ## Internals

  defp dispatch_verb(%Controller{} = controller, verb, args, opts) do
    if Keyword.has_key?(opts, :credential_purpose) do
      {:error, :credential_purpose_override_not_allowed}
    else
      do_dispatch_verb(controller, verb, args, nil, opts)
    end
  end

  defp dispatch_verb_for_purpose(
         %Controller{} = controller,
         "awx.current_user" = verb,
         args,
         :execution,
         opts
       ) do
    if Keyword.has_key?(opts, :credential_purpose) do
      {:error, :credential_purpose_override_not_allowed}
    else
      do_dispatch_verb(controller, verb, args, :execution, opts)
    end
  end

  defp do_dispatch_verb(%Controller{} = controller, verb, args, credential_purpose, opts) do
    {callback_credential_binding, dispatch_opts} =
      Keyword.pop(opts, :callback_credential_binding)

    with {:ok, secret_id} <- dispatch_credential(controller, verb, credential_purpose),
         {:ok, scope} <- broker_scope(controller.base_url, verb, args),
         {:ok, payload} <-
           build_payload(
             controller,
             verb,
             args,
             callback_credential_binding,
             secret_id,
             scope,
             dispatch_opts
           ) do
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

  defp dispatch_credential(%Controller{} = controller, verb, credential_purpose) do
    cond do
      blank?(controller.agent_id) ->
        {:error, :controller_agent_id_missing}

      blank?(controller.base_url) ->
        {:error, :controller_base_url_missing}

      is_nil(credential_purpose) ->
        credential_secret_id_for_verb(controller, verb)

      verb == "awx.current_user" and credential_purpose == :execution ->
        Controller.credential_secret_id_for(controller, :execution)

      true ->
        {:error, :credential_purpose_override_not_allowed}
    end
  end

  defp build_payload(
         %Controller{} = controller,
         verb,
         args,
         callback_binding,
         secret_id,
         scope,
         opts
       ) do
    with {:ok, grant} <- credential_broker_grant(controller, verb, secret_id, scope, opts) do
      {:ok,
       %{
         "schema" => @payload_schema,
         "verb" => verb,
         "args" => args,
         "base_url" => scope.base_url,
         "controller_id" => controller.id,
         "controller_name" => controller.name,
         "insecure_skip_verify" => insecure_skip_verify?(controller),
         "credential_broker" => grant
       }
       |> maybe_put(
         "authorized_request_body_b64",
         scope.authorized_request_body_b64
       )
       |> maybe_put(
         "callback_credential_binding",
         callback_binding
       )}
    end
  end

  defp credential_broker_grant(%Controller{} = controller, verb, secret_id, scope, opts) do
    attrs = credential_broker_grant_attrs(controller, verb, secret_id, scope)
    issuer = Keyword.get(opts, :grant_issuer, &issue_persisted_grant/1)
    issuer.(attrs)
  end

  defp credential_broker_grant_attrs(%Controller{} = controller, verb, secret_id, scope) do
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
      secret_id: secret_id,
      secret_ref: SecretRefs.network_credential_ref(secret_id),
      grant_type: @grant_type,
      consumer_kind: :ansible,
      consumer_id: controller.id,
      purpose: verb,
      target_kind: "awx_controller",
      target_id: controller.id,
      agent_id: controller.agent_id,
      resolution_location: :agent,
      inject: inject,
      allowed_methods: scope.allowed_methods,
      allowed_hosts: scope.allowed_hosts,
      allowed_paths: scope.allowed_paths,
      allowed_ports: scope.allowed_ports,
      allowed_schemes: scope.allowed_schemes,
      request_body_policy: scope.request_body_policy,
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

  defp allowed_methods_for(verb)
       when verb in [
              "awx.ping",
              "awx.list_inventories",
              "awx.list_hosts",
              "awx.list_inventory_groups",
              "awx.current_user",
              "awx.list_projects",
              "awx.list_templates",
              "awx.fetch_template",
              "awx.fetch_launch_preflight",
              "awx.inventory_sync",
              "awx.fetch_callback_credential",
              "awx.verify_callback_credential",
              "awx.list_callback_credentials",
              "awx.fetch_job",
              "awx.fetch_job_host_summaries",
              "awx.list_recent_jobs",
              "awx.fetch_events_for_jobs"
            ],
       do: ["GET"]

  defp allowed_methods_for(_verb), do: []

  defp allowed_paths_for("awx.ping", args) do
    if empty_args?(args), do: ["=/api/v2/ping/"], else: []
  end

  defp allowed_paths_for("awx.list_inventories", args) do
    if empty_args?(args), do: ["=/api/v2/inventories/"], else: []
  end

  defp allowed_paths_for("awx.list_projects", args) do
    if empty_args?(args), do: ["=/api/v2/projects/"], else: []
  end

  defp allowed_paths_for("awx.list_templates", args) do
    if empty_args?(args), do: ["=/api/v2/job_templates/"], else: []
  end

  defp allowed_paths_for("awx.current_user", args) do
    if empty_args?(args), do: ["=/api/v2/me/"], else: []
  end

  defp allowed_paths_for("awx.inventory_sync", args) do
    if empty_args?(args) do
      ["=/api/v2/inventories/", "/api/v2/inventories/*"]
    else
      []
    end
  end

  defp allowed_paths_for("awx.list_hosts", args) do
    case exact_positive_arg(args, ~w(inventory_id), "inventory_id") do
      {:ok, inventory_id} -> ["=/api/v2/inventories/#{inventory_id}/hosts/"]
      _ -> []
    end
  end

  defp allowed_paths_for("awx.list_inventory_groups", args) do
    case exact_positive_arg(args, ~w(inventory_id), "inventory_id") do
      {:ok, inventory_id} -> ["=/api/v2/inventories/#{inventory_id}/groups/"]
      _ -> []
    end
  end

  defp allowed_paths_for("awx.fetch_template", args) do
    case exact_positive_arg(args, ~w(template_id), "template_id") do
      {:ok, template_id} ->
        [
          "=/api/v2/job_templates/#{template_id}/",
          "=/api/v2/job_templates/#{template_id}/survey_spec/"
        ]

      _ ->
        []
    end
  end

  defp allowed_paths_for("awx.fetch_launch_preflight", args) do
    case normalize_launch_preflight_request(args) do
      {:ok, request} ->
        credential_paths = Enum.map(request["credential_ids"], &"=/api/v2/credentials/#{&1}/")

        host_paths = Enum.map(request["selected_hosts"], &"=/api/v2/hosts/#{&1["awx_host_id"]}/")

        [
          "=/api/v2/job_templates/#{request["template_id"]}/",
          "=/api/v2/job_templates/#{request["template_id"]}/survey_spec/",
          "=/api/v2/projects/#{request["project_id"]}/",
          "=/api/v2/inventories/#{request["inventory_id"]}/",
          "=/api/v2/execution_environments/#{request["execution_environment_id"]}/"
          | credential_paths ++ host_paths
        ]

      _ ->
        []
    end
  end

  defp allowed_paths_for("awx.launch_job", args) do
    with true <- valid_launch_args?(args),
         {:ok, template_id} <- positive_arg(args, "template_id") do
      ["=/api/v2/job_templates/#{template_id}/launch/"]
    else
      _ -> []
    end
  end

  defp allowed_paths_for("awx.fetch_job", args) do
    case exact_positive_arg(args, ~w(job_id), "job_id") do
      {:ok, job_id} -> ["=/api/v2/jobs/#{job_id}/"]
      _ -> []
    end
  end

  defp allowed_paths_for("awx.fetch_job_host_summaries", args) do
    with true <- exact_arg_keys?(args, ~w(job_id max_hosts)),
         {:ok, job_id} <- positive_arg(args, "job_id"),
         max_hosts when is_integer(max_hosts) and max_hosts in 1..10_000 <-
           Map.get(args, "max_hosts") do
      ["=/api/v2/jobs/#{job_id}/job_host_summaries/"]
    else
      _ -> []
    end
  end

  defp allowed_paths_for("awx.list_recent_jobs", args) do
    with true <- exact_arg_keys?(args, @recent_job_arg_keys),
         {:ok, _template_id} <- positive_arg(args, "template_id"),
         {:ok, _inventory_id} <- positive_arg(args, "inventory_id"),
         {:ok, _created_by_id} <- positive_arg(args, "created_by_id"),
         created_after when is_binary(created_after) and created_after != "" <-
           Map.get(args, "created_after"),
         {:ok, _datetime, _offset} <- DateTime.from_iso8601(created_after),
         page_size when is_integer(page_size) and page_size in 1..100 <-
           Map.get(args, "page_size"),
         max_candidates
         when is_integer(max_candidates) and
                max_candidates in 1..@max_recent_job_candidates <-
           Map.get(args, "max_candidates") do
      ["=/api/v2/jobs/"]
    else
      _ -> []
    end
  end

  defp allowed_paths_for("awx.cancel_job", args) do
    case exact_positive_arg(args, ~w(job_id), "job_id") do
      {:ok, job_id} -> ["=/api/v2/jobs/#{job_id}/cancel/"]
      _ -> []
    end
  end

  defp allowed_paths_for("awx.fetch_events_for_jobs", args) do
    with true <- exact_arg_keys?(args, ~w(pairs)),
         pairs when is_list(pairs) and length(pairs) in 1..@max_event_batch_size <-
           Map.get(args, "pairs"),
         true <- Enum.all?(pairs, &valid_event_pair?/1),
         true <- unique_event_job_ids?(pairs) do
      pairs
      |> Enum.map(&Map.fetch!(&1, "job_id"))
      |> Enum.map(&"=/api/v2/jobs/#{&1}/job_events/")
    else
      _ -> []
    end
  end

  defp allowed_paths_for("awx.create_callback_credential", args) do
    with true <- exact_arg_keys?(args, @callback_create_arg_keys),
         {:ok, credential_type_id} <- positive_arg(args, "credential_type_id"),
         {:ok, _organization_id} <- positive_arg(args, "organization_id"),
         true <- bounded_nonempty_string?(Map.get(args, "credential_name"), 128),
         injector_sha256 when is_binary(injector_sha256) <- Map.get(args, "injector_sha256"),
         true <- Regex.match?(@sha256_hex, injector_sha256) do
      ["=/api/v2/credential_types/#{credential_type_id}/", "=/api/v2/credentials/"]
    else
      _ -> []
    end
  end

  defp allowed_paths_for("awx.fetch_callback_credential", args) do
    with true <- exact_arg_keys?(args, @callback_fetch_arg_keys),
         {:ok, _credential_type_id} <- positive_arg(args, "credential_type_id"),
         {:ok, _organization_id} <- positive_arg(args, "organization_id"),
         true <- bounded_nonempty_string?(Map.get(args, "credential_name"), 128) do
      ["=/api/v2/credentials/"]
    else
      _ -> []
    end
  end

  defp allowed_paths_for("awx.verify_callback_credential", args) do
    with true <- exact_arg_keys?(args, @callback_verify_arg_keys),
         {:ok, credential_id} <- positive_arg(args, "credential_id"),
         {:ok, _credential_type_id} <- positive_arg(args, "credential_type_id"),
         {:ok, _organization_id} <- positive_arg(args, "organization_id"),
         true <- bounded_nonempty_string?(Map.get(args, "credential_name"), 128) do
      ["=/api/v2/credentials/#{credential_id}/"]
    else
      _ -> []
    end
  end

  defp allowed_paths_for("awx.list_callback_credentials", args) do
    with true <- exact_arg_keys?(args, @callback_list_arg_keys),
         {:ok, _credential_type_id} <- positive_arg(args, "credential_type_id"),
         {:ok, _organization_id} <- positive_arg(args, "organization_id"),
         true <- bounded_nonempty_string?(Map.get(args, "credential_name"), 128),
         max_credentials
         when is_integer(max_credentials) and
                max_credentials in 1..@max_callback_credentials <-
           Map.get(args, "max_credentials") do
      ["=/api/v2/credentials/"]
    else
      _ -> []
    end
  end

  defp allowed_paths_for("awx.delete_callback_credential", args) do
    with true <- exact_arg_keys?(args, @callback_delete_arg_keys),
         {:ok, credential_id} <- positive_arg(args, "credential_id"),
         {:ok, _credential_type_id} <- positive_arg(args, "credential_type_id"),
         {:ok, _organization_id} <- positive_arg(args, "organization_id"),
         true <- bounded_nonempty_string?(Map.get(args, "credential_name"), 128) do
      ["=/api/v2/credentials/#{credential_id}/"]
    else
      _ -> []
    end
  end

  defp allowed_paths_for(_verb, _args), do: []

  defp normalize_controller_endpoint(base_url) when is_binary(base_url) do
    base_url = String.trim(base_url)

    with true <- base_url != "",
         {:ok, %URI{} = uri} <- URI.new(base_url),
         scheme when scheme in ["http", "https"] <- String.downcase(uri.scheme || ""),
         host when is_binary(host) and host != "" <- uri.host,
         true <- valid_controller_host?(host),
         true <- is_nil(uri.userinfo),
         true <- uri.path in [nil, "", "/"],
         true <- is_nil(uri.query) and is_nil(uri.fragment),
         port when is_integer(port) and port in 1..65_535 <- uri.port do
      normalized_uri = %{
        uri
        | scheme: scheme,
          host: String.downcase(host),
          path: nil,
          query: nil,
          fragment: nil,
          userinfo: nil
      }

      {:ok,
       %{
         base_url: URI.to_string(normalized_uri),
         scheme: scheme,
         host: normalized_uri.host,
         port: port
       }}
    else
      _ -> {:error, :invalid_controller_base_url}
    end
  end

  defp normalize_controller_endpoint(_base_url), do: {:error, :invalid_controller_base_url}

  defp valid_controller_host?(host) do
    String.trim(host) == host and not Regex.match?(~r/\s/u, host)
  end

  defp empty_args?(args), do: is_map(args) and map_size(args) == 0

  defp exact_arg_keys?(args, expected) when is_map(args) do
    MapSet.new(Map.keys(args)) == MapSet.new(expected)
  end

  defp exact_arg_keys?(_args, _expected), do: false

  defp subset_arg_keys?(args, expected) when is_map(args) do
    keys = MapSet.new(Map.keys(args))
    MapSet.member?(keys, "template_id") and MapSet.subset?(keys, expected)
  end

  defp subset_arg_keys?(_args, _expected), do: false

  defp exact_positive_arg(args, expected_keys, key) do
    if exact_arg_keys?(args, expected_keys), do: positive_arg(args, key), else: :error
  end

  defp positive_arg(args, key) when is_map(args) do
    positive_integer(Map.get(args, key))
  end

  defp positive_arg(_args, _key), do: {:error, :invalid_positive_integer}

  defp valid_event_pair?(pair) when is_map(pair) do
    exact_arg_keys?(pair, @event_pair_keys) and
      match?({:ok, _job_id}, positive_arg(pair, "job_id")) and
      is_integer(Map.get(pair, "since_id")) and Map.get(pair, "since_id") in 0..2_147_483_647
  end

  defp valid_event_pair?(_pair), do: false

  defp unique_event_job_ids?(pairs) do
    job_ids = Enum.map(pairs, &Map.fetch!(&1, "job_id"))
    Enum.uniq(job_ids) == job_ids
  end

  defp bounded_nonempty_string?(value, max_bytes) when is_binary(value) do
    String.trim(value) != "" and byte_size(value) <= max_bytes
  end

  defp bounded_nonempty_string?(_value, _max_bytes), do: false

  defp valid_launch_args?(args) when is_map(args) do
    subset_arg_keys?(args, @launch_arg_keys) and
      match?({:ok, _template_id}, positive_arg(args, "template_id")) and
      optional_arg?(args, "extra_vars", &valid_launch_extra_vars?/1) and
      optional_arg?(args, "host_limit", &bounded_nonempty_string?(&1, 16 * 1024)) and
      optional_arg?(args, "inventory_id", &positive_integer_value?/1) and
      optional_arg?(args, "credential_ids", &valid_launch_id_list?/1) and
      optional_arg?(args, "execution_environment_id", &positive_integer_value?/1) and
      optional_arg?(args, "job_type", &(&1 in ["run", "check"])) and
      optional_arg?(args, "diff_mode", &is_boolean/1) and
      optional_arg?(args, "verbosity", &(is_integer(&1) and &1 in 0..5)) and
      optional_arg?(args, "forks", &(is_integer(&1) and &1 in 1..10_000)) and
      optional_arg?(args, "job_slice_count", &(is_integer(&1) and &1 in 1..10_000)) and
      optional_arg?(args, "timeout", &(is_integer(&1) and &1 in 1..604_800)) and
      optional_arg?(args, "job_tags", &bounded_string?(&1, 4 * 1024)) and
      optional_arg?(args, "skip_tags", &bounded_string?(&1, 4 * 1024)) and
      optional_arg?(args, "labels", &valid_launch_id_list?/1) and
      optional_arg?(args, "instance_group_ids", &valid_launch_id_list?/1)
  end

  defp valid_launch_args?(_args), do: false

  defp normalize_launch_preflight_request(request) when is_map(request) do
    with {:ok, request} <- stringify_exact_launch_preflight_request(request),
         true <- request["schema"] == @launch_preflight_schema,
         {:ok, controller_id} <- canonical_uuid(request["controller_id"]),
         :ok <- canonical_positive_decimal(request["template_id"]),
         :ok <- canonical_positive_decimal(request["project_id"]),
         :ok <- canonical_positive_decimal(request["inventory_id"]),
         :ok <- canonical_positive_decimal(request["execution_environment_id"]),
         {:ok, credential_ids} <- canonical_credential_ids(request["credential_ids"]),
         {:ok, selected_hosts} <-
           canonical_preflight_targets(
             request["selected_hosts"],
             controller_id,
             request["inventory_id"]
           ) do
      {:ok,
       request
       |> Map.put("controller_id", controller_id)
       |> Map.put("credential_ids", credential_ids)
       |> Map.put("selected_hosts", selected_hosts)}
    else
      _ -> {:error, :invalid_awx_launch_preflight_request}
    end
  end

  defp normalize_launch_preflight_request(_request),
    do: {:error, :invalid_awx_launch_preflight_request}

  defp exact_preflight_controller(%Controller{} = controller, controller_id) do
    case canonical_uuid(controller.id) do
      {:ok, canonical_controller_id} ->
        if canonical_controller_id == controller_id,
          do: :ok,
          else: {:error, :controller_launch_preflight_identity_mismatch}

      _ ->
        {:error, :controller_launch_preflight_identity_invalid}
    end
  end

  defp exact_preflight_controller(_controller, _controller_id),
    do: {:error, :controller_launch_preflight_identity_invalid}

  defp stringify_exact_launch_preflight_request(request) do
    normalized =
      Enum.reduce_while(request, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case canonical_map_key(key) do
          {:ok, normalized_key} ->
            if Map.has_key?(acc, normalized_key) do
              {:halt, {:error, :duplicate_awx_launch_preflight_key}}
            else
              {:cont, {:ok, Map.put(acc, normalized_key, value)}}
            end

          :error ->
            {:halt, {:error, :invalid_awx_launch_preflight_key}}
        end
      end)

    with {:ok, normalized} <- normalized,
         true <- MapSet.new(Map.keys(normalized)) == @launch_preflight_arg_keys do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_awx_launch_preflight_request}
    end
  end

  defp canonical_credential_ids(ids) when is_list(ids) do
    with true <- length(ids) <= @max_launch_preflight_credentials,
         true <- Enum.all?(ids, &(canonical_positive_decimal(&1) == :ok)),
         true <- ids == Enum.sort_by(ids, &String.to_integer/1),
         true <- ids == Enum.uniq(ids) do
      {:ok, ids}
    else
      _ -> {:error, :invalid_awx_launch_preflight_credentials}
    end
  end

  defp canonical_credential_ids(_ids), do: {:error, :invalid_awx_launch_preflight_credentials}

  defp canonical_preflight_targets(targets, controller_id, inventory_id)
       when is_list(targets) and length(targets) in 1..@max_launch_preflight_targets do
    with {:ok, normalized} <-
           Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
             case canonical_preflight_target(target, controller_id, inventory_id) do
               {:ok, normalized_target} -> {:cont, {:ok, [normalized_target | acc]}}
               {:error, _reason} = error -> {:halt, error}
             end
           end),
         normalized = Enum.reverse(normalized),
         true <- normalized == Enum.sort_by(normalized, &String.to_integer(&1["awx_host_id"])),
         true <- unique_preflight_target_ids?(normalized) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_awx_launch_preflight_targets}
    end
  end

  defp canonical_preflight_targets(_targets, _controller_id, _inventory_id),
    do: {:error, :invalid_awx_launch_preflight_targets}

  defp canonical_preflight_target(target, controller_id, inventory_id) when is_map(target) do
    with {:ok, target} <- stringify_exact_preflight_target(target),
         {:ok, membership_id} <- canonical_uuid(target["membership_id"]),
         true <- target["controller_id"] == controller_id,
         true <- target["inventory_id"] == inventory_id,
         :ok <- canonical_positive_decimal(target["awx_host_id"]),
         :ok <- canonical_positive_decimal(target["membership_generation"]),
         :ok <- safe_launch_preflight_text(target["canonical_device_uid"], 1_024),
         :ok <- canonical_preflight_host_name(target["host_name"]),
         :ok <- canonical_preflight_address(target["ansible_host"]),
         true <- target["enabled"] == true,
         true <-
           is_binary(target["source_fingerprint"]) and
             Regex.match?(@source_fingerprint, target["source_fingerprint"]) do
      {:ok, Map.put(target, "membership_id", membership_id)}
    else
      _ -> {:error, :invalid_awx_launch_preflight_target}
    end
  end

  defp canonical_preflight_target(_target, _controller_id, _inventory_id),
    do: {:error, :invalid_awx_launch_preflight_target}

  defp stringify_exact_preflight_target(target) do
    normalized =
      Enum.reduce_while(target, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case canonical_map_key(key) do
          {:ok, normalized_key} ->
            if Map.has_key?(acc, normalized_key) do
              {:halt, {:error, :duplicate_awx_launch_preflight_target_key}}
            else
              {:cont, {:ok, Map.put(acc, normalized_key, value)}}
            end

          :error ->
            {:halt, {:error, :invalid_awx_launch_preflight_target_key}}
        end
      end)

    with {:ok, normalized} <- normalized,
         true <- MapSet.new(Map.keys(normalized)) == @launch_preflight_target_keys do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_awx_launch_preflight_target}
    end
  end

  defp unique_preflight_target_ids?(targets) do
    host_ids = Enum.map(targets, & &1["awx_host_id"])
    membership_ids = Enum.map(targets, & &1["membership_id"])

    length(host_ids) == length(Enum.uniq(host_ids)) and
      length(membership_ids) == length(Enum.uniq(membership_ids))
  end

  defp canonical_positive_decimal(value) when is_binary(value) do
    if Regex.match?(@canonical_positive_decimal, value) and
         String.to_integer(value) <= 2_147_483_647,
       do: :ok,
       else: :error
  end

  defp canonical_positive_decimal(_value), do: :error

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid_uuid}

  defp canonical_map_key(key) when is_binary(key), do: {:ok, key}
  defp canonical_map_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp canonical_map_key(_key), do: :error

  defp canonical_preflight_host_name(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if normalized == value and
         byte_size(normalized) <= 255 and
         normalized not in ["", "all", "ungrouped"] and
         Regex.match?(~r/\A[a-z0-9][a-z0-9._-]*\z/, normalized),
       do: :ok,
       else: :error
  end

  defp canonical_preflight_host_name(_value), do: :error

  defp canonical_preflight_address(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> unbracket_preflight_address()
      |> normalize_preflight_address()

    if normalized == value, do: :ok, else: :error
  end

  defp canonical_preflight_address(_value), do: :error

  defp unbracket_preflight_address("[" <> rest) do
    if String.ends_with?(rest, "]"),
      do: String.trim_trailing(rest, "]"),
      else: "[" <> rest
  end

  defp unbracket_preflight_address(value), do: value

  defp normalize_preflight_address(value) when is_binary(value) do
    case safe_launch_preflight_text(value, 255) do
      :error ->
        :invalid

      :ok ->
        cond do
          String.contains?(value, ["/", "\\", "@", "?", "#", "%"]) ->
            :invalid

          String.contains?(value, ":") ->
            if Regex.match?(~r/\A[0-9A-Fa-f:.]+\z/, value),
              do: String.downcase(value),
              else: :invalid

          true ->
            normalized = value |> String.downcase() |> String.trim_trailing(".")

            if normalized != "" and
                 not String.contains?(normalized, "..") and
                 Regex.match?(~r/\A[a-z0-9._-]+\z/, normalized),
               do: normalized,
               else: :invalid
        end
    end
  end

  defp safe_launch_preflight_text(value, max_bytes)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max_bytes do
    if String.valid?(value) and not String.match?(value, ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u),
      do: :ok,
      else: :error
  end

  defp safe_launch_preflight_text(_value, _max_bytes), do: :error

  defp optional_arg?(args, key, validator) do
    not Map.has_key?(args, key) or validator.(Map.get(args, key))
  end

  defp positive_integer_value?(value), do: match?({:ok, _value}, positive_integer(value))

  defp valid_launch_id_list?(values) when is_list(values) do
    length(values) in 1..128 and Enum.uniq(values) == values and
      Enum.all?(values, &positive_integer_value?/1)
  end

  defp valid_launch_id_list?(_values), do: false

  defp valid_launch_extra_vars?(extra_vars) when is_map(extra_vars) do
    Enum.all?(extra_vars, fn
      {key, value} when is_binary(key) and key in @reserved_dispatch_vars ->
        bounded_nonempty_string?(value, 512) and CredentialRedactor.redact(value) == value

      {key, value} ->
        VariableSchema.reviewed_input_name?(key) and valid_non_secret_extra_var_value?(value)
    end)
  end

  defp valid_launch_extra_vars?(_extra_vars), do: false

  defp valid_non_secret_extra_var_value?(value) when is_binary(value) do
    byte_size(value) <= @max_launch_input_string_bytes and
      CredentialRedactor.redact(value) == value
  end

  defp valid_non_secret_extra_var_value?(value) when is_boolean(value) or is_nil(value), do: true

  defp valid_non_secret_extra_var_value?(value) when is_integer(value),
    do: value in -9_007_199_254_740_991..9_007_199_254_740_991

  defp valid_non_secret_extra_var_value?(value) when is_float(value), do: true

  defp valid_non_secret_extra_var_value?(values) when is_list(values) do
    length(values) <= @max_launch_input_list_items and
      Enum.all?(values, fn value ->
        not is_list(value) and not is_map(value) and valid_non_secret_extra_var_value?(value)
      end)
  end

  defp valid_non_secret_extra_var_value?(_value), do: false

  defp request_body_binding_for("awx.launch_job", args) do
    with true <- valid_launch_args?(args),
         body = launch_request_body(args),
         true <- CredentialRedactor.redact(body) == body,
         {:ok, encoded} <- Jason.encode(body),
         true <- byte_size(encoded) in 1..@max_authorized_request_body_bytes do
      {:ok,
       %{
         policy:
           RequestBodyPolicy.bound_bytes(encoded,
             content_type: "application/json",
             max_bytes: @max_authorized_request_body_bytes,
             max_mutations: 1
           ),
         authorized_request_body_b64: Base.encode64(encoded)
       }}
    else
      _ -> {:error, :invalid_awx_request_body_policy}
    end
  end

  defp request_body_binding_for(verb, _args)
       when verb in ["awx.cancel_job", "awx.delete_callback_credential"] do
    {:ok,
     %{
       policy: RequestBodyPolicy.empty(content_type: "application/json", max_mutations: 1),
       authorized_request_body_b64: nil
     }}
  end

  defp request_body_binding_for("awx.create_callback_credential", _args) do
    {:ok,
     %{
       policy:
         RequestBodyPolicy.trusted_rewrite(RequestBodyPolicy.callback_rewrite_handler(),
           content_type: "application/json",
           max_bytes: @max_authorized_request_body_bytes,
           max_mutations: 1
         ),
       authorized_request_body_b64: nil
     }}
  end

  defp request_body_binding_for(_verb, _args),
    do: {:ok, %{policy: %{}, authorized_request_body_b64: nil}}

  defp launch_request_body(args) do
    Enum.reduce(@launch_body_key_map, %{}, fn {arg_key, awx_key}, body ->
      case Map.fetch(args, arg_key) do
        {:ok, value} -> Map.put(body, awx_key, value)
        :error -> body
      end
    end)
  end

  defp bounded_string?(value, max_bytes) when is_binary(value), do: byte_size(value) <= max_bytes

  defp bounded_string?(_value, _max_bytes), do: false

  defp insecure_skip_verify?(%Controller{metadata: meta}) when is_map(meta) do
    Map.get(meta, "insecure_skip_verify") == true or
      Map.get(meta, :insecure_skip_verify) == true
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

  defp fetch_bounded_positive_int!(map, key, maximum) do
    case fetch_int!(map, key) do
      value when value > 0 and value <= maximum ->
        value

      value ->
        raise ArgumentError,
              "expected #{inspect(key)} in 1..#{maximum}, got #{inspect(value)}"
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

  defp durable_recent_job_bound(map) do
    case Map.get(map, :max_candidates) ||
           Map.get(map, "max_candidates") || @max_recent_job_candidates do
      @max_recent_job_candidates ->
        @max_recent_job_candidates

      value ->
        raise ArgumentError,
              "expected max_candidates to equal the durable #{@max_recent_job_candidates} bound, got #{inspect(value)}"
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
