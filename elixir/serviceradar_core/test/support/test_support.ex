defmodule ServiceRadar.TestSupport do
  @moduledoc """
  Test support utilities for ServiceRadar Core.

  In the single-deployment architecture, each deployment is single-deployment.
  The PostgreSQL search_path (set by CNPG credentials) determines the schema.
  """

  alias Ecto.Adapters.SQL.Sandbox

  @sandbox_teardown_margin_ms 60_000

  @doc "Starts core without implicitly taking database ownership."
  def start_core!(opts \\ []) do
    Application.put_env(
      :serviceradar_core,
      :audit_writer_async?,
      not Keyword.get(opts, :synchronous_audit_writes?, true)
    )

    {:ok, _} = Application.ensure_all_started(:serviceradar_core)
    ensure_repo_started!()

    if sandbox_mode = Keyword.get(opts, :sandbox_mode) do
      Sandbox.mode(ServiceRadar.Repo, sandbox_mode)
    end

    if Keyword.get(opts, :sandbox_owner?, false) do
      checkout_repo!()
    end

    :ok
  end

  @doc "Checks out a rollback-only database owner for the current test."
  def checkout_repo!(context \\ %{}) do
    cond do
      is_nil(Process.whereis(ServiceRadar.Repo)) ->
        :ok

      context[:sandbox] == :unboxed ->
        Sandbox.mode(ServiceRadar.Repo, :auto)

        ExUnit.Callbacks.on_exit(fn ->
          Sandbox.mode(ServiceRadar.Repo, :manual)
        end)

        :ok

      true ->
        owner_opts = sandbox_owner_opts(context)
        owner = Sandbox.start_owner!(ServiceRadar.Repo, owner_opts)

        ExUnit.Callbacks.on_exit(fn ->
          stop_repo_owner(owner)
        end)

        {:ok, sandbox_owner: owner}
    end
  end

  @doc "Runs a function in a fresh rollback-only database owner."
  def with_repo_owner(fun) when is_function(fun, 0) do
    owner = Sandbox.start_owner!(ServiceRadar.Repo, shared: true)

    try do
      fun.()
    after
      stop_repo_owner(owner)
    end
  end

  defp stop_repo_owner(owner) do
    if Process.alive?(owner) do
      Sandbox.stop_owner(owner)
    end
  after
    # start_owner!/2 leaves the pool pointing at the stopped shared owner.
    Sandbox.mode(ServiceRadar.Repo, :manual)
  end

  defp sandbox_owner_opts(context) do
    opts = [shared: not context[:async]]

    case sandbox_ownership_timeout(context) do
      nil -> opts
      timeout -> Keyword.put(opts, :ownership_timeout, timeout)
    end
  end

  @doc false
  def sandbox_ownership_timeout(context) do
    case context[:timeout] do
      timeout when is_integer(timeout) and timeout > 120_000 ->
        timeout + @sandbox_teardown_margin_ms

      _other ->
        nil
    end
  end

  defp ensure_repo_started! do
    repo_enabled? = Application.get_env(:serviceradar_core, :repo_enabled, true) != false

    if repo_enabled? and is_nil(Process.whereis(ServiceRadar.Repo)) do
      case ServiceRadar.Repo.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    else
      :ok
    end
  end
end
