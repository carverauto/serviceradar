defmodule ServiceRadarWebNGWeb.AuthOverrides do
  @moduledoc """
  Overrides for AshAuthentication.Phoenix components.

  Customizes the appearance and behavior of authentication forms
  to match the ServiceRadar daisyUI design system.
  """

  use AshAuthentication.Phoenix.Overrides

  # Override the sign-in form
  override AshAuthentication.Phoenix.Components.Password.SignInForm do
    set(:label, "Sign in with email")
  end

  # Override the registration form
  override AshAuthentication.Phoenix.Components.Password.RegisterForm do
    set(:label, "Create an account")
  end

  # Override the password reset form
  override AshAuthentication.Phoenix.Components.Password.ResetForm do
    set(:label, "Reset your password")
  end

  # Override the magic link request form
  override AshAuthentication.Phoenix.Components.MagicLink.RequestForm do
    set(:label, "Sign in with magic link")
  end
end
