struct MemoryUserCredential {
    domain: Option<Zeroizing<String>>,
    username: Zeroizing<String>,
    password: RedactedSecret,
}

struct RedactedSecret {
    value: Zeroizing<String>,
}

impl MemoryUserCredential {
    fn has_material(&self) -> bool {
        !self.username.is_empty() && !self.password.value.is_empty()
    }

    fn connector_identity(&self) -> (Option<&str>, &str) {
        (
            self.domain.as_ref().map(|domain| domain.as_str()),
            self.username.as_str(),
        )
    }
}

impl std::fmt::Debug for MemoryUserCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemoryUserCredential")
            .field("domain", &"<redacted>")
            .field("username", &"<redacted>")
            .field("password", &self.password)
            .finish()
    }
}

impl std::fmt::Debug for RedactedSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("<redacted>")
    }
}
