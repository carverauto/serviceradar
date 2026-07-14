//!
//! ## Examples
//!
//! Connecting over TCP:
//!
//! ```no_run
//! use cri_api::v1::runtime_service_client::RuntimeServiceClient;
//! use cri_api::v1::ListContainersRequest;
//! use tokio::main;
//!
//! #[tokio::main]
//! async fn main() {
//!     let mut client = RuntimeServiceClient::connect("http://[::1]:50051")
//!         .await
//!         .expect("Could not create client.");
//!
//!     let request = tonic::Request::new(ListContainersRequest { filter: None });
//!     let response = client
//!         .list_containers(request)
//!         .await
//!         .expect("Request failed.");
//!     println!("{:?}", response);
//! }
//! ```
//!
//! Connecting to a Unix domain socket:
//!
//! ```no_run
//! use std::convert::TryFrom;
//! use tokio::main;
//!
//! use cri_api::v1::runtime_service_client::RuntimeServiceClient;
//! use tokio::net::UnixStream;
//! use tonic::transport::{Channel, Endpoint, Uri};
//! use tower::service_fn;
//!
//! #[tokio::main]
//! async fn main() {
//!     let path = "/run/containerd/containerd.sock";
//!
//!     let channel = Endpoint::try_from("http://[::]")
//!         .unwrap()
//!         .connect_with_connector(service_fn(move |_: Uri| UnixStream::connect(path)))
//!         .await
//!         .expect("Could not create client.");
//!
//!     let mut client = RuntimeServiceClient::new(channel);
//! }
//! ```
//!
//! List sandboxes
//!
//! ```no_run
//! use cri_api::v1::{ListPodSandboxRequest};
//! use cri_api::v1::runtime_service_client::RuntimeServiceClient;
//! use tokio::net::UnixStream;
//! use tonic::transport::{Endpoint, Uri};
//! use tower::service_fn;
//! use tokio::main;
//!
//! #[tokio::main]
//! async fn main() {
//!
//！    let path = "/run/containerd/containerd.sock";
//！    let channel = Endpoint::try_from("http://[::]")
//！         .unwrap()
//！         .connect_with_connector(service_fn(move |_: Uri| UnixStream::connect(path)))
//！         .await
//！         .expect("Could not create client.");
//!
//!     let mut client = RuntimeServiceClient::new(channel);
//!
//!     let request = ListPodSandboxRequest {
//!         filter: None
//!     };
//!
//!     let response =  client.list_pod_sandbox(request).await;
//!     println!("{:#?}", response);
//! }
//! ```
//!
//! List containers
//!
//! ```no_run
//! use cri_api::v1::{ListContainersRequest};
//! use cri_api::v1::runtime_service_client::RuntimeServiceClient;
//! use tokio::net::UnixStream;
//! use tonic::transport::{Endpoint, Uri};
//! use tower::service_fn;
//! use tokio::main;
//!
//! #[tokio::main]
//! async fn main() {
//!     let path = "/run/containerd/containerd.sock";
//!     let channel = Endpoint::try_from("http://[::]")
//!         .unwrap()
//!         .connect_with_connector(service_fn(move |_: Uri| UnixStream::connect(path)))
//!         .await
//!         .expect("Could not create client.");
//!
//!     let mut client = RuntimeServiceClient::new(channel);
//!
//!     let request = ListContainersRequest {
//!         filter: None
//!     };
//!
//!     let response =  client.list_containers(request).await;
//!     println!("{:#?}", response);
//! }
//! ```
//!
//! Container Stats
//!
//! ```no_run
//! use cri_api::v1::{ListContainersRequest, ContainerStatsRequest};
//! use cri_api::v1::runtime_service_client::RuntimeServiceClient;
//! use tokio::net::UnixStream;
//! use tonic::transport::{Endpoint, Uri};
//! use tower::service_fn;
//! use tokio::main;
//!
//! #[tokio::main]
//! async fn main() {
//!     let path = "/run/containerd/containerd.sock";
//!     let channel = Endpoint::try_from("http://[::]")
//!         .unwrap()
//!         .connect_with_connector(service_fn(move |_: Uri| UnixStream::connect(path)))
//!         .await
//!         .expect("Could not create client.");
//!
//!     let mut client = RuntimeServiceClient::new(channel);
//!
//!     let containers = client.list_containers(
//!         ListContainersRequest::default()).await.expect("REASON").into_inner();
//!     for container in containers.containers {
//!         let stats = client.container_stats(ContainerStatsRequest {
//!             container_id: container.id.clone(),
//!         }).await.expect("REASON").into_inner();
//!
//!         println!("Container ID: {:?}", container.id);
//!         println!("Usage: {:?}", stats);
//!
//!     }
//! }
//! ```

/**
 * Copyright (2024, ) Institute of Software, Chinese Academy of Sciences
 * since 0.1.1
 **/

pub mod v1 {
    //! API version v1, [original Protocol Buffers file](https://github.com/kubernetes/cri-api/tree/7d8ade91836419c9dd49d059bda1fe4a7dc283f5/pkg/apis/runtime/v1/api.proto).
    tonic::include_proto!("runtime.v1");
}

