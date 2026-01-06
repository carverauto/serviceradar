defmodule ServiceRadar.Cluster.TenantSchemasTest do
  @moduledoc """
  Tests for PostgreSQL schema-based tenant isolation (SOC2 compliance).

  Note: These tests require a running PostgreSQL database and may
  create/drop schemas. They are marked as not async to avoid conflicts.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Cluster.TenantSchemas

  @test_tenant_slug "test-tenant-schema"
  @test_tenant_slug_2 "test-tenant-schema-2"

  describe "schema_for/1" do
    test "generates valid schema name from slug" do
      schema = TenantSchemas.schema_for("acme-corp")
      assert schema == "tenant_acme_corp"
    end

    test "sanitizes invalid characters" do
      schema = TenantSchemas.schema_for("ACME Corp! 123")
      assert schema == "tenant_acme_corp_123"
    end

    test "handles multiple underscores" do
      schema = TenantSchemas.schema_for("my--company---name")
      assert schema == "tenant_my_company_name"
    end

    test "trims leading/trailing underscores" do
      schema = TenantSchemas.schema_for("-company-")
      assert schema == "tenant_company"
    end

    test "lowercase conversion" do
      schema = TenantSchemas.schema_for("UPPERCASE")
      assert schema == "tenant_uppercase"
    end
  end

  describe "query_opts/1" do
    test "returns prefix option with schema name" do
      opts = TenantSchemas.query_opts("acme-corp")
      assert opts == [prefix: "tenant_acme_corp"]
    end
  end

  describe "with_tenant/2" do
    test "sets tenant schema in process dictionary during execution" do
      result =
        TenantSchemas.with_tenant("test-tenant", fn ->
          TenantSchemas.current_schema()
        end)

      assert result == "tenant_test_tenant"
    end

    test "restores previous schema after execution" do
      # Set initial schema
      Process.put(:tenant_schema, "original_schema")

      TenantSchemas.with_tenant("test-tenant", fn ->
        assert TenantSchemas.current_schema() == "tenant_test_tenant"
      end)

      assert TenantSchemas.current_schema() == "original_schema"

      Process.delete(:tenant_schema)
    end

    test "clears schema if none was set before" do
      Process.delete(:tenant_schema)

      TenantSchemas.with_tenant("test-tenant", fn ->
        :ok
      end)

      assert TenantSchemas.current_schema() == nil
    end
  end

  describe "tenant_migrations_path/0" do
    test "returns path to tenant migrations directory" do
      path = TenantSchemas.tenant_migrations_path()
      assert String.ends_with?(path, "priv/repo/tenant_migrations")
    end
  end

  # The following tests require database access and are skipped by default
  # Uncomment to run integration tests with a real database

  @tag :database
  @tag :skip
  describe "create_schema/2" do
    setup do
      # Clean up test schemas before and after
      on_exit(fn ->
        TenantSchemas.drop_schema(@test_tenant_slug, cascade: true)
        TenantSchemas.drop_schema(@test_tenant_slug_2, cascade: true)
      end)

      :ok
    end

    test "creates PostgreSQL schema for tenant" do
      assert {:ok, "tenant_test_tenant_schema"} =
               TenantSchemas.create_schema(@test_tenant_slug, run_migrations: false)

      assert TenantSchemas.schema_exists?(@test_tenant_slug)
    end

    test "is idempotent - can be called multiple times" do
      assert {:ok, _} = TenantSchemas.create_schema(@test_tenant_slug, run_migrations: false)
      assert {:ok, _} = TenantSchemas.create_schema(@test_tenant_slug, run_migrations: false)
    end
  end

  @tag :database
  @tag :skip
  describe "drop_schema/2" do
    setup do
      TenantSchemas.create_schema(@test_tenant_slug, run_migrations: false)
      :ok
    end

    test "drops existing schema" do
      assert TenantSchemas.schema_exists?(@test_tenant_slug)
      assert :ok = TenantSchemas.drop_schema(@test_tenant_slug)
      refute TenantSchemas.schema_exists?(@test_tenant_slug)
    end

    test "if_exists option prevents error for non-existent schema" do
      assert :ok = TenantSchemas.drop_schema("non-existent-schema", if_exists: true)
    end
  end

  @tag :database
  @tag :skip
  describe "list_schemas/0" do
    setup do
      TenantSchemas.create_schema(@test_tenant_slug, run_migrations: false)
      TenantSchemas.create_schema(@test_tenant_slug_2, run_migrations: false)

      on_exit(fn ->
        TenantSchemas.drop_schema(@test_tenant_slug, cascade: true)
        TenantSchemas.drop_schema(@test_tenant_slug_2, cascade: true)
      end)

      :ok
    end

    test "lists all tenant schemas" do
      schemas = TenantSchemas.list_schemas()

      assert "tenant_test_tenant_schema" in schemas
      assert "tenant_test_tenant_schema_2" in schemas
    end
  end

  @tag :database
  @tag :skip
  describe "all_tenants/0" do
    test "returns same as list_schemas for migration purposes" do
      assert TenantSchemas.all_tenants() == TenantSchemas.list_schemas()
    end
  end
end
