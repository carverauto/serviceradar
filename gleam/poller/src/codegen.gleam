/// Code generation script for monitoring.proto
/// This generates Gleam types and functions from our protobuf definitions
import gleam/io
import gleam/result
import gleam/string
import protozoa/internal/codegen
import protozoa/parser
import simplifile

pub fn main() {
  io.println("Generating Gleam code from monitoring.proto...")

  case generate_monitoring_code() {
    Ok(_) -> io.println("✓ Code generation completed successfully!")
    Error(error) -> io.println("✗ Code generation failed: " <> error)
  }
}

fn generate_monitoring_code() -> Result(Nil, String) {
  // Read the proto file
  use proto_content <- result.try(
    simplifile.read("proto/monitoring.proto")
    |> result.map_error(fn(_) { "Failed to read proto/monitoring.proto" }),
  )

  // Parse the proto file
  use parsed_file <- result.try(
    parser.parse(proto_content)
    |> result.map_error(fn(err) {
      "Failed to parse proto file: " <> string.inspect(err)
    }),
  )

  // Generate Gleam code
  let generated_code = codegen.generate_simple_for_testing(parsed_file)

  // Write to src/monitoring.gleam
  use _ <- result.try(
    simplifile.write("src/monitoring.gleam", generated_code)
    |> result.map_error(fn(_) { "Failed to write generated code" }),
  )

  io.println("Generated code written to src/monitoring.gleam")
  Ok(Nil)
}
