use std::fmt::Debug;
use std::net::IpAddr;
use std::sync::LazyLock;

use crate::generator::{
    GeneratorAcceptSecurityContext, GeneratorChangePassword, GeneratorInitSecurityContext, YieldPointLocal,
};
use crate::kdc::detect_kdc_url;
use crate::kerberos::client::generators::get_client_principal_realm;
use crate::ntlm::NtlmConfig;
#[allow(unused)]
use crate::utils::is_azure_ad_domain;
use crate::{
    builders, kerberos, ntlm, pku2u, AcceptSecurityContextResult, AcquireCredentialsHandleResult, AuthIdentity,
    CertTrustStatus, ContextNames, ContextSizes, CredentialUse, Credentials, CredentialsBuffers, DecryptionFlags,
    Error, ErrorKind, InitializeSecurityContextResult, Kerberos, KerberosConfig, Ntlm, PackageCapabilities,
    PackageInfo, Pku2u, Result, SecurityBuffer, SecurityBufferRef, SecurityPackageType, SecurityStatus, Sspi, SspiEx,
    SspiImpl, PACKAGE_ID_NONE,
};

pub const PKG_NAME: &str = "Negotiate";

pub static PACKAGE_INFO: LazyLock<PackageInfo> = LazyLock::new(|| PackageInfo {
    capabilities: PackageCapabilities::empty(),
    rpc_id: PACKAGE_ID_NONE,
    max_token_len: 0xbb80, // 48 000 bytes: default maximum token len in Windows
    name: SecurityPackageType::Negotiate,
    comment: String::from("Microsoft Package Negotiator"),
});

pub trait ProtocolConfig: Debug + Send + Sync {
    fn new_instance(&self) -> Result<NegotiatedProtocol>;
    fn box_clone(&self) -> Box<dyn ProtocolConfig>;
}

#[derive(Debug)]
pub struct NegotiateConfig {
    pub protocol_config: Box<dyn ProtocolConfig>,
    pub package_list: Option<String>,
    /// Computer name, or "workstation name", of the client machine performing the authentication attempt
    ///
    /// This is also referred to as the "Source Workstation", i.e.: the name of the computer attempting to logon.
    pub client_computer_name: String,
}

impl NegotiateConfig {
    /// package_list format, "kerberos,ntlm,pku2u"
    pub fn new(
        protocol_config: Box<dyn ProtocolConfig + Send>,
        package_list: Option<String>,
        client_computer_name: String,
    ) -> Self {
        Self {
            protocol_config,
            package_list,
            client_computer_name,
        }
    }

    pub fn from_protocol_config(protocol_config: Box<dyn ProtocolConfig + Send>, client_computer_name: String) -> Self {
        Self {
            protocol_config,
            package_list: None,
            client_computer_name,
        }
    }
}

impl Clone for NegotiateConfig {
    fn clone(&self) -> Self {
        Self {
            protocol_config: self.protocol_config.box_clone(),
            package_list: None,
            client_computer_name: self.client_computer_name.clone(),
        }
    }
}

#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone)]
pub enum NegotiatedProtocol {
    Pku2u(Pku2u),
    Kerberos(Kerberos),
    Ntlm(Ntlm),
}

impl NegotiatedProtocol {
    pub fn protocol_name(&self) -> &str {
        match self {
            NegotiatedProtocol::Pku2u(_) => pku2u::PKG_NAME,
            NegotiatedProtocol::Kerberos(_) => kerberos::PKG_NAME,
            NegotiatedProtocol::Ntlm(_) => ntlm::PKG_NAME,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Negotiate {
    protocol: NegotiatedProtocol,
    package_list: Option<String>,
    auth_identity: Option<CredentialsBuffers>,
    client_computer_name: String,
    is_client: bool,
}

struct PackageListConfig {
    ntlm: bool,
    kerberos: bool,
    pku2u: bool,
}

impl Negotiate {
    pub fn new_client(config: NegotiateConfig) -> Result<Self> {
        let is_client = true;
        let mut protocol = config.protocol_config.new_instance()?;
        if let Some(filtered_protocol) =
            Self::filter_protocol(&protocol, &config.package_list, &config.client_computer_name, is_client)?
        {
            protocol = filtered_protocol;
        }

        Ok(Negotiate {
            protocol,
            package_list: config.package_list,
            auth_identity: None,
            client_computer_name: config.client_computer_name,
            is_client,
        })
    }

    pub fn new_server(config: NegotiateConfig) -> Result<Self> {
        let is_client = false;
        let mut protocol = config.protocol_config.new_instance()?;
        if let Some(filtered_protocol) =
            Self::filter_protocol(&protocol, &config.package_list, &config.client_computer_name, is_client)?
        {
            protocol = filtered_protocol;
        }

        Ok(Negotiate {
            protocol,
            package_list: config.package_list,
            auth_identity: None,
            client_computer_name: config.client_computer_name,
            is_client,
        })
    }

    // negotiates the authorization protocol based on the username and the domain
    // Decision rules:
    // 1) if `self.protocol` is not NTLM then we've already negotiated a suitable protocol. Nothing to do.
    // 2) if the provided domain is Azure AD domain then it'll use Pku2u
    // 3) if the provided username is FQDN and we can resolve KDC then it'll use Kerberos
    // 4) if SSPI_KDC_URL_ENV is set then it'll also use Kerberos
    // 5) in any other cases, it'll use NTLM
    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip(self))]
    fn negotiate_protocol(&mut self, username: &str, domain: &str) -> Result<()> {
        let enabled_packages = Self::parse_package_list_config(&self.package_list);

        if let NegotiatedProtocol::Ntlm(_) = &self.protocol {
            #[cfg(target_os = "windows")]
            if enabled_packages.pku2u && is_azure_ad_domain(domain) {
                use super::pku2u::Pku2uConfig;

                debug!("Negotiate: try Pku2u");

                self.protocol = NegotiatedProtocol::Pku2u(Pku2u::new_client_from_config(
                    Pku2uConfig::default_client_config(self.client_computer_name.clone())?,
                )?);
            }

            if enabled_packages.kerberos {
                if let Some(host) = detect_kdc_url(&get_client_principal_realm(username, domain)) {
                    debug!("Negotiate: try Kerberos");

                    self.protocol = NegotiatedProtocol::Kerberos(Kerberos::new_client_from_config(KerberosConfig {
                        kdc_url: Some(host),
                        client_computer_name: Some(self.client_computer_name.clone()),
                    })?);
                }
            }
        }

        if let Some(filtered_protocol) = Self::filter_protocol(
            &self.protocol,
            &self.package_list,
            &self.client_computer_name,
            self.is_client,
        )? {
            self.protocol = filtered_protocol;
        }

        Ok(())
    }

    fn parse_package_list_config(package_list: &Option<String>) -> PackageListConfig {
        let mut ntlm: bool = true;
        let mut kerberos: bool = true;
        let mut pku2u: bool = true;

        if let Some(package_list) = &package_list {
            for package in package_list.split(',') {
                let (package_name, enabled) = if let Some(package_name) = package.strip_prefix('!') {
                    (package_name.to_lowercase(), false)
                } else {
                    let package_name = package.to_lowercase();
                    (package_name, true)
                };

                match package_name.as_str() {
                    "ntlm" => ntlm = enabled,
                    "kerberos" => kerberos = enabled,
                    "pku2u" => pku2u = enabled,
                    _ => warn!("unexpected package name: {}", &package_name),
                }
            }
        }

        PackageListConfig { ntlm, kerberos, pku2u }
    }

    fn filter_protocol(
        negotiated_protocol: &NegotiatedProtocol,
        package_list: &Option<String>,
        client_computer_name: &str,
        is_client: bool,
    ) -> Result<Option<NegotiatedProtocol>> {
        let mut filtered_protocol = None;
        let PackageListConfig {
            ntlm: is_ntlm,
            kerberos: is_kerberos,
            pku2u: is_pku2u,
        } = Self::parse_package_list_config(package_list);

        match &negotiated_protocol {
            NegotiatedProtocol::Pku2u(pku2u) => {
                if !is_pku2u {
                    let ntlm_config = NtlmConfig::new(pku2u.config().client_hostname.clone());
                    filtered_protocol = Some(NegotiatedProtocol::Ntlm(Ntlm::with_config(ntlm_config)));
                }
            }
            NegotiatedProtocol::Kerberos(kerberos) => {
                if !is_kerberos {
                    let ntlm_config = kerberos
                        .config()
                        .client_computer_name
                        .clone()
                        .map(NtlmConfig::new)
                        .unwrap_or_default();
                    filtered_protocol = Some(NegotiatedProtocol::Ntlm(Ntlm::with_config(ntlm_config)));
                }
            }
            NegotiatedProtocol::Ntlm(_) => {
                if !is_ntlm {
                    let config = KerberosConfig {
                        client_computer_name: Some(client_computer_name.to_owned()),
                        kdc_url: None,
                    };

                    if is_client {
                        let kerberos_client = Kerberos::new_client_from_config(config)?;
                        filtered_protocol = Some(NegotiatedProtocol::Kerberos(kerberos_client));
                    } else {
                        // Aborting because we need an additional data (ServerProperties object) to create the server-side Kerberos instance.
                        error!(
                            ?package_list,
                            "NTLM protocol has been negotiated but it is disabled in package_list."
                        );

                        return Err(Error::new(
                            ErrorKind::InternalError,
                            "NTLM protocol has been negotiated but it is disabled in package_list",
                        ));
                    }
                }
            }
        }

        Ok(filtered_protocol)
    }

    pub fn negotiated_protocol(&self) -> &NegotiatedProtocol {
        &self.protocol
    }

    fn is_protocol_ntlm(&self) -> bool {
        matches!(&self.protocol, NegotiatedProtocol::Ntlm(_))
    }

    fn can_downgrade_ntlm(&self) -> bool {
        let package_list = Self::parse_package_list_config(&self.package_list);
        package_list.ntlm
    }

    fn is_target_name_ip_address(address: &str) -> bool {
        let stripped_address = address.split('/').next_back().unwrap_or(address);
        stripped_address.parse::<IpAddr>().is_ok()
    }

    fn check_target_name_for_ntlm_downgrade(&mut self, target_name: &str) {
        let should_downgrade = Self::is_target_name_ip_address(target_name);
        let can_downgrade = self.can_downgrade_ntlm();

        if can_downgrade && should_downgrade && !self.is_protocol_ntlm() {
            let ntlm_config = NtlmConfig::new(self.client_computer_name.clone());
            self.protocol = NegotiatedProtocol::Ntlm(Ntlm::with_config(ntlm_config));
        }
    }
}

impl SspiEx for Negotiate {
    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn custom_set_auth_identity(&mut self, identity: Self::AuthenticationData) -> Result<()> {
        self.auth_identity = Some(identity.clone().try_into().unwrap());

        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => {
                pku2u.custom_set_auth_identity(identity.auth_identity().ok_or_else(|| {
                    Error::new(
                        ErrorKind::IncompleteCredentials,
                        "Provided credentials are not password-based",
                    )
                })?)
            }
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.custom_set_auth_identity(identity),
            NegotiatedProtocol::Ntlm(ntlm) => {
                ntlm.custom_set_auth_identity(identity.auth_identity().ok_or_else(|| {
                    Error::new(
                        ErrorKind::IncompleteCredentials,
                        "Provided credentials are not password-based",
                    )
                })?)
            }
        }
    }
}

impl Sspi for Negotiate {
    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip(self))]
    fn complete_auth_token(&mut self, token: &mut [SecurityBuffer]) -> Result<SecurityStatus> {
        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => pku2u.complete_auth_token(token),
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.complete_auth_token(token),
            NegotiatedProtocol::Ntlm(ntlm) => ntlm.complete_auth_token(token),
        }
    }

    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn encrypt_message(
        &mut self,
        flags: crate::EncryptionFlags,
        message: &mut [SecurityBufferRef<'_>],
        sequence_number: u32,
    ) -> Result<SecurityStatus> {
        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => pku2u.encrypt_message(flags, message, sequence_number),
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.encrypt_message(flags, message, sequence_number),
            NegotiatedProtocol::Ntlm(ntlm) => ntlm.encrypt_message(flags, message, sequence_number),
        }
    }

    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn decrypt_message(
        &mut self,
        message: &mut [SecurityBufferRef<'_>],
        sequence_number: u32,
    ) -> Result<DecryptionFlags> {
        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => pku2u.decrypt_message(message, sequence_number),
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.decrypt_message(message, sequence_number),
            NegotiatedProtocol::Ntlm(ntlm) => ntlm.decrypt_message(message, sequence_number),
        }
    }

    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn query_context_sizes(&mut self) -> Result<ContextSizes> {
        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => pku2u.query_context_sizes(),
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.query_context_sizes(),
            NegotiatedProtocol::Ntlm(ntlm) => ntlm.query_context_sizes(),
        }
    }

    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn query_context_names(&mut self) -> Result<ContextNames> {
        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => pku2u.query_context_names(),
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.query_context_names(),
            NegotiatedProtocol::Ntlm(ntlm) => ntlm.query_context_names(),
        }
    }

    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn query_context_package_info(&mut self) -> Result<PackageInfo> {
        crate::query_security_package_info(SecurityPackageType::Negotiate)
    }

    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn query_context_negotiation_package(&mut self) -> Result<PackageInfo> {
        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => pku2u.query_context_package_info(),
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.query_context_package_info(),
            NegotiatedProtocol::Ntlm(ntlm) => ntlm.query_context_package_info(),
        }
    }

    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn query_context_cert_trust_status(&mut self) -> Result<CertTrustStatus> {
        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => pku2u.query_context_cert_trust_status(),
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.query_context_cert_trust_status(),
            NegotiatedProtocol::Ntlm(ntlm) => ntlm.query_context_cert_trust_status(),
        }
    }

    #[instrument(fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn query_context_session_key(&self) -> Result<crate::SessionKeys> {
        match &self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => pku2u.query_context_session_key(),
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.query_context_session_key(),
            NegotiatedProtocol::Ntlm(ntlm) => ntlm.query_context_session_key(),
        }
    }

    fn change_password<'a>(
        &'a mut self,
        change_password: builders::ChangePassword<'a>,
    ) -> Result<GeneratorChangePassword<'a>> {
        Ok(GeneratorChangePassword::new(move |mut yield_point| async move {
            self.change_password(&mut yield_point, change_password).await
        }))
    }

    fn make_signature(
        &mut self,
        flags: u32,
        message: &mut [SecurityBufferRef<'_>],
        sequence_number: u32,
    ) -> Result<()> {
        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => pku2u.make_signature(flags, message, sequence_number),
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.make_signature(flags, message, sequence_number),
            NegotiatedProtocol::Ntlm(ntlm) => ntlm.make_signature(flags, message, sequence_number),
        }
    }

    fn verify_signature(&mut self, message: &mut [SecurityBufferRef<'_>], sequence_number: u32) -> Result<u32> {
        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => pku2u.verify_signature(message, sequence_number),
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.verify_signature(message, sequence_number),
            NegotiatedProtocol::Ntlm(ntlm) => ntlm.verify_signature(message, sequence_number),
        }
    }
}

impl SspiImpl for Negotiate {
    type CredentialsHandle = Option<CredentialsBuffers>;
    type AuthenticationData = Credentials;

    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn acquire_credentials_handle_impl(
        &mut self,
        builder: builders::FilledAcquireCredentialsHandle<'_, Self::CredentialsHandle, Self::AuthenticationData>,
    ) -> Result<AcquireCredentialsHandleResult<Self::CredentialsHandle>> {
        if builder.credential_use == CredentialUse::Outbound && builder.auth_data.is_none() {
            return Err(Error::new(
                ErrorKind::NoCredentials,
                "The client must specify the auth data",
            ));
        }

        if let Some(Credentials::AuthIdentity(identity)) = builder.auth_data {
            let account_name = identity.username.account_name();
            let domain_name = identity.username.domain_name().unwrap_or("");
            self.negotiate_protocol(account_name, domain_name)?;
        }

        self.auth_identity = builder
            .auth_data
            .cloned()
            .map(|auth_data| auth_data.try_into())
            .transpose()?;

        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => {
                let auth_identity = if let Some(Credentials::AuthIdentity(identity)) = builder.auth_data {
                    identity
                } else {
                    return Err(Error::new(
                        ErrorKind::NoCredentials,
                        "Auth identity is not provided for the Pku2u",
                    ));
                };
                let new_builder = builder.full_transform(Some(auth_identity));
                new_builder.execute(pku2u)?;
            }
            NegotiatedProtocol::Kerberos(kerberos) => {
                kerberos.acquire_credentials_handle_impl(builder)?;
            }
            NegotiatedProtocol::Ntlm(ntlm) => {
                let auth_identity = if builder.credential_use == CredentialUse::Outbound {
                    if let Some(Credentials::AuthIdentity(identity)) = builder.auth_data {
                        Some(identity)
                    } else {
                        return Err(Error::new(
                            ErrorKind::NoCredentials,
                            "Auth identity is not provided for the Ntlm",
                        ));
                    }
                } else {
                    None
                };
                let new_builder = builder.full_transform(auth_identity);
                new_builder.execute(ntlm)?;
            }
        };

        Ok(AcquireCredentialsHandleResult {
            credentials_handle: self.auth_identity.clone(),
            expiry: None,
        })
    }

    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    fn accept_security_context_impl<'a>(
        &'a mut self,
        builder: builders::FilledAcceptSecurityContext<'a, Self::CredentialsHandle>,
    ) -> Result<GeneratorAcceptSecurityContext<'a>> {
        Ok(GeneratorAcceptSecurityContext::new(move |mut yield_point| async move {
            self.accept_security_context_impl(&mut yield_point, builder).await
        }))
    }

    fn initialize_security_context_impl<'ctx, 'b, 'g>(
        &'ctx mut self,
        builder: &'b mut builders::FilledInitializeSecurityContext<'ctx, Self::CredentialsHandle>,
    ) -> Result<GeneratorInitSecurityContext<'g>>
    where
        'ctx: 'g,
        'b: 'g,
    {
        Ok(GeneratorInitSecurityContext::new(move |mut yield_point| async move {
            self.initialize_security_context_impl(&mut yield_point, builder).await
        }))
    }
}

impl<'a> Negotiate {
    #[instrument(ret, level = "debug", fields(protocol = self.protocol.protocol_name()), skip_all)]
    pub(crate) async fn change_password(
        &'a mut self,
        yield_point: &mut YieldPointLocal,
        change_password: builders::ChangePassword<'a>,
    ) -> Result<()> {
        self.negotiate_protocol(&change_password.account_name, &change_password.domain_name)?;

        match &mut self.protocol {
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.change_password(yield_point, change_password).await,
            _ => Err(Error::new(
                ErrorKind::UnsupportedFunction,
                "cannot change password for this protocol",
            )),
        }
    }

    pub(crate) async fn accept_security_context_impl(
        &mut self,
        yield_point: &mut YieldPointLocal,
        builder: builders::FilledAcceptSecurityContext<'a, <Self as SspiImpl>::CredentialsHandle>,
    ) -> Result<AcceptSecurityContextResult> {
        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => {
                let mut creds_handle = builder
                    .credentials_handle
                    .as_ref()
                    .and_then(|creds| (*creds).clone())
                    .and_then(|creds_handle| creds_handle.auth_identity());
                let new_builder = builder.full_transform(Some(&mut creds_handle));
                pku2u.accept_security_context_impl(yield_point, new_builder).await
            }
            NegotiatedProtocol::Kerberos(kerberos) => kerberos.accept_security_context_impl(yield_point, builder).await,
            NegotiatedProtocol::Ntlm(ntlm) => {
                let mut creds_handle = builder
                    .credentials_handle
                    .as_ref()
                    .and_then(|creds| (*creds).clone())
                    .and_then(|creds_handle| creds_handle.auth_identity());
                let new_builder = builder.full_transform(Some(&mut creds_handle));
                ntlm.accept_security_context_impl(new_builder)
            }
        }
    }

    #[instrument(ret, fields(protocol = self.protocol.protocol_name()), skip_all)]
    pub(crate) async fn initialize_security_context_impl(
        &'a mut self,
        yield_point: &mut YieldPointLocal,
        builder: &'a mut builders::FilledInitializeSecurityContext<'_, <Self as SspiImpl>::CredentialsHandle>,
    ) -> Result<InitializeSecurityContextResult> {
        if let Some(target_name) = &builder.target_name {
            self.check_target_name_for_ntlm_downgrade(target_name);
        }

        if let Some(Some(CredentialsBuffers::AuthIdentity(identity))) = builder.credentials_handle {
            let auth_identity =
                AuthIdentity::try_from(&*identity).map_err(|e| Error::new(ErrorKind::InvalidParameter, e))?;
            let account_name = auth_identity.username.account_name();
            let domain_name = auth_identity.username.domain_name().unwrap_or("");
            self.negotiate_protocol(account_name, domain_name)?;
            self.auth_identity = Some(CredentialsBuffers::AuthIdentity(auth_identity.into()));
        }

        #[cfg(feature = "scard")]
        if let Some(Some(CredentialsBuffers::SmartCard(identity))) = builder.credentials_handle {
            if let NegotiatedProtocol::Ntlm(_) = &self.protocol {
                let username = crate::utils::bytes_to_utf16_string(&identity.username)?;
                let host = detect_kdc_url(&get_client_principal_realm(&username, ""))
                    .ok_or_else(|| Error::new(ErrorKind::NoAuthenticatingAuthority, "can not detect KDC url"))?;
                debug!("Negotiate: try Kerberos");

                let config = KerberosConfig {
                    kdc_url: Some(host),
                    client_computer_name: Some(self.client_computer_name.clone()),
                };

                self.protocol = NegotiatedProtocol::Kerberos(Kerberos::new_client_from_config(config)?);
            }
        }

        if let NegotiatedProtocol::Kerberos(kerberos) = &mut self.protocol {
            match kerberos.initialize_security_context_impl(yield_point, builder).await {
                Result::Err(Error {
                    error_type: ErrorKind::NoCredentials,
                    ..
                }) => {
                    warn!("Negotiate: Fall back to the NTLM");

                    let ntlm_config = kerberos
                        .config()
                        .client_computer_name
                        .clone()
                        .map(NtlmConfig::new)
                        .unwrap_or_default();
                    self.protocol = NegotiatedProtocol::Ntlm(Ntlm::with_auth_identity(
                        self.auth_identity.clone().and_then(|c| c.auth_identity()),
                        ntlm_config,
                    ));
                }
                result => return result,
            };
        }

        match &mut self.protocol {
            NegotiatedProtocol::Pku2u(pku2u) => {
                let mut credentials_handle = self.auth_identity.as_mut().and_then(|c| c.clone().auth_identity());
                let mut transformed_builder = builder.full_transform(Some(&mut credentials_handle));

                pku2u.initialize_security_context_impl(&mut transformed_builder)
            }
            NegotiatedProtocol::Kerberos(kerberos) => {
                kerberos.initialize_security_context_impl(yield_point, builder).await
            }
            NegotiatedProtocol::Ntlm(ntlm) => {
                let mut credentials_handle = self.auth_identity.as_mut().and_then(|c| c.clone().auth_identity());
                let mut transformed_builder = builder.full_transform(Some(&mut credentials_handle));

                ntlm.initialize_security_context_impl(&mut transformed_builder)
            }
        }
    }
}
