defmodule ServiceRadarWebNGWeb.Settings.MailLive do
  @moduledoc """
  Deployment-level outbound mail settings.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Integrations.OutboundMailSettings
  alias ServiceRadar.OutboundMail
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.mail.manage") do
      settings = load_settings(scope)

      {:ok,
       socket
       |> assign(:page_title, "Outbound Mail")
       |> assign(:current_path, "/settings/mail")
       |> assign(:settings, socket_settings(settings))
       |> assign(:mail_form, settings_to_form(settings))
       |> assign(:credential_options, credential_options(scope))
       |> assign(:test_result, nil)
       |> assign(:send_result, nil)
       |> assign(:test_sending, false)
       |> assign(:test_to, default_test_recipient(scope))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage outbound mail")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("validate", %{"mail" => params}, socket) do
    {:noreply, assign(socket, :mail_form, merge_form(socket.assigns.mail_form, params))}
  end

  def handle_event("save", %{"mail" => params}, socket) do
    scope = socket.assigns.current_scope
    attrs = params_to_attrs(params)

    case save_settings(scope, socket.assigns.settings, attrs) do
      {:ok, %OutboundMailSettings{} = settings} ->
        reloaded = load_settings(scope)

        {:noreply,
         socket
         |> put_flash(:info, "Outbound mail settings saved")
         |> assign(:settings, socket_settings(reloaded || settings))
         |> assign(:mail_form, settings_to_form(reloaded || settings))
         |> assign(:test_result, nil)
         |> assign(:send_result, nil)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save outbound mail settings: #{format_error(reason)}")}
    end
  end

  def handle_event("test_config", _params, socket) do
    case load_settings(socket.assigns.current_scope) do
      %OutboundMailSettings{enabled: true} = settings ->
        case OutboundMail.config(settings) do
          {:ok, config} ->
            {:noreply, assign(socket, :test_result, {:ok, adapter_label(Keyword.fetch!(config, :adapter))})}

          {:error, reason} ->
            {:noreply, assign(socket, :test_result, {:error, format_error(reason)})}
        end

      %OutboundMailSettings{} ->
        {:noreply, assign(socket, :test_result, {:error, "Outbound mail is disabled."})}

      _ ->
        {:noreply, assign(socket, :test_result, {:error, "Save settings before testing."})}
    end
  end

  def handle_event("send_test", _params, %{assigns: %{test_sending: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("send_test", params, socket) do
    to = test_recipient(params)

    socket =
      socket
      |> assign(:test_to, to)
      |> assign(:send_result, nil)
      |> assign(:test_sending, true)
      |> start_async(:send_test_email, fn -> OutboundMail.send_test(to) end)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:send_test_email, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:test_sending, false)
     |> assign(:send_result, normalize_send_result(result))}
  end

  def handle_async(:send_test_email, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:test_sending, false)
     |> assign(:send_result, {:error, format_send_error(reason)})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      shell={:operations}
    >
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
        <section class="space-y-2">
          <p class="text-sm font-medium text-sr-brand">Settings</p>
          <h1 class="text-2xl font-semibold tracking-normal">Outbound Mail</h1>
          <p class="max-w-3xl text-sm text-sr-ink/65">
            Configure the deployment mail provider used by dashboard reports and other system email.
          </p>
        </section>

        <section class="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr)_320px]">
          <.form
            for={@mail_form}
            as={:mail}
            phx-change="validate"
            phx-submit="save"
            class="space-y-6 rounded-lg border border-sr-line bg-sr-surface p-4"
          >
            <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
              <.input field={@mail_form[:enabled]} type="checkbox" label="Enable outbound mail" />
              <.input
                field={@mail_form[:adapter]}
                type="select"
                label="Adapter"
                options={adapter_options()}
              />
              <.input field={@mail_form[:from_name]} type="text" label="From name" />
              <.input field={@mail_form[:from_email]} type="email" label="From email" />
            </div>
            <p class="text-xs text-sr-muted">
              From email must be an address the SMTP user is allowed to send as.
              Many relays reject a default like noreply@ if the username is a
              different mailbox.
            </p>

            <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
              <.input field={@mail_form[:relay]} type="text" label="SMTP relay / endpoint" />
              <.input field={@mail_form[:port]} type="number" label="Port" />
              <.input field={@mail_form[:hostname]} type="text" label="SMTP hostname" />
              <.input field={@mail_form[:username]} type="text" label="Username" />
              <.input field={@mail_form[:auth]} type="select" label="Auth" options={mode_options()} />
              <.input field={@mail_form[:tls]} type="select" label="TLS" options={mode_options()} />
              <.input field={@mail_form[:ssl]} type="checkbox" label="Use SSL socket" />
              <.input field={@mail_form[:retries]} type="number" label="Retries" />
            </div>

            <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
              <.input
                field={@mail_form[:password_secret_id]}
                type="select"
                label="Password secret"
                options={@credential_options}
              />
              <.input
                field={@mail_form[:api_key_secret_id]}
                type="select"
                label="API key secret"
                options={@credential_options}
              />
              <.input
                field={@mail_form[:password]}
                type="password"
                label={secret_label("Password", @settings, :password_present)}
              />
              <.input
                field={@mail_form[:api_key]}
                type="password"
                label={secret_label("API key", @settings, :api_key_present)}
              />
              <.input
                field={@mail_form[:clear_password]}
                type="checkbox"
                label="Clear local password"
              />
              <.input field={@mail_form[:clear_api_key]} type="checkbox" label="Clear local API key" />
            </div>

            <.input
              field={@mail_form[:provider_options_json]}
              type="textarea"
              label="Provider options JSON"
            />

            <div class="flex flex-wrap gap-2">
              <.ui_button type="submit" size="sm" variant="primary">
                <.icon name="hero-check" class="size-4" /> Save Settings
              </.ui_button>
              <.ui_button type="button" phx-click="test_config" size="sm" variant="neutral">
                <.icon name="hero-wrench-screwdriver" class="size-4" /> Validate Runtime Config
              </.ui_button>
            </div>
          </.form>

          <aside class="space-y-4 rounded-lg border border-sr-line bg-sr-surface p-4">
            <div>
              <h2 class="text-sm font-semibold">Secret Sources</h2>
              <p class="mt-1 text-xs text-sr-muted">
                Use local encrypted values for simple SMTP credentials, or select a reusable credential secret backed by the secret server.
              </p>
            </div>
            <div class="rounded-lg border border-sr-line p-3 text-xs text-sr-ink/65">
              <div class="font-medium text-sr-ink">Configured adapter</div>
              <div class="mt-1">{adapter_display(@mail_form[:adapter].value)}</div>
            </div>
            <div
              :if={@test_result}
              class={[
                "rounded-lg border p-3 text-xs",
                match?({:ok, _}, @test_result) && "border-success/30 text-success",
                match?({:error, _}, @test_result) && "border-error/30 text-error"
              ]}
            >
              {test_result_message(@test_result)}
            </div>

            <div class="space-y-2 border-t border-sr-line pt-4">
              <h2 class="text-sm font-semibold">Send test email</h2>
              <p class="text-xs text-sr-muted">
                Uses the saved settings, not unsaved form values. Acceptance by the
                mail server is as far as ServiceRadar can see.
              </p>
              <form id="mail-send-test" phx-submit="send_test" class="space-y-2">
                <.input
                  id="mail-test-to"
                  name="to"
                  type="email"
                  label="Send to"
                  value={@test_to}
                  required
                  autocomplete="email"
                />
                <.ui_button type="submit" size="sm" variant="neutral" disabled={@test_sending}>
                  <.icon name="hero-paper-airplane" class="size-4" />
                  {if @test_sending, do: "Sending…", else: "Send test email"}
                </.ui_button>
              </form>
            </div>
            <div
              :if={@send_result}
              class={[
                "rounded-lg border p-3 text-xs",
                match?({:ok, _}, @send_result) && "border-success/30 text-success",
                match?({:error, _}, @send_result) && "border-error/30 text-error"
              ]}
            >
              {send_result_message(@send_result)}
            </div>
          </aside>
        </section>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp load_settings(scope) do
    case OutboundMailSettings.get_settings(scope: scope) do
      {:ok, %OutboundMailSettings{} = settings} -> settings
      {:ok, nil} -> nil
      {:error, _reason} -> nil
    end
  end

  defp save_settings(scope, %OutboundMailSettings{} = settings, attrs) do
    OutboundMailSettings.update_settings(settings, attrs, scope: scope)
  end

  defp save_settings(scope, _settings, attrs) do
    case OutboundMailSettings.create(attrs, scope: scope) do
      {:ok, settings} ->
        {:ok, settings}

      {:error, create_error} ->
        case load_settings(scope) do
          %OutboundMailSettings{} = settings -> OutboundMailSettings.update_settings(settings, attrs, scope: scope)
          _ -> {:error, create_error}
        end
    end
  end

  defp socket_settings(%OutboundMailSettings{} = settings) do
    settings
    |> Map.put(:password, nil)
    |> Map.put(:api_key, nil)
  end

  defp socket_settings(settings), do: settings

  defp credential_options(scope) do
    if RBAC.can?(scope, "settings.credentials.manage") do
      NetworkCredentialSecret
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(name: :asc)
      |> Ash.read(scope: scope)
      |> case do
        {:ok, secrets} -> [{"Local encrypted value", ""} | Enum.map(secrets, &{credential_label(&1), &1.id})]
        {:error, _reason} -> [{"Local encrypted value", ""}]
      end
    else
      [{"Local encrypted value", ""}]
    end
  end

  defp settings_to_form(nil), do: to_form(default_form(), as: :mail)

  defp settings_to_form(%OutboundMailSettings{} = settings) do
    to_form(
      %{
        "enabled" => bool_string(settings.enabled),
        "adapter" => settings.adapter || "local",
        "from_name" => settings.from_name || "ServiceRadar",
        "from_email" => settings.from_email || "noreply@serviceradar.cloud",
        "relay" => settings.relay || "",
        "port" => int_string(settings.port),
        "hostname" => settings.hostname || "",
        "username" => settings.username || "",
        "password" => "",
        "api_key" => "",
        "password_secret_id" => settings.password_secret_id || "",
        "api_key_secret_id" => settings.api_key_secret_id || "",
        "clear_password" => "false",
        "clear_api_key" => "false",
        "auth" => settings.auth || "if_available",
        "tls" => settings.tls || "if_available",
        "ssl" => bool_string(settings.ssl),
        "retries" => int_string(settings.retries || 1),
        "provider_options_json" => Jason.encode!(settings.provider_options || %{}, pretty: true)
      },
      as: :mail
    )
  end

  defp default_form do
    %{
      "enabled" => "false",
      "adapter" => "local",
      "from_name" => "ServiceRadar",
      "from_email" => "noreply@serviceradar.cloud",
      "relay" => "",
      "port" => "",
      "hostname" => "",
      "username" => "",
      "password" => "",
      "api_key" => "",
      "password_secret_id" => "",
      "api_key_secret_id" => "",
      "clear_password" => "false",
      "clear_api_key" => "false",
      "auth" => "if_available",
      "tls" => "if_available",
      "ssl" => "false",
      "retries" => "1",
      "provider_options_json" => "{}"
    }
  end

  defp merge_form(form, params), do: form.params |> Map.merge(params) |> to_form(as: :mail)

  defp params_to_attrs(params) do
    %{
      enabled: truthy?(params["enabled"]),
      adapter: params["adapter"],
      from_name: blank_to_default(params["from_name"], "ServiceRadar"),
      from_email: blank_to_default(params["from_email"], "noreply@serviceradar.cloud"),
      relay: blank_to_nil(params["relay"]),
      port: int_or_nil(params["port"]),
      hostname: blank_to_nil(params["hostname"]),
      username: blank_to_nil(params["username"]),
      password: blank_to_nil(params["password"]),
      api_key: blank_to_nil(params["api_key"]),
      password_secret_id: blank_to_nil(params["password_secret_id"]),
      api_key_secret_id: blank_to_nil(params["api_key_secret_id"]),
      clear_password: truthy?(params["clear_password"]),
      clear_api_key: truthy?(params["clear_api_key"]),
      auth: params["auth"] || "if_available",
      tls: params["tls"] || "if_available",
      ssl: truthy?(params["ssl"]),
      retries: int_or_default(params["retries"], 1),
      provider_options: provider_options(params["provider_options_json"])
    }
  end

  defp provider_options(value) do
    case Jason.decode(value || "{}") do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp adapter_options, do: Enum.map(OutboundMailSettings.adapters(), &{adapter_display(&1), &1})
  defp mode_options, do: [{"If available", "if_available"}, {"Always", "always"}, {"Never", "never"}]
  defp adapter_display("amazon_ses"), do: "Amazon SES"
  defp adapter_display("smtp2go"), do: "SMTP2GO"
  defp adapter_display("smtp"), do: "SMTP"
  defp adapter_display("local"), do: "Local"
  defp adapter_display("test"), do: "Test"

  defp adapter_display(value) when is_binary(value) do
    value |> String.replace("_", " ") |> String.split() |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp adapter_label(module), do: module |> inspect() |> String.replace("Elixir.", "")

  defp secret_label(base, %OutboundMailSettings{} = settings, field),
    do: if(Map.get(settings, field), do: "#{base} (saved)", else: base)

  defp secret_label(base, _settings, _field), do: base

  defp credential_label(secret) do
    source = if secret.source_type in [:external_reference, "external_reference"], do: "secret server", else: "local"
    "#{secret.name} (#{secret.provider}, #{source})"
  end

  defp test_result_message({:ok, adapter}), do: "Runtime config is valid for #{adapter}."
  defp test_result_message({:error, reason}), do: "Runtime config failed: #{reason}"

  defp default_test_recipient(%{user: %{email: email}}) when not is_nil(email), do: to_string(email)
  defp default_test_recipient(_scope), do: ""

  defp test_recipient(%{"to" => to}) when is_binary(to), do: String.trim(to)
  defp test_recipient(_params), do: ""

  defp normalize_send_result({:ok, _metadata}) do
    {:ok, "Test email accepted by the mail server. Check the inbox (and spam)."}
  end

  defp normalize_send_result({:error, {_class, message}}) when is_binary(message) do
    {:error, message}
  end

  defp normalize_send_result({:error, reason}), do: {:error, format_send_error(reason)}
  defp normalize_send_result(other), do: {:error, format_send_error(other)}

  defp send_result_message({:ok, message}), do: message
  defp send_result_message({:error, reason}), do: "Test email failed: #{reason}"

  defp format_send_error(reason), do: OutboundMail.format_delivery_error(reason)

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value
  defp blank_to_default(value, default), do: blank_to_nil(value) || default

  defp int_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(_value), do: nil
  defp int_or_default(value, default), do: int_or_nil(value) || default
  defp int_string(nil), do: ""
  defp int_string(value), do: to_string(value)
  defp bool_string(true), do: "true"
  defp bool_string(_), do: "false"
  defp truthy?(value), do: value in [true, "true", "1", "on", "yes"]
  defp format_error(reason), do: inspect(reason)
end
