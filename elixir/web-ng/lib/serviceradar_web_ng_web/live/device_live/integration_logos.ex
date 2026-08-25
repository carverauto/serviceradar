defmodule ServiceRadarWebNGWeb.DeviceLive.IntegrationLogos do
  @moduledoc """
  Vendored integration wordmarks used on device details.

  Official logos are stored under `priv/static/images/integrations/` rather
  than hotlinked. Theme picking uses the project's `data-theme=dark` Tailwind
  variant where a dark/light pair exists: white/reversed wordmarks on dark
  surfaces, the original marks on light. NetBox ships a single brand mark
  that reads on both themes.
  """

  use ServiceRadarWebNGWeb, :html

  attr(:name, :atom, required: true, values: [:armis, :netbox, :proxmox, :ansible])
  attr(:class, :any, default: "h-4 w-auto")

  def wordmark(assigns) do
    assigns = assign(assigns, :sources, logo_sources(assigns.name))

    ~H"""
    <span class="inline-flex items-center">
      <span class="sr-only">{logo_label(@name)}</span>
      <img :for={source <- @sources} src={source.src} alt="" class={[source.class, @class]} />
    </span>
    """
  end

  defp logo_label(:armis), do: "Armis"
  defp logo_label(:netbox), do: "NetBox"
  defp logo_label(:proxmox), do: "Proxmox"
  defp logo_label(:ansible), do: "AWX / Ansible"

  defp logo_sources(:armis) do
    [
      %{src: static_src("/images/integrations/armis-dark.svg"), class: "inline dark:hidden"},
      %{src: static_src("/images/integrations/armis.svg"), class: "hidden dark:inline"}
    ]
  end

  defp logo_sources(:netbox) do
    [%{src: static_src("/images/integrations/netbox.svg"), class: "inline"}]
  end

  defp logo_sources(:proxmox) do
    [
      %{src: static_src("/images/integrations/proxmox-dark.svg"), class: "inline dark:hidden"},
      %{src: static_src("/images/integrations/proxmox.svg"), class: "hidden dark:inline"}
    ]
  end

  defp logo_sources(:ansible) do
    [
      %{src: static_src("/images/integrations/ansible-dark.svg"), class: "inline dark:hidden"},
      %{src: static_src("/images/integrations/ansible.svg"), class: "hidden dark:inline"}
    ]
  end

  # VerifiedRoutes `~p` for static files calls Endpoint.static_path/1, which
  # requires the endpoint process. db_free component tests do not start it, so
  # fall back to the undigested path there. Live requests still get the digest.
  defp static_src(path) do
    endpoint = ServiceRadarWebNGWeb.Endpoint

    if Process.whereis(endpoint) do
      endpoint.static_path(path)
    else
      path
    end
  end
end
