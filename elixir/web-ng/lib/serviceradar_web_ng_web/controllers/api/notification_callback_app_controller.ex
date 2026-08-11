defmodule ServiceRadarWebNGWeb.Api.NotificationCallbackAppController do
  @moduledoc """
  Registering and rotating the provider applications whose signatures authorise
  an inbound notification callback (task 4.3.1a).

  This is the operator-facing half of `NotificationCallbackApp`. Without it the
  resource exists, the callback can resolve a secret, and there is no supported
  way to put one there - which is the difference between a feature that ships and
  a feature that works.

  Authorisation is the resource's own policy, reached by passing the request
  scope to every Ash call rather than by a check restated here. Reading the
  registry or editing a label requires `notifications.providers.manage`.
  Registering, rotating, or deleting key material additionally requires
  `observability.alerts.manage`, because the secret authorises an alert
  transition.

  ## The secret is write-only

  A registration accepts a plaintext `signing_secret` and stores only its
  `ServiceRadar.Edge.Crypto` ciphertext. No response ever includes either form.
  An operator who has lost the secret rotates it; there is no read path, because
  a credential store that answers "what is it?" over HTTP is one leak away from
  being the leak.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Edge.Crypto
  alias ServiceRadar.Notifications.NotificationCallbackApp

  require Ash.Query

  action_fallback ServiceRadarWebNGWeb.Api.FallbackController

  # Mirrors the resource's closed provider list. A key outside it would create a
  # row nothing can ever resolve.
  @providers %{"slack" => :slack, "pagerduty" => :pagerduty}

  @doc """
  GET /api/admin/notification-callback-apps

  Lists registered applications. Never includes key material in any form.
  """
  def index(conn, _params) do
    scope = conn.assigns.current_scope

    NotificationCallbackApp
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, apps} -> json(conn, %{data: Enum.map(apps, &to_json/1)})
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  POST /api/admin/notification-callback-apps

  Registers an application. Body: `provider_key`, `external_app_id`,
  `signing_secret`, and an optional `label`.
  """
  def create(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, provider_key} <- provider_key(params),
         {:ok, external_app_id} <- required(params, "external_app_id"),
         {:ok, secret} <- required(params, "signing_secret") do
      NotificationCallbackApp
      |> Ash.Changeset.for_create(
        :register,
        %{
          provider_key: provider_key,
          external_app_id: external_app_id,
          label: Map.get(params, "label"),
          signing_secret_ciphertext: Crypto.encrypt(secret)
        },
        scope: scope
      )
      |> Ash.create(scope: scope)
      |> case do
        {:ok, app} -> conn |> put_status(:created) |> json(to_json(app))
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc """
  POST /api/admin/notification-callback-apps/:id/rotate-secret

  Replaces the key material without changing identity. Body: `signing_secret`.
  """
  def rotate_secret(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, secret} <- required(params, "signing_secret"),
         {:ok, app} <- fetch(id, scope) do
      app
      |> Ash.Changeset.for_update(
        :rotate_secret,
        %{signing_secret_ciphertext: Crypto.encrypt(secret)},
        scope: scope
      )
      |> Ash.update(scope: scope)
      |> case do
        {:ok, app} -> json(conn, to_json(app))
        {:error, error} -> {:error, error}
      end
    end
  end

  @doc """
  DELETE /api/admin/notification-callback-apps/:id

  Deregisters an application. Every inbound interaction from it is refused from
  that point, which is the intended effect of removing a compromised app.
  """
  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {:ok, app} <- fetch(id, scope),
         :ok <- Ash.destroy(app, scope: scope) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch(id, scope) do
    NotificationCallbackApp
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(scope: scope)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, app} -> {:ok, app}
      {:error, error} -> {:error, error}
    end
  end

  defp provider_key(params) do
    # A closed map, never String.to_atom/1 on request text.
    case Map.fetch(@providers, Map.get(params, "provider_key")) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :unsupported_provider_key}
    end
  end

  # Bare atoms rather than {:invalid_argument, field} tuples: the shared
  # `FallbackController` renders `{:error, atom}` as a 400 and has no clause for
  # a tuple, so a tuple would leave a validation failure raising a 500.
  defp required(params, "external_app_id"), do: present(params, "external_app_id", :missing_external_app_id)
  defp required(params, "signing_secret"), do: present(params, "signing_secret", :missing_signing_secret)

  defp present(params, key, error) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _absent -> {:error, error}
    end
  end

  # Deliberately omits signing_secret_ciphertext. There is no read path for key
  # material, in any encoding.
  defp to_json(app) do
    %{
      id: app.id,
      provider_key: app.provider_key,
      external_app_id: app.external_app_id,
      label: app.label,
      inserted_at: app.inserted_at,
      updated_at: app.updated_at
    }
  end
end
