defmodule ServiceRadarWebNGWeb.Auth.PasswordResetDelivery do
  @moduledoc """
  Creates a one-hour password-reset token and submits its email to the configured
  mail relay for the authenticated, cluster-private control-plane route.

  A successful return value means the configured Swoosh adapter accepted the
  message. It does not assert delivery to the recipient's mailbox.

  This private route and the public browser reset route share the same
  `LoginPolicy.password_recovery_allowed?/2` decision. The control plane is a
  delivery authority, not a recovery-policy override: it cannot issue a local
  reset credential for an SSO-only identity or otherwise make an ineligible
  account locally password-authenticated.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Accounts.UserNotifier
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNGWeb.Auth.ConfigCache
  alias ServiceRadarWebNGWeb.Auth.LoginPolicy
  alias ServiceRadarWebNGWeb.AuthURL

  @type error_reason :: :invalid_request | :request_rejected | :smtp_delivery_failed

  @spec deliver(String.t(), keyword()) :: {:ok, :smtp_accepted} | {:error, error_reason()}
  def deliver(email, opts \\ [])

  def deliver(email, opts) when is_binary(email) do
    actor = Keyword.get_lazy(opts, :actor, fn -> SystemActor.system(:control_plane_password_reset) end)
    user_lookup = Keyword.get(opts, :user_lookup, &User.get_by_email(&1, actor: actor))
    settings_loader = Keyword.get(opts, :settings_loader, &ConfigCache.get_settings/0)

    token_issuer =
      Keyword.get(opts, :token_issuer, fn user ->
        Guardian.create_access_token(user, token_type: "reset", ttl: {1, :hour})
      end)

    reset_url_builder = Keyword.get(opts, :reset_url_builder, &AuthURL.password_reset_url/1)

    email_submitter =
      Keyword.get(
        opts,
        :email_submitter,
        &UserNotifier.deliver_reset_password_instructions/2
      )

    with {:ok, normalized_email} <- normalize_email(email),
         {:user_lookup, {:ok, %User{} = user}} <-
           {:user_lookup, user_lookup.(normalized_email)},
         {:recovery_policy, :ok} <-
           {:recovery_policy, enforce_password_recovery(user, settings_loader)},
         {:token_creation, {:ok, token, _claims}} <-
           {:token_creation, token_issuer.(user)},
         reset_url = reset_url_builder.(token),
         {:smtp_submission, {:ok, _email}} <-
           {:smtp_submission, submit_email(email_submitter, user, reset_url)} do
      {:ok, :smtp_accepted}
    else
      {:error, :invalid_request} -> {:error, :invalid_request}
      {:smtp_submission, _failure} -> {:error, :smtp_delivery_failed}
      {:user_lookup, _failure} -> {:error, :request_rejected}
      {:recovery_policy, _failure} -> {:error, :request_rejected}
      {:token_creation, _failure} -> {:error, :request_rejected}
      _other -> {:error, :request_rejected}
    end
  rescue
    _exception -> {:error, :request_rejected}
  end

  def deliver(_email, _opts), do: {:error, :invalid_request}

  defp enforce_password_recovery(user, settings_loader) do
    settings =
      case settings_loader.() do
        {:ok, settings} -> settings
        {:error, _reason} -> nil
      end

    if LoginPolicy.password_recovery_allowed?(user, settings),
      do: :ok,
      else: {:error, :password_recovery_denied}
  end

  defp submit_email(email_submitter, user, reset_url) do
    email_submitter.(user, reset_url)
  rescue
    _exception -> {:error, :smtp_submission_failed}
  end

  defp normalize_email(email) do
    email = String.trim(email)

    if email != "" and byte_size(email) <= 320 do
      {:ok, email}
    else
      {:error, :invalid_request}
    end
  end
end
