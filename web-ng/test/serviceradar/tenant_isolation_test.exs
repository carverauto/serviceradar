defmodule ServiceRadar.TenantIsolationTest do
  @moduledoc """
  Stub module for tenant isolation tests.

  In a tenant-instance model, cross-tenant isolation is handled at the
  infrastructure level (CNPG credentials set PostgreSQL search_path).
  Each tenant gets their own deployment with separate DB connections.

  These tests are not applicable to tenant instances - they only apply to the
  Control Plane which manages multiple tenants in a single deployment.
  """

  use ExUnit.Case, async: true

  # No tests - tenant isolation is handled at infrastructure level
  # Each tenant instance has its own deployment with CNPG-managed search_path
end
