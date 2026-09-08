defmodule Serviceradar.Config.V1.Phase do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.config.v1.Phase",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :PHASE_UNSPECIFIED, 0
  field :PHASE_CONFIG, 1
  field :PHASE_RESOLVED, 2
  field :PHASE_BOTH, 3
end

defmodule Serviceradar.Config.V1.Scope do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.Scope",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :kinds, 1, repeated: true, type: Serviceradar.Config.V1.EnvironmentKind, enum: true

  field :except_kinds, 2,
    repeated: true,
    type: Serviceradar.Config.V1.EnvironmentKind,
    json_name: "exceptKinds",
    enum: true
end

defmodule Serviceradar.Config.V1.Required do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.Required",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3
end

defmodule Serviceradar.Config.V1.NonEmpty do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.NonEmpty",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3
end

defmodule Serviceradar.Config.V1.IntRange do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.IntRange",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :min, 1, proto3_optional: true, type: :int64
  field :max, 2, proto3_optional: true, type: :int64
end

defmodule Serviceradar.Config.V1.OneOf do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.OneOf",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :enum_values, 1, repeated: true, type: :string, json_name: "enumValues"
  field :string_values, 2, repeated: true, type: :string, json_name: "stringValues"
end

defmodule Serviceradar.Config.V1.Matches do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.Matches",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :pattern, 1, proto3_optional: true, type: :string
end

defmodule Serviceradar.Config.V1.RequiredIf do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.RequiredIf",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :other_field_path, 1, proto3_optional: true, type: :string, json_name: "otherFieldPath"
  field :other_enum_value, 2, proto3_optional: true, type: :string, json_name: "otherEnumValue"

  field :other_string_value, 3,
    proto3_optional: true,
    type: :string,
    json_name: "otherStringValue"
end

defmodule Serviceradar.Config.V1.ForbiddenValue do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.ForbiddenValue",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :enum_value, 1, proto3_optional: true, type: :string, json_name: "enumValue"
  field :string_value, 2, proto3_optional: true, type: :string, json_name: "stringValue"
end

defmodule Serviceradar.Config.V1.ForbiddenIf do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.ForbiddenIf",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :other_field_path, 1, proto3_optional: true, type: :string, json_name: "otherFieldPath"
  field :other_enum_values, 2, repeated: true, type: :string, json_name: "otherEnumValues"
  field :other_string_values, 3, repeated: true, type: :string, json_name: "otherStringValues"
end

defmodule Serviceradar.Config.V1.EqualAcrossEnvs do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.EqualAcrossEnvs",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3
end

defmodule Serviceradar.Config.V1.Rule do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.Rule",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  oneof :predicate, 0

  field :field_path, 1, proto3_optional: true, type: :string, json_name: "fieldPath"
  field :code, 2, proto3_optional: true, type: :string
  field :phase, 3, proto3_optional: true, type: Serviceradar.Config.V1.Phase, enum: true
  field :scope, 4, proto3_optional: true, type: Serviceradar.Config.V1.Scope
  field :description, 5, proto3_optional: true, type: :string
  field :required, 10, type: Serviceradar.Config.V1.Required, oneof: 0
  field :non_empty, 11, type: Serviceradar.Config.V1.NonEmpty, json_name: "nonEmpty", oneof: 0
  field :int_range, 12, type: Serviceradar.Config.V1.IntRange, json_name: "intRange", oneof: 0
  field :one_of, 13, type: Serviceradar.Config.V1.OneOf, json_name: "oneOf", oneof: 0
  field :matches, 14, type: Serviceradar.Config.V1.Matches, oneof: 0

  field :required_if, 15,
    type: Serviceradar.Config.V1.RequiredIf,
    json_name: "requiredIf",
    oneof: 0

  field :forbidden_value, 16,
    type: Serviceradar.Config.V1.ForbiddenValue,
    json_name: "forbiddenValue",
    oneof: 0

  field :equal_across_envs, 17,
    type: Serviceradar.Config.V1.EqualAcrossEnvs,
    json_name: "equalAcrossEnvs",
    oneof: 0

  field :forbidden_if, 18,
    type: Serviceradar.Config.V1.ForbiddenIf,
    json_name: "forbiddenIf",
    oneof: 0
end

defmodule Serviceradar.Config.V1.RuleSet do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.RuleSet",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :rules, 1, repeated: true, type: Serviceradar.Config.V1.Rule
end

defmodule Serviceradar.Config.V1.ExpectedViolation do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.ExpectedViolation",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :code, 1, proto3_optional: true, type: :string
  field :field_path, 2, proto3_optional: true, type: :string, json_name: "fieldPath"
end

defmodule Serviceradar.Config.V1.Fixture do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.Fixture",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :name, 1, proto3_optional: true, type: :string
  field :description, 2, proto3_optional: true, type: :string
  field :phase, 3, proto3_optional: true, type: Serviceradar.Config.V1.Phase, enum: true
  field :instance, 4, proto3_optional: true, type: Serviceradar.Config.V1.EnvironmentConfig

  field :expected_violations, 5,
    repeated: true,
    type: Serviceradar.Config.V1.ExpectedViolation,
    json_name: "expectedViolations"
end

defmodule Serviceradar.Config.V1.FixtureSet do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.config.v1.FixtureSet",
    protoc_gen_elixir_version: "0.16.1",
    syntax: :proto3

  field :fixtures, 1, repeated: true, type: Serviceradar.Config.V1.Fixture
end
