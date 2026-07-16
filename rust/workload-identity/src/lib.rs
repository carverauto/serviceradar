//! Node-local workload identity collection and runtime metadata enrichment.

/// Kubernetes CRI runtime API, generated from `//proto/cri/v1.proto` by `build.rs`.
///
/// Generated in-tree rather than taken from the `cri-api` crate: that crate is built against
/// tonic 0.12, so depending on it forced a second gRPC stack (tonic 0.12, tonic-build 0.12,
/// prost-build 0.13, axum 0.7) alongside the workspace's tonic 0.14.
pub mod cri {
    pub mod v1 {
        tonic::include_proto!("runtime.v1");
    }
}

use std::{
    collections::{BTreeMap, HashMap},
    fs,
    future::Future,
    path::{Path, PathBuf},
    sync::{Arc, RwLock},
    time::Duration,
};

use serde::{Deserialize, Serialize};

#[cfg(unix)]
use std::os::unix::fs::FileTypeExt;

#[cfg(unix)]
use crate::cri::v1::{
    Container, ContainerFilter, ContainerState, ContainerStateValue, ContainerStatusRequest,
    ContainerStatusResponse, ListContainersRequest, PodSandboxStatusRequest,
    PodSandboxStatusResponse, runtime_service_client::RuntimeServiceClient,
};
#[cfg(unix)]
use anyhow::{Context, Result};
#[cfg(unix)]
use hyper_util::rt::TokioIo;
#[cfg(unix)]
use serde_json::Value;
#[cfg(unix)]
use tokio::io::{AsyncReadExt, AsyncWriteExt};
#[cfg(unix)]
use tokio::net::UnixStream;
#[cfg(unix)]
use tonic::transport::{Channel, Endpoint, Uri};
#[cfg(unix)]
use tower::service_fn;

const DEFAULT_CRI_REFRESH_INTERVAL: Duration = Duration::from_secs(60);

const COMMON_CRI_ENDPOINTS: &[&str] = &[
    "/run/k3s/containerd/containerd.sock",
    "/run/containerd/containerd.sock",
    "/var/run/containerd/containerd.sock",
    "/var/run/crio/crio.sock",
];

const COMMON_DOCKER_ENDPOINTS: &[&str] = &["/var/run/docker.sock", "/run/docker.sock"];

const CRI_CONFIG_FILES: &[&str] = &[
    "/etc/crictl.yaml",
    "/var/lib/rancher/k3s/agent/etc/crictl.yaml",
];

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Default)]
pub enum RuntimeSource {
    #[default]
    Containerd,
    Crio,
    Docker,
}

impl RuntimeSource {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Containerd => "containerd",
            Self::Crio => "crio",
            Self::Docker => "docker",
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
pub struct CgroupIdentity {
    pub pod_uid: Option<String>,
    pub container_id: Option<String>,
    pub runtime_source: Option<RuntimeSource>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
pub enum MetadataConfidence {
    #[default]
    Unknown,
    High,
    Degraded,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
pub struct WorkloadIdentity {
    pub pod_sandbox_id: Option<String>,
    pub pod_name: Option<String>,
    pub pod_namespace: Option<String>,
    pub pod_uid: Option<String>,
    pub container_id: Option<String>,
    pub container_name: Option<String>,
    pub image: Option<String>,
    pub image_ref: Option<String>,
    pub runtime_pid: Option<u32>,
    pub cgroup_path: Option<String>,
    pub labels: BTreeMap<String, String>,
    pub annotations: BTreeMap<String, String>,
    pub runtime_source: RuntimeSource,
    pub confidence: MetadataConfidence,
    pub degradation_reason: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CriContainerLookup {
    pub container_id: String,
    pub identity: WorkloadIdentity,
}

#[derive(Clone, Debug, Default)]
pub struct WorkloadIdentityCache {
    identities: Arc<RwLock<HashMap<String, WorkloadIdentity>>>,
}

impl WorkloadIdentityCache {
    pub fn lookup(&self, container_id: &str) -> Option<WorkloadIdentity> {
        self.identities
            .read()
            .ok()
            .and_then(|identities| identities.get(container_id).cloned())
    }

    fn replace_all(&self, identities: Vec<CriContainerLookup>) {
        let Ok(mut cache) = self.identities.write() else {
            return;
        };

        cache.clear();
        cache.extend(
            identities
                .into_iter()
                .filter(|lookup| !lookup.container_id.is_empty())
                .map(|lookup| (lookup.container_id, lookup.identity)),
        );
    }

    pub fn len(&self) -> usize {
        self.identities
            .read()
            .map_or(0, |identities| identities.len())
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

pub type SharedWorkloadIdentityCache = WorkloadIdentityCache;

#[cfg(unix)]
pub struct WorkloadIdentityRuntime {
    cache: SharedWorkloadIdentityCache,
    task: tokio::task::JoinHandle<()>,
}

#[cfg(unix)]
impl WorkloadIdentityRuntime {
    pub fn start_cri(
        root: PathBuf,
        explicit_endpoint: Option<PathBuf>,
        refresh_interval: Option<Duration>,
    ) -> Result<Option<Self>> {
        let Some(endpoint) = discover_cri_endpoint(&root, explicit_endpoint.as_deref()) else {
            log::warn!("workload identity CRI enrichment disabled: no CRI endpoint discovered");
            return Ok(None);
        };

        let interval = refresh_interval
            .unwrap_or(DEFAULT_CRI_REFRESH_INTERVAL)
            .max(Duration::from_secs(10));
        let cache = WorkloadIdentityCache::default();
        let handle = tokio::runtime::Handle::try_current()
            .context("workload identity CRI runtime requires a Tokio runtime")?;
        let mut client = tokio::task::block_in_place(|| {
            handle.block_on(async {
                let mut client = CriRuntimeClient::connect(&endpoint).await?;
                refresh_cri_cache(&mut client, &cache).await?;
                Result::<CriRuntimeClient>::Ok(client)
            })
        })?;
        let task_cache = cache.clone();
        let task_endpoint = endpoint.clone();
        let task = tokio::spawn(async move {
            loop {
                tokio::time::sleep(interval).await;

                if let Err(err) = refresh_cri_cache(&mut client, &task_cache).await {
                    log::warn!("workload identity CRI refresh failed: {err:#}");

                    match CriRuntimeClient::connect(&task_endpoint).await {
                        Ok(reconnected) => {
                            client = reconnected;
                        }
                        Err(connect_err) => {
                            log::warn!(
                                "workload identity CRI reconnect failed at {}: {connect_err:#}",
                                task_endpoint.path.display()
                            );
                        }
                    }
                }
            }
        });

        log::info!(
            "workload identity CRI enrichment active at {} with {} cached container(s)",
            endpoint.path.display(),
            cache.len()
        );

        Ok(Some(Self { cache, task }))
    }

    pub fn cache(&self) -> SharedWorkloadIdentityCache {
        self.cache.clone()
    }
}

#[cfg(unix)]
impl Drop for WorkloadIdentityRuntime {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[cfg(unix)]
async fn refresh_cri_cache(
    client: &mut CriRuntimeClient,
    cache: &SharedWorkloadIdentityCache,
) -> Result<()> {
    let identities = client.list_container_identities().await?;
    cache.replace_all(identities);
    Ok(())
}

pub trait CgroupIdentityBackend {
    fn identity_from_cgroup(&self, cgroup_payload: &str) -> CgroupIdentity;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct CgroupParserBackend;

impl CgroupIdentityBackend for CgroupParserBackend {
    fn identity_from_cgroup(&self, cgroup_payload: &str) -> CgroupIdentity {
        parse_cgroup_identity(cgroup_payload)
    }
}

pub trait WorkloadIdentityBackend {
    fn backend_name(&self) -> &'static str;

    fn list_container_identities(
        &mut self,
    ) -> impl Future<Output = Result<Vec<CriContainerLookup>>> + Send + '_;

    fn container_identity<'a>(
        &'a mut self,
        container_id: &'a str,
    ) -> impl Future<Output = Result<Option<WorkloadIdentity>>> + Send + 'a;
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub enum CriEndpointSource {
    Explicit,
    ConfigFile(PathBuf),
    CommonPath,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CriEndpoint {
    pub path: PathBuf,
    pub source: CriEndpointSource,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub enum DockerEndpointSource {
    Explicit,
    CommonPath,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DockerEndpoint {
    pub path: PathBuf,
    pub source: DockerEndpointSource,
}

#[cfg(unix)]
pub struct CriRuntimeClient {
    client: RuntimeServiceClient<Channel>,
    runtime_source: RuntimeSource,
}

#[cfg(unix)]
impl CriRuntimeClient {
    pub async fn connect(endpoint: &CriEndpoint) -> Result<Self> {
        let socket_path = endpoint.path.clone();
        let runtime_source = runtime_source_from_endpoint(&socket_path);
        let channel = Endpoint::try_from("http://[::]")
            .context("create CRI Unix-socket endpoint")?
            .connect_with_connector(service_fn(move |_: Uri| {
                let socket_path = socket_path.clone();

                async move { UnixStream::connect(socket_path).await.map(TokioIo::new) }
            }))
            .await
            .with_context(|| format!("connect to CRI socket {}", endpoint.path.display()))?;

        Ok(Self {
            client: RuntimeServiceClient::new(channel),
            runtime_source,
        })
    }

    pub async fn list_container_identities(&mut self) -> Result<Vec<CriContainerLookup>> {
        let containers = self
            .client
            .list_containers(ListContainersRequest {
                filter: Some(ContainerFilter {
                    id: String::new(),
                    state: Some(ContainerStateValue {
                        state: ContainerState::ContainerRunning as i32,
                    }),
                    pod_sandbox_id: String::new(),
                    label_selector: std::collections::HashMap::new(),
                }),
            })
            .await
            .context("list CRI containers")?
            .into_inner()
            .containers;

        let mut identities = Vec::with_capacity(containers.len());

        for container in containers {
            if let Some(identity) = self.identity_for_container(container).await? {
                let container_id = identity.container_id.clone().unwrap_or_default();
                identities.push(CriContainerLookup {
                    container_id,
                    identity,
                });
            }
        }

        Ok(identities)
    }

    pub async fn container_identity(
        &mut self,
        container_id: &str,
    ) -> Result<Option<WorkloadIdentity>> {
        let containers = self
            .client
            .list_containers(ListContainersRequest {
                filter: Some(ContainerFilter {
                    id: container_id.to_string(),
                    state: None,
                    pod_sandbox_id: String::new(),
                    label_selector: std::collections::HashMap::new(),
                }),
            })
            .await
            .with_context(|| format!("list CRI container {container_id}"))?
            .into_inner()
            .containers;

        let Some(container) = containers.into_iter().next() else {
            return Ok(None);
        };

        self.identity_for_container(container).await
    }

    async fn identity_for_container(
        &mut self,
        container: Container,
    ) -> Result<Option<WorkloadIdentity>> {
        let status = self
            .client
            .container_status(ContainerStatusRequest {
                container_id: container.id.clone(),
                verbose: true,
            })
            .await
            .with_context(|| format!("read CRI container status {}", container.id))?
            .into_inner();

        let sandbox = if container.pod_sandbox_id.is_empty() {
            None
        } else {
            Some(
                self.client
                    .pod_sandbox_status(PodSandboxStatusRequest {
                        pod_sandbox_id: container.pod_sandbox_id.clone(),
                        verbose: true,
                    })
                    .await
                    .with_context(|| {
                        format!("read CRI pod sandbox status {}", container.pod_sandbox_id)
                    })?
                    .into_inner(),
            )
        };

        Ok(identity_from_cri(
            &container,
            &status,
            sandbox.as_ref(),
            self.runtime_source.clone(),
        ))
    }
}

#[cfg(unix)]
impl WorkloadIdentityBackend for CriRuntimeClient {
    fn backend_name(&self) -> &'static str {
        self.runtime_source.as_str()
    }

    async fn list_container_identities(&mut self) -> Result<Vec<CriContainerLookup>> {
        CriRuntimeClient::list_container_identities(self).await
    }

    async fn container_identity(&mut self, container_id: &str) -> Result<Option<WorkloadIdentity>> {
        CriRuntimeClient::container_identity(self, container_id).await
    }
}

#[cfg(unix)]
pub struct DockerRuntimeClient {
    endpoint: DockerEndpoint,
}

#[cfg(unix)]
impl DockerRuntimeClient {
    pub async fn connect(endpoint: &DockerEndpoint) -> Result<Self> {
        UnixStream::connect(&endpoint.path)
            .await
            .with_context(|| format!("connect to Docker socket {}", endpoint.path.display()))?;

        Ok(Self {
            endpoint: endpoint.clone(),
        })
    }

    pub async fn list_container_identities(&mut self) -> Result<Vec<CriContainerLookup>> {
        let containers: Vec<DockerContainerSummary> =
            docker_get_json(&self.endpoint.path, "/containers/json?all=false")
                .await
                .context("list Docker containers")?;

        let mut identities = Vec::with_capacity(containers.len());

        for container in containers {
            if let Some(identity) = self.identity_for_container(container).await? {
                let container_id = identity.container_id.clone().unwrap_or_default();
                identities.push(CriContainerLookup {
                    container_id,
                    identity,
                });
            }
        }

        Ok(identities)
    }

    pub async fn container_identity(
        &mut self,
        container_id: &str,
    ) -> Result<Option<WorkloadIdentity>> {
        let safe_id = docker_safe_container_id(container_id)?;
        let inspect: DockerContainerInspect =
            docker_get_json(&self.endpoint.path, &format!("/containers/{safe_id}/json"))
                .await
                .with_context(|| format!("inspect Docker container {container_id}"))?;

        Ok(Some(identity_from_docker(None, &inspect)))
    }

    async fn identity_for_container(
        &mut self,
        container: DockerContainerSummary,
    ) -> Result<Option<WorkloadIdentity>> {
        if container.id.is_empty() {
            return Ok(None);
        }

        let safe_id = docker_safe_container_id(&container.id)?;
        let inspect: DockerContainerInspect =
            docker_get_json(&self.endpoint.path, &format!("/containers/{safe_id}/json"))
                .await
                .with_context(|| format!("inspect Docker container {}", container.id))?;

        Ok(Some(identity_from_docker(Some(&container), &inspect)))
    }
}

#[cfg(unix)]
impl WorkloadIdentityBackend for DockerRuntimeClient {
    fn backend_name(&self) -> &'static str {
        RuntimeSource::Docker.as_str()
    }

    async fn list_container_identities(&mut self) -> Result<Vec<CriContainerLookup>> {
        DockerRuntimeClient::list_container_identities(self).await
    }

    async fn container_identity(&mut self, container_id: &str) -> Result<Option<WorkloadIdentity>> {
        DockerRuntimeClient::container_identity(self, container_id).await
    }
}

pub fn parse_cgroup_identity(cgroup_payload: &str) -> CgroupIdentity {
    let mut identity = CgroupIdentity::default();

    for line in cgroup_payload.lines() {
        let path = cgroup_path_from_record(line);
        if path.is_empty() {
            continue;
        }

        if identity.pod_uid.is_none() {
            identity.pod_uid = extract_pod_uid(path);
        }

        if identity.container_id.is_none()
            && let Some((runtime, container_id)) = extract_container_id(path)
        {
            identity.runtime_source = Some(runtime);
            identity.container_id = Some(container_id);
        }

        if identity.pod_uid.is_some() && identity.container_id.is_some() {
            break;
        }
    }

    identity
}

pub fn discover_cri_endpoint(root: &Path, explicit: Option<&Path>) -> Option<CriEndpoint> {
    if let Some(path) = explicit {
        let candidate = rooted_path(root, path);

        if is_socket(&candidate) {
            return Some(CriEndpoint {
                path: path.to_path_buf(),
                source: CriEndpointSource::Explicit,
            });
        }
    }

    for config_file in CRI_CONFIG_FILES {
        let config_path = rooted_path(root, Path::new(config_file));
        let Ok(contents) = fs::read_to_string(&config_path) else {
            continue;
        };

        for endpoint in parse_cri_endpoints_from_config(&contents) {
            let candidate = rooted_path(root, &endpoint);

            if is_socket(&candidate) {
                return Some(CriEndpoint {
                    path: endpoint,
                    source: CriEndpointSource::ConfigFile(PathBuf::from(config_file)),
                });
            }
        }
    }

    COMMON_CRI_ENDPOINTS.iter().find_map(|path| {
        let path = PathBuf::from(path);
        let candidate = rooted_path(root, &path);

        is_socket(&candidate).then_some(CriEndpoint {
            path,
            source: CriEndpointSource::CommonPath,
        })
    })
}

pub fn discover_docker_endpoint(root: &Path, explicit: Option<&Path>) -> Option<DockerEndpoint> {
    if let Some(path) = explicit {
        let candidate = rooted_path(root, path);

        if is_socket(&candidate) {
            return Some(DockerEndpoint {
                path: path.to_path_buf(),
                source: DockerEndpointSource::Explicit,
            });
        }
    }

    COMMON_DOCKER_ENDPOINTS.iter().find_map(|path| {
        let path = PathBuf::from(path);
        let candidate = rooted_path(root, &path);

        is_socket(&candidate).then_some(DockerEndpoint {
            path,
            source: DockerEndpointSource::CommonPath,
        })
    })
}

fn cgroup_path_from_record(record: &str) -> &str {
    let record = record.trim();
    let mut parts = record.splitn(3, ':');
    let first = parts.next().unwrap_or_default();
    let second = parts.next();
    let third = parts.next();

    if !first.is_empty()
        && first.bytes().all(|b| b.is_ascii_digit())
        && let (Some(_controllers), Some(path)) = (second, third)
    {
        return path.trim();
    }

    record
}

fn extract_pod_uid(path: &str) -> Option<String> {
    for (idx, _) in path.match_indices("pod") {
        let rest = &path[idx + 3..];
        let raw: String = rest
            .chars()
            .take_while(|ch| ch.is_ascii_hexdigit() || *ch == '-' || *ch == '_')
            .collect();
        if let Some(uid) = normalize_pod_uid(&raw).filter(|uid| is_uuid_like(uid)) {
            return Some(uid);
        }
    }

    None
}

fn extract_container_id(path: &str) -> Option<(RuntimeSource, String)> {
    let marker_match = [
        ("cri-containerd", RuntimeSource::Containerd),
        ("containerd", RuntimeSource::Containerd),
        ("crio", RuntimeSource::Crio),
        ("docker", RuntimeSource::Docker),
    ]
    .into_iter()
    .find_map(|(marker, runtime)| {
        path.find(marker).and_then(|idx| {
            let tail = &path[idx + marker.len()..];
            extract_hex_token(tail, 64).map(|container_id| (runtime, container_id))
        })
    });

    marker_match.or_else(|| extract_hex_token(path, 64).map(|id| (RuntimeSource::Containerd, id)))
}

fn extract_hex_token(value: &str, len: usize) -> Option<String> {
    let mut start = None;
    let mut count = 0usize;

    for (idx, ch) in value.char_indices() {
        if ch.is_ascii_hexdigit() {
            start.get_or_insert(idx);
            count += 1;

            if count == len {
                let start = start?;
                return Some(value[start..idx + ch.len_utf8()].to_ascii_lowercase());
            }
        } else {
            start = None;
            count = 0;
        }
    }

    None
}

fn normalize_pod_uid(raw: &str) -> Option<String> {
    let normalized = raw.trim_end_matches(".slice").replace('_', "-");

    if normalized.len() == 36 {
        return Some(normalized.to_ascii_lowercase());
    }

    if normalized.len() == 32 && normalized.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return Some(format!(
            "{}-{}-{}-{}-{}",
            &normalized[0..8],
            &normalized[8..12],
            &normalized[12..16],
            &normalized[16..20],
            &normalized[20..32]
        ));
    }

    None
}

fn is_uuid_like(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && [8, 13, 18, 23].into_iter().all(|idx| bytes[idx] == b'-')
        && value
            .chars()
            .filter(|ch| *ch != '-')
            .all(|ch| ch.is_ascii_hexdigit())
}

fn parse_cri_endpoints_from_config(contents: &str) -> Vec<PathBuf> {
    contents
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;

            if key.trim() != "runtime-endpoint" {
                return None;
            }

            endpoint_path(value.trim().trim_matches('"').trim_matches('\''))
        })
        .collect()
}

fn endpoint_path(value: &str) -> Option<PathBuf> {
    value
        .strip_prefix("unix://")
        .or_else(|| value.strip_prefix("unix:"))
        .map(PathBuf::from)
        .or_else(|| value.starts_with('/').then(|| PathBuf::from(value)))
}

fn rooted_path(root: &Path, path: &Path) -> PathBuf {
    if root == Path::new("/") {
        return path.to_path_buf();
    }

    match path.strip_prefix("/") {
        Ok(stripped) => root.join(stripped),
        Err(_) => root.join(path),
    }
}

fn runtime_source_from_endpoint(path: &Path) -> RuntimeSource {
    let path = path.to_string_lossy();

    if path.contains("crio") {
        RuntimeSource::Crio
    } else if path.contains("docker") {
        RuntimeSource::Docker
    } else {
        RuntimeSource::Containerd
    }
}

#[cfg(unix)]
#[derive(Debug, Deserialize)]
struct DockerContainerSummary {
    #[serde(rename = "Id", default)]
    id: String,
    #[serde(rename = "Names", default)]
    names: Vec<String>,
    #[serde(rename = "Image", default)]
    image: String,
    #[serde(rename = "ImageID", default)]
    image_id: String,
    #[serde(rename = "Labels", default)]
    labels: std::collections::HashMap<String, String>,
}

#[cfg(unix)]
#[derive(Debug, Deserialize)]
struct DockerContainerInspect {
    #[serde(rename = "Id", default)]
    id: String,
    #[serde(rename = "Name", default)]
    name: String,
    #[serde(rename = "Image", default)]
    image_ref: String,
    #[serde(rename = "Config", default)]
    config: Option<DockerContainerConfig>,
    #[serde(rename = "State", default)]
    state: Option<DockerContainerState>,
    #[serde(rename = "HostConfig", default)]
    host_config: Option<DockerHostConfig>,
}

#[cfg(unix)]
#[derive(Debug, Default, Deserialize)]
struct DockerContainerConfig {
    #[serde(rename = "Image", default)]
    image: String,
    #[serde(rename = "Labels", default)]
    labels: std::collections::HashMap<String, String>,
}

#[cfg(unix)]
#[derive(Debug, Default, Deserialize)]
struct DockerContainerState {
    #[serde(rename = "Pid", default)]
    pid: u32,
}

#[cfg(unix)]
#[derive(Debug, Default, Deserialize)]
struct DockerHostConfig {
    #[serde(rename = "CgroupParent", default)]
    cgroup_parent: String,
}

#[cfg(unix)]
fn identity_from_docker(
    summary: Option<&DockerContainerSummary>,
    inspect: &DockerContainerInspect,
) -> WorkloadIdentity {
    let labels = docker_labels(summary, inspect);
    let container_name = docker_container_name(summary, inspect);

    WorkloadIdentity {
        pod_sandbox_id: None,
        pod_name: None,
        pod_namespace: None,
        pod_uid: None,
        container_id: non_empty_string(&inspect.id)
            .or_else(|| summary.and_then(|summary| non_empty_string(&summary.id))),
        container_name,
        image: inspect
            .config
            .as_ref()
            .and_then(|config| non_empty_string(&config.image))
            .or_else(|| summary.and_then(|summary| non_empty_string(&summary.image))),
        image_ref: non_empty_string(&inspect.image_ref)
            .or_else(|| summary.and_then(|summary| non_empty_string(&summary.image_id))),
        runtime_pid: inspect
            .state
            .as_ref()
            .and_then(|state| (state.pid > 0).then_some(state.pid)),
        cgroup_path: inspect
            .host_config
            .as_ref()
            .and_then(|host_config| non_empty_string(&host_config.cgroup_parent)),
        labels,
        annotations: BTreeMap::new(),
        runtime_source: RuntimeSource::Docker,
        confidence: MetadataConfidence::High,
        degradation_reason: None,
    }
}

#[cfg(unix)]
fn docker_container_name(
    summary: Option<&DockerContainerSummary>,
    inspect: &DockerContainerInspect,
) -> Option<String> {
    non_empty_string(inspect.name.trim_start_matches('/')).or_else(|| {
        summary.and_then(|summary| {
            summary
                .names
                .iter()
                .find_map(|name| non_empty_string(name.trim_start_matches('/')))
        })
    })
}

#[cfg(unix)]
fn docker_labels(
    summary: Option<&DockerContainerSummary>,
    inspect: &DockerContainerInspect,
) -> BTreeMap<String, String> {
    let mut labels = BTreeMap::new();
    if let Some(summary) = summary {
        labels.extend(
            summary
                .labels
                .iter()
                .map(|(key, value)| (key.clone(), value.clone())),
        );
    }
    if let Some(config) = inspect.config.as_ref() {
        labels.extend(
            config
                .labels
                .iter()
                .map(|(key, value)| (key.clone(), value.clone())),
        );
    }

    labels
}

#[cfg(unix)]
async fn docker_get_json<T>(socket_path: &Path, path: &str) -> Result<T>
where
    T: for<'de> Deserialize<'de>,
{
    let mut stream = UnixStream::connect(socket_path)
        .await
        .with_context(|| format!("connect to Docker socket {}", socket_path.display()))?;
    let request = format!(
        "GET {path} HTTP/1.1\r\nHost: docker\r\nConnection: close\r\nAccept: application/json\r\n\r\n"
    );
    stream
        .write_all(request.as_bytes())
        .await
        .context("write Docker API request")?;
    stream
        .shutdown()
        .await
        .context("finish Docker API request")?;

    let mut response = Vec::new();
    stream
        .read_to_end(&mut response)
        .await
        .context("read Docker API response")?;

    let body = docker_response_body(&response)?;
    serde_json::from_slice(&body).context("decode Docker API JSON")
}

#[cfg(unix)]
fn docker_response_body(response: &[u8]) -> Result<Vec<u8>> {
    let header_end = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .context("Docker API response missing header terminator")?;
    let headers = std::str::from_utf8(&response[..header_end])
        .context("Docker API response headers are not UTF-8")?;
    let mut lines = headers.lines();
    let status = lines.next().unwrap_or_default();
    let status_code = status
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .unwrap_or_default();
    if !(200..300).contains(&status_code) {
        anyhow::bail!("Docker API request failed: {status}");
    }

    if headers
        .lines()
        .any(|line| line.eq_ignore_ascii_case("transfer-encoding: chunked"))
    {
        return decode_http_chunks(&response[header_end + 4..]);
    }

    Ok(response[header_end + 4..].to_vec())
}

#[cfg(unix)]
fn decode_http_chunks(body: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut offset = 0usize;

    loop {
        let size_end = body[offset..]
            .windows(2)
            .position(|window| window == b"\r\n")
            .map(|idx| offset + idx)
            .context("chunked Docker API response missing chunk size")?;
        let size_line =
            std::str::from_utf8(&body[offset..size_end]).context("chunk size is not UTF-8")?;
        let size_hex = size_line.split(';').next().unwrap_or_default().trim();
        let size = usize::from_str_radix(size_hex, 16).context("invalid chunk size")?;
        offset = size_end + 2;

        if size == 0 {
            return Ok(out);
        }
        if body.len() < offset + size + 2 {
            anyhow::bail!("chunked Docker API response ended early");
        }

        out.extend_from_slice(&body[offset..offset + size]);
        offset += size;
        if body.get(offset..offset + 2) != Some(b"\r\n") {
            anyhow::bail!("chunked Docker API response missing chunk terminator");
        }
        offset += 2;
    }
}

#[cfg(unix)]
fn docker_safe_container_id(container_id: &str) -> Result<&str> {
    let trimmed = container_id.trim();
    if trimmed.is_empty()
        || !trimmed
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-' || byte == b'_')
    {
        anyhow::bail!("Docker container id is invalid: {container_id:?}");
    }

    Ok(trimmed)
}

#[cfg(unix)]
fn identity_from_cri(
    container: &Container,
    container_status: &ContainerStatusResponse,
    sandbox_status: Option<&PodSandboxStatusResponse>,
    runtime_source: RuntimeSource,
) -> Option<WorkloadIdentity> {
    let status = container_status.status.as_ref();
    let sandbox = sandbox_status.and_then(|response| response.status.as_ref());
    let container_metadata = status
        .and_then(|status| status.metadata.as_ref())
        .or(container.metadata.as_ref());
    let container_image = status
        .and_then(|status| status.image.as_ref())
        .or(container.image.as_ref());
    let sandbox_metadata = sandbox.and_then(|sandbox| sandbox.metadata.as_ref());

    Some(WorkloadIdentity {
        pod_sandbox_id: (!container.pod_sandbox_id.is_empty())
            .then(|| container.pod_sandbox_id.clone()),
        pod_name: sandbox_metadata.and_then(|metadata| non_empty_string(&metadata.name)),
        pod_namespace: sandbox_metadata.and_then(|metadata| non_empty_string(&metadata.namespace)),
        pod_uid: sandbox_metadata.and_then(|metadata| non_empty_string(&metadata.uid)),
        container_id: non_empty_string(&container.id),
        container_name: container_metadata.and_then(|metadata| non_empty_string(&metadata.name)),
        image: container_image.and_then(|image| non_empty_string(&image.image)),
        image_ref: status
            .and_then(|status| non_empty_string(&status.image_ref))
            .or_else(|| non_empty_string(&container.image_ref)),
        runtime_pid: runtime_pid_from_info(&container_status.info),
        cgroup_path: cgroup_path_from_info(&container_status.info)
            .or_else(|| sandbox_status.and_then(|status| cgroup_path_from_info(&status.info))),
        labels: merge_maps(
            sandbox.map(|sandbox| &sandbox.labels),
            status
                .map(|status| &status.labels)
                .or(Some(&container.labels)),
        ),
        annotations: merge_maps(
            sandbox.map(|sandbox| &sandbox.annotations),
            status
                .map(|status| &status.annotations)
                .or(Some(&container.annotations)),
        ),
        runtime_source,
        confidence: MetadataConfidence::High,
        degradation_reason: None,
    })
}

fn non_empty_string(value: &str) -> Option<String> {
    (!value.is_empty()).then(|| value.to_string())
}

#[cfg(unix)]
fn merge_maps(
    first: Option<&std::collections::HashMap<String, String>>,
    second: Option<&std::collections::HashMap<String, String>>,
) -> BTreeMap<String, String> {
    let mut merged = BTreeMap::new();

    if let Some(values) = first {
        merged.extend(
            values
                .iter()
                .map(|(key, value)| (key.clone(), value.clone())),
        );
    }

    if let Some(values) = second {
        merged.extend(
            values
                .iter()
                .map(|(key, value)| (key.clone(), value.clone())),
        );
    }

    merged
}

#[cfg(unix)]
fn runtime_pid_from_info(info: &std::collections::HashMap<String, String>) -> Option<u32> {
    find_json_u64(info, &["pid", "Pid"]).and_then(|pid| u32::try_from(pid).ok())
}

#[cfg(unix)]
fn cgroup_path_from_info(info: &std::collections::HashMap<String, String>) -> Option<String> {
    find_json_string(
        info,
        &[
            "cgroupsPath",
            "cgroups_path",
            "cgroupPath",
            "cgroup_path",
            "cgroup",
        ],
    )
}

#[cfg(unix)]
fn find_json_u64(info: &std::collections::HashMap<String, String>, keys: &[&str]) -> Option<u64> {
    info.values()
        .filter_map(|value| serde_json::from_str::<Value>(value).ok())
        .find_map(|value| find_u64_in_json(&value, keys))
}

#[cfg(unix)]
fn find_json_string(
    info: &std::collections::HashMap<String, String>,
    keys: &[&str],
) -> Option<String> {
    info.values()
        .filter_map(|value| serde_json::from_str::<Value>(value).ok())
        .find_map(|value| find_string_in_json(&value, keys))
}

#[cfg(unix)]
fn find_u64_in_json(value: &Value, keys: &[&str]) -> Option<u64> {
    match value {
        Value::Object(map) => {
            for key in keys {
                if let Some(value) = map.get(*key).and_then(Value::as_u64) {
                    return Some(value);
                }
            }

            map.values().find_map(|value| find_u64_in_json(value, keys))
        }
        Value::Array(values) => values
            .iter()
            .find_map(|value| find_u64_in_json(value, keys)),
        _ => None,
    }
}

#[cfg(unix)]
fn find_string_in_json(value: &Value, keys: &[&str]) -> Option<String> {
    match value {
        Value::Object(map) => {
            for key in keys {
                if let Some(value) = map
                    .get(*key)
                    .and_then(Value::as_str)
                    .filter(|value| !value.is_empty())
                {
                    return Some(value.to_string());
                }
            }

            map.values()
                .find_map(|value| find_string_in_json(value, keys))
        }
        Value::Array(values) => values
            .iter()
            .find_map(|value| find_string_in_json(value, keys)),
        _ => None,
    }
}

#[cfg(unix)]
fn is_socket(path: &Path) -> bool {
    fs::metadata(path)
        .map(|metadata| metadata.file_type().is_socket())
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_socket(path: &Path) -> bool {
    path.exists()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::net::UnixListener};

    #[cfg(unix)]
    use crate::cri::v1::{
        Container, ContainerMetadata, ContainerStatus, ContainerStatusResponse, ImageSpec,
        PodSandboxMetadata, PodSandboxStatus, PodSandboxStatusResponse,
    };

    #[test]
    fn parses_k3s_systemd_cgroup_identity() {
        let identity = parse_cgroup_identity(
            "kubepods-burstable-pod57e67067_89e4_4001_bdd4_8632d39ea02b.slice:cri-containerd:6d393320601b821561e43bd46f658284cb172cf297ecc3d3665be657870d32e2",
        );

        assert_eq!(
            identity.pod_uid.as_deref(),
            Some("57e67067-89e4-4001-bdd4-8632d39ea02b")
        );
        assert_eq!(
            identity.container_id.as_deref(),
            Some("6d393320601b821561e43bd46f658284cb172cf297ecc3d3665be657870d32e2")
        );
        assert_eq!(identity.runtime_source, Some(RuntimeSource::Containerd));
    }

    #[test]
    fn parses_procfs_cgroup_record_with_containerd_scope() {
        let identity = parse_cgroup_identity(
            "0::/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod57e67067_89e4_4001_bdd4_8632d39ea02b.slice/cri-containerd-6d393320601b821561e43bd46f658284cb172cf297ecc3d3665be657870d32e2.scope",
        );

        assert_eq!(
            identity.pod_uid.as_deref(),
            Some("57e67067-89e4-4001-bdd4-8632d39ea02b")
        );
        assert_eq!(
            identity.container_id.as_deref(),
            Some("6d393320601b821561e43bd46f658284cb172cf297ecc3d3665be657870d32e2")
        );
        assert_eq!(identity.runtime_source, Some(RuntimeSource::Containerd));
    }

    #[test]
    fn parses_docker_scope_identity() {
        let identity = parse_cgroup_identity(
            "1:name=systemd:/system.slice/docker-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef.scope",
        );

        assert_eq!(identity.pod_uid, None);
        assert_eq!(
            identity.container_id.as_deref(),
            Some("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        );
        assert_eq!(identity.runtime_source, Some(RuntimeSource::Docker));
    }

    #[test]
    fn discovers_explicit_cri_endpoint() {
        let temp = tempfile::tempdir().unwrap();
        let socket_path = temp.path().join("runtime.sock");
        let _listener = UnixListener::bind(&socket_path).unwrap();

        let endpoint = discover_cri_endpoint(temp.path(), Some(Path::new("runtime.sock"))).unwrap();

        assert_eq!(endpoint.path, PathBuf::from("runtime.sock"));
        assert_eq!(endpoint.source, CriEndpointSource::Explicit);
    }

    #[test]
    fn discovers_cri_endpoint_from_crictl_config() {
        let temp = tempfile::tempdir().unwrap();
        let socket_path = temp.path().join("run/k3s/containerd/containerd.sock");
        fs::create_dir_all(socket_path.parent().unwrap()).unwrap();
        let _listener = UnixListener::bind(&socket_path).unwrap();
        let config_path = temp.path().join("etc/crictl.yaml");
        fs::create_dir_all(config_path.parent().unwrap()).unwrap();
        fs::write(
            &config_path,
            "runtime-endpoint: unix:///run/k3s/containerd/containerd.sock\n",
        )
        .unwrap();

        let endpoint = discover_cri_endpoint(temp.path(), None).unwrap();

        assert_eq!(
            endpoint.path,
            PathBuf::from("/run/k3s/containerd/containerd.sock")
        );
        assert_eq!(
            endpoint.source,
            CriEndpointSource::ConfigFile(PathBuf::from("/etc/crictl.yaml"))
        );
    }

    #[test]
    fn discovers_cri_endpoint_from_common_paths() {
        let temp = tempfile::tempdir().unwrap();
        let socket_path = temp.path().join("run/k3s/containerd/containerd.sock");
        fs::create_dir_all(socket_path.parent().unwrap()).unwrap();
        let _listener = UnixListener::bind(&socket_path).unwrap();

        let endpoint = discover_cri_endpoint(temp.path(), None).unwrap();

        assert_eq!(
            endpoint.path,
            PathBuf::from("/run/k3s/containerd/containerd.sock")
        );
        assert_eq!(endpoint.source, CriEndpointSource::CommonPath);
    }

    #[cfg(unix)]
    #[test]
    fn maps_cri_container_and_sandbox_status_to_workload_identity() {
        let container = Container {
            id: "container-1".to_string(),
            pod_sandbox_id: "sandbox-1".to_string(),
            metadata: Some(ContainerMetadata {
                name: "redis".to_string(),
                attempt: 0,
            }),
            image: Some(ImageSpec {
                image: "redis:7".to_string(),
                annotations: Default::default(),
            }),
            image_ref: "docker.io/library/redis@sha256:abc".to_string(),
            state: 0,
            created_at: 1,
            labels: [("container-label".to_string(), "value".to_string())].into(),
            annotations: Default::default(),
        };
        let mut container_info = std::collections::HashMap::new();
        container_info.insert(
            "info".to_string(),
            r#"{"pid":1234,"runtimeSpec":{"linux":{"cgroupsPath":"kubepods.slice/podabc/cri-containerd-container-1.scope"}}}"#
                .to_string(),
        );
        let container_status = ContainerStatusResponse {
            status: Some(ContainerStatus {
                id: "container-1".to_string(),
                metadata: Some(ContainerMetadata {
                    name: "redis".to_string(),
                    attempt: 0,
                }),
                state: 0,
                created_at: 1,
                started_at: 2,
                finished_at: 0,
                exit_code: 0,
                image: Some(ImageSpec {
                    image: "redis:7".to_string(),
                    annotations: Default::default(),
                }),
                image_ref: "docker.io/library/redis@sha256:abc".to_string(),
                reason: String::new(),
                message: String::new(),
                labels: [("app".to_string(), "redis".to_string())].into(),
                annotations: [("annotation".to_string(), "safe".to_string())].into(),
                mounts: Vec::new(),
                log_path: String::new(),
                resources: None,
            }),
            info: container_info,
        };
        let sandbox_status = PodSandboxStatusResponse {
            status: Some(PodSandboxStatus {
                id: "sandbox-1".to_string(),
                metadata: Some(PodSandboxMetadata {
                    name: "redis-0".to_string(),
                    uid: "57e67067-89e4-4001-bdd4-8632d39ea02b".to_string(),
                    namespace: "demo".to_string(),
                    attempt: 0,
                }),
                state: 0,
                created_at: 1,
                network: None,
                linux: None,
                labels: [("pod-label".to_string(), "value".to_string())].into(),
                annotations: Default::default(),
                runtime_handler: String::new(),
            }),
            info: Default::default(),
        };

        let identity = identity_from_cri(
            &container,
            &container_status,
            Some(&sandbox_status),
            RuntimeSource::Containerd,
        )
        .unwrap();

        assert_eq!(identity.pod_sandbox_id.as_deref(), Some("sandbox-1"));
        assert_eq!(identity.pod_namespace.as_deref(), Some("demo"));
        assert_eq!(identity.pod_name.as_deref(), Some("redis-0"));
        assert_eq!(
            identity.pod_uid.as_deref(),
            Some("57e67067-89e4-4001-bdd4-8632d39ea02b")
        );
        assert_eq!(identity.container_id.as_deref(), Some("container-1"));
        assert_eq!(identity.container_name.as_deref(), Some("redis"));
        assert_eq!(identity.image.as_deref(), Some("redis:7"));
        assert_eq!(
            identity.image_ref.as_deref(),
            Some("docker.io/library/redis@sha256:abc")
        );
        assert_eq!(identity.runtime_pid, Some(1234));
        assert_eq!(
            identity.cgroup_path.as_deref(),
            Some("kubepods.slice/podabc/cri-containerd-container-1.scope")
        );
        assert_eq!(
            identity.labels.get("pod-label").map(String::as_str),
            Some("value")
        );
        assert_eq!(
            identity.labels.get("app").map(String::as_str),
            Some("redis")
        );
        assert_eq!(
            identity.annotations.get("annotation").map(String::as_str),
            Some("safe")
        );
        assert_eq!(identity.runtime_source, RuntimeSource::Containerd);
        assert_eq!(identity.confidence, MetadataConfidence::High);
        assert_eq!(identity.degradation_reason, None);
    }

    #[cfg(unix)]
    #[test]
    fn maps_docker_container_to_workload_identity() {
        let summary = DockerContainerSummary {
            id: "0123456789abcdef".to_string(),
            names: vec!["/compose-web-1".to_string()],
            image: "nginx:alpine".to_string(),
            image_id: "sha256:summary".to_string(),
            labels: [(
                "com.docker.compose.project".to_string(),
                "demo-stack".to_string(),
            )]
            .into(),
        };
        let inspect = DockerContainerInspect {
            id: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".to_string(),
            name: "/compose-web-1".to_string(),
            image_ref: "sha256:inspect".to_string(),
            config: Some(DockerContainerConfig {
                image: "nginx:1.27-alpine".to_string(),
                labels: [
                    (
                        "com.docker.compose.project".to_string(),
                        "demo-stack".to_string(),
                    ),
                    ("com.docker.compose.service".to_string(), "web".to_string()),
                ]
                .into(),
            }),
            state: Some(DockerContainerState { pid: 4242 }),
            host_config: Some(DockerHostConfig {
                cgroup_parent: "/system.slice/docker.scope".to_string(),
            }),
        };

        let identity = identity_from_docker(Some(&summary), &inspect);

        assert_eq!(
            identity.container_id.as_deref(),
            Some("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        );
        assert_eq!(identity.container_name.as_deref(), Some("compose-web-1"));
        assert_eq!(identity.image.as_deref(), Some("nginx:1.27-alpine"));
        assert_eq!(identity.image_ref.as_deref(), Some("sha256:inspect"));
        assert_eq!(identity.runtime_pid, Some(4242));
        assert_eq!(
            identity
                .labels
                .get("com.docker.compose.service")
                .map(String::as_str),
            Some("web")
        );
        assert_eq!(identity.runtime_source, RuntimeSource::Docker);
        assert_eq!(identity.confidence, MetadataConfidence::High);
    }

    #[cfg(unix)]
    #[test]
    fn extracts_runtime_info_from_nested_json_values() {
        let mut info = std::collections::HashMap::new();
        info.insert(
            "runtime".to_string(),
            r#"{"runtimeSpec":{"linux":{"cgroupsPath":"/kubepods.slice/pod.scope"}},"status":{"Pid":4321}}"#
                .to_string(),
        );

        assert_eq!(runtime_pid_from_info(&info), Some(4321));
        assert_eq!(
            cgroup_path_from_info(&info).as_deref(),
            Some("/kubepods.slice/pod.scope")
        );
    }
}
