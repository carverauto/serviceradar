defmodule ServiceRadarWebNGWeb.Settings.DeclarativeCheckLive.Edit do
  @moduledoc """
  Settings LiveView (`/settings/declarative-checks/new` and `/settings/declarative-checks/:slug`)
  hosting the two-way Blueprint v6 + `@xyflow/react` + `elkjs` + `Monaco` DAG builder
  (`DeclarativeCheckCanvasHook`), credential binding persistence, interactive **Test Run**,
  and deterministic canonical JSON export.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.DeclarativeChecks
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @current_path "/settings/declarative-checks"
  @view_permission "declarative_checks.view"
  @manage_permission "declarative_checks.manage"
  @evaluate_permission "declarative_checks.evaluate"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_access?(scope) do
      default_doc = default_starter_document()

      {:ok,
       socket
       |> assign(:page_title, "Declarative Check Builder")
       |> assign(:current_path, @current_path)
       |> assign(:can_view, can_access?(scope))
       |> assign(:can_manage, RBAC.can?(scope, @manage_permission))
       |> assign(:can_evaluate, RBAC.can?(scope, @evaluate_permission))
       |> assign(:mode, :new)
       |> assign(:slug, nil)
       |> assign(:check, nil)
       |> assign(:document, default_doc)
       |> assign(:credential_bindings, [])
       |> assign(:credential_options, %{secrets: [], rules: []})
       |> assign(:posture_evaluators, default_posture_evaluators())
       |> assign(:loading?, not connected?(socket))
       |> assign(:dirty, false)
       |> assign(:confirm_detach, false)
       |> assign(:detach_prompt_open, false)
       |> assign(:pending_save_payload, nil)
       |> assign(:validation_errors, [])
       |> assign(:test_run_result, nil)
       |> assign(:exported_json, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to access Declarative Checks")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        handle_new_params(socket)

      :edit ->
        handle_edit_params(socket, Map.get(params, "slug"))
    end
  end

  defp handle_new_params(socket) do
    if socket.assigns.can_manage do
      default_doc = default_starter_document()

      cred_opts =
        if should_load?(socket) do
          backend(socket).list_credential_options(scope: socket.assigns.current_scope)
        else
          %{secrets: [], rules: []}
        end

      {:noreply,
       socket
       |> assign(:mode, :new)
       |> assign(:slug, nil)
       |> assign(:check, nil)
       |> assign(:page_title, "New Declarative Check")
       |> assign(:document, default_doc)
       |> assign(:credential_bindings, [])
       |> assign(:credential_options, cred_opts)
       |> assign(:posture_evaluators, backend(socket).supported_posture_evaluators())
       |> assign(:loading?, false)
       |> assign(:dirty, false)
       |> assign(:confirm_detach, false)
       |> assign(:detach_prompt_open, false)
       |> assign(:pending_save_payload, nil)
       |> assign(:validation_errors, [])
       |> assign(:test_run_result, nil)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Missing required permission: declarative_checks.manage")
       |> push_navigate(to: ~p"/settings/declarative-checks")}
    end
  end

  defp handle_edit_params(socket, slug_or_id) when is_binary(slug_or_id) and slug_or_id != "" do
    if should_load?(socket) do
      scope = socket.assigns.current_scope

      case backend(socket).get_check(slug_or_id, scope: scope) do
        {:ok, check} ->
          resolved_slug = check["slug"]
          cred_opts = backend(socket).list_credential_options(scope: scope)
          bindings = Map.get(check, "credential_bindings", [])
          doc = canonical_doc_from_check(check)

          {:noreply,
           socket
           |> assign(:mode, :edit)
           |> assign(:slug, resolved_slug)
           |> assign(:check, check)
           |> assign(:page_title, "Edit Check -- #{check["name"] || resolved_slug}")
           |> assign(:document, doc)
           |> assign(:credential_bindings, bindings)
           |> assign(:credential_options, cred_opts)
           |> assign(:posture_evaluators, backend(socket).supported_posture_evaluators())
           |> assign(:loading?, false)
           |> assign(:dirty, false)
           |> assign(:confirm_detach, false)
           |> assign(:detach_prompt_open, false)
           |> assign(:pending_save_payload, nil)
           |> assign(:validation_errors, [])}

        {:error, :not_found} ->
          {:noreply,
           socket
           |> put_flash(:error, "Declarative check not found")
           |> push_navigate(to: ~p"/settings/declarative-checks")}

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, format_error(reason))
           |> push_navigate(to: ~p"/settings/declarative-checks")}
      end
    else
      {:noreply,
       socket
       |> assign(:mode, :edit)
       |> assign(:slug, slug_or_id)
       |> assign(:loading?, true)}
    end
  end

  defp handle_edit_params(socket, _missing) do
    {:noreply, push_navigate(socket, to: ~p"/settings/declarative-checks")}
  end

  @impl true
  def handle_event("canvas_change", params, socket) do
    if socket.assigns.can_manage do
      next_doc = Map.get(params, "document") || socket.assigns.document
      next_bindings = Map.get(params, "credential_bindings") || socket.assigns.credential_bindings
      confirm_detach = params["confirm_detach"] in [true, "true"] or socket.assigns.confirm_detach

      {:noreply,
       socket
       |> assign(:document, next_doc)
       |> assign(:credential_bindings, next_bindings)
       |> assign(:confirm_detach, confirm_detach)
       |> assign(:dirty, true)
       |> assign(:validation_errors, [])}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("confirm_detach", params, socket) do
    if socket.assigns.can_manage do
      next_doc =
        params
        |> Map.get("document", socket.assigns.document)
        |> Map.put("managed", false)

      next_bindings = Map.get(params, "credential_bindings") || socket.assigns.credential_bindings

      {:noreply,
       socket
       |> assign(:document, next_doc)
       |> assign(:credential_bindings, next_bindings)
       |> assign(:confirm_detach, true)
       |> assign(:detach_prompt_open, false)
       |> assign(:dirty, true)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("cancel_detach_prompt", _params, socket) do
    if can_access?(socket.assigns.current_scope) do
      {:noreply,
       socket
       |> assign(:detach_prompt_open, false)
       |> assign(:pending_save_payload, nil)}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("confirm_detach_and_save", _params, socket) do
    if socket.assigns.can_manage do
      payload =
        socket.assigns.pending_save_payload ||
          %{
            "document" => socket.assigns.document,
            "credential_bindings" => socket.assigns.credential_bindings
          }

      persist_check(
        socket,
        Map.get(payload, "document", socket.assigns.document),
        Map.get(payload, "credential_bindings", socket.assigns.credential_bindings),
        true
      )
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("save_check", params, socket) do
    if socket.assigns.can_manage do
      doc = Map.get(params, "document") || socket.assigns.document
      bindings = Map.get(params, "credential_bindings") || socket.assigns.credential_bindings
      confirm_detach = params["confirm_detach"] in [true, "true"] or socket.assigns.confirm_detach

      persist_check(socket, doc, bindings, confirm_detach)
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  def handle_event("run_test", params, socket) do
    if socket.assigns.can_evaluate do
      doc = Map.get(params, "document") || socket.assigns.document
      overrides = Map.get(params, "parameter_overrides") || Map.get(doc, "parameter_overrides") || %{}
      run_params = %{"parameter_overrides" => overrides}

      case backend(socket).test_run(doc, run_params, scope: socket.assigns.current_scope) do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:test_run_result, result)
           |> assign(:validation_errors, [])
           |> push_event("test_run_result", %{result: result})}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(:validation_errors, extract_diagnostics(error))
           |> put_flash(:error, format_error(error))}
      end
    else
      {:noreply, put_flash(socket, :error, "Missing required permission: declarative_checks.evaluate")}
    end
  end

  def handle_event("export_json", _params, socket) do
    scope = socket.assigns.current_scope

    if can_access?(scope) do
      slug = socket.assigns.slug || Map.get(socket.assigns.document, "slug", "declarative-check")

      canonical_json =
        case {socket.assigns.mode, socket.assigns.dirty} do
          {:edit, false} when is_binary(socket.assigns.slug) ->
            case backend(socket).export_check_json(socket.assigns.slug, scope: scope) do
              {:ok, exported} -> exported
              _ -> backend(socket).canonical_pretty_json(socket.assigns.document)
            end

          _ ->
            backend(socket).canonical_pretty_json(socket.assigns.document)
        end

      {:noreply,
       socket
       |> assign(:exported_json, canonical_json)
       |> push_event("download_canonical_json", %{
         filename: "#{slug}.declarative-check.json",
         content: canonical_json
       })}
    else
      {:noreply, unauthorized_flash(socket)}
    end
  end

  @impl true
  def render(assigns) do
    canvas_props = %{
      initialDocument: assigns.document,
      initialBindings: assigns.credential_bindings,
      credentialOptions: assigns.credential_options,
      postureEvaluators: assigns.posture_evaluators,
      initialTestRun: assigns.test_run_result,
      isNew: assigns.mode == :new,
      canManage: assigns.can_manage,
      canEvaluate: assigns.can_evaluate
    }

    assigns = assign(assigns, :canvas_props, canvas_props)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div id="declarative-check-editor-page" class="space-y-4">
          <header class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <h1 class="text-xl font-semibold text-sr-ink">
                  {if @mode == :new,
                    do: "New Declarative Check",
                    else: @document["name"] || @slug}
                </h1>
                <span :if={@slug} class="font-mono text-xs text-sr-muted">{@slug}</span>
                <.ui_badge :if={@dirty} size="sm" variant="warning">Unsaved</.ui_badge>
                <.ui_badge :if={@document["managed"] == true} size="sm" variant="info">
                  Managed Pack
                </.ui_badge>
              </div>
              <p class="mt-0.5 text-xs text-sr-muted">
                Visual DAG pipeline builder and deterministic canonical JSON editor (`schema_version: 1`).
              </p>
            </div>

            <div class="flex flex-wrap items-center gap-2">
              <.ui_button
                id="back-to-declarative-checks-btn"
                size="xs"
                variant="ghost"
                navigate={~p"/settings/declarative-checks"}
              >
                Back to Checks
              </.ui_button>

              <.ui_button
                :if={@can_evaluate}
                id="header-test-run-btn"
                type="button"
                size="xs"
                variant="outline"
                phx-click="run_test"
              >
                Test Run
              </.ui_button>

              <.ui_button
                id="header-export-json-btn"
                type="button"
                size="xs"
                variant="ghost"
                phx-click="export_json"
              >
                Export JSON
              </.ui_button>

              <.ui_button
                :if={@can_manage}
                id="header-save-check-btn"
                type="button"
                size="xs"
                variant="primary"
                phx-click="save_check"
              >
                Save Check
              </.ui_button>
            </div>
          </header>

          <div
            :if={@detach_prompt_open}
            id="managed-detach-confirmation-banner"
            class="rounded-lg border border-amber-500/40 bg-amber-500/10 p-4 space-y-2"
          >
            <div class="text-sm font-semibold text-amber-300">
              Confirm Detach from Solution Pack Management
            </div>
            <p class="text-xs text-sr-ink">
              Structural changes to nodes, edges, or schedules on{" "}
              <code>{@document["pack_id"] || "managed-pack"}</code> require detaching
              (<code>managed: false</code>) so pack upgrades will not overwrite custom logic.
            </p>
            <div class="flex items-center gap-2">
              <.ui_button
                id="cancel-detach-save-btn"
                type="button"
                size="xs"
                variant="ghost"
                phx-click="cancel_detach_prompt"
              >
                Cancel
              </.ui_button>
              <.ui_button
                id="confirm-detach-save-btn"
                type="button"
                size="xs"
                variant="primary"
                phx-click="confirm_detach_and_save"
              >
                Detach &amp; Save
              </.ui_button>
            </div>
          </div>

          <div
            :if={@validation_errors != []}
            id="declarative-check-validation-banner"
            class="rounded-lg border border-rose-500/40 bg-rose-500/10 p-3 text-xs text-rose-300 space-y-1"
          >
            <div class="font-semibold">Validation Diagnostics</div>
            <ul class="list-disc pl-5 space-y-0.5">
              <li :for={diag <- @validation_errors}>
                <code>{diag.path}</code> ({diag.code}): {diag.message}
              </li>
            </ul>
          </div>

          <div
            :if={@test_run_result}
            id="declarative-check-test-run-summary"
            class="rounded-lg border border-sr-line bg-sr-surface p-3 text-xs space-y-2"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="font-semibold text-sr-ink">
                Ephemeral Test Run Verdict:{" "}
                <span class="font-mono">{@test_run_result["status"]}</span>
                ( <code>{@test_run_result["verdict"]}</code>) -- {@test_run_result["duration_ms"] || 0}ms
              </div>
              <span class="text-sr-muted">ServiceState &amp; alerts untouched</span>
            </div>
            <pre
              id="declarative-check-test-run-traces"
              phx-no-curly-interpolation
              class="max-h-40 overflow-auto rounded border border-sr-line bg-sr-subtle p-2 font-mono text-[11px] text-sr-ink"
            ><%= Jason.encode!(@test_run_result["node_traces"] || [], pretty: true) %></pre>
          </div>

          <div
            :if={@exported_json}
            id="declarative-check-exported-json"
            class="rounded-lg border border-sr-line bg-sr-surface p-3 text-xs space-y-1"
          >
            <div class="font-semibold text-sr-ink">Exported Canonical JSON</div>
            <pre
              phx-no-curly-interpolation
              class="max-h-44 overflow-auto rounded border border-sr-line bg-sr-subtle p-2 font-mono text-[11px] text-sr-ink"
            ><%= @exported_json %></pre>
          </div>

          <div
            :if={@loading?}
            id="declarative-check-builder-loading"
            class="rounded-lg border border-sr-line bg-sr-surface p-8 text-center text-sm text-sr-muted"
          >
            Loading declarative check builder...
          </div>

          <div
            :if={!@loading?}
            id="declarative-check-canvas"
            phx-hook="DeclarativeCheckCanvasHook"
            phx-update="ignore"
            data-props={Jason.encode!(@canvas_props)}
            class="min-h-[680px]"
          >
          </div>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp persist_check(socket, doc, bindings, confirm_detach) do
    scope = socket.assigns.current_scope
    attrs = Map.put(doc, "credential_bindings", normalize_binding_list(bindings))

    opts =
      then([scope: scope], fn o ->
        if confirm_detach,
          do: o |> Keyword.put(:confirm_detach, true) |> Keyword.put(:allow_detach, true),
          else: o
      end)

    result =
      case socket.assigns.mode do
        :new ->
          backend(socket).create_check(attrs, opts)

        :edit ->
          target_slug = socket.assigns.slug || doc["slug"]
          backend(socket).update_check(target_slug, Map.delete(attrs, "slug"), opts)
      end

    case result do
      {:ok, saved} ->
        saved_slug = saved["slug"]
        saved_bindings = Map.get(saved, "credential_bindings", bindings)
        was_new? = socket.assigns.mode == :new

        socket =
          socket
          |> assign(:mode, :edit)
          |> assign(:slug, saved_slug)
          |> assign(:check, saved)
          |> assign(:document, canonical_doc_from_check(saved))
          |> assign(:credential_bindings, saved_bindings)
          |> assign(:dirty, false)
          |> assign(:detach_prompt_open, false)
          |> assign(:pending_save_payload, nil)
          |> assign(:validation_errors, [])
          |> put_flash(:info, "Declarative check saved")

        if was_new? do
          {:noreply, push_patch(socket, to: ~p"/settings/declarative-checks/#{saved_slug}")}
        else
          {:noreply, socket}
        end

      {:error, :managed_detach_confirmation_required} ->
        {:noreply,
         socket
         |> assign(:detach_prompt_open, true)
         |> assign(:pending_save_payload, %{
           "document" => doc,
           "credential_bindings" => bindings
         })}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:validation_errors, extract_diagnostics(error))
         |> put_flash(:error, format_error(error))}
    end
  end

  defp normalize_binding_list(bindings) when is_list(bindings) do
    Enum.flat_map(bindings, fn b ->
      slot = b["slot"] || b[:slot]
      secret_id = b["credential_secret_id"] || b[:credential_secret_id]
      rule_id = b["credential_rule_id"] || b[:credential_rule_id]

      cond do
        is_binary(slot) and is_binary(secret_id) and secret_id != "" ->
          [%{"slot" => slot, "credential_secret_id" => secret_id}]

        is_binary(slot) and is_binary(rule_id) and rule_id != "" ->
          [%{"slot" => slot, "credential_rule_id" => rule_id}]

        true ->
          []
      end
    end)
  end

  defp normalize_binding_list(_), do: []

  defp canonical_doc_from_check(check) when is_map(check) do
    Map.drop(check, [
      "id",
      "credential_bindings",
      "instance_rollup",
      "last_evaluated_at",
      "inserted_at",
      "updated_at"
    ])
  end

  defp default_starter_document do
    %{
      "schema_version" => 1,
      "slug" => "http-json-api-check",
      "name" => "HTTP JSON API Check",
      "description" => "Synthetic HTTPS JSON endpoint availability and status assertion.",
      "state" => "draft",
      "managed" => false,
      "parameter_overrides" => %{},
      "schedule" => %{
        "interval_seconds" => 60,
        "timeout_seconds" => 15,
        "jitter_seconds" => 5
      },
      "target_binding" => %{
        "mode" => "singleton"
      },
      "inputs" => [
        %{
          "key" => "expected_status",
          "type" => "string",
          "default" => "ok",
          "description" => "Expected $.status field value"
        }
      ],
      "credential_slots" => [],
      "nodes" => [
        %{
          "id" => "http_1",
          "kind" => "http_request",
          "label" => "GET API Health",
          "config" => %{
            "url" => "https://api.example.com/v1/health",
            "method" => "GET",
            "expected_statuses" => [200],
            "timeout_ms" => 5_000
          }
        },
        %{
          "id" => "extract_status",
          "kind" => "extract_field",
          "label" => "Extract $.status",
          "config" => %{
            "source_type" => "jsonpath",
            "expression" => "$.status",
            "output_key" => "service_status"
          }
        },
        %{
          "id" => "assert_status",
          "kind" => "threshold_assert",
          "label" => "Assert Status OK",
          "config" => %{
            "field" => "service_status",
            "crit" => %{"op" => "!=", "value" => "{{inputs.expected_status}}"}
          }
        },
        %{
          "id" => "out_1",
          "kind" => "alert_output",
          "label" => "API Health Verdict",
          "config" => %{
            "verdict_map" => %{
              "healthy" => "api_healthy",
              "degraded" => "api_degraded",
              "down" => "api_unhealthy",
              "unknown" => "api_unknown"
            }
          }
        }
      ],
      "edges" => [
        %{
          "id" => "e1",
          "source" => "http_1",
          "source_handle" => "signal",
          "target" => "extract_status",
          "target_handle" => "in"
        },
        %{
          "id" => "e2",
          "source" => "extract_status",
          "source_handle" => "value",
          "target" => "assert_status",
          "target_handle" => "in"
        },
        %{
          "id" => "e3",
          "source" => "assert_status",
          "source_handle" => "verdict",
          "target" => "out_1",
          "target_handle" => "in"
        }
      ],
      "alert_policy" => %{
        "emit_ocsf_transition" => true,
        "open_on_statuses" => ["down"],
        "priority" => 2,
        "threshold" => 1,
        "window_seconds" => 300,
        "cooldown_seconds" => 300,
        "renotify_seconds" => 21_600
      },
      "ui_layout" => %{
        "nodes" => %{
          "http_1" => %{"x" => 60, "y" => 120},
          "extract_status" => %{"x" => 340, "y" => 120},
          "assert_status" => %{"x" => 620, "y" => 120},
          "out_1" => %{"x" => 900, "y" => 120}
        }
      }
    }
  end

  defp default_posture_evaluators do
    [
      "storage.entitlement_utilization",
      "storage.hold_pin_pressure",
      "storage.archive_credential_and_usage_health",
      "camera.continuous_recording_silence"
    ]
  end

  defp extract_diagnostics(%{errors: errors}) when is_list(errors) do
    Enum.map(errors, fn err ->
      %{
        path: Map.get(err, :path) || Map.get(err, "path") || "$",
        code: to_string(Map.get(err, :code) || Map.get(err, "code") || "invalid"),
        message: Map.get(err, :message) || Map.get(err, "message") || "Validation failed"
      }
    end)
  end

  defp extract_diagnostics(other) do
    [%{path: "$", code: "validation_error", message: format_error(other)}]
  end

  defp format_error(%{errors: [first | _]}) do
    Map.get(first, :message) || Map.get(first, "message") || "Validation failed"
  end

  defp format_error(:not_found), do: "Declarative check not found"
  defp format_error(err) when is_exception(err), do: Exception.message(err)
  defp format_error(other), do: inspect(other)

  defp should_load?(socket) do
    connected?(socket) or socket.assigns[:force_connected_load?] == true
  end

  defp can_access?(scope) do
    RBAC.can?(scope, @view_permission) or
      RBAC.can?(scope, @manage_permission) or
      RBAC.can?(scope, @evaluate_permission)
  end

  defp unauthorized_flash(socket) do
    put_flash(socket, :error, "You do not have permission to perform this action")
  end

  defp backend(socket) do
    socket.assigns[:declarative_checks_backend] ||
      Application.get_env(:serviceradar_web_ng, :declarative_checks, DeclarativeChecks)
  end
end
