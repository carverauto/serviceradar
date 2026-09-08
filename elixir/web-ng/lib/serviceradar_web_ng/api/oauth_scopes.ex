defmodule ServiceRadarWebNG.Api.OauthScopes do
  @moduledoc """
  Canonical OAuth2 scope names for API credentials.

  Atoms here are compiled in so `String.to_existing_atom/1` in the token
  issuer cannot raise on a newly introduced scope such as `mcp`.
  """

  @scopes ~w(read write admin mcp)a

  @spec all() :: [atom()]
  def all, do: @scopes

  @spec names() :: [String.t()]
  def names, do: Enum.map(@scopes, &Atom.to_string/1)

  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: name in names()
  def valid_name?(name) when is_atom(name), do: name in @scopes
  def valid_name?(_), do: false

  @spec to_atom(String.t() | atom()) :: atom()
  def to_atom(scope) when is_atom(scope) and scope in @scopes, do: scope

  def to_atom(scope) when is_binary(scope) do
    if valid_name?(scope), do: String.to_existing_atom(scope), else: :read
  end

  def to_atom(_), do: :read
end
