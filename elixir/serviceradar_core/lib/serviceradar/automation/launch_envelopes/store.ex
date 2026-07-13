defmodule ServiceRadar.Automation.LaunchEnvelopes.Store do
  @moduledoc """
  Transaction and locked-consume boundary for automation launch envelopes.

  `transaction/2` must roll back the pending callback grant if sealing fails.
  `consume/6` must prove the exact preallocated callback-credential command,
  invoke the supplied in-memory decrypt/validation function while the row is
  locked, and only then commit both its secret-free audit and the
  sealed-to-resolved transition. Failed decryption must leave the row sealed.
  """

  @callback transaction((-> {:ok, term()} | {:error, term()}), term()) ::
              {:ok, term()} | {:error, term()}
  @callback create_sealed(map(), term()) :: {:ok, map()} | {:error, term()}

  @callback consume(
              binary(),
              map(),
              DateTime.t(),
              map(),
              (map() -> {:ok, map()} | {:error, term()}),
              term()
            ) ::
              {:ok, map()} | {:error, term()}
end
