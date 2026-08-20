defmodule ServiceradarSecret.Names do
  @moduledoc """
  The logical names of the secrets a database connection needs.

  Names, not values: `ServiceradarSecret` resolves each through the provider its environment
  selects. They live here rather than in any one consumer because two components resolving "the
  database password" must ask for the SAME name -- and because the name is what
  `ServiceradarSecret.EnvProvider.variable_for/1` turns into an environment variable, so a
  component that spells it differently silently reads a variable nothing sets.

  Mirrors `//config/manager_config/rust` `secrets.rs`. The two lists must agree exactly: the same
  fixture is reached from both languages in one CI run, through variables named by this
  transform.

  They mirror `DatabaseConfig` in the schema, which carries every part of a connection that is
  NOT secret -- host, port, roles, TLS mode, server name. Anything a certificate or password
  could be recovered from belongs here instead.
  """

  @doc "The password for `DatabaseConfig.connecting_role`."
  def database_password, do: "database.password"

  @doc """
  The password for `DatabaseConfig.admin_role`.

  Separate from `database_password/0` because the roles are separate: the suite connects as the
  application role, which deliberately lacks CREATEDB, while creating and dropping the per-run
  database needs one that does not.
  """
  def database_admin_password, do: "database.admin_password"

  @doc """
  PEM for the CA the server certificate chains to.

  Content, never a path: a path is only meaningful on the host that resolves it, which is the
  assumption that stops a test action from running anywhere but one machine.
  """
  def database_ca_cert, do: "database.ca_cert"

  @doc """
  PEM for the CA the Dgraph Alpha certificate chains to.

  Separate from `database_ca_cert/0` because they are separate trust decisions: Dgraph is
  issued by an in-cluster CA for a name no public authority will sign, and the client verifies
  against this CA instead of the system roots.
  """
  def dgraph_ca_cert, do: "dgraph.ca_cert"


  def dgraph_admin_password, do: "dgraph.admin_password"

  @doc "PEM client certificate, for a server that requires mutual TLS."
  def database_client_cert, do: "database.client_cert"

  @doc "PEM private key matching `database_client_cert/0`."
  def database_client_key, do: "database.client_key"
end
