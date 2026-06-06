use std::{
    fs,
    path::{Path, PathBuf},
};

#[cfg(unix)]
use std::os::unix::fs::FileTypeExt;

const COMMON_CRI_ENDPOINTS: &[&str] = &[
    "/run/k3s/containerd/containerd.sock",
    "/run/containerd/containerd.sock",
    "/var/run/containerd/containerd.sock",
    "/var/run/crio/crio.sock",
];

const CRI_CONFIG_FILES: &[&str] = &[
    "/etc/crictl.yaml",
    "/var/lib/rancher/k3s/agent/etc/crictl.yaml",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RuntimeSource {
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

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CgroupIdentity {
    pub pod_uid: Option<String>,
    pub container_id: Option<String>,
    pub runtime_source: Option<RuntimeSource>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CriEndpointSource {
    Explicit,
    ConfigFile(PathBuf),
    CommonPath,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CriEndpoint {
    pub path: PathBuf,
    pub source: CriEndpointSource,
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

        if identity.container_id.is_none() {
            if let Some((runtime, container_id)) = extract_container_id(path) {
                identity.runtime_source = Some(runtime);
                identity.container_id = Some(container_id);
            }
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

fn cgroup_path_from_record(record: &str) -> &str {
    let record = record.trim();
    let mut parts = record.splitn(3, ':');
    let first = parts.next().unwrap_or_default();
    let second = parts.next();
    let third = parts.next();

    if !first.is_empty() && first.bytes().all(|b| b.is_ascii_digit()) {
        if let (Some(_controllers), Some(path)) = (second, third) {
            return path.trim();
        }
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
}
