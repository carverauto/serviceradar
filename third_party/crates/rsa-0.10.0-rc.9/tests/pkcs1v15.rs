// simple but prevent regression - see https://github.com/RustCrypto/RSA/issues/329
#[cfg(feature = "encoding")]
#[test]
fn signature_stringify() {
    use pkcs8::DecodePrivateKey;
    use signature::Signer;

    use rsa::pkcs1v15::SigningKey;
    use rsa::RsaPrivateKey;

    let pem = include_str!("examples/pkcs8/rsa2048-priv.pem");
    let private_key = RsaPrivateKey::from_pkcs8_pem(pem).unwrap();
    let signing_key = SigningKey::<sha2::Sha256>::new(private_key);

    let bytes: &[u8] = b"rsa4096"; // HACK - the criterion is that the signature has leading zeros.
    let signature = signing_key.sign(bytes);

    let expected = "029E365B60971D5A499FF5E1C288B954D3A5DCF52482CEE46DB90DC860B725A8D6CA031146FA156E9F17579BE6122FFB11DAC35E59B2193D75F7B31CE1442DDE7F4FF7885AD5D6080266E9A33BB4CEC93FCC2B6B885457A0ABF19E2DAA00876F694B37F535F119925CCCF9A17B90AE6CF39F07D7FEFBEECDF1B344C14B728196DDD154230BADDEDA5A7EFF373F6CD3EF6D41789572A7A068E3A252D3B7D5D706C6170D8CFDB48C8E738A4B3BFEA3E15716805E376EBD99EA09C6E82F3CFA13CEB23CD289E8F95C27F489ADC05AAACE8A9276EE7CED3B7A5C7264F0D34FF18CEDC3E91D667FCF9992A8CFDE8562F65FDDE1E06595C27E0F82063839A358C927B2";
    assert_eq!(format!("{}", signature), expected);
    assert_eq!(format!("{:x}", signature), expected.to_lowercase());
    assert_eq!(format!("{:X}", signature), expected);
    assert_eq!(signature.to_string(), expected);
}

#[cfg(feature = "encoding")]
#[test]
fn signing_key_new_same_as_from() {
    use pkcs1::DecodeRsaPrivateKey;
    use rsa::RsaPrivateKey;
    use signature::{Keypair, Signer, Verifier};

    // randomly generated key, hardcoded for test repeatability
    const PRIV_KEY_PKCS1_PEM: &str = "-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAwQe5brkkpxrwR/5TJ6JXsUyBzYtbEL/w8u8P6NnxQ8sL4KYp
MzzTB6aq1gq7bieYXChg0PIWeTukGaOzZe96KxhT0GbhhYRlukktM/quRrM7nYdm
UmXo7+KWU55kfcNOjWKADL/7qmxn6y/+kPmBg83nHdr1Mq6/pNkeHY/1CeGGECl0
rg7gfEkssHjZw/uKafA271fX9A/q3LcAeWi7iA01PgmP28BrWb7OQoYVY71kFY11
e919VlMh8oXsIV0nXCkYu9dR8Pzq6U4gFASK32fFkKX/djRMljEgss3kR0SWPH7t
m5uXX1wRTJ2mRaZh/BmGweIvYCZ5y0+9ESOD1wIDAQABAoIBAAj3NuGxr8YjNi3h
3jLlE3WkvBKz+lLY13QxLmf+V3pyn+abUSaUGKkuUJkIfpQrOqRtK7IIzIps/r5C
ID8H1IDT7HCtlqQA9kikxXi4mAeoo4g5lcMWAK/Dsn/Hx5sfyzI99PyininYRyth
W02YiS96DNYSKXllLHmXrBJrcVI4FqXAz5s7MezU0XYi+jeaVGEP2bd2cHfQJki/
pLOKBvA5DGT7HbmMV7Z1qg/zcr/4Py+7qAFC5XsbQIILSMTfC45QFgs1lApnUG8H
uIhf5lgZ8m0ouDBb/e1Q04ANtdLLI6EmrR11PwavUmvPvXuedXkv2OvnuAbiJr6g
j0I0VaECgYEAyWf2QZrEoZLzVrInZ+VYtov1+jjgFcxW9lHuCJXtTx8hFla13Bmp
bc8PoxWb+37jPdrOYPW0yv1sk5VeVkxOJbms0Gn8hpyI+0muQZ3jmwlS0A10T6FL
wWECYvrxO8DCaVCQ4V+egLSDb/GMkRgHJF3Dr7g3ep7krXf2eeWILQUCgYEA9VqJ
ijMDKw/KX6swyMe3A1nA0MlLBeseXxrwNIJenwRXCzjG3BH6oHW2MGwH0EV7sSoG
FR6j7LZbp9I9NvRcAYU/s1qiAX3iX3KIsbZYNtEC6tKn/HClaHLZOhyuE8tjshyD
jhK/0rhw7R5VQ1GfJhmuzvwoMFTA0fqZBQpWZCsCgYBA5WO+3dyv50bLT5pM6uR7
5Xs7xinGPFJlCh812wFdNj2WEhiFNCuYu1hhhyv8jHUyUBehvGol4iSjJUUBb5La
qwpZGV2KDlRBDAu/Dt3w7b8mVL9+jQ144QZA2HT0ePbrsk8Mn5/V/tQ/NMjDU8ex
WxkbvLL7qskqb/YWbvRC9QKBgQDUJYvFpmQ36LhozmIpSZ6yU/oHzfWD0Y/6VhWa
oZtlTeBhwJ8aDKWz9vQonFCJQns4bgjCXDMLa4aG7p+lk9a2LdwtndF1Dr8dHrCZ
UPynsUQffTRpb5FmZd/0gnX2gafbixIpV4brkjV6of7BbaL50702Fgw99hqftVp4
ZD7c7wKBgD7uIs6rgpaJzKbf7ejjZSjfLOgHlJhtH6Nejp8KoJRsEQI1ofWyIn7D
eMjIuecwLapPwjY2G0/sUW61bqrxgW10wDJHPNllGsZFanzpb7x5o/7eNhzc4qNf
Rmb665iB5fwpqmbE/hYKIn7asYQE+V0dkgt8M3qvlJJ5JJbCrJx3
-----END RSA PRIVATE KEY-----";

    let priv_key = RsaPrivateKey::from_pkcs1_pem(PRIV_KEY_PKCS1_PEM).unwrap();

    let msg = b"1234";

    let key_via_new = rsa::pkcs1v15::SigningKey::<sha2::Sha256>::new(priv_key.clone());
    let key_via_from = rsa::pkcs1v15::SigningKey::<sha2::Sha256>::from(priv_key.clone());
    let sig_via_new = key_via_new.sign(msg);
    let sig_via_from = key_via_from.sign(msg);
    assert_eq!(sig_via_new, sig_via_from);

    // each verifies the other
    assert!(key_via_new
        .verifying_key()
        .verify(msg, &sig_via_from)
        .is_ok());
    assert!(key_via_from
        .verifying_key()
        .verify(msg, &sig_via_new)
        .is_ok());
}
