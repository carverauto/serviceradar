use der::{
    asn1::{Ia5StringRef, PrintableStringRef},
    Decode, Encode, SliceReader,
};
use hex_literal::hex;
use x509_cert::anchor::{CertPolicies, TrustAnchorChoice};
use x509_cert::ext::pkix::name::GeneralName;

#[test]
fn decode_ta1() {
    // features an ECA cert wrapped in a TrustAnchorInfo that contains a pile of certificate policies
    // in the cert path controls field
    let der_encoded_tac = include_bytes!("examples/eca_policies.ta");
    let der_encoded_cert = include_bytes!("examples/eca.der");

    let mut decoder = SliceReader::new(der_encoded_tac).unwrap();
    let tac = TrustAnchorChoice::decode(&mut decoder).unwrap();
    let reencoded_tac = tac.to_der().unwrap();
    println!("Original : {:02X?}", der_encoded_cert);
    println!("Reencoded: {:02X?}", reencoded_tac);
    assert_eq!(der_encoded_tac, reencoded_tac.as_slice());

    match tac {
        TrustAnchorChoice::TaInfo(tai) => {
            assert_eq!(
                tai.pub_key.algorithm.oid.to_string(),
                "1.2.840.113549.1.1.1"
            );

            assert_eq!(
                &hex!("335BA56F7A55602B814B2614CC79BF4ABA8B32BD"),
                tai.key_id.as_bytes()
            );

            let policy_ids: [&str; 42] = [
                "1.2.36.1.334.1.2.1.2",
                "1.2.840.113549.5.6.1.3.1.12",
                "1.2.840.113549.5.6.1.3.1.18",
                "1.3.6.1.4.1.103.100.1.1.3.1",
                "1.3.6.1.4.1.13948.1.1.1.2",
                "1.3.6.1.4.1.13948.1.1.1.6",
                "1.3.6.1.4.1.1569.10.1.1",
                "1.3.6.1.4.1.1569.10.1.2",
                "1.3.6.1.4.1.16304.3.6.2.12",
                "1.3.6.1.4.1.16304.3.6.2.20",
                "1.3.6.1.4.1.16334.509.2.6",
                "1.3.6.1.4.1.23337.1.1.10",
                "1.3.6.1.4.1.23337.1.1.8",
                "1.3.6.1.4.1.2396.2.1.2",
                "1.3.6.1.4.1.2396.2.1.7",
                "1.3.6.1.4.1.24019.1.1.1.18",
                "1.3.6.1.4.1.24019.1.1.1.19",
                "1.3.6.1.4.1.24019.1.1.1.2",
                "1.3.6.1.4.1.24019.1.1.1.7",
                "1.3.6.1.4.1.73.15.3.1.12",
                "1.3.6.1.4.1.73.15.3.1.5",
                "2.16.528.1.1003.1.2.5.1",
                "2.16.528.1.1003.1.2.5.2",
                "2.16.840.1.101.2.1.11.19",
                "2.16.840.1.101.3.2.1.12.2",
                "2.16.840.1.101.3.2.1.12.3",
                "2.16.840.1.101.3.2.1.3.12",
                "2.16.840.1.101.3.2.1.3.13",
                "2.16.840.1.101.3.2.1.3.16",
                "2.16.840.1.101.3.2.1.3.18",
                "2.16.840.1.101.3.2.1.3.24",
                "2.16.840.1.101.3.2.1.3.4",
                "2.16.840.1.101.3.2.1.3.7",
                "2.16.840.1.101.3.2.1.5.4",
                "2.16.840.1.101.3.2.1.5.5",
                "2.16.840.1.101.3.2.1.6.12",
                "2.16.840.1.101.3.2.1.6.4",
                "2.16.840.1.113733.1.7.23.3.1.18",
                "2.16.840.1.113733.1.7.23.3.1.7",
                "2.16.840.1.114027.200.3.10.7.2",
                "2.16.840.1.114027.200.3.10.7.4",
                "2.16.840.1.114027.200.3.10.7.6",
            ];

            let cert_path = tai.cert_path.as_ref().unwrap();
            let mut counter = 0;
            let exts = cert_path.policy_set.as_ref().unwrap();
            let i = exts.0.iter();
            for ext in i {
                assert_eq!(policy_ids[counter], ext.policy_identifier.to_string());
                counter += 1;
            }

            counter = 0;
            let i = cert_path.ta_name.0.iter();
            for rdn in i {
                let i1 = rdn.0.iter();
                for atav in i1 {
                    if 0 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.6");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "US"
                        );
                    } else if 1 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.10");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "U.S. Government"
                        );
                    } else if 2 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.11");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "ECA"
                        );
                    } else if 3 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.3");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "ECA Root CA 4"
                        );
                    }
                    counter += 1;
                }
            }

            let reencoded_cert = cert_path.certificate.to_der().unwrap();
            assert_eq!(der_encoded_cert, reencoded_cert.as_slice());
        }
        _ => panic!("Unexpected TrustAnchorChoice contents"),
    }
}

#[test]
fn decode_ta2() {
    // features an Entrust cert wrapped in a TrustAnchorInfo that contains an excluded subtree in the
    // name constraint in the cert path controls field
    let der_encoded_tac = include_bytes!("examples/entrust_dnConstraint.ta");
    let der_encoded_cert = include_bytes!("examples/entrust.der");

    let mut decoder = SliceReader::new(der_encoded_tac).unwrap();
    let tac = TrustAnchorChoice::decode(&mut decoder).unwrap();
    let reencoded_tac = tac.to_der().unwrap();
    println!("Original : {:02X?}", der_encoded_cert);
    println!("Reencoded: {:02X?}", reencoded_tac);
    assert_eq!(der_encoded_tac, reencoded_tac.as_slice());

    match tac {
        TrustAnchorChoice::TaInfo(tai) => {
            assert_eq!(
                tai.pub_key.algorithm.oid.to_string(),
                "1.2.840.113549.1.1.1"
            );

            assert_eq!(
                &hex!("1A74551E8A85089F505D3E8A46018A819CF99E1E"),
                tai.key_id.as_bytes()
            );

            let cert_path = tai.cert_path.as_ref().unwrap();

            let mut counter = 0;
            let i = cert_path.ta_name.0.iter();
            for rdn in i {
                let i1 = rdn.0.iter();
                for atav in i1 {
                    if 0 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.6");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "US"
                        );
                    } else if 1 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.10");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "Entrust"
                        );
                    } else if 2 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.11");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "Certification Authorities"
                        );
                    } else if 3 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.11");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "Entrust Managed Services NFI Root CA"
                        );
                    }
                    counter += 1;
                }
            }

            let nc = cert_path.name_constr.as_ref().unwrap();
            counter = 0;
            let gsi = nc.excluded_subtrees.as_ref().unwrap().iter();
            for gs in gsi {
                match &gs.base {
                    GeneralName::DirectoryName(dn) => {
                        let i = dn.0.iter();
                        for rdn in i {
                            let i1 = rdn.0.iter();
                            for atav in i1 {
                                if 0 == counter {
                                    assert_eq!(atav.oid.to_string(), "2.5.4.6");
                                    assert_eq!(
                                        PrintableStringRef::try_from(&atav.value)
                                            .unwrap()
                                            .to_string(),
                                        "US"
                                    );
                                } else if 1 == counter {
                                    assert_eq!(atav.oid.to_string(), "2.5.4.10");
                                    assert_eq!(
                                        PrintableStringRef::try_from(&atav.value)
                                            .unwrap()
                                            .to_string(),
                                        "U.S. Government"
                                    );
                                } else if 2 == counter {
                                    assert_eq!(atav.oid.to_string(), "2.5.4.11");
                                    assert_eq!(
                                        PrintableStringRef::try_from(&atav.value)
                                            .unwrap()
                                            .to_string(),
                                        "DoD"
                                    );
                                }
                                counter += 1;
                            }
                        }
                    }
                    _ => panic!("Unexpected GeneralSubtree type"),
                }
            }

            let reencoded_cert = cert_path.certificate.to_der().unwrap();
            assert_eq!(der_encoded_cert, reencoded_cert.as_slice());
        }
        _ => panic!("Unexpected TrustAnchorChoice contents"),
    }
}

#[test]
fn decode_ta3() {
    // features an Exostar cert wrapped in a TrustAnchorInfo that contains an excluded subtree in the
    // name constraint and policy flags in the cert path controls field
    let der_encoded_tac = include_bytes!("examples/exostar_policyFlags.ta");
    let der_encoded_cert = include_bytes!("examples/exostar.der");

    let mut decoder = SliceReader::new(der_encoded_tac).unwrap();
    let tac = TrustAnchorChoice::decode(&mut decoder).unwrap();
    let reencoded_tac = tac.to_der().unwrap();
    println!("Original : {:02X?}", der_encoded_cert);
    println!("Reencoded: {:02X?}", reencoded_tac);
    assert_eq!(der_encoded_tac, reencoded_tac.as_slice());

    match tac {
        TrustAnchorChoice::TaInfo(tai) => {
            assert_eq!(
                tai.pub_key.algorithm.oid.to_string(),
                "1.2.840.113549.1.1.1"
            );

            assert_eq!(
                &hex!("2EBE91A6776A373CF5FD1DB6DD78C9A6E5F42220"),
                tai.key_id.as_bytes()
            );

            let cert_path = tai.cert_path.as_ref().unwrap();

            assert_eq!(
                CertPolicies::InhibitPolicyMapping
                    | CertPolicies::RequireExplicitPolicy
                    | CertPolicies::InhibitAnyPolicy,
                cert_path.policy_flags.unwrap()
            );

            let mut counter = 0;
            let i = cert_path.ta_name.0.iter();
            for rdn in i {
                let i1 = rdn.0.iter();
                for atav in i1 {
                    if 0 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.6");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "US"
                        );
                    } else if 1 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.10");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "Exostar LLC"
                        );
                    } else if 2 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.11");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "Certification Authorities"
                        );
                    } else if 3 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.3");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "Exostar Federated Identity Service Root CA 1"
                        );
                    }
                    counter += 1;
                }
            }

            let nc = cert_path.name_constr.as_ref().unwrap();
            counter = 0;
            let gsi = nc.excluded_subtrees.as_ref().unwrap().iter();
            for gs in gsi {
                match &gs.base {
                    GeneralName::DirectoryName(dn) => {
                        let i = dn.0.iter();
                        for rdn in i {
                            let i1 = rdn.0.iter();
                            for atav in i1 {
                                if 0 == counter {
                                    assert_eq!(atav.oid.to_string(), "2.5.4.6");
                                    assert_eq!(
                                        PrintableStringRef::try_from(&atav.value)
                                            .unwrap()
                                            .to_string(),
                                        "US"
                                    );
                                } else if 1 == counter {
                                    assert_eq!(atav.oid.to_string(), "2.5.4.10");
                                    assert_eq!(
                                        PrintableStringRef::try_from(&atav.value)
                                            .unwrap()
                                            .to_string(),
                                        "U.S. Government"
                                    );
                                } else if 2 == counter {
                                    assert_eq!(atav.oid.to_string(), "2.5.4.11");
                                    assert_eq!(
                                        PrintableStringRef::try_from(&atav.value)
                                            .unwrap()
                                            .to_string(),
                                        "DoD"
                                    );
                                }
                                counter += 1;
                            }
                        }
                    }
                    _ => panic!("Unexpected GeneralSubtree type"),
                }
            }

            let reencoded_cert = cert_path.certificate.to_der().unwrap();
            assert_eq!(der_encoded_cert, reencoded_cert.as_slice());
        }
        _ => panic!("Unexpected TrustAnchorChoice contents"),
    }
}

#[test]
fn decode_ta4() {
    // features an Exostar cert wrapped in a TrustAnchorInfo that contains path length constraint in
    // the cert path controls field
    let der_encoded_tac = include_bytes!("examples/raytheon_pathLenConstraint.ta");
    let der_encoded_cert = include_bytes!("examples/raytheon.der");

    let mut decoder = SliceReader::new(der_encoded_tac).unwrap();
    let tac = TrustAnchorChoice::decode(&mut decoder).unwrap();
    let reencoded_tac = tac.to_der().unwrap();
    println!("Original : {:02X?}", der_encoded_cert);
    println!("Reencoded: {:02X?}", reencoded_tac);
    assert_eq!(der_encoded_tac, reencoded_tac.as_slice());

    match tac {
        TrustAnchorChoice::TaInfo(tai) => {
            assert_eq!(
                tai.pub_key.algorithm.oid.to_string(),
                "1.2.840.113549.1.1.1"
            );

            assert_eq!(
                &hex!("283086D556154210425CF07B1C11B28389D47920"),
                tai.key_id.as_bytes()
            );

            let cert_path = tai.cert_path.as_ref().unwrap();

            let mut counter = 0;
            let i = cert_path.ta_name.0.iter();
            for rdn in i {
                let i1 = rdn.0.iter();
                for atav in i1 {
                    if 0 == counter {
                        assert_eq!(atav.oid.to_string(), "0.9.2342.19200300.100.1.25");
                        assert_eq!(
                            Ia5StringRef::try_from(&atav.value).unwrap().to_string(),
                            "com"
                        );
                    } else if 1 == counter {
                        assert_eq!(atav.oid.to_string(), "0.9.2342.19200300.100.1.25");
                        assert_eq!(
                            Ia5StringRef::try_from(&atav.value).unwrap().to_string(),
                            "raytheon"
                        );
                    } else if 2 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.10");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "CAs"
                        );
                    } else if 3 == counter {
                        assert_eq!(atav.oid.to_string(), "2.5.4.11");
                        assert_eq!(
                            PrintableStringRef::try_from(&atav.value)
                                .unwrap()
                                .to_string(),
                            "RaytheonRoot"
                        );
                    }
                    counter += 1;
                }
            }

            let pl = cert_path.path_len_constraint.unwrap();
            if 2 != pl {
                panic!("Wrong path length constraint");
            }

            let reencoded_cert = cert_path.certificate.to_der().unwrap();
            assert_eq!(der_encoded_cert, reencoded_cert.as_slice());
        }
        _ => panic!("Unexpected TrustAnchorChoice contents"),
    }
}
