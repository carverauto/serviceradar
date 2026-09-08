#[derive(Default)]
pub struct IronRdpBackend;

impl RdpBackend for IronRdpBackend {
    fn open(&mut self, request: OpenPayload) -> Result<Box<dyn RdpBackendSession>, BackendError> {
        let Some(grant) = request.credential_grant.as_ref() else {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        };
        if !is_memory_user_grant(grant) {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        }
        let plan = build_nonsecret_connection_plan(&request)?;
        let credential = build_memory_user_credential(grant, &request.actor_id)?;
        if !credential.has_material() {
            return Err(BackendError::Unsupported(MEMORY_USER_REQUIRED));
        }
        let _connector_identity = credential.connector_identity();
        #[cfg(serviceradar_rdp_connector_link_probe)]
        {
            return open_connector_for_experimental(&request, &plan, &credential);
        }

        #[cfg(not(serviceradar_rdp_connector_link_probe))]
        {
            let _ = plan;

            Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
        }
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn prepare_connector_open_for_experimental(
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<(), BackendError> {
    let _verified_tls = build_verified_tls_client_config_for_plan(plan)?;
    let _preflight = build_connector_config_preflight_for_experimental(plan, credential)?;

    Ok(())
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn open_connector_for_experimental(
    request: &OpenPayload,
    plan: &NonSecretConnectionPlan,
    credential: &MemoryUserCredential,
) -> Result<Box<dyn RdpBackendSession>, BackendError> {
    let runtime = connector_runtime_policy_from_request(request)?;

    open_connector_for_experimental_with_runtime(request, plan, credential, runtime)
}
