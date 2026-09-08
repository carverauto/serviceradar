defmodule ServiceRadar.Notifications.Callbacks.AppRegistry do
  @moduledoc """
  Resolves the key material an inbound callback is verified against
  (task 4.3.1a).

  The callback knows only what the provider told it - for Slack, an
  `api_app_id`. This turns that into a signing secret, or into a reason it could
  not.

  ## Failing closed, and saying which kind of closed

  An unregistered app and a corrupt ciphertext are both refusals, and they are
  deliberately different values. `:app_not_registered` is an operator task (the
  Slack app was never registered, or a second workspace installed a different
  app); `:key_material_unreadable` means the row exists but `Edge.Crypto` could
  not decrypt it, which is a `CLOAK_KEY` problem and no amount of re-registering
  will fix it. Collapsing them into one error is how an operator spends an
  afternoon rotating a secret that was never the problem.

  Neither is ever reported to the provider. The controller answers a failed
  verification the same way whatever the cause, because telling an unauthenticated
  caller whether an app id is registered is a membership oracle.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.Crypto
  alias ServiceRadar.Notifications.NotificationCallbackApp

  @type reason :: :app_not_registered | :key_material_unreadable

  @doc """
  The signing secret registered for a provider application.

  Runs as the system actor: verification happens before any principal is known,
  so there is no operator identity to authorise with, and the read is not
  operator-facing in any case.

  ## Options

    * `:actor` - overrides the system actor.
    * `:lookup` - `fun(provider_key, external_app_id)` replacing the read, so a
      test needs no database.
  """
  @spec signing_secret(atom(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, reason()}
  def signing_secret(provider_key, external_app_id, opts \\ [])

  def signing_secret(provider_key, external_app_id, opts)
      when is_atom(provider_key) and is_binary(external_app_id) and external_app_id != "" do
    case lookup(provider_key, external_app_id, opts) do
      {:ok, %{signing_secret_ciphertext: ciphertext}} when is_binary(ciphertext) ->
        decrypt(ciphertext)

      _absent ->
        {:error, :app_not_registered}
    end
  end

  def signing_secret(_provider_key, _external_app_id, _opts), do: {:error, :app_not_registered}

  defp lookup(provider_key, external_app_id, opts) do
    case Keyword.get(opts, :lookup) do
      fun when is_function(fun, 2) ->
        fun.(provider_key, external_app_id)

      nil ->
        actor = Keyword.get(opts, :actor) || SystemActor.system(:notification_callback)

        case NotificationCallbackApp.get_by_external_app_id(provider_key, external_app_id,
               actor: actor
             ) do
          {:ok, nil} -> {:error, :app_not_registered}
          {:ok, app} -> {:ok, app}
          {:error, _reason} -> {:error, :app_not_registered}
        end
    end
  end

  defp decrypt(ciphertext) do
    case Crypto.decrypt_safe(ciphertext) do
      {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
      _unreadable -> {:error, :key_material_unreadable}
    end
  end
end
