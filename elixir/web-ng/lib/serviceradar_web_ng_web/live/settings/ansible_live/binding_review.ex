defmodule ServiceRadarWebNGWeb.Settings.AnsibleLive.BindingReview do
  @moduledoc """
  Template bindings tab state for `ServiceRadarWebNGWeb.Settings.AnsibleLive`.

  The tab mirrors the two-phase API contract of
  `/api/admin/ansible-template-bindings`:

    1. the operator submits a request and `prepare_binding/2` returns the
       broker-observed review and its digest;
    2. only a prepared review offers Create, which submits the same request
       with `expected_review_digest`. A review that changed in between is
       prepared again and shown; it is never accepted silently.

  Every call goes through `ServiceRadarWebNG.AnsibleAutomation` with the
  session user's scope, so `ServiceRadar.Automation.Ansible.AwxBindingReview`
  re-checks the human principal and current `ansible.controllers.manage`
  authority from storage. The caller re-checks that permission before invoking
  any function here.

  Prepare and create run with `start_async/3` because both repeat brokered AWX
  reads through the controller's edge agent; the results arrive through
  `prepared/2` and `created/2`.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  import Phoenix.LiveView,
    only: [put_flash: 3, start_async: 3, stream: 4, stream_configure: 3]

  alias ServiceRadarWebNG.AnsibleAutomation
  alias ServiceRadarWebNG.RBAC

  @catalog_permission "ansible.catalog.view"
  @membership_permission "ansible.runs.view"
  @default_ttl 3_600
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @doc "Initial, inert tab state. Safe for the disconnected mount."
  def init(socket) do
    socket
    |> assign(:binding_controller_id, nil)
    |> assign(:binding_templates, [])
    |> assign(:binding_template_id, nil)
    |> assign(:binding_notice, nil)
    |> assign(:binding_version_count, 0)
    |> assign(:show_binding_form, false)
    |> assign(:binding_form, to_form(%{}, as: :binding))
    |> assign(:binding_choice_notice, nil)
    |> assign(:binding_choice_count, 0)
    |> assign(:binding_review, nil)
    |> assign(:binding_pending, nil)
    |> assign(:revoking_binding, nil)
    |> assign(:revoke_form, to_form(%{}, as: :revoke))
    |> assign(:revoke_error, nil)
    |> stream_configure(:binding_versions, dom_id: &"ansible-binding-#{&1.id}")
    |> stream(:binding_versions, [], reset: true)
    |> stream_configure(:binding_choices, dom_id: &"ansible-binding-choice-#{&1.id}")
    |> stream(:binding_choices, [], reset: true)
  end

  @doc "Loads the tab for the given controllers, keeping the current selection when valid."
  def activate(socket, controllers) do
    socket
    |> assign(:binding_controller_id, keep_or_first(socket.assigns.binding_controller_id, controllers))
    |> load_templates()
    |> load_versions()
  end

  @doc "Applies a controller/template selection from the scope form."
  def select_scope(socket, params, controllers) do
    requested_controller = Map.get(params, "controller_id")

    if requested_controller == socket.assigns.binding_controller_id do
      template_id =
        case parse_awx_id(params["template_id"]) do
          {:ok, id} -> id
          :error -> nil
        end

      socket
      |> assign(:binding_template_id, template_id)
      |> load_versions()
    else
      socket
      |> assign(:binding_controller_id, keep_or_first(requested_controller, controllers))
      |> assign(:binding_template_id, nil)
      |> close_form()
      |> load_templates()
      |> load_versions()
    end
  end

  ## Review form -------------------------------------------------------------

  @doc "Opens an empty review request for the selected controller and template."
  def new_review(%{assigns: %{binding_controller_id: nil}} = socket) do
    put_flash(socket, :error, "Register an AWX controller before reviewing a binding.")
  end

  def new_review(socket) do
    params =
      prefill_template(
        %{
          "template_id" => optional_string(socket.assigns.binding_template_id),
          "project_id" => "",
          "inventory_id" => "",
          "credential_ids" => "",
          "machine_credential_id" => "",
          "execution_environment_id" => "",
          "membership_ids" => [],
          "content_sha256" => "",
          "review_ticket" => "",
          "approval_ttl_seconds" => Integer.to_string(@default_ttl),
          "input_schema" => "",
          "input_classifications" => ""
        },
        socket.assigns.binding_templates
      )

    socket
    |> assign(:show_binding_form, true)
    |> assign(:binding_review, nil)
    |> assign(:binding_form, to_form(params, as: :binding))
    |> load_choices(params["inventory_id"])
  end

  def cancel_form(socket), do: close_form(socket)

  @doc """
  Tracks edits to the request. Any edit discards a prepared review, because
  Create must submit exactly the request that was reviewed.
  """
  def validate(%{assigns: %{binding_pending: pending}} = socket, _params) when not is_nil(pending), do: socket

  def validate(socket, params) do
    previous = socket.assigns.binding_form.params || %{}

    params =
      if params["template_id"] == previous["template_id"],
        do: params,
        else: prefill_template(params, socket.assigns.binding_templates)

    socket =
      socket
      |> assign(:binding_review, nil)
      |> assign(:binding_form, to_form(params, as: :binding))

    if params["inventory_id"] == previous["inventory_id"],
      do: socket,
      else: load_choices(socket, params["inventory_id"])
  end

  @doc "Validates the request locally, then asks the domain for a broker-observed review."
  def prepare(%{assigns: %{binding_pending: pending}} = socket, _params) when not is_nil(pending), do: socket

  def prepare(socket, params) do
    socket = assign(socket, :binding_form, to_form(params, as: :binding))

    case build_request(params, socket.assigns.binding_controller_id) do
      {:ok, request} ->
        socket
        |> assign(:binding_review, nil)
        |> start_prepare(request, :prepare)

      {:error, message} ->
        put_flash(socket, :error, message)
    end
  end

  @doc "Creates the binding from the prepared review, bound to its digest."
  def create(%{assigns: %{binding_pending: pending}} = socket) when not is_nil(pending), do: socket

  def create(%{assigns: %{binding_review: nil}} = socket) do
    put_flash(socket, :error, "Prepare and inspect a review before creating the binding.")
  end

  def create(%{assigns: %{binding_review: %{request: request, digest: digest}}} = socket) do
    scope = socket.assigns.current_scope
    body = Map.put(request, "expected_review_digest", digest)

    socket
    |> assign(:binding_pending, :create)
    |> start_async(:ansible_binding_create, fn ->
      {request, automation().create_binding(scope, body)}
    end)
  end

  def discard_review(socket), do: assign(socket, :binding_review, nil)

  @doc "Handles the result of a prepare started by `prepare/2` or a changed create."
  def prepared(socket, {:ok, {request, {:ok, %{review: review, review_digest: digest}}}})
      when is_map(review) and is_binary(digest) do
    changed? = socket.assigns.binding_pending == :reprepare

    socket
    |> assign(:binding_pending, nil)
    |> assign(:binding_review, %{request: request, review: review, digest: digest, changed?: changed?})
  end

  def prepared(socket, {:ok, {_request, {:error, reason}}}) do
    socket
    |> assign(:binding_pending, nil)
    |> put_flash(:error, "The binding review could not be prepared: #{format_reason(reason)}.")
  end

  def prepared(socket, _result) do
    socket
    |> assign(:binding_pending, nil)
    |> put_flash(:error, "The binding review could not be prepared.")
  end

  @doc "Handles the result of a create started by `create/1`."
  def created(socket, {:ok, {_request, {:ok, binding}}}) do
    socket
    |> put_flash(
      :info,
      "Created binding version #{binding[:binding_version]} for template #{binding[:job_template_id]}."
    )
    |> close_form()
    |> assign(:binding_template_id, binding[:job_template_id])
    |> load_versions()
  end

  def created(socket, {:ok, {request, {:error, :binding_review_changed}}}) do
    socket
    |> assign(:binding_review, nil)
    |> put_flash(
      :error,
      "AWX changed after you prepared the review, so nothing was created. " <>
        "The review is being prepared again; inspect it before creating."
    )
    |> start_prepare(request, :reprepare)
  end

  def created(socket, {:ok, {_request, {:error, reason}}}) do
    socket
    |> assign(:binding_pending, nil)
    |> put_flash(:error, "The binding was not created: #{format_reason(reason)}.")
  end

  def created(socket, _result) do
    socket
    |> assign(:binding_pending, nil)
    |> put_flash(:error, "The binding was not created.")
  end

  ## Revoke ------------------------------------------------------------------

  @doc "Opens the typed-confirmation dialog for one current approved version."
  def start_revoke(socket, id) do
    case fetch_versions(socket) do
      {:ok, versions} ->
        socket = put_versions(socket, versions)

        case Enum.find(versions, &(to_string(&1.id) == id)) do
          %{} = binding ->
            if revocable?(binding) do
              socket
              |> assign(:revoking_binding, binding)
              |> assign(:revoke_error, nil)
              |> assign(:revoke_form, to_form(%{"id" => id, "confirmation_id" => ""}, as: :revoke))
            else
              put_flash(socket, :error, "Only the current approved version can be revoked.")
            end

          nil ->
            put_flash(socket, :error, "That binding version was not found.")
        end

      {:error, socket} ->
        socket
    end
  end

  def close_revoke(socket) do
    socket
    |> assign(:revoking_binding, nil)
    |> assign(:revoke_error, nil)
  end

  @doc "Revokes the version in the open dialog once its exact ID has been typed."
  def confirm_revoke(%{assigns: %{revoking_binding: nil}} = socket, _params) do
    put_flash(socket, :error, "Open the revoke dialog for a binding version first.")
  end

  def confirm_revoke(%{assigns: %{revoking_binding: binding}} = socket, params) do
    id = to_string(binding.id)
    typed = params |> Map.get("confirmation_id", "") |> to_string() |> String.trim()

    if Map.get(params, "id") == id and typed == id do
      revoke(socket, id)
    else
      socket
      |> assign(:revoke_form, to_form(%{"id" => id, "confirmation_id" => ""}, as: :revoke))
      |> assign(:revoke_error, "Type the exact binding ID to confirm revocation.")
    end
  end

  defp revoke(socket, id) do
    case automation().revoke_binding(socket.assigns.current_scope, id, %{}) do
      {:ok, revoked} ->
        socket
        |> close_revoke()
        |> put_flash(
          :info,
          "Revoked binding version #{revoked[:binding_version]} for template #{revoked[:job_template_id]}."
        )
        |> load_versions()

      {:error, reason} ->
        socket
        |> close_revoke()
        |> put_flash(:error, "The binding was not revoked: #{format_reason(reason)}.")
        |> load_versions()
    end
  end

  ## Display helpers ---------------------------------------------------------

  @doc "A short state label and badge variant for one binding version."
  def state(binding, now \\ DateTime.utc_now()) do
    case {binding[:approval_state], binding[:current]} do
      {:revoked, _} -> {"revoked", "error"}
      {:expired, _} -> {"expired", "ghost"}
      {:approved, true} -> if live?(binding, now), do: {"current", "success"}, else: {"expired", "warning"}
      {:approved, _} -> {"superseded", "ghost"}
      {other, _} -> {to_string(other), "ghost"}
    end
  end

  def revocable?(binding), do: binding[:approval_state] == :approved and binding[:current] == true

  def modes(binding) do
    [
      binding[:run_mode_supported] == true && "run",
      binding[:check_mode_supported] == true && "check"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> "none"
      modes -> Enum.join(modes, ", ")
    end
  end

  def short_digest(nil), do: "-"
  def short_digest(digest) when is_binary(digest), do: String.slice(digest, 0, 12)

  ## Request -----------------------------------------------------------------

  @doc """
  Builds the exact API request body from form params, or returns a message for
  the first field that cannot be sent. The domain repeats every check.
  """
  def build_request(params, controller_id) do
    with {:ok, controller_id} <- controller(controller_id),
         {:ok, template_id} <- awx_id(params, "template_id", "Template ID"),
         {:ok, project_id} <- awx_id(params, "project_id", "Project ID"),
         {:ok, inventory_id} <- awx_id(params, "inventory_id", "Inventory ID"),
         {:ok, credential_ids} <- credential_ids(params["credential_ids"]),
         {:ok, machine_id} <- awx_id(params, "machine_credential_id", "Machine credential ID"),
         :ok <- machine_in_credentials(machine_id, credential_ids),
         {:ok, environment_id} <-
           awx_id(params, "execution_environment_id", "Execution environment ID"),
         {:ok, membership_ids} <- membership_ids(params["membership_ids"]),
         {:ok, content_sha256} <- content_sha256(params["content_sha256"]),
         {:ok, review_ticket} <- review_ticket(params["review_ticket"]),
         {:ok, ttl} <- ttl(params["approval_ttl_seconds"]),
         {:ok, input_schema} <- json_object(params["input_schema"], "Input schema"),
         {:ok, classifications} <-
           json_object(params["input_classifications"], "Input classifications") do
      {:ok,
       %{
         "controller_id" => controller_id,
         "template_id" => template_id,
         "project_id" => project_id,
         "inventory_id" => inventory_id,
         "credential_ids" => credential_ids,
         "machine_credential_id" => machine_id,
         "execution_environment_id" => environment_id,
         "membership_ids" => membership_ids,
         "content_sha256" => content_sha256,
         "review_ticket" => review_ticket,
         "approval_ttl_seconds" => ttl
       }
       |> put_optional("input_schema", input_schema)
       |> put_optional("input_classifications", classifications)}
    end
  end

  ## Loading -----------------------------------------------------------------

  defp start_prepare(socket, request, marker) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:binding_pending, marker)
    |> start_async(:ansible_binding_prepare, fn ->
      {request, automation().prepare_binding(scope, request)}
    end)
  end

  defp close_form(socket) do
    socket
    |> assign(:show_binding_form, false)
    |> assign(:binding_review, nil)
    |> assign(:binding_choice_count, 0)
    |> assign(:binding_choice_notice, nil)
    |> stream(:binding_choices, [], reset: true)
  end

  defp load_templates(%{assigns: %{binding_controller_id: nil}} = socket) do
    socket
    |> assign(:binding_templates, [])
    |> assign(:binding_template_id, nil)
  end

  defp load_templates(socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @catalog_permission) do
      case automation().list_binding_templates(scope, socket.assigns.binding_controller_id) do
        {:ok, templates} ->
          socket
          |> assign(:binding_notice, nil)
          |> assign(:binding_templates, templates)
          |> assign(:binding_template_id, default_template(socket.assigns.binding_template_id, templates))

        {:error, reason} ->
          socket
          |> assign(:binding_templates, [])
          |> assign(:binding_notice, "Could not list AWX templates: #{format_reason(reason)}.")
      end
    else
      socket
      |> assign(:binding_templates, [])
      |> assign(:binding_template_id, nil)
      |> assign(:binding_notice, "Listing template bindings requires the #{@catalog_permission} permission.")
    end
  end

  defp load_versions(socket) do
    case fetch_versions(socket) do
      {:ok, versions} -> put_versions(socket, versions)
      {:error, socket} -> socket
    end
  end

  defp fetch_versions(%{assigns: %{binding_controller_id: controller_id, binding_template_id: template_id}} = socket)
       when is_nil(controller_id) or is_nil(template_id) do
    {:error, put_versions(socket, [])}
  end

  defp fetch_versions(socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @catalog_permission) do
      request = %{
        "controller_id" => socket.assigns.binding_controller_id,
        "job_template_id" => socket.assigns.binding_template_id
      }

      case automation().list_bindings(scope, request) do
        {:ok, versions} ->
          {:ok, versions}

        {:error, reason} ->
          {:error,
           socket
           |> put_versions([])
           |> assign(:binding_notice, "Could not list binding versions: #{format_reason(reason)}.")}
      end
    else
      {:error, put_versions(socket, [])}
    end
  end

  defp put_versions(socket, versions) do
    socket
    |> assign(:binding_version_count, length(versions))
    |> stream(:binding_versions, versions, reset: true)
  end

  defp load_choices(socket, inventory) do
    scope = socket.assigns.current_scope

    with {:ok, inventory_id} <- parse_awx_id(inventory),
         true <- RBAC.can?(scope, @membership_permission) || :no_permission,
         {:ok, memberships} <-
           automation().list_memberships(scope, %{
             "controller_id" => socket.assigns.binding_controller_id,
             "inventory_id" => inventory_id
           }) do
      choices =
        Enum.filter(memberships, &(&1.link_disposition == :approved and &1.enabled == true))

      socket
      |> assign(:binding_choice_count, length(choices))
      |> assign(
        :binding_choice_notice,
        if(choices == [], do: "No approved memberships in inventory #{inventory_id}.")
      )
      |> stream(:binding_choices, choices, reset: true)
    else
      :error ->
        put_choices_notice(socket, "Enter the AWX inventory ID to choose approved memberships.")

      :no_permission ->
        put_choices_notice(
          socket,
          "Choosing memberships requires the #{@membership_permission} permission."
        )

      {:error, reason} ->
        put_choices_notice(socket, "Could not list memberships: #{format_reason(reason)}.")
    end
  end

  defp put_choices_notice(socket, notice) do
    socket
    |> assign(:binding_choice_count, 0)
    |> assign(:binding_choice_notice, notice)
    |> stream(:binding_choices, [], reset: true)
  end

  defp prefill_template(params, templates) do
    with {:ok, template_id} <- parse_awx_id(params["template_id"]),
         %{} = template <- Enum.find(templates, &(&1.job_template_id == template_id)) do
      params
      |> put_known("project_id", template.project_id)
      |> put_known("inventory_id", template.inventory_id)
    else
      _ -> params
    end
  end

  defp put_known(params, _key, nil), do: params
  defp put_known(params, key, value), do: Map.put(params, key, Integer.to_string(value))

  defp default_template(current, templates) do
    ids = Enum.map(templates, & &1.job_template_id)

    cond do
      is_integer(current) -> current
      ids == [] -> nil
      true -> hd(ids)
    end
  end

  defp keep_or_first(requested, controllers) do
    ids = Enum.map(controllers, &to_string(&1.id))

    cond do
      is_binary(requested) and requested in ids -> requested
      ids == [] -> nil
      true -> hd(ids)
    end
  end

  ## Field parsing -----------------------------------------------------------

  defp controller(nil), do: {:error, "Select a controller."}
  defp controller(id), do: {:ok, to_string(id)}

  defp awx_id(params, key, label) do
    case parse_awx_id(params[key]) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "#{label} must be a positive AWX ID."}
    end
  end

  defp parse_awx_id(value) when is_integer(value) and value in 1..2_147_483_647, do: {:ok, value}

  defp parse_awx_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id in 1..2_147_483_647 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_awx_id(_value), do: :error

  defp credential_ids(value) when is_binary(value) do
    ids =
      value
      |> String.split([",", " ", "\n", "\t"], trim: true)
      |> Enum.map(&parse_awx_id/1)

    cond do
      ids == [] -> {:error, "Enter at least one AWX credential ID."}
      Enum.any?(ids, &(&1 == :error)) -> {:error, "Credential IDs must be positive AWX IDs."}
      length(ids) > 128 -> {:error, "At most 128 credential IDs are allowed."}
      true -> {:ok, ids |> Enum.map(fn {:ok, id} -> id end) |> Enum.uniq()}
    end
  end

  defp credential_ids(_value), do: {:error, "Enter at least one AWX credential ID."}

  defp machine_in_credentials(machine_id, credential_ids) do
    if machine_id in credential_ids,
      do: :ok,
      else: {:error, "The machine credential must be one of the credential IDs."}
  end

  defp membership_ids(values) when is_list(values) do
    ids = values |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    cond do
      ids == [] -> {:error, "Choose at least one approved membership."}
      length(ids) > 100 -> {:error, "At most 100 memberships can be bound in one review."}
      Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) -> {:ok, ids}
      true -> {:error, "Membership selections are invalid; reload the page."}
    end
  end

  defp membership_ids(_values), do: {:error, "Choose at least one approved membership."}

  defp content_sha256(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    if Regex.match?(@sha256, value),
      do: {:ok, value},
      else: {:error, "Content SHA-256 must be 64 hexadecimal characters."}
  end

  defp content_sha256(_value), do: {:error, "Content SHA-256 must be 64 hexadecimal characters."}

  defp review_ticket(value) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) in 1..255,
      do: {:ok, value},
      else: {:error, "Enter a review ticket of at most 255 bytes."}
  end

  defp review_ticket(_value), do: {:error, "Enter a review ticket of at most 255 bytes."}

  defp ttl(value) when value in [nil, ""], do: {:ok, @default_ttl}

  defp ttl(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds in 60..86_400 -> {:ok, seconds}
      _ -> {:error, "Approval TTL must be between 60 and 86400 seconds."}
    end
  end

  defp ttl(_value), do: {:error, "Approval TTL must be between 60 and 86400 seconds."}

  defp json_object(value, _label) when value in [nil, ""], do: {:ok, nil}

  defp json_object(value, label) when is_binary(value) do
    case value |> String.trim() |> Jason.decode() do
      {:ok, %{} = object} -> {:ok, object}
      {:ok, _other} -> {:error, "#{label} must be a JSON object."}
      {:error, _reason} -> {:error, "#{label} is not valid JSON."}
    end
  end

  defp json_object(_value, label), do: {:error, "#{label} must be a JSON object."}

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp optional_string(nil), do: ""
  defp optional_string(value), do: to_string(value)

  defp live?(binding, now) do
    case binding[:approval_expires_at] do
      %DateTime{} = expires_at -> DateTime.after?(expires_at, now)
      _ -> false
    end
  end

  defp format_reason(reason) when is_atom(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")
  defp format_reason(%Ash.Error.Forbidden{}), do: "permission denied"
  defp format_reason(_reason), do: "request rejected"

  defp automation, do: Application.get_env(:serviceradar_web_ng, :ansible_automation, AnsibleAutomation)
end
