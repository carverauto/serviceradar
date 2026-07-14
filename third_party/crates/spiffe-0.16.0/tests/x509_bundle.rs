#![expect(missing_docs, reason = "integration test")]
#![expect(unused_crate_dependencies, reason = "used in the library target")]

#[cfg(feature = "x509")]
#[expect(
    clippy::tests_outside_test_module,
    reason = "https://github.com/rust-lang/rust-clippy/issues/11024"
)]
mod x509_bundle_tests {
    use spiffe::cert::error::CertificateError;
    use spiffe::{TrustDomain, X509Bundle, X509BundleError};

    #[test]
    fn test_x509_bundle_parse_from_der() {
        let bundle_bytes = include_bytes!("testdata/bundle/x509/bundle.der");

        let trust_domain = TrustDomain::new("domain.test").unwrap();
        let x509_bundle = X509Bundle::parse_from_der(trust_domain.clone(), bundle_bytes).unwrap();

        assert_eq!(x509_bundle.trust_domain(), &trust_domain);
        assert_eq!(x509_bundle.authorities().len(), 2);
    }

    #[test]
    fn test_x509_bundle_parse_from_authorities() {
        let authority1: &[u8] = include_bytes!("testdata/bundle/x509/cert1.der");
        let authority2: &[u8] = include_bytes!("testdata/bundle/x509/cert2.der");

        let x509_authorities = &[authority1, authority2];

        let trust_domain = TrustDomain::new("domain.test").unwrap();
        let x509_bundle =
            X509Bundle::from_x509_authorities(trust_domain.clone(), x509_authorities).unwrap();

        assert_eq!(x509_bundle.trust_domain(), &trust_domain);
        assert_eq!(x509_bundle.authorities().len(), 2);
    }

    #[test]
    fn test_x509_bundle_parse_from_der_corrupted() {
        let bundle_bytes = include_bytes!("testdata/bundle/x509/corrupted");

        let trust_domain = TrustDomain::new("example.org").unwrap();
        let result = X509Bundle::parse_from_der(trust_domain, bundle_bytes);

        assert!(matches!(
            result.unwrap_err(),
            X509BundleError::Certificate(CertificateError::ParseX509Certificate(..))
        ));
    }

    #[test]
    fn test_x509_bundle_from_x509_authorities_corrupted() {
        let bundle_bytes: &[u8] = include_bytes!("testdata/bundle/x509/corrupted");

        let trust_domain = TrustDomain::new("example.org").unwrap();
        let result = X509Bundle::from_x509_authorities(trust_domain, &[bundle_bytes]);

        assert!(matches!(
            result.unwrap_err(),
            X509BundleError::Certificate(CertificateError::ParseX509Certificate(..))
        ));
    }

    #[test]
    #[cfg(feature = "x509")]
    fn test_x509_bundle_authorities_parseable_as_openssl_x509_certs() {
        let bundle_bytes = include_bytes!("testdata/bundle/x509/bundle.der");

        let trust_domain = TrustDomain::new("example.org").unwrap();
        let x509_bundle = X509Bundle::parse_from_der(trust_domain, bundle_bytes).unwrap();

        for cert in x509_bundle.authorities() {
            openssl::x509::X509::from_der(cert.as_ref()).unwrap();
        }
    }

    #[test]
    fn test_x509_bundle_add_authority() {
        let trust_domain = TrustDomain::new("domain.test").unwrap();
        let mut b = X509Bundle::new(trust_domain.clone());

        let authority1: &[u8] = include_bytes!("testdata/bundle/x509/cert1.der");
        b.add_authority(authority1).unwrap();

        assert_eq!(b.trust_domain(), &trust_domain);
        assert_eq!(b.authorities().len(), 1);
    }

    /// Test that X.509 bundles can contain many trust anchors without triggering chain length limits.
    ///
    /// Bundles are collections of trust anchors and may legitimately contain many certificates.
    /// Unlike certificate chains, bundles are not subject to the `MAX_CERT_CHAIN_LENGTH` limit.
    #[test]
    fn test_x509_bundle_can_contain_many_certificates() {
        let cert1: &[u8] = include_bytes!("testdata/bundle/x509/cert1.der");
        let cert2: &[u8] = include_bytes!("testdata/bundle/x509/cert2.der");

        let trust_domain = TrustDomain::new("example.org").unwrap();

        // Build a bundle with many trust anchors (more than MAX_CERT_CHAIN_LENGTH)
        let mut many_certs = Vec::new();
        for _ in 0..20 {
            many_certs.extend_from_slice(cert1);
            many_certs.extend_from_slice(cert2);
        }

        let result = X509Bundle::parse_from_der(trust_domain, &many_certs);
        assert!(
            result.is_ok(),
            "bundle parsing should succeed with many trust anchors (bundles are not chain-limited)"
        );

        let bundle = result.unwrap();
        // Assert bundle contains more than the chain limit to verify it's not bounded
        assert!(
            bundle.authorities().len() > 16,
            "bundle should contain more than MAX_CERT_CHAIN_LENGTH (16) trust anchors"
        );
    }
}
