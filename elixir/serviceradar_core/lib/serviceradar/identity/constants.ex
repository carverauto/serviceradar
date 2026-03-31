defmodule ServiceRadar.Identity.Constants do
  @moduledoc false

  @allowed_roles [:viewer, :helpdesk, :operator, :admin]
  @all_roles @allowed_roles
  @operator_roles [:operator, :admin]
  @helpdesk_roles [:helpdesk, :operator, :admin]
  @admin_roles [:admin]
  @auth_manage_permission "settings.auth.manage"
  @password_manage_permission "settings.password.manage"
  @rbac_manage_permission "settings.rbac.manage"

  def allowed_roles, do: @allowed_roles
  def all_roles, do: @all_roles
  def operator_roles, do: @operator_roles
  def helpdesk_roles, do: @helpdesk_roles
  def admin_roles, do: @admin_roles
  def auth_manage_permission, do: @auth_manage_permission
  def password_manage_permission, do: @password_manage_permission
  def rbac_manage_permission, do: @rbac_manage_permission
end
