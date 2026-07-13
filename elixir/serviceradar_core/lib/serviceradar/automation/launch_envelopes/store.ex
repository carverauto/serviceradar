defmodule ServiceRadar.Automation.LaunchEnvelopes.Store do
  @moduledoc """
  Transaction and locked-consume boundary for automation launch envelopes.

  `transaction/2` must roll back the pending callback grant if sealing fails.
  `consume/5` must prove the exact preallocated callback-credential command and
  commit both its secret-free audit and the sealed-to-resolved transition
  before returning ciphertext to the service for decryption.
  """

  @callback transaction((-> {:ok, term()} | {:error, term()}), term()) ::
              {:ok, term()} | {:error, term()}
  @callback create_sealed(map(), term()) :: {:ok, map()} | {:error, term()}

  @callback consume(binary(), map(), DateTime.t(), map(), term()) ::
              {:ok, map()} | {:error, term()}
end
