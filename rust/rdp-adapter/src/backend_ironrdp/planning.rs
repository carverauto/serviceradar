fn is_memory_user_grant(grant: &DesktopCredentialGrant) -> bool {
    grant.mode == "memory_user"
        && !grant.username.trim().is_empty()
        && grant
            .password
            .expose()
            .map(|password| !password.is_empty())
            .unwrap_or(false)
}

fn build_nonsecret_connection_plan(
    request: &OpenPayload,
) -> Result<NonSecretConnectionPlan, BackendError> {
    let upstream_host = request.target.upstream.host.trim();
    let tls_server_name = request.target.tls.server_name.trim();
    let effective_tls_server_name = if tls_server_name.is_empty() {
        upstream_host
    } else {
        tls_server_name
    };
    let tls_trust_source = build_tls_trust_source(request)?;
    let upstream_port = u16::try_from(request.target.upstream.port)
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;
    let desktop_width = u16::try_from(request.target.screen.max_width)
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;
    let desktop_height = u16::try_from(request.target.screen.max_height)
        .map_err(|_| BackendError::Unsupported(INVALID_CONNECTION_PLAN))?;

    if upstream_host.is_empty()
        || effective_tls_server_name.is_empty()
        || !tls_server_name_is_valid_dns_name(effective_tls_server_name)
    {
        return Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN));
    }

    Ok(NonSecretConnectionPlan {
        upstream_host: upstream_host.to_owned(),
        upstream_port,
        tls_server_name: effective_tls_server_name.to_owned(),
        tls_trust_source,
        kdc_proxy_url: optional_metadata_value(&request.target.metadata, METADATA_KDC_PROXY_URL),
        kerberos_hostname: optional_metadata_value(
            &request.target.metadata,
            METADATA_KERBEROS_HOSTNAME,
        ),
        desktop_width,
        desktop_height,
    })
}

fn tls_server_name_is_valid_dns_name(name: &str) -> bool {
    if name.parse::<std::net::IpAddr>().is_ok() {
        return true;
    }

    if name.is_empty()
        || name.len() > MAX_DIAL_HOST_LEN
        || name.starts_with('.')
        || name.ends_with('.')
    {
        return false;
    }

    name.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    })
}

fn optional_metadata_value(
    metadata: &std::collections::BTreeMap<String, String>,
    key: &str,
) -> Option<String> {
    metadata
        .get(key)
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn build_tls_trust_source(request: &OpenPayload) -> Result<TlsTrustSource, BackendError> {
    let ca_bundle_id = request.target.tls.ca_bundle_id.trim();
    let ca_bundle_pem = request.target.tls.ca_bundle_pem.trim();

    match request.target.tls.mode.as_str() {
        TLS_MODE_SYSTEM => Ok(TlsTrustSource::SystemRoots),
        TLS_MODE_VERIFY if ca_bundle_id.is_empty() => Ok(TlsTrustSource::SystemRoots),
        TLS_MODE_VERIFY if ca_bundle_pem.is_empty() => {
            Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN))
        }
        TLS_MODE_VERIFY => Ok(TlsTrustSource::RegisteredCaBundle {
            id: ca_bundle_id.to_owned(),
            pem: ca_bundle_pem.to_owned(),
        }),
        TLS_MODE_PINNED_CA if ca_bundle_id.is_empty() || ca_bundle_pem.is_empty() => {
            Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN))
        }
        TLS_MODE_PINNED_CA => Ok(TlsTrustSource::RegisteredCaBundle {
            id: ca_bundle_id.to_owned(),
            pem: ca_bundle_pem.to_owned(),
        }),
        _ => Err(BackendError::Unsupported(INVALID_CONNECTION_PLAN)),
    }
}

fn build_memory_user_credential(
    grant: &DesktopCredentialGrant,
    authenticated_actor_id: &str,
) -> Result<MemoryUserCredential, BackendError> {
    let raw_username = grant.username.trim();
    let password = grant
        .password
        .expose()
        .map_err(|_| BackendError::Unsupported(MEMORY_USER_REQUIRED))?;
    if raw_username.is_empty()
        || password.is_empty()
        || grant.actor_id.trim().is_empty()
        || grant.actor_id != authenticated_actor_id
    {
        return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
    }
    let (domain, username) = split_domain_username(raw_username);
    if username.is_empty() {
        return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
    }

    Ok(MemoryUserCredential {
        domain: domain.map(|value| Zeroizing::new(value.to_owned())),
        username: Zeroizing::new(username.to_owned()),
        password: RedactedSecret {
            value: Zeroizing::new(password.to_owned()),
        },
    })
}

fn split_domain_username(username: &str) -> (Option<&str>, &str) {
    if let Some((domain, login)) = username.split_once('\\') {
        if !domain.is_empty() && !login.is_empty() {
            return (Some(domain), login);
        }
    }

    (None, username)
}
