defmodule ServiceRadarWebNGWeb.Plugins.ShowLive do
  @moduledoc """
  Detail page for one Wasm plugin package: review (approve, deny, revoke,
  restage), the Wasm blob, assignments to agents, and legacy assignment
  recovery.

  The package is read only once the socket is connected; the disconnected
  render does no database work.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.PluginConfigForm
  import ServiceRadarWebNGWeb.Plugins.Components

  alias ServiceRadar.Plugins.IntegrationCatalog
  alias ServiceRadarWebNG.Observability.ContractRegistry
  alias ServiceRadarWebNG.Plugins.Assignments
  alias ServiceRadarWebNG.Plugins.CredentialCoverage
  alias ServiceRadarWebNG.Plugins.Packages
  alias ServiceRadarWebNG.Plugins.Storage
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @plugin_assignment_manage_permission "settings.plugins.manage"
  @credential_manage_permission "settings.credentials.manage"
  @policy_recovery_poll_delay_ms 2_000
  @policy_recovery_poll_attempt_limit 30

  # Capabilities that grant network egress or raw request access from a Wasm
  # plugin. These MUST be explicitly carried into a package's approved
  # capabilities before the host will allow the plugin to use them (the host's
  # first guard is `hasCapability/1`). They are surfaced distinctly in the review
  # UI so an operator does not silently drop one when hand-typing the approved
  # list — omitting a requested sensitive capability denies it.
  @sensitive_capabilities ~w(
    http_request
    grpc_request
    websocket_connect
    websocket_send
    websocket_recv
    websocket_close
  )

  @fallback_assignment_interval_seconds 60
  @fallback_assignment_timeout_seconds 10
  @fallback_assignment_interval_min 5
  @fallback_assignment_timeout_min 1

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "plugins.view") do
      can_assign_plugins = RBAC.can?(scope, @plugin_assignment_manage_permission)

      socket =
        socket
        |> assign(:can_stage_plugins, RBAC.can?(scope, "plugins.stage"))
        |> assign(:can_approve_plugins, RBAC.can?(scope, "plugins.approve"))
        # PluginAssignment mutations (including legacy recovery) are guarded
        # by the core `settings.plugins.manage` policy. Do not advertise a
        # weaker `plugins.assign` browser capability that the server will deny.
        |> assign(:can_assign_plugins, can_assign_plugins)
        |> assign(
          :can_reconcile_credential_rules,
          can_assign_plugins and RBAC.can?(scope, @credential_manage_permission)
        )
        |> assign(:page_title, "Plugin package")
        |> assign(:current_path, nil)
        |> assign(:plugins_base_path, "/admin/plugins")
        |> assign(:selected_package, nil)
        |> assign(:review_form, default_review_form())
        |> assign(:assignment_form, default_assignment_form())
        |> assign(:assignments, [])
        |> assign(:authenticated_partition_preview, nil)
        |> assign(:recovery_confirmation, nil)
        |> assign(:policy_recovery_polls, %{})
        |> assign(:credential_fields, [])
        |> assign(:credential_coverage, nil)
        |> assign(:assignment_coverage, %{})
        |> assign(:versions, [])
        |> assign(:agents, [])
        |> assign(:verification_policy, plugin_verification_policy())
        |> assign(:upload_url, nil)
        |> assign(:upload_token, nil)
        |> assign(:upload_expires_at, nil)
        |> assign(:download_url, nil)
        |> assign(:download_token, nil)
        |> assign(:download_expires_at, nil)
        |> assign(:blob_present, nil)
        |> assign(:upload_errors, [])
        |> allow_upload(:wasm_blob,
          accept: ~w(.wasm),
          max_entries: 1,
          max_file_size: Storage.max_upload_bytes()
        )

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to access Plugins.")
       |> redirect(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, url, socket) do
    socket =
      socket
      |> assign(:current_path, current_path_from_url(url))
      |> assign(:plugins_base_path, plugins_base_path_from_url(url))

    if connected?(socket) do
      {:noreply, load_package(socket, id)}
    else
      {:noreply, socket}
    end
  end

  defp load_package(socket, id) do
    scope = socket.assigns.current_scope

    case Packages.get(id, scope: scope) do
      {:ok, package} ->
        versions = list_versions(package.plugin_id, scope)
        prior_approved = Enum.find(versions, &(&1.status == :approved))

        socket
        |> assign(:page_title, "#{package.name} #{package.version}")
        |> assign(:selected_package, package)
        |> assign(:review_form, build_review_form(package, prior_approved))
        |> assign(:assignment_form, default_assignment_form(package))
        |> assign(:assignments, list_plugin_assignments(package.plugin_id, scope))
        |> assign(:authenticated_partition_preview, nil)
        |> assign(:recovery_confirmation, nil)
        |> assign(:policy_recovery_polls, %{})
        |> assign_credential_context(package)
        |> assign(:versions, versions)
        |> assign(:agents, Assignments.assignable_agents(scope))
        |> assign(:upload_errors, [])
        |> assign_package_urls(package, scope)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Package not found")
        |> push_navigate(to: socket.assigns.plugins_base_path)

      {:error, _error} ->
        socket
        |> put_flash(:error, "Failed to load package")
        |> push_navigate(to: socket.assigns.plugins_base_path)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path || @plugins_base_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <.plugins_nav
          active={:detail}
          base_path={@plugins_base_path}
          can_stage_plugins={@can_stage_plugins}
        />

        <%= if @selected_package do %>
          <.package_details
            package={@selected_package}
            can_stage_plugins={@can_stage_plugins}
            can_approve_plugins={@can_approve_plugins}
            review_form={@review_form}
            assignments={@assignments}
            agents={@agents}
            assignment_form={@assignment_form}
            assignment_coverage={@assignment_coverage}
            credential_fields={@credential_fields}
            credential_coverage={@credential_coverage}
            authenticated_partition_preview={@authenticated_partition_preview}
            recovery_confirmation={@recovery_confirmation}
            can_assign_plugins={@can_assign_plugins}
            can_reconcile_credential_rules={@can_reconcile_credential_rules}
            versions={@versions}
            blob_present={@blob_present}
            uploads={@uploads}
            upload_errors={@upload_errors}
            verification_policy={@verification_policy}
            upload_url={@upload_url}
            upload_token={@upload_token}
            upload_expires_at={@upload_expires_at}
            download_url={@download_url}
            download_token={@download_token}
            download_expires_at={@download_expires_at}
            plugins_base_path={@plugins_base_path}
            current_scope={@current_scope}
          />
        <% else %>
          <div
            id="plugin-package-loading"
            class="rounded-xl border border-dashed border-sr-line bg-sr-surface p-8 text-center text-sm text-sr-muted"
          >
            Loading package…
          </div>
        <% end %>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:refresh_policy_recovery, legacy_assignment_id, poll_ref, attempt}, socket) do
    poll = Map.get(socket.assigns.policy_recovery_polls, legacy_assignment_id)

    if current_policy_recovery_poll?(poll, poll_ref, attempt) and
         not is_nil(socket.assigns.selected_package) do
      package = socket.assigns.selected_package
      scope = socket.assigns.current_scope
      assignments = list_plugin_assignments(package.plugin_id, scope)
      state = policy_recovery_state_for_assignment(assignments, legacy_assignment_id)

      socket = assign(socket, :assignments, assignments)

      case state do
        state when state in [:queued, :pending] ->
          {:noreply, schedule_policy_recovery_poll(socket, legacy_assignment_id, poll_ref, attempt)}

        state when is_atom(state) ->
          {:noreply,
           socket
           |> clear_policy_recovery_poll(legacy_assignment_id)
           |> put_flash(:info, policy_recovery_terminal_message(state))}

        _ ->
          {:noreply,
           socket
           |> clear_policy_recovery_poll(legacy_assignment_id)
           |> put_flash(
             :error,
             "Could not refresh policy reconciliation status. Refresh the page before retrying."
           )}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("review_change", %{"review" => params}, socket) do
    {:noreply, assign(socket, :review_form, Map.merge(socket.assigns.review_form, params))}
  end

  def handle_event("upload_wasm", _params, %{assigns: %{can_stage_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to stage plugin packages.")}
  end

  def handle_event("upload_wasm", _params, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package

    cond do
      is_nil(package) ->
        {:noreply, put_flash(socket, :error, "No package selected")}

      socket.assigns.uploads.wasm_blob.entries == [] ->
        {:noreply, put_flash(socket, :error, "Select a .wasm file to upload")}

      true ->
        handle_wasm_upload(socket, package, scope)
    end
  end

  def handle_event("wasm_upload_change", _params, socket) do
    {:noreply, assign(socket, :upload_errors, [])}
  end

  def handle_event("assignment_change", %{"assignment" => params}, socket) do
    form = Map.merge(socket.assigns.assignment_form, params)

    {:noreply,
     socket
     |> assign(:assignment_form, form)
     |> assign_form_coverage(form["agent_uid"])
     |> assign_authenticated_partition_preview(form["agent_uid"])}
  end

  def handle_event("approve_package", %{"review" => _params}, %{assigns: %{can_approve_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to approve plugin packages.")}
  end

  def handle_event("approve_package", %{"review" => params}, socket) do
    scope = socket.assigns.current_scope
    approved_by = get_actor(socket)

    with {:ok, attrs} <- parse_review_params(params),
         {:ok, package} <-
           Packages.approve(
             socket.assigns.selected_package.id,
             attrs,
             scope: scope,
             approved_by: approved_by
           ) do
      {:noreply,
       socket
       |> assign(:selected_package, package)
       |> assign(:review_form, build_review_form(package))
       |> put_flash(:info, "Package approved")}
    else
      {:error, {:invalid_json, message}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, :verification_required} ->
        {:noreply, put_flash(socket, :error, "GitHub package must be GPG verified before approval")}

      {:error, :signature_required} ->
        {:noreply, put_flash(socket, :error, "Unsigned uploads are blocked by verification policy")}

      {:error, :trusted_upload_signers_not_configured} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Upload signing keys are not configured for strict verification"
         )}

      {:error, :invalid_signature} ->
        {:noreply, put_flash(socket, :error, "Upload signature verification failed")}

      {:error, :unsupported_signature_algorithm} ->
        {:noreply, put_flash(socket, :error, "Upload signature algorithm is not supported")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to approve: #{format_error(error)}")}
    end
  end

  def handle_event("deny_package", _params, %{assigns: %{can_approve_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to approve plugin packages.")}
  end

  def handle_event("deny_package", _params, socket) do
    scope = socket.assigns.current_scope
    reason = socket.assigns.review_form["denied_reason"]

    case Packages.deny(socket.assigns.selected_package.id, %{denied_reason: reason}, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> assign(:selected_package, package)
         |> assign(:review_form, build_review_form(package))
         |> put_flash(:info, "Package denied")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to deny: #{format_error(error)}")}
    end
  end

  def handle_event("revoke_package", _params, %{assigns: %{can_approve_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to approve plugin packages.")}
  end

  def handle_event("revoke_package", _params, socket) do
    scope = socket.assigns.current_scope
    reason = socket.assigns.review_form["denied_reason"]

    case Packages.revoke(socket.assigns.selected_package.id, %{denied_reason: reason}, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> assign(:selected_package, package)
         |> assign(:review_form, build_review_form(package))
         |> put_flash(:info, "Package revoked")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke: #{format_error(error)}")}
    end
  end

  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("create_assignment", %{"assignment" => _params}, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign plugins.")}
  end

  def handle_event("create_assignment", %{"assignment" => params}, socket) do
    if producer_schedule_provisioned?(socket.assigns.selected_package) do
      {:noreply, put_flash(socket, :error, producer_schedule_assignment_message())}
    else
      scope = socket.assigns.current_scope

      case parse_assignment_params(params, socket.assigns.selected_package) do
        {:ok, attrs} ->
          handle_assignment_upsert(socket, scope, attrs)

        {:error, {:invalid_json, message}} ->
          Logger.error("Plugin assignment failed - invalid JSON: #{message}")
          {:noreply, put_flash(socket, :error, message)}

        {:error, error} ->
          Logger.error("Plugin assignment failed: #{inspect(error)}")
          {:noreply, put_flash(socket, :error, "Failed to assign: #{format_error(error)}")}
      end
    end
  end

  def handle_event("delete_assignment", %{"id" => _id}, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign plugins.")}
  end

  def handle_event("delete_assignment", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Assignments.delete(id, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(
           :assignments,
           list_plugin_assignments(socket.assigns.selected_package.plugin_id, scope)
         )
         |> assign_credential_context(socket.assigns.selected_package)
         |> put_flash(:info, "Assignment removed")}

      {:error, error} ->
        Logger.error("Plugin assignment deletion failed for #{id}: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to remove: #{format_error(error)}")}
    end
  end

  def handle_event("upgrade_assignment", %{"id" => _id}, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to assign plugins.")}
  end

  def handle_event("upgrade_assignment", %{"id" => id, "target-package-id" => target_package_id}, socket) do
    upgrade_assignment(socket, id, target_package_id)
  end

  def handle_event("upgrade_assignment", %{"id" => id, "assignment_upgrade" => params}, socket) do
    upgrade_assignment(socket, id, Map.get(params, "target_package_id"))
  end

  def handle_event("request_legacy_recovery", _params, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to recover plugin assignments.")}
  end

  def handle_event("request_legacy_recovery", %{"id" => id, "kind" => kind}, socket) do
    case legacy_recovery_confirmation(socket.assigns.assignments, id, kind) do
      {:ok, confirmation} ->
        if legacy_recovery_confirmation_allowed?(socket, confirmation) do
          {:noreply, assign(socket, :recovery_confirmation, confirmation)}
        else
          {:noreply, put_flash(socket, :error, credential_recovery_permission_message())}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Legacy assignment was not found. Refresh and try again.")}

      {:error, :unsupported_policy_owner} ->
        {:noreply, put_flash(socket, :error, unsupported_policy_owner_message())}

      {:error, :recovery_unavailable} ->
        {:noreply, put_flash(socket, :error, legacy_recovery_unavailable_message())}

      {:error, :not_recoverable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This assignment is not an unbound legacy row and cannot be recovered through reapproval."
         )}

      {:error, :kind_mismatch} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The requested recovery action does not match this assignment."
         )}
    end
  end

  def handle_event("cancel_legacy_recovery", _params, socket) do
    {:noreply, assign(socket, :recovery_confirmation, nil)}
  end

  def handle_event("confirm_legacy_recovery", _params, %{assigns: %{can_assign_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to recover plugin assignments.")}
  end

  def handle_event("confirm_legacy_recovery", %{"id" => id, "kind" => kind}, socket) do
    confirmation = socket.assigns.recovery_confirmation

    case {
      recovery_confirmation_matches?(confirmation, id, kind),
      legacy_recovery_confirmation_allowed?(socket, confirmation)
    } do
      {true, true} ->
        perform_legacy_recovery(socket, id, kind)

      {true, false} ->
        {:noreply, put_flash(socket, :error, credential_recovery_permission_message())}

      _ ->
        {:noreply, put_flash(socket, :error, "Review this recovery request again before confirming.")}
    end
  end

  def handle_event("restage_package", _params, %{assigns: %{can_approve_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to approve plugin packages.")}
  end

  def handle_event("restage_package", _params, socket) do
    scope = socket.assigns.current_scope

    case Packages.restage(socket.assigns.selected_package.id, scope: scope) do
      {:ok, package} ->
        {:noreply,
         socket
         |> assign(:selected_package, package)
         |> assign(:review_form, build_review_form(package))
         |> put_flash(:info, "Package moved back to staged")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to restage: #{format_error(error)}")}
    end
  end

  def handle_event("delete_package", %{"id" => _id}, %{assigns: %{can_approve_plugins: false}} = socket) do
    {:noreply, put_flash(socket, :error, "You don't have permission to approve plugin packages.")}
  end

  def handle_event("delete_package", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    package = socket.assigns.selected_package

    case delete_package_and_assignments(id, package, scope) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Package deleted")
         |> push_navigate(to: socket.assigns.plugins_base_path)}

      {:error, {:assignment_errors, errors}} ->
        {:noreply, put_flash(socket, :error, "Failed to remove assignments: #{Enum.join(errors, "; ")}")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Failed to delete package: #{format_error(error)}")}
    end
  end

  defp delete_package_and_assignments(id, package, scope) do
    assignment_errors =
      id
      |> list_assignments(scope)
      |> Enum.reduce([], fn assignment, errors ->
        # Assignments.delete/2 normalizes destroys to {:ok, _} | {:error, _}.
        case Assignments.delete(assignment.id, scope: scope) do
          {:ok, _} -> errors
          {:error, error} -> [format_error(error) | errors]
        end
      end)

    case assignment_errors do
      [] ->
        _ = maybe_delete_blob(package)

        case Packages.delete(id, scope: scope) do
          :ok -> :ok
          {:ok, _package} -> :ok
          {:error, error} -> {:error, error}
        end

      errors ->
        {:error, {:assignment_errors, Enum.reverse(errors)}}
    end
  end

  defp handle_assignment_upsert(socket, scope, attrs) do
    case existing_assignment(socket.assigns.assignments, attrs.agent_uid) do
      nil ->
        create_assignment(socket, scope, attrs)

      assignment ->
        cond do
          legacy_unbound_assignment?(assignment) ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This agent has an unbound legacy assignment. Use its recovery action instead of updating it."
             )}

          assignment_source(assignment) == :policy ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This agent already has this plugin assigned by policy. Change the policy to move versions."
             )}

          assignment_package_id(assignment) != attrs.plugin_package_id ->
            upgrade_assignment(socket, scope, assignment, attrs)

          true ->
            update_assignment(socket, scope, assignment, attrs)
        end
    end
  end

  defp create_assignment(socket, scope, attrs) do
    case Assignments.create(attrs, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(
           :assignments,
           list_plugin_assignments(socket.assigns.selected_package.plugin_id, scope)
         )
         |> assign(:assignment_form, default_assignment_form(socket.assigns.selected_package))
         |> assignment_saved_flash("Assignment created", attrs.agent_uid)}

      {:error, error} ->
        Logger.error("Plugin assignment creation failed: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, assignment_create_error_message(error))}
    end
  end

  defp update_assignment(socket, scope, assignment, attrs) do
    update_attrs =
      attrs
      |> Map.delete(:agent_uid)
      |> Map.delete(:plugin_package_id)

    case Assignments.update(assignment.id, update_attrs, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(
           :assignments,
           list_plugin_assignments(socket.assigns.selected_package.plugin_id, scope)
         )
         |> assign(:assignment_form, default_assignment_form(socket.assigns.selected_package))
         |> assignment_saved_flash("Assignment updated", assignment.agent_uid)}

      {:error, error} ->
        Logger.error("Plugin assignment update failed for #{assignment.id}: #{inspect(error)}")

        {:noreply, put_flash(socket, :error, "Failed to update assignment: #{format_error(error)}")}
    end
  end

  defp upgrade_assignment(socket, scope, assignment, attrs) do
    case Assignments.upgrade(assignment.id, attrs.plugin_package_id, scope: scope, attrs: attrs) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(
           :assignments,
           list_plugin_assignments(socket.assigns.selected_package.plugin_id, scope)
         )
         |> assign(:assignment_form, default_assignment_form(socket.assigns.selected_package))
         |> assignment_saved_flash("Assignment upgraded", attrs.agent_uid)}

      {:error, error} ->
        Logger.error("Plugin assignment upgrade failed for #{assignment.id}: #{inspect(error)}")

        {:noreply, put_flash(socket, :error, "Failed to upgrade assignment: #{format_error(error)}")}
    end
  end

  defp upgrade_assignment(socket, id, target_package_id) when is_binary(target_package_id) and target_package_id != "" do
    scope = socket.assigns.current_scope

    case Assignments.upgrade(id, target_package_id, scope: scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(
           :assignments,
           list_plugin_assignments(socket.assigns.selected_package.plugin_id, scope)
         )
         |> assign(:versions, list_versions(socket.assigns.selected_package.plugin_id, scope))
         |> put_flash(:info, "Assignment upgraded")}

      {:error, error} ->
        Logger.error("Plugin assignment upgrade failed for #{id}: #{inspect(error)}")

        {:noreply, put_flash(socket, :error, "Failed to upgrade assignment: #{format_error(error)}")}
    end
  end

  defp upgrade_assignment(socket, _id, _target_package_id) do
    {:noreply, put_flash(socket, :error, "Select a plugin version to upgrade to.")}
  end

  defp perform_legacy_recovery(socket, id, kind) do
    scope = socket.assigns.current_scope

    result =
      case normalize_legacy_recovery_kind(kind) do
        {:ok, :manual} ->
          Assignments.reapprove_legacy_manual(id, %{confirm: true}, scope: scope)

        {:ok, :policy} ->
          Assignments.reconcile_legacy_policy(id, %{confirm: true}, scope: scope)

        :error ->
          {:error, :invalid_recovery_kind}
      end

    case result do
      {:ok, recovery} ->
        package = socket.assigns.selected_package

        socket =
          socket
          |> assign(:assignments, list_plugin_assignments(package.plugin_id, scope))
          |> assign_credential_context(package)
          |> assign(:recovery_confirmation, nil)
          |> schedule_policy_recovery_poll(id, recovery)

        {:noreply, put_flash(socket, :info, legacy_recovery_success_message(kind, recovery))}

      {:error, error} ->
        package = socket.assigns.selected_package

        socket =
          socket
          |> assign(:assignments, list_plugin_assignments(package.plugin_id, scope))
          |> assign_credential_context(package)
          |> assign(:recovery_confirmation, nil)

        {:noreply, put_flash(socket, :error, legacy_recovery_failure_message(error))}
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp handle_wasm_upload(socket, package, scope) do
    results =
      consume_uploaded_entries(socket, :wasm_blob, fn %{path: path}, _entry ->
        case File.read(path) do
          {:ok, payload} ->
            {:ok, payload}

          {:error, reason} ->
            Logger.error("plugin wasm upload read failed package_id=#{package.id} path=#{path} reason=#{inspect(reason)}")

            {:error, :read_failed}
        end
      end)

    case results do
      [payload] when is_binary(payload) ->
        upload_wasm_payload(socket, package, scope, payload)

      _ ->
        {:noreply,
         socket
         |> assign(:upload_errors, ["failed to read uploaded file"])
         |> put_flash(:error, "Failed to upload Wasm blob")}
    end
  end

  defp upload_wasm_payload(socket, package, scope, payload) do
    case Packages.upload_blob(package, payload, scope: scope) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign_package_urls(updated, scope)
         |> assign(:upload_errors, [])
         |> put_flash(:info, "Wasm blob uploaded")}

      {:error, error} ->
        error_message = format_error(error)

        Logger.error(
          "plugin wasm upload failed package_id=#{package.id} plugin_id=#{package.plugin_id} object_key=#{package.wasm_object_key || Storage.object_key_for(package)} error=#{inspect(error)}"
        )

        {:noreply,
         socket
         |> assign(:upload_errors, [error_message])
         |> put_flash(:error, "Failed to upload Wasm blob: #{error_message}")}
    end
  end

  defp package_details(assigns) do
    ~H"""
    <section id="plugin-package-details" class="rounded-xl border border-sr-line bg-sr-surface p-6">
      <div>
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h3 class="text-lg font-semibold">{@package.name}</h3>
            <p class="text-xs text-sr-muted font-mono">{@package.plugin_id}</p>
            <p class="text-xs text-sr-muted">Version {@package.version}</p>
          </div>
          <div class="flex items-center gap-2">
            <.status_badge status={@package.status} />
            <.ui_badge variant="ghost" size="xs">{@package.source_type}</.ui_badge>
          </div>
        </div>

        <%= if policy_requires_verification?(@package, @verification_policy) do %>
          <div class="mt-3 rounded-xl border border-warning/30 bg-warning/10 p-3 text-xs text-warning">
            This package is unverified and will be blocked by the current verification policy.
          </div>
        <% end %>

        <div class="mt-4 grid grid-cols-1 lg:grid-cols-2 gap-4">
          <div class="space-y-4">
            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Requested Capabilities</div>
              <div class="mt-2 flex flex-wrap gap-2">
                <%= for cap <- requested_capabilities(@package) do %>
                  <.ui_badge
                    size="xs"
                    variant={if sensitive_capability?(cap), do: "warning", else: "ghost"}
                    title={
                      if sensitive_capability?(cap),
                        do: "Sensitive: grants network egress. Must be explicitly approved.",
                        else: nil
                    }
                  >
                    {cap}<span :if={sensitive_capability?(cap)} aria-hidden="true">&nbsp;⚠</span>
                  </.ui_badge>
                <% end %>
                <%= if requested_capabilities(@package) == [] do %>
                  <span class="text-xs text-sr-muted">None</span>
                <% end %>
              </div>
              <p
                :if={sensitive_requested_capabilities(@package) != []}
                class="mt-2 text-xs text-warning"
              >
                Sensitive (network-egress) capabilities are highlighted. They are only granted if
                they appear in the approved capabilities below — leave the field blank to accept all
                requested capabilities, or list every capability the plugin needs.
              </p>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Requested Permissions</div>
              <pre class="mt-2 bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(requested_permissions(@package)) %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Requested Resources</div>
              <pre class="mt-2 bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(requested_resources(@package)) %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Northbound Actions</div>
              <div class="mt-3 space-y-3">
                <%= for action <- requested_actions(@package) do %>
                  <div class="rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3">
                    <div class="flex flex-wrap items-start justify-between gap-2">
                      <div>
                        <div class="text-sm font-medium">
                          {action_label(action)}
                        </div>
                        <div class="font-mono text-[11px] text-sr-muted">
                          {action_id(action)} · v{action_version(action)}
                        </div>
                      </div>
                      <div class="flex flex-wrap gap-1">
                        <%= for scope <- action_scopes(action) do %>
                          <.ui_badge size="xs" variant="ghost">{scope}</.ui_badge>
                        <% end %>
                      </div>
                    </div>
                    <p :if={action_description(action)} class="mt-2 text-xs text-sr-muted">
                      {action_description(action)}
                    </p>
                    <div class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-sr-muted">
                      <span>Safety: {action_safety(action)}</span>
                      <span>Timeout: {action_timeout(action)}s</span>
                      <span>
                        Confirmation: {if action_requires_confirmation?(action),
                          do: "required",
                          else: "not required"}
                      </span>
                    </div>
                  </div>
                <% end %>
                <%= if requested_actions(@package) == [] do %>
                  <span class="text-xs text-sr-muted">None</span>
                <% end %>
              </div>
            </div>
          </div>

          <div class="space-y-4">
            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Manifest</div>
              <pre class="mt-2 bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-64">
    <%= format_json_value(@package.manifest) %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Config Schema</div>
              <pre class="mt-2 bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(@package.config_schema) %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Display Contract</div>
              <pre class="mt-2 bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-48">
    <%= format_json_value(@package.display_contract) %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4 space-y-2">
              <div class="text-sm font-semibold">Runtime Display Contracts</div>
              <p class="text-xs text-sr-muted">
                Contracts this package ships, resolved at runtime by the UI. A package needs no
                web-ng release to render its own signals; a contract listed as refused renders
                through the generic view instead.
              </p>
              <div :if={@package.display_contracts == %{}} class="text-xs text-sr-muted">
                This package ships no display contracts.
              </div>
              <div
                :for={key <- Enum.sort(Map.keys(@package.display_contracts))}
                class="text-xs font-mono"
              >
                {key}
              </div>
              <div
                :for={diagnostic <- display_contract_diagnostics(@package)}
                class="text-xs text-warning"
              >
                {diagnostic.source}: {diagnostic.reason}
              </div>
            </div>

            <div class="rounded-xl border border-sr-line p-4 space-y-2">
              <div class="text-sm font-semibold">Integrity & Verification</div>
              <div class="text-xs text-sr-muted">Content hash</div>
              <div class="text-xs font-mono">{format_hash(@package.content_hash)}</div>
              <div class="text-xs text-sr-muted mt-2">Blob stored</div>
              <div class="text-xs">{blob_status(@blob_present)}</div>
              <div class="text-xs text-sr-muted mt-2">GPG verification</div>
              <div class="text-xs">
                <%= if @package.gpg_verified_at do %>
                  Verified
                  <.user_time
                    id={"admin-plugin-package-#{@package.id}-gpg-verified-at"}
                    value={@package.gpg_verified_at}
                    timezone={@current_scope.user.timezone || "Etc/UTC"}
                    style={:compact}
                  />{gpg_key_suffix(@package.gpg_key_id)}
                <% else %>
                  {gpg_status(@package.gpg_key_id)}
                <% end %>
              </div>
              <div class="text-xs text-sr-muted mt-2">Signature metadata</div>
              <div class="text-xs font-mono">{signature_status(@package.signature)}</div>
            </div>

            <div
              :if={@package.source_type == :first_party}
              class="rounded-xl border border-sr-line p-4 space-y-2"
            >
              <div class="text-sm font-semibold">First-party Provenance</div>
              <div class="text-xs text-sr-muted">Release</div>
              <div class="text-xs font-mono">{@package.source_release_tag}</div>
              <div class="text-xs text-sr-muted mt-2">OCI reference</div>
              <div class="text-xs font-mono break-all">{@package.source_oci_ref}</div>
              <div class="text-xs text-sr-muted mt-2">OCI digest</div>
              <div class="text-xs font-mono break-all">{@package.source_oci_digest}</div>
              <div class="text-xs text-sr-muted mt-2">Bundle digest</div>
              <div class="text-xs font-mono break-all">{@package.source_bundle_digest}</div>
              <div class="text-xs text-sr-muted mt-2">Verification</div>
              <div class="text-xs">{@package.verification_status || "unknown"}</div>
            </div>

            <div
              :if={@can_stage_plugins and @package.status == :staged}
              class="rounded-xl border border-sr-line p-4 space-y-3"
            >
              <div class="text-sm font-semibold">Upload Wasm Blob</div>
              <p class="text-xs text-sr-muted">
                Upload the compiled `.wasm` binary to complete this package.
              </p>

              <.form
                for={%{}}
                phx-change="wasm_upload_change"
                phx-submit="upload_wasm"
                class="space-y-3"
              >
                <.live_file_input
                  upload={@uploads.wasm_blob}
                  class={
                    ui_field_class(
                      class:
                        "w-full file:mr-3 file:rounded-sr-control file:border-0 file:bg-sr-subtle file:px-3 file:py-1.5 file:text-sm file:font-semibold file:text-sr-ink"
                    )
                  }
                  phx-change="wasm_upload_change"
                />

                <%= for entry <- @uploads.wasm_blob.entries do %>
                  <div class="flex items-center gap-2 text-xs">
                    <.icon name="hero-document-text" class="size-4 text-sr-brand" />
                    <span>{entry.client_name}</span>
                    <span class="text-sr-muted">
                      ({Float.round(entry.client_size / 1024, 1)} KB)
                    </span>
                    <%= for err <- upload_errors(@uploads.wasm_blob, entry) do %>
                      <span class="text-error text-xs">{wasm_upload_error(err)}</span>
                    <% end %>
                  </div>
                <% end %>

                <div class="flex justify-end">
                  <.ui_button
                    type="submit"
                    disabled={@uploads.wasm_blob.entries == []}
                    size="sm"
                    variant="primary"
                  >
                    Upload Wasm
                  </.ui_button>
                </div>
              </.form>

              <%= if @upload_errors != [] do %>
                <div class="rounded-lg border border-error/40 bg-error/5 p-2 text-xs text-error">
                  <%= for error <- @upload_errors do %>
                    <div>{error}</div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <div class="rounded-xl border border-sr-line p-4 space-y-2">
              <div class="text-sm font-semibold">Wasm Package Requests</div>
              <div :if={@can_stage_plugins and @package.status == :staged} class="space-y-2">
                <div class="text-xs text-sr-muted">
                  Upload endpoint expires
                  <.user_time
                    id="admin-plugin-upload-endpoint-expires-at"
                    value={@upload_expires_at}
                    timezone={@current_scope.user.timezone || "Etc/UTC"}
                    style={:compact}
                  />
                </div>
                <pre class="bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= @upload_url %>
    </pre>
                <div class="text-xs text-sr-muted">
                  Upload token
                </div>
                <pre class="bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= @upload_token %>
    </pre>
              </div>
              <div class="text-xs text-sr-muted">
                Download endpoint expires
                <.user_time
                  id="admin-plugin-download-endpoint-expires-at"
                  value={@download_expires_at}
                  timezone={@current_scope.user.timezone || "Etc/UTC"}
                  style={:compact}
                />
              </div>
              <pre class="bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= @download_url %>
    </pre>
              <div class="text-xs text-sr-muted">
                Download token
              </div>
              <pre class="bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= @download_token %>
    </pre>
              <div class="text-xs text-sr-muted">
                Example download
              </div>
              <pre class="bg-sr-subtle/50 p-3 rounded-lg text-xs font-mono overflow-x-auto">
    <%= if @download_url && @download_token do %>curl -fsSL -X POST -H "x-serviceradar-plugin-token: <%= @download_token %>" "<%= @download_url %>" -o plugin.wasm<% end %>
    </pre>
            </div>

            <div class="rounded-xl border border-sr-line p-4">
              <div class="text-sm font-semibold">Version History</div>
              <%= if @versions == [] do %>
                <p class="mt-2 text-xs text-sr-muted">No other versions found.</p>
              <% else %>
                <div class="mt-2 space-y-2">
                  <%= for version <- @versions do %>
                    <div class="flex items-center justify-between text-xs">
                      <div>
                        <span class="font-medium">{version.version}</span>
                        <span class="text-sr-muted">• {version.status}</span>
                        <%= if version.id == @package.id do %>
                          <.ui_badge size="xs" variant="ghost" class="ml-2">current</.ui_badge>
                        <% end %>
                      </div>
                      <.link
                        navigate={plugins_show_path(@plugins_base_path, version.id)}
                        class="text-sr-brand hover:underline"
                      >
                        View
                      </.link>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <div class="mt-6 grid grid-cols-1 lg:grid-cols-2 gap-4">
          <div class="rounded-xl border border-sr-line p-4 space-y-3">
            <div class="text-sm font-semibold">Assignments</div>
            <%= if @recovery_confirmation do %>
              <div
                id="legacy-recovery-confirmation"
                role="alert"
                class={
                  ui_alert_class(variant: "warning", class: "alert-vertical sm:alert-horizontal")
                }
              >
                <div>
                  <div class="font-semibold">{legacy_confirmation_title(@recovery_confirmation)}</div>
                  <p class="mt-1 text-xs">
                    {legacy_confirmation_message(@recovery_confirmation)}
                  </p>
                </div>
                <div class="flex shrink-0 flex-wrap gap-2">
                  <.ui_button
                    id="confirm-legacy-recovery"
                    type="button"
                    phx-click="confirm_legacy_recovery"
                    phx-value-id={@recovery_confirmation.id}
                    phx-value-kind={@recovery_confirmation.kind}
                    size="sm"
                    variant="warning"
                  >
                    {legacy_confirmation_action_label(@recovery_confirmation)}
                  </.ui_button>
                  <.ui_button
                    id="cancel-legacy-recovery"
                    type="button"
                    phx-click="cancel_legacy_recovery"
                    size="sm"
                    variant="ghost"
                  >
                    Cancel
                  </.ui_button>
                </div>
              </div>
            <% end %>
            <%= if @assignments == [] do %>
              <p class="text-xs text-sr-muted">No agents assigned yet.</p>
            <% else %>
              <div class="space-y-2">
                <%= for assignment <- @assignments do %>
                  <% current_package = package_for_assignment(assignment, @versions) %>
                  <% upgrade_target = latest_upgrade_target(assignment, @versions) %>
                  <% approved_targets = approved_version_targets(assignment, @versions) %>
                  <% latest_approved? =
                    latest_approved_assignment_version?(assignment, @versions) %>
                  <% legacy_kind = legacy_recovery_kind_for_display(assignment) %>
                  <% legacy_compatibility = legacy_recovery_compatibility_message(assignment) %>
                  <% legacy_partition_context = legacy_authenticated_partition_message(assignment) %>
                  <% manual_recovery = legacy_manual_recovery_status(assignment) %>
                  <% manual_legacy_state = legacy_manual_presentation_state(assignment) %>
                  <% policy_recovery = legacy_policy_recovery_status(assignment) %>
                  <% credential_rule_recovery? = legacy_credential_rule_recovery?(assignment) %>
                  <div
                    id={"assignment-#{assignment.id}"}
                    class="rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3 text-xs"
                  >
                    <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                      <div>
                        <div class="font-medium flex flex-wrap items-center gap-2">
                          {assignment.agent_uid}
                          <%= if assignment.enabled == false do %>
                            <.ui_badge size="xs" variant="ghost">disabled</.ui_badge>
                          <% end %>
                          <%= if assignment.source == :policy do %>
                            <.ui_badge size="xs" variant="ghost">policy</.ui_badge>
                          <% end %>
                          <%= if legacy_kind == :manual and manual_legacy_state == :completed do %>
                            <.ui_badge size="xs" variant="success">legacy recovered</.ui_badge>
                          <% else %>
                            <%= if legacy_kind do %>
                              <.ui_badge size="xs" variant="warning">legacy unbound</.ui_badge>
                            <% end %>
                          <% end %>
                          <%= if uncovered_assignment?(@assignment_coverage, assignment.id) do %>
                            <.ui_badge
                              size="xs"
                              variant="warning"
                              title={coverage_badge_title(@assignment_coverage, assignment.id)}
                            >
                              no credential rule coverage
                            </.ui_badge>
                          <% end %>
                        </div>
                        <div class="text-sr-muted">
                          every {assignment.interval_seconds}s, timeout {assignment.timeout_seconds}s
                        </div>
                        <div
                          id={"assignment-version-#{assignment.id}"}
                          class="text-sr-muted"
                        >
                          version {package_version(current_package)}
                          <%= if upgrade_target do %>
                            <span>-> newer {upgrade_target.version}</span>
                          <% else %>
                            <%= if latest_approved? do %>
                              <span class="text-success">· latest approved</span>
                            <% end %>
                          <% end %>
                        </div>
                      </div>
                      <div class="flex flex-wrap items-center gap-2">
                        <%= if legacy_kind == :manual and manual_legacy_state == :actionable do %>
                          <.ui_button
                            id={"request-manual-reapproval-#{assignment.id}"}
                            type="button"
                            phx-click="request_legacy_recovery"
                            phx-value-id={assignment.id}
                            phx-value-kind="manual"
                            disabled={
                              not manual_recovery_action_enabled?(
                                @can_assign_plugins,
                                manual_recovery
                              )
                            }
                            size="xs"
                            variant="warning"
                          >
                            {manual_recovery_action_label(manual_recovery)}
                          </.ui_button>
                        <% end %>
                        <%= if legacy_kind == :policy do %>
                          <.ui_button
                            id={"request-policy-reconciliation-#{assignment.id}"}
                            type="button"
                            phx-click="request_legacy_recovery"
                            phx-value-id={assignment.id}
                            phx-value-kind="policy"
                            disabled={
                              not policy_recovery_action_enabled?(
                                @can_assign_plugins,
                                @can_reconcile_credential_rules,
                                credential_rule_recovery?,
                                policy_recovery
                              )
                            }
                            size="xs"
                            variant="warning"
                          >
                            {policy_recovery_action_label(
                              @can_reconcile_credential_rules,
                              credential_rule_recovery?,
                              policy_recovery
                            )}
                          </.ui_button>
                        <% end %>
                        <%= if is_nil(legacy_kind) and assignment.source == :policy do %>
                          <span class="text-[11px] text-sr-muted">managed by policy</span>
                        <% end %>
                        <%= if is_nil(legacy_kind) and assignment.source != :policy do %>
                          <%= if upgrade_target do %>
                            <.ui_button
                              id={"upgrade-assignment-#{assignment.id}"}
                              type="button"
                              phx-click="upgrade_assignment"
                              phx-value-id={assignment.id}
                              phx-value-target-package-id={upgrade_target.id}
                              data-confirm={"Upgrade this assignment to #{upgrade_target.version}?"}
                              size="xs"
                              variant="primary"
                            >
                              Upgrade
                            </.ui_button>
                          <% end %>
                          <%= if approved_targets != [] do %>
                            <form
                              id={"assignment-version-form-#{assignment.id}"}
                              phx-submit="upgrade_assignment"
                              phx-value-id={assignment.id}
                              class="flex items-center gap-1"
                            >
                              <select
                                id={"assignment-version-select-#{assignment.id}"}
                                name="assignment_upgrade[target_package_id]"
                                aria-label={"Change version for #{assignment.agent_uid}"}
                                required
                                class={
                                  ui_field_class(size: "xs", class: "w-auto min-w-[4.75rem] shrink-0")
                                }
                              >
                                <option value="" selected disabled>Change version</option>
                                <%= for target <- approved_targets do %>
                                  <option value={target.id}>
                                    {assignment_version_option_label(target, current_package)}
                                  </option>
                                <% end %>
                              </select>
                              <.ui_button
                                id={"apply-assignment-version-#{assignment.id}"}
                                type="submit"
                                size="xs"
                                variant="ghost"
                              >
                                Apply
                              </.ui_button>
                            </form>
                          <% end %>
                        <% end %>
                        <%= if is_nil(legacy_kind) do %>
                          <.ui_button
                            type="button"
                            phx-click="delete_assignment"
                            phx-value-id={assignment.id}
                            data-confirm="Remove this assignment?"
                            size="xs"
                            variant="ghost"
                          >
                            Remove
                          </.ui_button>
                        <% end %>
                      </div>
                    </div>
                    <%= if legacy_kind == :manual and manual_legacy_state != :actionable do %>
                      <div
                        id={"legacy-assignment-recovery-#{assignment.id}"}
                        role="status"
                        class={[
                          "mt-3 rounded-md border px-3 py-2 text-xs",
                          manual_legacy_state == :completed &&
                            "border-success/30 bg-success/5 text-sr-muted",
                          manual_legacy_state != :completed &&
                            "border-sr-line bg-sr-subtle/30 text-sr-muted"
                        ]}
                      >
                        <div class="font-medium">
                          {legacy_manual_presentation_title(manual_legacy_state)}
                        </div>
                        <p class="mt-1">
                          {legacy_manual_presentation_message(manual_legacy_state)}
                        </p>
                      </div>
                    <% else %>
                      <%= if legacy_kind do %>
                        <div
                          id={"legacy-assignment-recovery-#{assignment.id}"}
                          role="status"
                          class={ui_alert_class(variant: "warning", class: "alert-vertical mt-3")}
                        >
                          <div>
                            <div class="font-semibold">{legacy_recovery_label(legacy_kind)}</div>
                            <p class="mt-1 text-xs">{legacy_recovery_message(legacy_kind)}</p>
                            <p
                              :if={legacy_kind == :policy and legacy_recovery_owner_label(assignment)}
                              class="mt-1 text-xs"
                            >
                              Owner: {legacy_recovery_owner_label(assignment)}
                            </p>
                            <p :if={legacy_compatibility} class="mt-1 text-xs">
                              {legacy_compatibility}
                            </p>
                            <p :if={legacy_partition_context} class="mt-1 text-xs">
                              {legacy_partition_context}
                            </p>
                            <p
                              :if={
                                legacy_kind == :manual and
                                  legacy_manual_recovery_message(manual_recovery)
                              }
                              class="mt-1 text-xs font-medium"
                            >
                              {legacy_manual_recovery_message(manual_recovery)}
                            </p>
                            <p
                              :if={
                                legacy_kind == :policy and
                                  legacy_policy_recovery_message(policy_recovery)
                              }
                              class="mt-1 text-xs font-medium"
                            >
                              {legacy_policy_recovery_message(policy_recovery)}
                            </p>
                            <p
                              :if={
                                legacy_kind == :policy and credential_rule_recovery? and
                                  not @can_reconcile_credential_rules
                              }
                              class="mt-1 text-xs"
                            >
                              You also need credential-management permission to reconcile this credential rule.
                            </p>
                          </div>
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <div class="rounded-xl border border-sr-line p-4 space-y-3">
            <div class="text-sm font-semibold">Assign to Agent</div>
            <.credential_rule_assignment_banner
              :if={
                producer_schedule_provisioned?(@package) or
                  (is_list(@credential_fields) and @credential_fields != [])
              }
              plugin_id={@package.plugin_id}
              coverage={@credential_coverage}
              producer_schedule?={producer_schedule_provisioned?(@package)}
            />
            <form
              :if={!producer_schedule_provisioned?(@package)}
              phx-submit="create_assignment"
              phx-change="assignment_change"
              class="space-y-3"
            >
              <div>
                <label class="flex items-center justify-between gap-2">
                  <span class="text-sm font-medium text-sr-ink">Agent</span>
                </label>
                <select name="assignment[agent_uid]" class={ui_field_class(class: "w-full")}>
                  <option value="">Select an agent</option>
                  <%= for agent <- @agents do %>
                    <option value={agent.uid} selected={@assignment_form["agent_uid"] == agent.uid}>
                      {agent_label(agent)}
                    </option>
                  <% end %>
                </select>
              </div>
              <%= if @authenticated_partition_preview do %>
                <div
                  id="authenticated-partition-preview"
                  role="status"
                  class={
                    ui_alert_class(
                      variant:
                        if(@authenticated_partition_preview.state == :available,
                          do: "info",
                          else: "warning"
                        ),
                      class: "flex-col"
                    )
                  }
                >
                  <%= if @authenticated_partition_preview.state == :available do %>
                    <div>
                      <div class="font-semibold">
                        Authenticated partition: {@authenticated_partition_preview.partition_id}
                      </div>
                      <p class="mt-1 text-xs">
                        Derived from this agent's current live mTLS control session. It is informational
                        only and will be resolved again when you save.
                      </p>
                    </div>
                  <% else %>
                    <div>
                      <div class="font-semibold">Authenticated partition: unavailable</div>
                      <p class="mt-1 text-xs">
                        {authenticated_partition_preview_message(@authenticated_partition_preview)}
                      </p>
                    </div>
                  <% end %>
                </div>
              <% end %>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Interval (seconds)</span>
                  </label>
                  <input
                    type="number"
                    min={assignment_interval_min(@package)}
                    name="assignment[interval_seconds]"
                    value={@assignment_form["interval_seconds"]}
                    class={ui_field_class(class: "w-full")}
                  />
                </div>
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Timeout (seconds)</span>
                  </label>
                  <input
                    type="number"
                    min={assignment_timeout_min(@package)}
                    name="assignment[timeout_seconds]"
                    value={@assignment_form["timeout_seconds"]}
                    class={ui_field_class(class: "w-full")}
                  />
                </div>
              </div>
              <%= if config_schema_present?(@package.config_schema) do %>
                <div class="rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3 space-y-3">
                  <div class="text-xs font-semibold text-sr-muted">Configuration</div>
                  <.plugin_config_fields
                    schema={@package.config_schema}
                    params={assignment_params_map(@assignment_form)}
                    base_name="assignment[params]"
                    credential_coverage={@credential_coverage}
                  />
                </div>

                <details class="rounded-lg border border-sr-line/70 bg-sr-surface/60 p-3">
                  <summary class="cursor-pointer text-xs font-semibold text-sr-muted">
                    Raw Params (JSON)
                  </summary>
                  <div class="mt-3">
                    <textarea
                      name="assignment[params_raw]"
                      class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                    ><%= assignment_params_raw(@assignment_form) %></textarea>
                  </div>
                </details>
              <% else %>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                  <div>
                    <label class="flex items-center justify-between gap-2">
                      <span class="text-sm font-medium text-sr-ink">Params (JSON)</span>
                    </label>
                    <textarea
                      name="assignment[params]"
                      class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                    ><%= assignment_params_raw(@assignment_form) %></textarea>
                  </div>
                  <div>
                    <label class="flex items-center justify-between gap-2">
                      <span class="text-sm font-medium text-sr-ink">Permissions Override (JSON)</span>
                    </label>
                    <textarea
                      name="assignment[permissions_override]"
                      class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                    ><%= @assignment_form["permissions_override"] %></textarea>
                  </div>
                </div>
              <% end %>
              <%= if config_schema_present?(@package.config_schema) do %>
                <div>
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Permissions Override (JSON)</span>
                  </label>
                  <textarea
                    name="assignment[permissions_override]"
                    class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                  ><%= @assignment_form["permissions_override"] %></textarea>
                </div>
              <% end %>
              <div>
                <label class="flex items-center justify-between gap-2">
                  <span class="text-sm font-medium text-sr-ink">Resources Override (JSON)</span>
                </label>
                <textarea
                  name="assignment[resources_override]"
                  class={ui_field_class(mono: true, class: "w-full min-h-[80px] py-2.5 text-xs")}
                ><%= @assignment_form["resources_override"] %></textarea>
              </div>
              <div class="flex justify-end">
                <.ui_button
                  type="submit"
                  disabled={
                    assignment_submit_disabled?(
                      @package,
                      @blob_present,
                      @authenticated_partition_preview
                    )
                  }
                  size="sm"
                  variant="primary"
                >
                  Assign
                </.ui_button>
              </div>
            </form>
            <%= if not producer_schedule_provisioned?(@package) and @package.status != :approved do %>
              <p class="text-xs text-sr-muted">
                Approve the package before assigning it to agents.
              </p>
            <% end %>
            <%= if not producer_schedule_provisioned?(@package) and @package.status == :approved and
                    not blob_present?(@blob_present) do %>
              <p class="text-xs text-warning">
                Upload the Wasm blob before assigning this package.
              </p>
            <% end %>
          </div>
        </div>

        <form
          class="mt-6 space-y-4"
          phx-submit={review_submit_action(@package)}
          phx-change="review_change"
        >
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">
                  Approved Capabilities (comma separated)
                </span>
              </label>
              <input
                type="text"
                name="review[approved_capabilities]"
                value={@review_form["approved_capabilities"]}
                class={ui_field_class(class: "w-full")}
                placeholder="Leave blank to accept requested capabilities"
              />
              <p class="mt-1 text-xs text-sr-muted">
                Blank grants every requested capability (including sensitive ones). If you list
                capabilities explicitly, include each sensitive capability the plugin needs (for
                example <code class="font-mono">http_request</code>) — anything omitted is denied.
              </p>
            </div>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Reason (for deny/revoke)</span>
              </label>
              <input
                type="text"
                name="review[denied_reason]"
                value={@review_form["denied_reason"]}
                class={ui_field_class(class: "w-full")}
                placeholder="Optional"
              />
            </div>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Approved Permissions (JSON)</span>
              </label>
              <textarea
                name="review[approved_permissions]"
                class={ui_field_class(mono: true, class: "w-full min-h-[120px] py-2.5 text-xs")}
                placeholder="Leave blank to accept requested permissions"
              ><%= @review_form["approved_permissions"] %></textarea>
            </div>
            <div>
              <label class="flex items-center justify-between gap-2">
                <span class="text-sm font-medium text-sr-ink">Approved Resources (JSON)</span>
              </label>
              <textarea
                name="review[approved_resources]"
                class={ui_field_class(mono: true, class: "w-full min-h-[120px] py-2.5 text-xs")}
                placeholder="Leave blank to accept requested resources"
              ><%= @review_form["approved_resources"] %></textarea>
            </div>
          </div>

          <div class="flex flex-wrap justify-end gap-2 pt-2">
            <%= if @package.status == :staged do %>
              <.ui_button type="submit" disabled={!@can_approve_plugins} size="sm" variant="primary">
                Approve
              </.ui_button>
              <.ui_button
                type="button"
                phx-click="deny_package"
                phx-value-id={@package.id}
                disabled={!@can_approve_plugins}
                size="sm"
                variant="outline"
              >
                Deny
              </.ui_button>
              <p :if={!@can_approve_plugins} class="w-full text-right text-xs text-sr-muted">
                You do not have permission to approve or deny plugin packages.
              </p>
            <% end %>

            <%= if @package.status == :approved do %>
              <.ui_button
                type="button"
                phx-click="revoke_package"
                phx-value-id={@package.id}
                size="sm"
                variant="outline"
              >
                Revoke
              </.ui_button>
            <% end %>

            <%= if @package.status in [:denied, :revoked] do %>
              <.ui_button
                type="button"
                phx-click="restage_package"
                phx-value-id={@package.id}
                size="sm"
                variant="outline"
              >
                Move to Staged
              </.ui_button>
            <% end %>

            <.ui_button
              type="button"
              phx-click="delete_package"
              phx-value-id={@package.id}
              data-confirm="Delete this package and remove all assignments?"
              size="sm"
              variant="outline"
            >
              Delete Package
            </.ui_button>

            <.ui_button navigate={@plugins_base_path} size="sm" variant="neutral">
              Close
            </.ui_button>
          </div>
        </form>
      </div>
    </section>
    """
  end

  defp review_submit_action(package) do
    case package.status do
      :staged -> "approve_package"
      _ -> "noop"
    end
  end

  defp list_assignments(package_id, scope) do
    Assignments.list(%{"plugin_package_id" => package_id}, scope: scope)
  end

  defp list_plugin_assignments(plugin_id, scope) do
    plugin_id
    |> then(&Assignments.list(%{"plugin_id" => &1}, scope: scope))
    |> Enum.reject(&legacy_unbound_assignment?/1)
  end

  defp schedule_policy_recovery_poll(socket, legacy_assignment_id, recovery) when is_map(recovery) do
    case legacy_recovery_result_state(recovery) do
      state when state in [:queued, :pending] ->
        schedule_policy_recovery_poll(socket, legacy_assignment_id, make_ref(), 0)

      _ ->
        socket
    end
  end

  defp schedule_policy_recovery_poll(socket, _legacy_assignment_id, _recovery), do: socket

  defp schedule_policy_recovery_poll(socket, legacy_assignment_id, poll_ref, attempt)
       when is_binary(legacy_assignment_id) and is_reference(poll_ref) and is_integer(attempt) and
              attempt < @policy_recovery_poll_attempt_limit do
    next_attempt = attempt + 1

    if connected?(socket) do
      Process.send_after(
        self(),
        {:refresh_policy_recovery, legacy_assignment_id, poll_ref, next_attempt},
        @policy_recovery_poll_delay_ms
      )
    end

    polls =
      Map.put(socket.assigns.policy_recovery_polls, legacy_assignment_id, %{
        ref: poll_ref,
        attempt: next_attempt
      })

    assign(socket, :policy_recovery_polls, polls)
  end

  defp schedule_policy_recovery_poll(socket, legacy_assignment_id, _poll_ref, _attempt) do
    clear_policy_recovery_poll(socket, legacy_assignment_id)
  end

  defp clear_policy_recovery_poll(socket, legacy_assignment_id) do
    assign(
      socket,
      :policy_recovery_polls,
      Map.delete(socket.assigns.policy_recovery_polls, legacy_assignment_id)
    )
  end

  defp current_policy_recovery_poll?(%{ref: poll_ref, attempt: attempt}, poll_ref, attempt), do: true

  defp current_policy_recovery_poll?(_poll, _poll_ref, _attempt), do: false

  defp policy_recovery_state_for_assignment(assignments, legacy_assignment_id) do
    assignments
    |> Enum.find(&(assignment_id(&1) == legacy_assignment_id))
    |> legacy_policy_recovery_status()
    |> value_from_map(:state)
  end

  defp list_versions(plugin_id, scope) do
    Packages.list(%{"plugin_id" => plugin_id}, scope: scope)
  end

  defp policy_requires_verification?(package, policy) do
    source =
      case package.source_type do
        value when is_atom(value) -> Atom.to_string(value)
        value when is_binary(value) -> value
        _ -> ""
      end

    policy.require_gpg_for_github && source == "github" && is_nil(package.gpg_verified_at)
  end

  defp assign_package_urls(socket, package, scope) do
    case prepare_package_for_urls(socket, package, scope) do
      {:ok, package} ->
        {upload_url, upload_token, upload_expires_at} = upload_access(socket, package)

        {download_token, download_expires_at} =
          Storage.sign_token(
            :download,
            package.id,
            package.wasm_object_key,
            Storage.download_ttl_seconds()
          )

        socket
        |> assign(:selected_package, package)
        |> assign(:upload_url, upload_url)
        |> assign(:upload_token, upload_token)
        |> assign(:upload_expires_at, upload_expires_at)
        |> assign(:download_url, Storage.download_url(package.id))
        |> assign(:download_token, download_token)
        |> assign(:download_expires_at, download_expires_at)
        |> assign(:blob_present, Storage.blob_exists?(package.wasm_object_key))

      {:error, _error} ->
        socket
        |> assign(:upload_url, nil)
        |> assign(:upload_token, nil)
        |> assign(:download_url, nil)
        |> assign(:download_token, nil)
        |> assign(:blob_present, nil)
    end
  end

  defp prepare_package_for_urls(%{assigns: %{can_stage_plugins: true}}, package, scope) do
    ensure_object_key(package, scope)
  end

  defp prepare_package_for_urls(_socket, %{wasm_object_key: key} = package, _scope) when is_binary(key) and key != "",
    do: {:ok, package}

  defp prepare_package_for_urls(_socket, _package, _scope), do: {:error, :missing_object_key}

  defp upload_access(%{assigns: %{can_stage_plugins: true}}, %{status: :staged} = package) do
    {token, expires_at} =
      Storage.sign_token(
        :upload,
        package.id,
        package.wasm_object_key,
        Storage.upload_ttl_seconds()
      )

    {Storage.upload_url(package.id), token, expires_at}
  end

  defp upload_access(_socket, _package), do: {nil, nil, nil}

  defp ensure_object_key(package, scope) do
    if package.wasm_object_key in [nil, ""] do
      object_key = Storage.object_key_for(package)

      package
      |> Ash.Changeset.for_update(:update, %{wasm_object_key: object_key})
      |> Ash.update(scope: scope)
    else
      {:ok, package}
    end
  end

  defp config_schema_present?(schema) when is_map(schema) do
    schema = stringify_keys(schema)
    properties = Map.get(schema, "properties", %{})
    map_size(properties) > 0
  end

  defp config_schema_present?(_), do: false

  defp assignment_params_map(form) when is_map(form) do
    params = Map.get(form, "params", %{})

    cond do
      is_map(params) -> stringify_keys(params)
      is_binary(params) -> parse_json_string(params)
      true -> %{}
    end
  end

  defp assignment_params_map(_), do: %{}

  defp assignment_params_raw(form) when is_map(form) do
    params_raw = Map.get(form, "params_raw", "")
    params = Map.get(form, "params", "")

    cond do
      is_binary(params_raw) and String.trim(params_raw) != "" -> params_raw
      is_binary(params) -> params
      is_map(params) -> Jason.encode!(params)
      true -> ""
    end
  end

  defp assignment_params_raw(_), do: ""

  defp parse_json_string(value) when is_binary(value) do
    case Jason.decode(String.trim(value)) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp parse_json_string(_), do: %{}

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp parse_assignment_params(params, package) do
    agent_uid = params["agent_uid"]
    timing = assignment_timing_defaults(package)

    interval_seconds =
      params["interval_seconds"]
      |> parse_int(timing.interval_seconds)
      |> clamp_int(timing.min_interval_seconds, timing.max_interval_seconds)

    timeout_seconds =
      params["timeout_seconds"]
      |> parse_int(timing.timeout_seconds)
      |> max(timing.min_timeout_seconds)

    # Prefer structured params (from config fields) over raw JSON
    # Only use params_raw if params["params"] is empty/nil
    params_source = resolve_params_source(params)
    config_schema = package.config_schema

    with true <-
           (is_binary(agent_uid) and String.trim(agent_uid) != "") ||
             {:error, "agent_uid required"},
         {:ok, parsed_params} <-
           parse_optional_json_map(params_source, "Params"),
         {:ok, permissions_override} <-
           parse_optional_json_map(params["permissions_override"], "Permissions override"),
         {:ok, resources_override} <-
           parse_optional_json_map(params["resources_override"], "Resources override") do
      # Normalize params using the config schema to convert string values to proper types
      normalized_params = normalize_assignment_params(parsed_params, config_schema)

      {:ok,
       %{
         agent_uid: String.trim(agent_uid),
         plugin_package_id: package.id,
         interval_seconds: interval_seconds,
         timeout_seconds: timeout_seconds,
         params: normalized_params,
         permissions_override: permissions_override,
         resources_override: resources_override
       }}
    else
      {:error, {:invalid_json, message}} -> {:error, {:invalid_json, message}}
      {:error, message} -> {:error, message}
      _ -> {:error, "invalid assignment"}
    end
  end

  # Prefer structured params from config fields over raw JSON textarea
  defp resolve_params_source(params) do
    structured_params = params["params"]
    raw_params = params["params_raw"]

    cond do
      # If structured params is a non-empty map, use it (config fields were filled)
      is_map(structured_params) and map_size(structured_params) > 0 ->
        structured_params

      # If raw params has content, use it
      is_binary(raw_params) and String.trim(raw_params) != "" ->
        raw_params

      # Fall back to structured params (might be empty map or nil)
      true ->
        structured_params
    end
  end

  defp normalize_assignment_params(params, config_schema) when is_map(params) and is_map(config_schema) do
    alias ServiceRadar.Plugins.ConfigSchema

    schema = stringify_keys(config_schema)
    required_fields = Map.get(schema, "required", [])

    # Remove empty strings only for non-required fields
    # Required fields with empty strings should fail validation with a clear error
    cleaned_params =
      params
      |> Enum.reject(fn {k, v} -> v == "" and k not in required_fields end)
      |> Map.new()

    if map_size(schema) > 0 do
      ConfigSchema.normalize_params(schema, cleaned_params)
    else
      cleaned_params
    end
  end

  defp normalize_assignment_params(params, _config_schema) when is_map(params), do: params

  defp parse_review_params(params) do
    approved_capabilities = parse_list(params["approved_capabilities"])

    with {:ok, approved_permissions} <-
           parse_optional_json_map(params["approved_permissions"], "Approved permissions"),
         {:ok, approved_resources} <-
           parse_optional_json_map(params["approved_resources"], "Approved resources") do
      {:ok,
       %{
         approved_capabilities: approved_capabilities,
         approved_permissions: approved_permissions,
         approved_resources: approved_resources
       }}
    end
  end

  defp parse_list(nil), do: []
  defp parse_list(""), do: []

  defp parse_list(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_list(list) when is_list(list), do: list
  defp parse_list(_), do: []

  defp default_review_form do
    %{
      "approved_capabilities" => "",
      "approved_permissions" => "",
      "approved_resources" => "",
      "denied_reason" => ""
    }
  end

  defp build_review_form(package, prior_approved \\ nil)

  defp build_review_form(%{status: :staged} = package, %{} = prior) do
    %{
      "approved_capabilities" =>
        fallback_empty(
          format_list_value(package.approved_capabilities),
          format_list_value(prior.approved_capabilities)
        ),
      "approved_permissions" =>
        fallback_empty(
          format_json_value(package.approved_permissions),
          format_json_value(prior.approved_permissions)
        ),
      "approved_resources" =>
        fallback_empty(
          format_json_value(package.approved_resources),
          format_json_value(prior.approved_resources)
        ),
      "denied_reason" => package.denied_reason || ""
    }
  end

  defp build_review_form(package, _prior) do
    %{
      "approved_capabilities" => format_list_value(package.approved_capabilities),
      "approved_permissions" => format_json_value(package.approved_permissions),
      "approved_resources" => format_json_value(package.approved_resources),
      "denied_reason" => package.denied_reason || ""
    }
  end

  defp fallback_empty("", fallback), do: fallback
  defp fallback_empty(value, _fallback), do: value

  defp requested_capabilities(package) do
    Map.get(package.manifest || %{}, "capabilities") ||
      Map.get(package.manifest || %{}, :capabilities) || []
  end

  defp sensitive_capability?(capability) when is_binary(capability) do
    capability in @sensitive_capabilities
  end

  defp sensitive_capability?(_capability), do: false

  defp sensitive_requested_capabilities(package) do
    package
    |> requested_capabilities()
    |> Enum.filter(&sensitive_capability?/1)
  end

  defp requested_permissions(package) do
    Map.get(package.manifest || %{}, "permissions") ||
      Map.get(package.manifest || %{}, :permissions) || %{}
  end

  defp requested_resources(package) do
    Map.get(package.manifest || %{}, "resources") || Map.get(package.manifest || %{}, :resources) ||
      %{}
  end

  defp requested_actions(package) do
    case Map.get(package.manifest || %{}, "actions") || Map.get(package.manifest || %{}, :actions) do
      actions when is_list(actions) -> actions
      _ -> []
    end
  end

  defp action_id(action), do: action_value(action, "action_id") || "unknown"
  defp action_label(action), do: action_value(action, "label") || action_id(action)
  defp action_version(action), do: action_value(action, "version") || "1.0.0"
  defp action_description(action), do: action_value(action, "description")
  defp action_safety(action), do: action_value(action, "safety_classification") || "standard"
  defp action_timeout(action), do: action_value(action, "timeout_seconds") || 60

  defp action_requires_confirmation?(action) do
    action_value(action, "requires_confirmation") in [true, "true", 1, "1"]
  end

  defp action_scopes(action) do
    case action_value(action, "scopes") do
      scopes when is_list(scopes) -> Enum.map(scopes, &to_string/1)
      _ -> []
    end
  end

  defp action_value(action, key) when is_map(action) do
    Map.get(action, key) || Map.get(action, action_atom_key(key))
  end

  defp action_value(_action, _key), do: nil

  defp action_atom_key("action_id"), do: :action_id
  defp action_atom_key("label"), do: :label
  defp action_atom_key("version"), do: :version
  defp action_atom_key("description"), do: :description
  defp action_atom_key("safety_classification"), do: :safety_classification
  defp action_atom_key("timeout_seconds"), do: :timeout_seconds
  defp action_atom_key("requires_confirmation"), do: :requires_confirmation
  defp action_atom_key("scopes"), do: :scopes
  defp action_atom_key(_key), do: nil

  defp default_assignment_form(package \\ nil) do
    timing = assignment_timing_defaults(package)

    %{
      "agent_uid" => "",
      "interval_seconds" => Integer.to_string(timing.interval_seconds),
      "timeout_seconds" => Integer.to_string(timing.timeout_seconds),
      "params" => "",
      "params_raw" => "",
      "permissions_override" => "",
      "resources_override" => ""
    }
  end

  defp assignment_interval_min(package), do: assignment_timing_defaults(package).min_interval_seconds

  defp assignment_timeout_min(package), do: assignment_timing_defaults(package).min_timeout_seconds

  defp assignment_timing_defaults(package) do
    schedule = first_producer_schedule(package)

    %{
      interval_seconds:
        positive_int(
          schedule_get(schedule, "default_cadence_seconds"),
          @fallback_assignment_interval_seconds
        ),
      timeout_seconds:
        positive_int(
          schedule_get(schedule, "timeout_seconds"),
          @fallback_assignment_timeout_seconds
        ),
      min_interval_seconds:
        positive_int(
          schedule_get(schedule, "min_cadence_seconds"),
          @fallback_assignment_interval_min
        ),
      max_interval_seconds: positive_int(schedule_get(schedule, "max_cadence_seconds"), nil),
      min_timeout_seconds: @fallback_assignment_timeout_min
    }
  end

  defp first_producer_schedule(%{producer_schedules: [schedule | _]}) when is_map(schedule), do: schedule

  defp first_producer_schedule(%{"producer_schedules" => [schedule | _]}) when is_map(schedule), do: schedule

  defp first_producer_schedule(_package), do: nil

  defp producer_schedule_provisioned?(package), do: match?(%{}, first_producer_schedule(package))

  defp producer_schedule_assignment_message do
    "This plugin is assigned from a credential rule under Settings → Networks → Credentials. Pick the agent as the rule Scope Value; do not assign it here."
  end

  defp schedule_get(nil, _key), do: nil

  defp schedule_get(schedule, key) when is_map(schedule) do
    Map.get(schedule, key) || Map.get(schedule, schedule_atom_key(key))
  end

  defp schedule_atom_key("default_cadence_seconds"), do: :default_cadence_seconds
  defp schedule_atom_key("timeout_seconds"), do: :timeout_seconds
  defp schedule_atom_key("min_cadence_seconds"), do: :min_cadence_seconds
  defp schedule_atom_key("max_cadence_seconds"), do: :max_cadence_seconds
  defp schedule_atom_key(_key), do: nil

  defp positive_int(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> fallback
    end
  end

  defp positive_int(_value, fallback), do: fallback

  defp clamp_int(value, low, high) when is_integer(low) and is_integer(high) and high >= low do
    value |> Kernel.max(low) |> Kernel.min(high)
  end

  defp clamp_int(value, low, _high) when is_integer(low), do: Kernel.max(value, low)
  defp clamp_int(value, _low, _high), do: value

  defp agent_label(agent) do
    name = agent.name || agent.host || agent.uid
    "#{name} (#{agent.uid})"
  end

  defp existing_assignment(assignments, agent_uid) when is_list(assignments) and is_binary(agent_uid) do
    Enum.find(assignments, fn assignment ->
      assignment.agent_uid == agent_uid and not legacy_unbound_assignment?(assignment)
    end)
  end

  defp existing_assignment(_assignments, _agent_uid), do: nil

  # Partition recovery deliberately derives all identity data from the current
  # authenticated control session. The preview makes that provenance visible,
  # but it is never submitted as assignment input and the recovery command
  # resolves it again immediately before it creates a replacement.
  defp assign_authenticated_partition_preview(socket, agent_uid) do
    case trim_or_nil(agent_uid) do
      nil ->
        assign(socket, :authenticated_partition_preview, nil)

      agent_uid ->
        scope = socket.assigns.current_scope

        preview =
          case Assignments.authenticated_partition_preview(agent_uid, scope: scope) do
            {:ok, preview} -> normalize_authenticated_partition_preview(agent_uid, preview)
            {:error, reason} -> unavailable_partition_preview(agent_uid, reason)
            _other -> unavailable_partition_preview(agent_uid, :unavailable)
          end

        assign(socket, :authenticated_partition_preview, preview)
    end
  rescue
    _exception ->
      # A preview must fail closed. In particular, do not fall back to an
      # agent record, a default partition, or a value from an earlier form.
      assign(
        socket,
        :authenticated_partition_preview,
        unavailable_partition_preview(agent_uid, :unavailable)
      )
  end

  defp normalize_authenticated_partition_preview(agent_uid, preview) when is_map(preview) do
    partition_id = value_from_map(preview, :partition_id)

    if is_binary(partition_id) and String.trim(partition_id) != "" do
      %{
        agent_uid: agent_uid,
        state: :available,
        partition_id: String.trim(partition_id)
      }
    else
      unavailable_partition_preview(agent_uid, value_from_map(preview, :reason) || :unavailable)
    end
  end

  defp normalize_authenticated_partition_preview(agent_uid, _preview),
    do: unavailable_partition_preview(agent_uid, :unavailable)

  defp unavailable_partition_preview(agent_uid, reason) do
    %{
      agent_uid: agent_uid,
      state: :unavailable,
      reason: normalize_partition_preview_reason(reason)
    }
  end

  defp normalize_partition_preview_reason(reason)
       when reason in [
              :agent_offline,
              :authenticated_agent_partition_unavailable,
              :authenticated_agent_partition_mismatch,
              :forbidden,
              :not_found
            ], do: reason

  defp normalize_partition_preview_reason(_reason), do: :unavailable

  defp authenticated_partition_preview_message(%{reason: :agent_offline}),
    do: "No live authenticated control session is available for this agent."

  defp authenticated_partition_preview_message(%{reason: :authenticated_agent_partition_unavailable}),
    do: "The live control session did not provide a trustworthy partition."

  defp authenticated_partition_preview_message(%{reason: :authenticated_agent_partition_mismatch}),
    do: "The live control-session identity does not match the selected agent."

  defp authenticated_partition_preview_message(%{reason: :forbidden}),
    do: "You are not authorized to inspect this agent's live control session."

  defp authenticated_partition_preview_message(%{reason: :not_found}),
    do: "The selected agent is no longer available in your current scope."

  defp authenticated_partition_preview_message(_preview),
    do: "The authenticated partition is unavailable. No saved or default partition will be used."

  defp assignment_submit_disabled?(package, blob_present, preview) do
    package.status != :approved or not blob_present?(blob_present) or
      not match?(%{state: :available}, preview)
  end

  defp legacy_recovery_confirmation(assignments, id, requested_kind) when is_list(assignments) do
    with assignment when not is_nil(assignment) <-
           Enum.find(assignments, &(assignment_id(&1) == id)),
         {:ok, kind} <- legacy_recovery_kind(assignment),
         {:ok, ^kind} <- normalize_legacy_recovery_kind(requested_kind) do
      {:ok,
       %{
         id: assignment_id(assignment),
         kind: kind,
         agent_uid: assignment_value(assignment, :agent_uid),
         owner_label: legacy_recovery_owner_label(assignment),
         credential_rule_recovery?: legacy_credential_rule_recovery?(assignment)
       }}
    else
      nil -> {:error, :not_found}
      {:error, :unsupported_policy_owner} -> {:error, :unsupported_policy_owner}
      {:error, :recovery_unavailable} -> {:error, :recovery_unavailable}
      :error -> {:error, :not_recoverable}
      {:error, _reason} -> {:error, :kind_mismatch}
    end
  end

  defp legacy_recovery_confirmation(_assignments, _id, _requested_kind), do: {:error, :not_found}

  defp recovery_confirmation_matches?(confirmation, id, kind) when is_map(confirmation) do
    case normalize_legacy_recovery_kind(kind) do
      {:ok, normalized_kind} ->
        value_from_map(confirmation, :id) == id and
          value_from_map(confirmation, :kind) == normalized_kind

      :error ->
        false
    end
  end

  defp recovery_confirmation_matches?(_confirmation, _id, _kind), do: false

  defp legacy_recovery_confirmation_allowed?(socket, confirmation) do
    not (value_from_map(confirmation, :kind) == :policy and
           value_from_map(confirmation, :credential_rule_recovery?) == true and
           not socket.assigns.can_reconcile_credential_rules)
  end

  defp credential_recovery_permission_message,
    do: "You need credential-management permission to reconcile this credential rule."

  defp legacy_unbound_assignment?(assignment) do
    assignment_value(assignment, :enabled) == false and
      blank_partition?(assignment_value(assignment, :partition_id))
  end

  defp legacy_recovery_kind(assignment) do
    if legacy_unbound_assignment?(assignment) do
      case core_legacy_recovery_kind(assignment) do
        :manual_reapproval ->
          {:ok, :manual}

        :policy_reconciliation ->
          {:ok, :policy}

        :unsupported_policy_owner ->
          {:error, :unsupported_policy_owner}

        :not_recoverable ->
          {:error, :recovery_unavailable}

        nil ->
          {:error, :recovery_unavailable}
      end
    else
      :error
    end
  end

  defp legacy_recovery_kind_for_display(assignment) do
    if legacy_unbound_assignment?(assignment) do
      case core_legacy_recovery_kind(assignment) do
        :manual_reapproval ->
          :manual

        :policy_reconciliation ->
          :policy

        :unsupported_policy_owner ->
          :unsupported_policy_owner

        _ ->
          :recovery_unavailable
      end
    end
  end

  # The core recovery read model owns this classification. In particular, a
  # legacy `source = :policy` value alone does not prove that its historical
  # owner is a current plugin policy or credential rule. A missing detail fails
  # closed: the UI renders a non-actionable warning instead of deriving an
  # action from legacy source text.
  defp core_legacy_recovery_kind(assignment) do
    projected_kind =
      assignment
      |> legacy_recovery_details()
      |> value_from_map(:recovery_kind)

    projected_kind = projected_kind || assignment_value(assignment, :recovery_kind)

    case projected_kind do
      kind when kind in [:manual_reapproval, "manual_reapproval"] ->
        :manual_reapproval

      kind when kind in [:policy_reconciliation, "policy_reconciliation"] ->
        :policy_reconciliation

      kind when kind in [:unsupported_policy_owner, "unsupported_policy_owner"] ->
        :unsupported_policy_owner

      kind when kind in [:not_recoverable, "not_recoverable"] ->
        :not_recoverable

      _ ->
        nil
    end
  end

  defp legacy_recovery_label(:manual), do: "Unbound legacy manual assignment"
  defp legacy_recovery_label(:policy), do: "Unbound legacy policy assignment"
  defp legacy_recovery_label(:unsupported_policy_owner), do: "Unbound legacy policy assignment"
  defp legacy_recovery_label(:recovery_unavailable), do: "Unbound legacy assignment"
  defp legacy_recovery_label(_kind), do: "Unbound legacy assignment"

  defp legacy_recovery_message(:manual),
    do:
      "This historical row has no trustworthy partition. Reapproval creates a new partition-bound assignment from the live mTLS session; this row remains disabled for audit history."

  defp legacy_recovery_message(:policy),
    do:
      "This historical row has no trustworthy partition. It cannot be cloned or edited here; reconciliation re-evaluates the current authoritative policy or credential rule."

  defp legacy_recovery_message(:unsupported_policy_owner), do: unsupported_policy_owner_message()

  defp legacy_recovery_message(:recovery_unavailable), do: legacy_recovery_unavailable_message()

  defp legacy_recovery_message(_kind),
    do: "This historical row has no trustworthy partition and requires explicit recovery review."

  defp unsupported_policy_owner_message do
    "This historical policy assignment cannot be reconciled because its owner is not a supported current plugin target policy or credential rule. It remains disabled for audit history; recreate it from a supported current policy or credential rule."
  end

  defp legacy_recovery_unavailable_message do
    "Recovery details are unavailable, so this historical row remains disabled. Refresh before taking any recovery action."
  end

  defp legacy_policy_recovery_status(assignment) do
    assignment
    |> legacy_recovery_details()
    |> value_from_map(:policy_recovery)
  end

  defp legacy_manual_recovery_status(assignment) do
    assignment
    |> legacy_recovery_details()
    |> value_from_map(:manual_recovery)
  end

  defp legacy_credential_rule_recovery?(assignment) do
    assignment
    |> legacy_recovery_details()
    |> value_from_map(:owner)
    |> value_from_map(:kind)
    |> case do
      kind when kind in [:credential_rule, "credential_rule"] -> true
      _ -> false
    end
  end

  defp policy_recovery_action_enabled?(
         can_assign_plugins,
         can_reconcile_credential_rules,
         credential_rule_recovery?,
         policy_recovery
       ) do
    can_assign_plugins and
      (not credential_rule_recovery? or can_reconcile_credential_rules) and
      not policy_recovery_active?(policy_recovery) and
      policy_recovery_state(policy_recovery) != :reconciled
  end

  defp manual_recovery_action_enabled?(can_assign_plugins, manual_recovery) do
    can_assign_plugins and manual_recovery_state(manual_recovery) != :reapproved
  end

  defp legacy_manual_presentation_state(assignment) do
    if manual_recovery_state(legacy_manual_recovery_status(assignment)) == :reapproved do
      :completed
    else
      case {legacy_config_compatibility_state(assignment), legacy_authenticated_partition_state(assignment)} do
        {:compatible, :available} ->
          :actionable

        {:incompatible, _partition_state} ->
          :incompatible

        {:unavailable, _partition_state} ->
          :package_unavailable

        {_config_state, partition_state} when partition_state in [:mismatch, :unavailable] ->
          :identity_unavailable

        _ ->
          :unavailable
      end
    end
  end

  defp legacy_manual_presentation_title(:completed), do: "Recovered legacy record"
  defp legacy_manual_presentation_title(:incompatible), do: "Inactive legacy record"
  defp legacy_manual_presentation_title(:package_unavailable), do: "Inactive legacy record"
  defp legacy_manual_presentation_title(:identity_unavailable), do: "Legacy record waiting for agent connection"
  defp legacy_manual_presentation_title(_state), do: "Inactive legacy record"

  defp legacy_manual_presentation_message(:completed) do
    "A current partition-bound replacement is active. This disabled audit record does not affect the agent."
  end

  defp legacy_manual_presentation_message(:incompatible) do
    "Its old configuration cannot be migrated safely. This record is disabled and does not affect the agent. Create a new assignment with the current form only if this add-on is still needed."
  end

  defp legacy_manual_presentation_message(:package_unavailable) do
    "Its package is not currently approved, so it cannot be migrated. This record is disabled and does not affect the agent."
  end

  defp legacy_manual_presentation_message(:identity_unavailable) do
    "This record is disabled and does not affect the agent. Reconnect the agent and refresh before attempting recovery."
  end

  defp legacy_manual_presentation_message(_state) do
    "This record is disabled and does not affect the agent. No recovery action is currently available."
  end

  defp manual_recovery_action_label(manual_recovery) do
    case manual_recovery_state(manual_recovery) do
      :reapproved -> "Reapproved"
      _ -> "Reapprove"
    end
  end

  defp policy_recovery_action_label(can_reconcile_credential_rules, true, _policy_recovery)
       when not can_reconcile_credential_rules, do: "Credential permission required"

  defp policy_recovery_action_label(_can_reconcile_credential_rules, _credential_rule_recovery?, policy_recovery) do
    case policy_recovery_state(policy_recovery) do
      :queued ->
        "Reconciliation queued"

      :pending ->
        "Reconciling"

      :reconciled ->
        "Reconciled"

      state
      when state in [
             :no_longer_eligible,
             :owner_not_authoritative,
             :identity_unavailable,
             :identity_changed,
             :package_unapproved,
             :schema_invalid,
             :conflict,
             :denied,
             :failed
           ] ->
        "Retry reconciliation"

      _ ->
        "Reconcile policy"
    end
  end

  defp legacy_policy_recovery_message(nil), do: nil

  defp legacy_policy_recovery_message(policy_recovery) do
    case policy_recovery_state(policy_recovery) do
      :queued ->
        "Policy reconciliation is queued. This row will refresh while the current source is re-evaluated."

      :pending ->
        "Policy reconciliation is running against the current source and live mTLS identity."

      :reconciled ->
        replacement_count = value_from_map(policy_recovery, :replacement_count) || 0

        "Policy reconciliation completed: #{replacement_count} current assignment#{plural_suffix(replacement_count)} restored."

      :no_longer_eligible ->
        "Policy reconciliation completed without a replacement because this target is no longer eligible. Review the current policy and target."

      :owner_not_authoritative ->
        "Policy reconciliation could not run because the historical policy or credential rule is no longer authoritative."

      :identity_unavailable ->
        "Policy reconciliation is waiting for trustworthy live partition evidence. Reconnect the target agent, then retry."

      :identity_changed ->
        "Policy reconciliation stopped because the target's live identity changed. Verify the agent and retry."

      :package_unapproved ->
        "Policy reconciliation stopped because the package is not currently approved. Review and approve the package before retrying."

      :schema_invalid ->
        "Policy reconciliation stopped because the current policy configuration no longer validates. Review the current policy before retrying."

      :conflict ->
        "Policy reconciliation found an enabled assignment for this target and partition. Review the current assignment before retrying."

      :denied ->
        "Policy reconciliation was denied after current authorization was rechecked. Confirm your permissions and retry."

      :failed ->
        "Policy reconciliation did not complete. Review the current source and retry."

      :unavailable ->
        "Policy reconciliation status is temporarily unavailable. Refresh this page before retrying."

      _ ->
        nil
    end
  end

  defp legacy_manual_recovery_message(manual_recovery) do
    case manual_recovery_state(manual_recovery) do
      :reapproved ->
        "Manual reapproval completed. Its partition-bound replacement remains in effect; this historical row stays disabled."

      _ ->
        nil
    end
  end

  defp manual_recovery_state(manual_recovery) when is_map(manual_recovery) do
    case value_from_map(manual_recovery, :state) do
      state when state in [:reapproved, "reapproved"] -> :reapproved
      _ -> nil
    end
  end

  defp manual_recovery_state(_manual_recovery), do: nil

  defp policy_recovery_active?(policy_recovery), do: policy_recovery_state(policy_recovery) in [:queued, :pending]

  defp policy_recovery_state(policy_recovery) when is_map(policy_recovery) do
    case value_from_map(policy_recovery, :state) do
      state when state in [:queued, "queued"] ->
        :queued

      state when state in [:pending, "pending"] ->
        :pending

      state when state in [:reconciled, "reconciled"] ->
        :reconciled

      state when state in [:no_longer_eligible, "no_longer_eligible"] ->
        :no_longer_eligible

      state when state in [:owner_not_authoritative, "owner_not_authoritative"] ->
        :owner_not_authoritative

      state when state in [:identity_unavailable, "identity_unavailable"] ->
        :identity_unavailable

      state when state in [:identity_changed, "identity_changed"] ->
        :identity_changed

      state when state in [:package_unapproved, "package_unapproved"] ->
        :package_unapproved

      state when state in [:schema_invalid, "schema_invalid"] ->
        :schema_invalid

      state when state in [:conflict, "conflict"] ->
        :conflict

      state when state in [:denied, "denied"] ->
        :denied

      state when state in [:failed, "failed"] ->
        :failed

      state when state in [:unavailable, "unavailable"] ->
        :unavailable

      _ ->
        nil
    end
  end

  defp policy_recovery_state(_policy_recovery), do: nil

  defp policy_recovery_terminal_message(:reconciled),
    do: "Policy reconciliation completed. The recovered assignment now reflects the current authoritative policy."

  defp policy_recovery_terminal_message(:no_longer_eligible),
    do: "Policy reconciliation completed without a replacement because the target is no longer eligible."

  defp policy_recovery_terminal_message(state) do
    legacy_policy_recovery_message(%{state: state}) ||
      "Policy reconciliation finished. Review the recovery status before retrying."
  end

  defp plural_suffix(1), do: ""
  defp plural_suffix(_count), do: "s"

  defp legacy_confirmation_title(%{kind: :manual}), do: "Confirm manual reapproval"
  defp legacy_confirmation_title(%{kind: :policy}), do: "Confirm policy reconciliation"
  defp legacy_confirmation_title(_confirmation), do: "Confirm legacy recovery"

  defp legacy_confirmation_message(%{kind: :manual, agent_uid: agent_uid}) do
    "Reapprove the legacy manual assignment for #{agent_uid}? The server will resolve current mTLS evidence again and retain the historical row disabled."
  end

  defp legacy_confirmation_message(%{kind: :policy, agent_uid: agent_uid} = confirmation) do
    owner = Map.get(confirmation, :owner_label)
    owner_text = if is_binary(owner) and owner != "", do: " for #{owner}", else: ""

    "Request reconciliation for #{agent_uid}#{owner_text}? The current source, target eligibility, and live mTLS evidence will be re-evaluated."
  end

  defp legacy_confirmation_message(_confirmation),
    do: "The server will validate this recovery against current authorization and live identity evidence."

  defp legacy_confirmation_action_label(%{kind: :manual}), do: "Confirm reapproval"
  defp legacy_confirmation_action_label(%{kind: :policy}), do: "Request reconciliation"
  defp legacy_confirmation_action_label(_confirmation), do: "Confirm recovery"

  defp normalize_legacy_recovery_kind(:manual), do: {:ok, :manual}
  defp normalize_legacy_recovery_kind("manual"), do: {:ok, :manual}
  defp normalize_legacy_recovery_kind(:policy), do: {:ok, :policy}
  defp normalize_legacy_recovery_kind("policy"), do: {:ok, :policy}
  defp normalize_legacy_recovery_kind(_kind), do: :error

  defp assignment_source(assignment) do
    case assignment_value(assignment, :source) do
      :manual -> :manual
      "manual" -> :manual
      :policy -> :policy
      "policy" -> :policy
      _ -> nil
    end
  end

  defp assignment_package_id(assignment), do: assignment_value(assignment, :plugin_package_id)
  defp assignment_id(assignment), do: assignment_value(assignment, :id)

  defp assignment_value(assignment, key) when is_map(assignment), do: value_from_map(assignment, key)

  defp assignment_value(_assignment, _key), do: nil

  defp value_from_map(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value_from_map(_map, _key), do: nil

  defp blank_partition?(partition_id), do: not (is_binary(partition_id) and String.trim(partition_id) != "")

  defp legacy_recovery_details(assignment) do
    case assignment_value(assignment, :recovery) do
      details when is_map(details) -> details
      _ -> %{}
    end
  end

  defp legacy_recovery_owner_label(assignment) do
    owner = assignment |> legacy_recovery_details() |> value_from_map(:owner)
    fallback_id = assignment_value(assignment, :policy_id)

    cond do
      is_map(owner) and is_binary(value_from_map(owner, :label)) and
          value_from_map(owner, :label) != "" ->
        value_from_map(owner, :label)

      is_map(owner) and is_binary(value_from_map(owner, :id)) and value_from_map(owner, :id) != "" ->
        legacy_owner_kind_label(value_from_map(owner, :kind)) <> " " <> value_from_map(owner, :id)

      is_binary(fallback_id) and fallback_id != "" ->
        "Policy #{fallback_id}"

      true ->
        nil
    end
  end

  defp legacy_owner_kind_label(:credential_rule), do: "Credential rule"
  defp legacy_owner_kind_label("credential_rule"), do: "Credential rule"
  defp legacy_owner_kind_label(:policy), do: "Policy"
  defp legacy_owner_kind_label("policy"), do: "Policy"
  defp legacy_owner_kind_label(_kind), do: "Owner"

  defp legacy_recovery_compatibility_message(assignment) do
    compatibility =
      assignment |> legacy_recovery_details() |> value_from_map(:config_compatibility)

    case {value_from_map(compatibility, :state), value_from_map(compatibility, :reason)} do
      {state, _reason} when state in [:compatible, "compatible"] ->
        "Configuration: compatible with the current package schema."

      {state, _reason} when state in [:incompatible, "incompatible"] ->
        "Configuration: the current package schema no longer accepts this historical configuration."

      {state, _reason} when state in [:unavailable, "unavailable"] ->
        "Configuration: the package is unavailable or no longer approved, so recovery cannot proceed."

      _ ->
        nil
    end
  end

  defp legacy_config_compatibility_state(assignment) do
    compatibility =
      assignment |> legacy_recovery_details() |> value_from_map(:config_compatibility)

    case value_from_map(compatibility, :state) do
      state when state in [:compatible, "compatible"] -> :compatible
      state when state in [:incompatible, "incompatible"] -> :incompatible
      state when state in [:unavailable, "unavailable"] -> :unavailable
      _state -> nil
    end
  end

  defp legacy_authenticated_partition_state(assignment) do
    partition =
      assignment |> legacy_recovery_details() |> value_from_map(:authenticated_partition)

    case value_from_map(partition, :state) do
      state when state in [:available, "available"] -> :available
      state when state in [:mismatch, "mismatch"] -> :mismatch
      state when state in [:unavailable, "unavailable"] -> :unavailable
      _state -> nil
    end
  end

  defp legacy_authenticated_partition_message(assignment) do
    partition =
      assignment |> legacy_recovery_details() |> value_from_map(:authenticated_partition)

    state = value_from_map(partition, :state)
    partition_id = value_from_map(partition, :partition_id)

    cond do
      state in [:available, "available"] and is_binary(partition_id) and
          String.trim(partition_id) != "" ->
        "Current authenticated partition: #{String.trim(partition_id)}. It will be resolved again when recovery runs."

      state in [:mismatch, "mismatch"] ->
        "Current authenticated partition: unavailable because the live control-session identity does not match this agent. Reconnect the agent and try again."

      state in [:unavailable, "unavailable"] ->
        "Current authenticated partition: unavailable. Reconnect the agent and try again."

      true ->
        nil
    end
  end

  defp legacy_recovery_success_message(kind, recovery) do
    case {normalize_legacy_recovery_kind(kind), legacy_recovery_result_state(recovery)} do
      {{:ok, :manual}, :already_reapproved} ->
        "This legacy manual assignment was already reapproved. Its partition-bound replacement remains in effect."

      {{:ok, :manual}, _state} ->
        "Legacy manual assignment reapproved. A new partition-bound assignment was created; the historical row remains disabled."

      {{:ok, :policy}, state} when state in [:queued, :pending] ->
        "Policy reconciliation queued. Its status will refresh here while the current policy or credential rule re-evaluates this target."

      {{:ok, :policy}, :already_reconciled} ->
        "This legacy policy assignment was already reconciled."

      {{:ok, :policy}, _state} ->
        "Policy reconciliation completed. Any replacement reflects the current authoritative policy, not the historical row."

      _ ->
        "Legacy assignment recovery completed."
    end
  end

  defp legacy_recovery_result_state(recovery) when is_map(recovery) do
    value_from_map(recovery, :state) || value_from_map(recovery, :status)
  end

  defp legacy_recovery_result_state(_recovery), do: nil

  defp legacy_recovery_error_message(:recovery_confirmation_required), do: "Explicit confirmation is required."

  defp legacy_recovery_error_message(:legacy_assignment_not_manual),
    do: "This row is policy-owned and must be reconciled by its authoritative policy."

  defp legacy_recovery_error_message(:legacy_assignment_not_policy),
    do: "This row is manually owned and must be reapproved instead."

  defp legacy_recovery_error_message(:legacy_assignment_not_unbound),
    do: "This row is no longer an unbound legacy assignment. Refresh and review its current state."

  defp legacy_recovery_error_message(:authenticated_agent_partition_unavailable),
    do: "The selected agent has no trustworthy live partition evidence."

  defp legacy_recovery_error_message(reason)
       when reason in [:authenticated_agent_partition_mismatch, :authenticated_agent_partition_changed],
       do: "The live control-session identity no longer matches the selected agent."

  defp legacy_recovery_error_message(:agent_offline), do: "The selected agent is offline. Reconnect it and try again."

  defp legacy_recovery_error_message(reason)
       when reason in [:active_assignment_conflict, :bound_manual_assignment_conflict],
       do: "An enabled assignment already owns this agent and plugin in the resolved partition."

  defp legacy_recovery_error_message(reason)
       when reason in [:package_not_approved, :plugin_package_not_approved, :plugin_package_not_found],
       do: "The package is no longer approved for assignment."

  defp legacy_recovery_error_message(reason)
       when reason in [:policy_owner_unavailable, :owner_not_found, :owner_not_authoritative],
       do: "The historical policy or credential rule is no longer authoritative."

  defp legacy_recovery_error_message(:policy_reconciliation_forbidden),
    do: "You are not authorized to reconcile the owning policy or credential rule."

  defp legacy_recovery_error_message(:unsupported_policy_owner), do: unsupported_policy_owner_message()

  defp legacy_recovery_error_message(:forbidden), do: "You are not authorized to recover this assignment."

  defp legacy_recovery_error_message(reason)
       when reason in [
              :authorization_denied,
              :initiating_actor_required,
              :initiating_principal_required,
              :current_authority_denied,
              :current_permission_denied,
              :principal_disabled,
              :principal_not_found,
              :principal_owner_changed,
              :service_principal_write_scope_required
            ], do: "You are not authorized to recover this assignment."

  defp legacy_recovery_error_message(reason)
       when reason in [:legacy_partition_reapproval_required, :legacy_assignment_not_unbound, :not_legacy_unbound],
       do: "This historical row must remain disabled. Use its explicit recovery action instead."

  defp legacy_recovery_error_message({:rejected, :not_legacy_unbound}),
    do: "This historical row must remain disabled. Use its explicit recovery action instead."

  defp legacy_recovery_error_message({:rejected, :policy_assignment_requires_reconciliation}),
    do: "This row is policy-owned and must be reconciled by its authoritative policy."

  defp legacy_recovery_error_message(:policy_assignment_requires_reconciliation),
    do: "This row is policy-owned and must be reconciled by its authoritative policy."

  defp legacy_recovery_error_message(:params_not_recoverable),
    do: "The historical configuration no longer satisfies the current package schema."

  defp legacy_recovery_error_message(:schema_invalid),
    do: "The historical configuration no longer satisfies the current package schema."

  defp legacy_recovery_error_message({:configuration_incompatible, _errors}),
    do: "The historical configuration no longer satisfies the current package schema."

  defp legacy_recovery_error_message({:schema_invalid, :params_not_recoverable}),
    do: "The historical configuration no longer satisfies the current package schema."

  defp legacy_recovery_error_message({:active_assignment_conflict, _assignment_id}),
    do: "An enabled assignment already owns this agent and plugin in the resolved partition."

  defp legacy_recovery_error_message(_error),
    do: "The server rejected recovery without creating or modifying an assignment."

  defp legacy_recovery_failure_message(error) do
    "Recovery was not completed. No live assignment was changed. #{legacy_recovery_error_message(error)}"
  end

  attr :plugin_id, :string, required: true
  attr :coverage, :map, default: nil
  attr :producer_schedule?, :boolean, default: false

  defp credential_rule_assignment_banner(assigns) do
    provider =
      case assigns.coverage do
        %{provider: provider} when is_binary(provider) and provider != "" -> provider
        _ -> credential_rule_provider(assigns.plugin_id)
      end

    assigns =
      assigns
      |> assign(:provider, provider)
      |> assign(:new_rule_path, credential_rule_new_path(provider))

    ~H"""
    <div class={[
      "rounded-lg p-3 text-sm space-y-2",
      if(@producer_schedule?,
        do: "border border-warning/30 bg-warning/10",
        else: "border border-info/20 bg-info/10"
      )
    ]}>
      <%= if @producer_schedule? do %>
        <div class="font-semibold">Do not assign this plugin here</div>
        <p class="text-xs text-sr-ink/80">
          This scheduled inventory plugin runs from a credential rule, not from this form.
          Create a <span class="font-mono">{@provider}</span>
          username/password credential and rule under <span class="font-medium">Settings → Networks → Credentials</span>.
          The rule's Scope Value is the agent that executes the Wasm module; saving
          the rule creates the assignment.
        </p>
      <% else %>
        <div class="font-semibold">Create a credential rule first</div>
        <p class="text-xs text-sr-ink/80">
          Passwords, API keys, and controller logins belong in <span class="font-medium">Settings → Networks → Credentials</span>,
          not on this assignment. Create a <span class="font-mono">{@provider}</span>
          rule, attach the secret, then assign this plugin to an agent that rule covers.
        </p>
        <p :if={match?(%{state: :uncovered}, @coverage)} class="text-xs text-warning">
          No enabled {@provider} rule covers the selected agent yet. The plugin will
          fail at runtime until one does.
        </p>
      <% end %>
      <.link navigate={@new_rule_path} class="link link-primary text-xs">
        Open the {@provider} credential rule form
      </.link>
    </div>
    """
  end

  defp credential_rule_provider(plugin_id) do
    case IntegrationCatalog.consumer_for_plugin_id(plugin_id) do
      {:ok, {profile, _consumer}} -> profile["provider"] || "matching"
      _ -> "matching"
    end
  end

  defp credential_rule_new_path(provider) when is_binary(provider) and provider != "matching" do
    ~p"/settings/networks/credentials/new?provider=#{provider}"
  end

  defp credential_rule_new_path(_provider), do: ~p"/settings/networks/credentials"

  # -- Credential-rule coverage (x-serviceradar-credential-materialized) -------
  #
  # PluginAssignment has no metadata column to persist a coverage flag, so the
  # warning is derived dynamically on every view: per-assignment badges in the
  # Assignments list, live status in the assignment form, and a loud flash on
  # save. It disappears on its own once a matching rule is enabled.

  defp assign_credential_context(socket, package) do
    fields = CredentialCoverage.materialized_fields(package.config_schema)

    socket
    |> assign(:credential_fields, fields)
    |> assign(:credential_coverage, nil)
    |> assign(
      :assignment_coverage,
      assignment_coverage(fields, package.plugin_id, socket.assigns.assignments)
    )
  end

  defp assignment_coverage([], _plugin_id, _assignments), do: %{}

  defp assignment_coverage(_fields, plugin_id, assignments) do
    Map.new(assignments, fn assignment ->
      case CredentialCoverage.coverage(plugin_id, assignment.agent_uid) do
        {:ok, coverage} -> {assignment.id, coverage}
        _ -> {assignment.id, nil}
      end
    end)
  end

  defp assign_form_coverage(socket, agent_uid) do
    package = socket.assigns.selected_package

    coverage =
      with true <- socket.assigns.credential_fields != [],
           %{plugin_id: plugin_id} when is_binary(plugin_id) <- package,
           trimmed when is_binary(trimmed) and trimmed != "" <- trim_or_nil(agent_uid),
           {:ok, coverage} <- CredentialCoverage.coverage(plugin_id, trimmed) do
        coverage
      else
        _ -> nil
      end

    assign(socket, :credential_coverage, coverage)
  end

  defp assignment_saved_flash(socket, base_message, agent_uid) do
    case saved_coverage_warning(socket, agent_uid) do
      nil -> put_flash(socket, :info, base_message)
      warning -> put_flash(socket, :error, base_message <> ". Warning: " <> warning)
    end
  end

  defp saved_coverage_warning(socket, agent_uid) do
    with true <- socket.assigns.credential_fields != [],
         %{plugin_id: plugin_id} when is_binary(plugin_id) <- socket.assigns.selected_package,
         trimmed when is_binary(trimmed) and trimmed != "" <- trim_or_nil(agent_uid),
         {:ok, coverage} <- CredentialCoverage.coverage(plugin_id, trimmed) do
      CredentialCoverage.warning_message(coverage, trimmed)
    else
      _ -> nil
    end
  end

  defp trim_or_nil(value) when is_binary(value), do: String.trim(value)
  defp trim_or_nil(_value), do: nil

  defp uncovered_assignment?(coverage_map, assignment_id) do
    match?(%{state: :uncovered}, Map.get(coverage_map || %{}, assignment_id))
  end

  defp coverage_badge_title(coverage_map, assignment_id) do
    case Map.get(coverage_map || %{}, assignment_id) do
      %{provider: provider, purpose: purpose} ->
        "No enabled #{provider} #{purpose} credential rule covers this agent"

      _ ->
        nil
    end
  end

  defp format_list_value(nil), do: ""
  defp format_list_value([]), do: ""
  defp format_list_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp format_list_value(value) when is_binary(value), do: value
  defp format_list_value(_), do: ""

  defp format_json_value(nil), do: ""
  defp format_json_value(""), do: ""
  defp format_json_value(value) when is_map(value), do: Jason.encode!(value, pretty: true)
  defp format_json_value(value) when is_binary(value), do: value
  defp format_json_value(_), do: ""

  # 3.5.3: a refused contract must be diagnosable from the package that shipped
  # it, not merely absent from the pages it would have rendered. Read from the
  # runtime index rather than re-validated here, so what is shown is exactly what
  # the renderer decided.
  defp display_contract_diagnostics(package) do
    producer_id = Map.get(package, :plugin_id) || Map.get(package, :addon_id)
    version = Map.get(package, :version)

    runtime =
      Enum.filter(ContractRegistry.diagnostics(), fn diagnostic ->
        diagnostic.package == producer_id and diagnostic.version == version
      end)

    runtime ++ import_display_contract_diagnostics(package)
  end

  # Contracts the bundle shipped and the importer refused. They were never
  # stored, so the runtime index cannot report them; the importer recorded the
  # reasons here instead.
  defp import_display_contract_diagnostics(package) do
    package
    |> Map.get(:source_metadata)
    |> case do
      %{} = metadata -> Map.get(metadata, "display_contract_errors") || []
      _other -> []
    end
    |> List.wrap()
    |> Enum.map(fn reason -> %{source: "at import", reason: to_string(reason)} end)
  end

  defp format_hash(nil), do: "—"
  defp format_hash(""), do: "—"
  defp format_hash(value) when is_binary(value), do: value
  defp format_hash(_), do: "—"

  defp wasm_upload_error(:too_large) do
    "File is too large (max #{format_bytes(Storage.max_upload_bytes())})"
  end

  defp wasm_upload_error(:not_accepted), do: "Invalid file type (only .wasm allowed)"
  defp wasm_upload_error(:too_many_files), do: "Only one file allowed"
  defp wasm_upload_error(:read_failed), do: "Failed to read uploaded file"
  defp wasm_upload_error(error), do: inspect(error)

  defp format_bytes(bytes) when is_integer(bytes) and bytes > 0 do
    mb = Float.round(bytes / 1_048_576, 1)
    "#{mb}MB"
  end

  defp format_bytes(_), do: "0MB"

  defp blob_status(true), do: "Stored"
  defp blob_status(false), do: "Missing"
  defp blob_status(nil), do: "Unknown"
  defp blob_status(_), do: "Unknown"

  defp blob_present?(true), do: true
  defp blob_present?(_), do: false

  defp gpg_status(nil), do: "Not verified"
  defp gpg_status(key_id) when is_binary(key_id), do: "Unverified (key #{key_id})"
  defp gpg_status(_key_id), do: "Unknown"

  defp gpg_key_suffix(key_id) when is_binary(key_id) and key_id != "", do: " (#{key_id})"
  defp gpg_key_suffix(_key_id), do: ""

  defp signature_status(nil), do: "none"
  defp signature_status(%{} = signature) when map_size(signature) == 0, do: "none"
  defp signature_status(%{}), do: "present"
  defp signature_status(_), do: "unknown"

  defp maybe_delete_blob(nil), do: :ok

  defp maybe_delete_blob(package) do
    key =
      case package do
        %{wasm_object_key: value} -> value
        _ -> nil
      end

    if is_binary(key) and String.trim(key) != "" do
      Storage.delete_blob(key)
    else
      :ok
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value
  defp parse_int(_value, default), do: default

  defp package_for_assignment(assignment, versions) do
    Enum.find(versions, &(&1.id == assignment.plugin_package_id))
  end

  defp package_version(nil), do: "unknown"
  defp package_version(package), do: package.version || "unknown"

  defp latest_upgrade_target(assignment, versions) do
    case package_for_assignment(assignment, versions) do
      nil ->
        nil

      current_package ->
        assignment
        |> approved_version_targets(versions)
        |> Enum.filter(&(compare_package_versions(&1, current_package) == :gt))
        |> List.last()
    end
  end

  defp approved_version_targets(assignment, versions) do
    versions
    |> Enum.filter(&approved_upgrade_target?(&1, assignment))
    |> Enum.sort(&version_before_or_equal?/2)
  end

  defp latest_approved_assignment_version?(assignment, versions) do
    current_package = package_for_assignment(assignment, versions)

    latest_package =
      versions
      |> Enum.filter(&approved_plugin_version?(&1, assignment.plugin_id))
      |> Enum.sort(&version_before_or_equal?/2)
      |> List.last()

    not is_nil(current_package) and not is_nil(latest_package) and
      current_package.id == latest_package.id
  end

  defp approved_upgrade_target?(package, assignment) do
    approved_plugin_version?(package, assignment.plugin_id) and
      package.id != assignment.plugin_package_id
  end

  defp approved_plugin_version?(package, plugin_id) do
    package.status in [:approved, "approved"] and package.plugin_id == plugin_id
  end

  defp assignment_version_option_label(target, current_package) do
    relation =
      case compare_package_versions(target, current_package) do
        :lt -> "rollback"
        :gt -> "newer"
        :eq -> "current"
      end

    "#{target.version} (#{relation})"
  end

  defp compare_package_versions(_left, nil), do: :eq

  defp compare_package_versions(left, right) do
    case {Version.parse(left.version || ""), Version.parse(right.version || "")} do
      {{:ok, left_version}, {:ok, right_version}} ->
        Version.compare(left_version, right_version)

      _ ->
        cond do
          (left.version || "") < (right.version || "") -> :lt
          (left.version || "") > (right.version || "") -> :gt
          true -> :eq
        end
    end
  end

  defp version_before_or_equal?(left, right) do
    compare_package_versions(left, right) != :gt
  end

  defp get_actor(socket) do
    case socket.assigns.current_scope.user do
      nil -> "system"
      user -> user.email
    end
  end

  defp assignment_create_error_message(error) do
    message = format_error(error)

    if String.contains?(message, "plugin is already enabled for this agent") or
         String.contains?(message, "plugin is already assigned to this agent by policy") do
      "This agent already has this plugin enabled. Use the existing assignment's upgrade or version selector instead."
    else
      "Failed to assign: #{message}"
    end
  end
end
