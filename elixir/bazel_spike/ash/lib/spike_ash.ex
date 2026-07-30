defmodule SpikeAsh.Thing do
  @moduledoc """
  The actual question this whole spike exists to answer: does Spark's compile-time DSL
  expansion (which `use Ash.Resource` drives) work when elixirc is invoked by Bazel rather
  than by mix? If this module compiles, the migration is viable.
  """
  use Ash.Resource, domain: SpikeAsh.Domain, validate_domain_inclusion?: false

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string)
  end

  actions do
    defaults([:read])
  end
end

defmodule SpikeAsh.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(SpikeAsh.Thing)
  end
end
