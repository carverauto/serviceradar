defmodule ServiceRadarWebNGWeb do
  # Ensure :current_user atom exists for AshAuthentication.Phoenix.LiveSession.
  # AshAuthentication calls String.to_existing_atom("current_#{subject_name}") which
  # requires the atom to already exist. Module attributes are stored in the beam
  # file and created when the module is loaded.
  @ash_auth_atoms [:current_user]

  # Force the atoms to be referenced so they're included in the atom table
  def __ash_auth_atoms__, do: @ash_auth_atoms

  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use ServiceRadarWebNGWeb, :controller
      use ServiceRadarWebNGWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: ServiceRadarWebNGWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: ServiceRadarWebNGWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import ServiceRadarWebNGWeb.CoreComponents
      import ServiceRadarWebNGWeb.UIComponents
      import ServiceRadarWebNGWeb.SRQLComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias ServiceRadarWebNGWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ServiceRadarWebNGWeb.Endpoint,
        router: ServiceRadarWebNGWeb.Router,
        statics: ServiceRadarWebNGWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
