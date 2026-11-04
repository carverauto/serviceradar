defmodule ServiceRadarWebNGWeb.ManagedDeploymentComponents do
  @moduledoc "Presentation of managed installation evidence alongside legacy edge deployments."
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Edge.ManagedCertificateOperation
  alias ServiceRadar.Edge.ManagedComponent

  def managed?(%{managed_component: %ManagedComponent{}}), do: true
  def managed?(_), do: false

  def current_operation(%{
        managed_component: %ManagedComponent{
          generation: generation,
          current_operation: %ManagedCertificateOperation{generation: generation} = operation
        }
      }), do: operation

  def current_operation(_), do: nil

  def last_update(%{managed_component: %ManagedComponent{}} = record) do
    if operation = current_operation(record), do: operation.updated_at
  end

  def last_update(record), do: record.last_seen_at

  attr :record, :any, required: true

  def deployment_badge(assigns) do
    status = assigns.record.deployment_status

    variant =
      cond do
        status in ["installed", "active", "ready", "downloaded"] -> "success"
        status in ["failed", "revoked", "offline"] -> "error"
        status in ["pending", "installing", "provisioning"] -> "warning"
        true -> "ghost"
      end

    assigns = assign(assigns, status: status, variant: variant)

    ~H"""
    <span title={if managed?(@record), do: "Managed installation state, not a runtime health check"}>
      <.ui_badge variant={@variant}>{@status}</.ui_badge>
    </span>
    """
  end

  attr :record, :any, required: true

  def managed_deployment_details(assigns) do
    assigns = assign(assigns, :operation, current_operation(assigns.record))

    ~H"""
    <div :if={managed?(@record)} class="space-y-2 text-sm">
      <p class="text-sr-muted">
        Managed installation state comes from the host's acknowledgement for the current enrollment.
        It does not confirm that the service is currently connected.
      </p>
      <.link navigate={~p"/admin/service-certificates"} class="text-sr-brand hover:underline">
        Manage service certificates
      </.link>
      <p
        :if={
          @record.deployment_status == "installed" && @operation && @operation.status != :activated
        }
        class="text-sr-muted"
      >
        Certificate renewal: {@operation.status}
      </p>
      <p
        :if={@operation && @operation.error}
        class={ui_alert_class(variant: "error", class: "text-sm")}
      >
        {@operation.error}
      </p>
    </div>
    """
  end
end
