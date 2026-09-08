defmodule ServiceradarConfig.Manager.SelectorError do
  @moduledoc "Why an environment identity could not be determined."

  alias ServiceradarConfig.Manager.Identity

  @doc """
  Renders a selector failure.

  The `:absent` case is the one failure a reader may be meeting for the first time, possibly at
  3am, in a crash loop with no other output. It says what is wrong, why nothing can proceed,
  exactly what to set, and how to set it on each platform -- because the reader's next action is
  editing a manifest, not reading source.
  """
  @spec message(term()) :: String.t()
  def message(:absent) do
    env = Identity.env_var()
    kinds = Enum.join(Identity.single_instance_kinds(), "\n  ")

    """

    ==============================================================================
    SERVICERADAR CANNOT START: #{env} is not set.
    ==============================================================================

    This one environment variable declares WHICH ServiceRadar environment this
    process is running in. Everything else is derived from it: the database, the
    message bus, the TLS posture, and which provider resolves secrets. Nothing can
    be loaded until it is set.

    There is deliberately NO DEFAULT. A guessed environment is a guessed database,
    and guessing wrong is silent -- the process would start and connect somewhere
    nobody chose.

    Set #{env} to exactly one of:

      #{kinds}
      #{Identity.onprem()}:<instance>     (on-prem is multi-instance; name the deployment)

    How to set it:

      Kubernetes   env:
                     - name: #{env}
                       value: saas
      Docker       docker run -e #{env}=saas ...
      Compose      environment:
                     #{env}: saas
      CI           export #{env}=ci
      Local dev    export #{env}=localhost
    ==============================================================================\
    """
  end

  def message({:unknown_kind, value}) do
    "#{Identity.env_var()}=#{inspect(value)} names no environment kind. " <>
      "Valid: #{Enum.join(Identity.single_instance_kinds(), ", ")}, #{Identity.onprem()}:<instance>."
  end

  def message({:instance_required, kind}) do
    "#{Identity.env_var()}=#{inspect(kind)} requires an instance identifier, as #{kind}:<instance>."
  end

  def message({:instance_not_accepted, kind}) do
    "#{Identity.env_var()} kind #{inspect(kind)} does not accept an instance identifier."
  end
end
