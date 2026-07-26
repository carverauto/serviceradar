/*
 * Copyright (c) "2025" . Marvin Hansen All Rights Reserved.
 */

#![allow(clippy::all)]

// The argument is the proto *package* ("package api;" in proto/api.proto), which is
// what prost names the generated file after -- not the directory it lives in. The
// module is named `api` to match what rules_rust_prost emits under Bazel, so both
// builds expose the same path: proto_dgraph::api::dgraph_client::DgraphClient.
pub mod api {
    tonic::include_proto!("api");
}
