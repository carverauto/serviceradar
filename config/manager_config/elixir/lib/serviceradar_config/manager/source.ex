defmodule ServiceradarConfig.Manager.Source do
  @moduledoc "Where the bytes for an identity come from."

  alias ServiceradarConfig.Manager.Identity

  @doc """
  Where a deployed environment's instance is mounted.

  A constant, not a variable. The platform decides WHICH environment a container is by setting
  `SERVICERADAR_ENV` and mounts the matching artifact here; making the path settable too would add
  a second thing that can disagree with the first.
  """
  @mounted_instance_path "/etc/serviceradar/environment.binpb"
  def mounted_instance_path, do: @mounted_instance_path

  defstruct [:kind, :name]
  @type t :: %__MODULE__{kind: :built_in | :mounted, name: String.t()}

  @doc """
  `localhost` and `ci` carry their instance in the artifact because neither has a platform to
  mount anything: a developer running a release directly and a Bazel test action both have a
  filesystem nobody provisioned. Every deployed kind reads the mount.
  """
  @spec for_identity(Identity.t()) :: t()
  def for_identity(%Identity{kind: kind} = identity) when kind in ~w(localhost ci) do
    %__MODULE__{kind: :built_in, name: Identity.to_string(identity)}
  end

  def for_identity(%Identity{}) do
    %__MODULE__{kind: :mounted, name: @mounted_instance_path}
  end

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{kind: :built_in, name: name}), do: "built-in:#{name}"
  def to_string(%__MODULE__{kind: :mounted, name: path}), do: path
end

defimpl String.Chars, for: ServiceradarConfig.Manager.Source do
  def to_string(source), do: ServiceradarConfig.Manager.Source.to_string(source)
end
