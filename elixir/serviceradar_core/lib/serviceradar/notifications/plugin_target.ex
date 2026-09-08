defmodule ServiceRadar.Notifications.PluginTarget do
  @moduledoc """
  Resolves which agent runs a plugin-backed notification, and which assignment
  on that agent runs it (design D3, tasks 3.3.1, 3.3.2).

  There is exactly ONE Wasm host in the product: wazero inside Go
  `package agent`. Both plugin routes therefore end at an agent, and they differ
  only in WHICH agent:

  | `execution_route` | Agent | Why |
  | --- | --- | --- |
  | `:control_plane` | the platform-resident `serviceradar-agent` that already ships (`helm/serviceradar/templates/agent.yaml`) | egress from the platform |
  | `:edge_agent` | the site agent named on the channel | egress from the customer network (R1) |

  Both then take the SAME `plugin.run_action` path, so a plugin authored for the
  edge runs unchanged on the platform agent - it is the same binary in the same
  runtime. Relocating a channel between the two is a data edit plus a
  `PluginAssignment`, not a repackage. That is the whole reason design.md
  rejected a second, server-side Wasm host: a Rustler/wasmtime NIF would mean
  reimplementing a 27-function ABI that must stay behaviourally identical
  forever, which is the parallel-implementation failure mode `AGENTS.md` bans.

  ## Why an assignment id is resolved here rather than left to the agent

  The assignment - not the package - is what carries the narrowed capability
  set, the config, and the resource limits the module runs under, so the
  dispatch has to name one.

  `go/pkg/agent` will resolve a notification addressed only by
  `plugin_package_id` (`plugin_runtime_notify.go`,
  `resolveNotificationAssignmentID`), but that fallback fails CLOSED the moment
  one package has more than one assignment on the agent, because two assignments
  of one package are two channel configurations and picking either would deliver
  to the wrong destination. Resolving here means the delivery fails with a
  legible, permanent reason in the Delivery Log instead of an agent-side
  ambiguity error - and it is the only place that can consult package approval
  and `effective_capabilities` before the command is ever sent.

  ## What this refuses, and why each refusal is permanent

  Every failure below is a CONFIGURATION error: no number of retries fixes it,
  and the useful behaviour is to burn the attempt budget quickly and fail over
  to the channel that can actually page. They are deliberately distinct
  `error_class` values so the Delivery Log names the missing piece rather than
  saying "dispatch failed".

    * `platform_agent_unconfigured` - a `:control_plane` plugin channel exists
      but the deployment never told core which agent is the platform-resident
      one. There is deliberately no default: guessing an agent id would dispatch
      a customer's notifications to whichever agent happened to match.
    * `edge_agent_unbound` - an `:edge_agent` channel with no `agent_uid`. The
      resource and the `notification_channels_edge_agent` check both prevent
      this; it is caught again here because dispatch must never send a command
      to a nil agent.
    * `provider_has_no_package` - a `:wasm_plugin` provider with no package
      reference. Also constrained by `notification_providers_plugin_ref`.
    * `plugin_package_unreadable` / `plugin_package_unapproved` - tasks 3.3.2.
      A package that was approved when the provider was activated and has since
      been revoked MUST NOT dispatch. `ServiceRadar.Notifications.PackageApprovalWatcher`
      disables the bound providers when that happens, but the watcher is an Ash
      notifier and a notifier is a signal, not a guarantee - this is the check
      that holds when the signal is missed.
    * `notify_capability_denied` - the package's EFFECTIVE capabilities do not
      include `notify:v1`. Capability narrowing is mandatory (design Security):
      what reaches the agent is `effective_capabilities`, computed from the
      package's approved set and falling back to the manifest's declared set
      when approval did not narrow it, exactly as
      `ServiceRadar.Edge.AgentConfigGenerator` computes it. The agent enforces
      the same capability again on its side
      (`go/pkg/agent/plugin_runtime_notify.go`); this check exists so the
      operator sees "you did not approve notify:v1" rather than an opaque agent
      denial.
    * `plugin_assignment_missing` - the package is approved but is not assigned
      to this agent, so there is no assignment id to run under.

  ## Testability

  The two database reads are injectable (`:load_package`, `:load_assignment`)
  so every branch above is exercisable in an async, database-free test. The
  real loaders are used when they are not supplied.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @type t :: %{
          agent_uid: String.t(),
          partition_id: String.t() | nil,
          plugin_assignment_id: String.t(),
          plugin_package_id: String.t(),
          notification_entrypoint: String.t(),
          notification_capabilities: [String.t()],
          credential_requirements: map(),
          effective_permissions: %{
            allowed_domains: [String.t()],
            allowed_networks: [String.t()],
            allowed_ports: [integer()]
          },
          execution_route: :control_plane | :edge_agent
        }

  @type failure :: {String.t(), String.t()}

  @doc """
  The configured platform-resident agent, as `{agent_uid, partition_id}`.

  `nil` when the deployment has not named one, which is what makes a
  `:control_plane` plugin channel fail with `platform_agent_unconfigured`
  rather than dispatching somewhere arbitrary.
  """
  @spec platform_agent() :: {String.t(), String.t() | nil} | nil
  def platform_agent do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    case presence(Keyword.get(config, :platform_agent_uid)) do
      nil -> nil
      uid -> {uid, presence(Keyword.get(config, :platform_agent_partition_id))}
    end
  end

  @doc """
  Resolves the agent and assignment a plugin-backed channel dispatches through.

  Options:

    * `:platform_agent` - `{agent_uid, partition_id}` or `nil`, replacing the
      configured value.
    * `:load_package` - a one-argument function taking a package id.
    * `:load_assignment` - a three-argument function taking `agent_uid`,
      `partition_id`, and `package_id`.
  """
  @spec resolve(map(), map() | nil, keyword()) :: {:ok, t()} | {:error, failure()}
  def resolve(channel, provider, opts \\ []) do
    with {:ok, agent} <- agent_binding(channel, opts),
         {:ok, package_id} <- package_reference(provider),
         {:ok, package} <- fetch_package(package_id, opts),
         :ok <- ensure_approved(package),
         :ok <- ensure_notify_capability(package),
         {:ok, notifier} <- resolve_notifier(package, provider),
         {:ok, assignment} <- fetch_assignment(agent, package_id, opts) do
      {:ok,
       %{
         agent_uid: agent.agent_uid,
         partition_id: agent.partition_id,
         plugin_assignment_id: assignment |> Map.fetch!(:id) |> to_string(),
         plugin_package_id: to_string(package_id),
         notification_entrypoint: Map.fetch!(notifier, "entrypoint"),
         notification_capabilities:
           notifier |> Map.get("capabilities", []) |> List.wrap() |> Enum.map(&to_string/1),
         credential_requirements: Map.get(notifier, "credential_requirements", %{}),
         effective_permissions:
           AgentConfigGenerator.effective_permissions(
             assignment,
             package,
             Map.get(package, :manifest) || %{}
           ),
         execution_route: agent.execution_route
       }}
    end
  end

  # --- agent binding --------------------------------------------------------

  defp agent_binding(%{execution_route: :edge_agent} = channel, _opts) do
    case presence(Map.get(channel, :agent_uid)) do
      nil ->
        {:error,
         {"edge_agent_unbound",
          "the channel routes to :edge_agent but names no agent to egress from"}}

      uid ->
        {:ok,
         %{
           agent_uid: uid,
           partition_id: presence(Map.get(channel, :partition_id)),
           execution_route: :edge_agent
         }}
    end
  end

  defp agent_binding(_channel, opts) do
    case Keyword.get_lazy(opts, :platform_agent, &platform_agent/0) do
      {uid, partition_id} when is_binary(uid) ->
        {:ok,
         %{
           agent_uid: uid,
           partition_id: presence(partition_id),
           execution_route: :control_plane
         }}

      _unconfigured ->
        {:error,
         {"platform_agent_unconfigured",
          "no platform-resident agent is configured; set SERVICERADAR_NOTIFICATION_PLATFORM_AGENT_ID " <>
            "to the agent id of the serviceradar-agent that runs alongside core"}}
    end
  end

  # --- package --------------------------------------------------------------

  defp package_reference(provider) do
    case provider && presence(Map.get(provider, :plugin_package_id)) do
      nil ->
        {:error,
         {"provider_has_no_package",
          "the provider is plugin-backed but references no plugin package"}}

      package_id ->
        {:ok, package_id}
    end
  end

  defp fetch_package(package_id, opts) do
    loader = Keyword.get(opts, :load_package, &load_package/1)

    case loader.(package_id) do
      {:ok, package} when is_map(package) ->
        {:ok, package}

      _unreadable ->
        {:error,
         {"plugin_package_unreadable",
          "the referenced plugin package #{package_id} could not be read"}}
    end
  end

  defp load_package(package_id) do
    actor = SystemActor.system(:notification_plugin_target)

    case Ash.get(PluginPackage, package_id, actor: actor) do
      {:ok, package} -> {:ok, package}
      other -> other
    end
  end

  defp ensure_approved(package) do
    case Map.get(package, :status) do
      :approved ->
        :ok

      status ->
        {:error,
         {"plugin_package_unapproved",
          "plugin package #{label(package)} is #{inspect(status)}; only an approved package may deliver"}}
    end
  end

  # Mirrors ServiceRadar.Edge.AgentConfigGenerator's effective_capabilities/2:
  # the approved set wins when approval narrowed anything, and an empty approved
  # set means approval did not narrow the manifest's declared set. Reimplementing
  # the rule differently here would let core promise a capability the agent then
  # refuses, or refuse one the agent would have allowed.
  defp ensure_notify_capability(package) do
    if Manifest.notify_capability() in effective_capabilities(package) do
      :ok
    else
      {:error,
       {"notify_capability_denied",
        "plugin package #{label(package)} does not carry #{Manifest.notify_capability()} in its " <>
          "effective capabilities; approve the capability before binding a notification provider to it"}}
    end
  end

  defp resolve_notifier(package, provider) do
    action_key =
      case provider && presence(Map.get(provider, :action_key)) do
        nil -> nil
        value -> to_string(value)
      end

    with key when is_binary(key) <- action_key,
         {:ok, entries} <- Manifest.notification_entries(Map.get(package, :manifest) || %{}),
         %{} = notifier <- Enum.find(entries, &(Map.get(&1, "key") == key)) do
      {:ok, notifier}
    else
      nil ->
        {:error,
         {"notification_action_missing",
          "the approved package does not declare notification action #{inspect(action_key)}"}}

      {:error, errors} ->
        {:error,
         {"notification_manifest_invalid",
          "the approved package notification manifest is invalid: #{Enum.join(errors, "; ")}"}}
    end
  end

  defp effective_capabilities(package) do
    case Map.get(package, :approved_capabilities) do
      [_ | _] = approved -> Enum.map(approved, &to_string/1)
      _empty -> manifest_capabilities(Map.get(package, :manifest))
    end
  end

  defp manifest_capabilities(manifest) when is_map(manifest) do
    manifest
    |> Map.get("capabilities", Map.get(manifest, :capabilities, []))
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp manifest_capabilities(_manifest), do: []

  # --- assignment -----------------------------------------------------------

  defp fetch_assignment(agent, package_id, opts) do
    loader = Keyword.get(opts, :load_assignment, &load_assignment/3)

    case loader.(agent.agent_uid, agent.partition_id, package_id) do
      {:ok, %{id: id} = assignment} when not is_nil(id) ->
        {:ok, assignment}

      _missing ->
        {:error,
         {"plugin_assignment_missing",
          "plugin package #{package_id} is not assigned to agent #{agent.agent_uid}; " <>
            "assign the package to that agent before dispatching notifications through it"}}
    end
  end

  # The partition is part of the lookup whenever the channel carries one,
  # because an agent uid is only unique within its partition. A channel with no
  # bound partition falls back to the uid alone rather than failing: partition
  # binding is mTLS-derived and a control-plane channel has no session to derive
  # it from.
  defp load_assignment(agent_uid, partition_id, package_id) do
    actor = SystemActor.system(:notification_plugin_target)

    PluginAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      agent_uid == ^agent_uid and plugin_package_id == ^package_id and enabled == true
    )
    |> filter_partition(partition_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, assignment} -> {:ok, assignment}
      other -> other
    end
  end

  defp filter_partition(query, nil), do: query

  defp filter_partition(query, partition_id) do
    Ash.Query.filter(query, partition_id == ^partition_id)
  end

  # --- helpers --------------------------------------------------------------

  defp label(%{plugin_id: plugin_id, version: version})
       when is_binary(plugin_id) and is_binary(version),
       do: "#{plugin_id}@#{version}"

  defp label(package), do: to_string(Map.get(package, :id))

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value
end
