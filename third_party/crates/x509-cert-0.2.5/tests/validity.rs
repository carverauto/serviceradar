//! Validity tests

use der::{Decode, Encode};
use hex_literal::hex;
use x509_cert::time::Validity;

#[test]
fn decode_validity() {
    // Decode Validity from GoodCACert.crt in NIST's PKITS certificate collection
    // 102  30:     SEQUENCE {
    // 104  13:       UTCTime 01/01/2010 08:30:00 GMT
    // 119  13:       UTCTime 31/12/2030 08:30:00 GMT
    //        :       }
    let val1 = Validity::from_der(
        &hex!("301E170D3130303130313038333030305A170D3330313233313038333030305A")[..],
    )
    .unwrap();

    // Decode Validity from InvalidEEnotAfterDateTest6EE.crt in NIST's PKITS certificate collection
    //  97  30:     SEQUENCE {
    //  99  13:       UTCTime 01/01/2010 08:30:00 GMT
    // 114  13:       UTCTime 01/01/2011 08:30:00 GMT
    //        :       }
    let val2 = Validity::from_der(
        &hex!("301E170D3130303130313038333030305A170D3131303130313038333030305A")[..],
    )
    .unwrap();

    // Compare to values from https://www.epochconverter.com/
    assert_eq!(val1.not_before.to_unix_duration().as_secs(), 1262334600);
    assert_eq!(val1.not_after.to_unix_duration().as_secs(), 1924936200);
    assert_eq!(
        val1.not_before.to_unix_duration().as_millis(),
        1262334600000
    );
    assert_eq!(val1.not_after.to_unix_duration().as_millis(), 1924936200000);

    assert_eq!(val2.not_before.to_unix_duration().as_secs(), 1262334600);
    assert_eq!(val2.not_after.to_unix_duration().as_secs(), 1293870600);
    assert_eq!(
        val2.not_before.to_unix_duration().as_millis(),
        1262334600000
    );
    assert_eq!(val2.not_after.to_unix_duration().as_millis(), 1293870600000);

    assert_ne!(val1, val2);
    assert_eq!(val1, val1);

    // Decode Validity from ValidGeneralizedTimenotAfterDateTest8EE.crt in NIST's PKITS certificate collection
    //  97  32:     SEQUENCE {
    //  99  13:       UTCTime 01/01/2010 08:30:00 GMT
    // 114  15:       GeneralizedTime 01/01/2050 12:01:00 GMT
    //        :       }
    let val3 = Validity::from_der(
        &hex!("3020170D3130303130313038333030305A180F32303530303130313132303130305A")[..],
    )
    .unwrap();
    assert_eq!(val3.not_before.to_unix_duration().as_secs(), 1262334600);
    assert_eq!(val3.not_after.to_unix_duration().as_secs(), 2524651260);
    assert_eq!(
        val3.not_before.to_unix_duration().as_millis(),
        1262334600000
    );
    assert_eq!(val3.not_after.to_unix_duration().as_millis(), 2524651260000);

    assert_ne!(val1, val3);
    assert_eq!(val3, val3);

    // Decode Validity from ValidGeneralizedTimenotBeforeDateTest4EE.crt in NIST's PKITS certificate collection
    //  97  32:     SEQUENCE {
    //  99  15:       GeneralizedTime 01/01/2002 12:01:00 GMT
    // 116  13:       UTCTime 31/12/2030 08:30:00 GMT
    //        :       }
    let val4 = Validity::from_der(
        &hex!("3020180F32303032303130313132303130305A170D3330313233313038333030305A")[..],
    )
    .unwrap();
    assert_eq!(val4.not_before.to_unix_duration().as_secs(), 1009886460);
    assert_eq!(val4.not_after.to_unix_duration().as_secs(), 1924936200);
    assert_eq!(
        val4.not_before.to_unix_duration().as_millis(),
        1009886460000
    );
    assert_eq!(val4.not_after.to_unix_duration().as_millis(), 1924936200000);

    assert_ne!(val4, val3);
    assert_eq!(val4, val4);
}

#[test]
fn encode_validity() {
    // Decode Validity from GoodCACert.crt in NIST's PKITS certificate collection then re-encode
    // 102  30:     SEQUENCE {
    // 104  13:       UTCTime 01/01/2010 08:30:00 GMT
    // 119  13:       UTCTime 31/12/2030 08:30:00 GMT
    //        :       }
    let val1 = Validity::from_der(
        &hex!("301E170D3130303130313038333030305A170D3330313233313038333030305A")[..],
    )
    .unwrap();
    let b1 = val1.to_der().unwrap();
    assert_eq!(
        b1,
        &hex!("301E170D3130303130313038333030305A170D3330313233313038333030305A")[..]
    );

    // Decode Validity from ValidGeneralizedTimenotAfterDateTest8EE.crt in NIST's PKITS certificate collection
    //  97  32:     SEQUENCE {
    //  99  13:       UTCTime 01/01/2010 08:30:00 GMT
    // 114  15:       GeneralizedTime 01/01/2050 12:01:00 GMT
    //        :       }
    let val3 = Validity::from_der(
        &hex!("3020170D3130303130313038333030305A180F32303530303130313132303130305A")[..],
    )
    .unwrap();
    let b3 = val3.to_der().unwrap();
    assert_eq!(
        b3,
        &hex!("3020170D3130303130313038333030305A180F32303530303130313132303130305A")[..]
    );

    // Decode Validity from ValidGeneralizedTimenotBeforeDateTest4EE.crt in NIST's PKITS certificate collection
    //  97  32:     SEQUENCE {
    //  99  15:       GeneralizedTime 01/01/2002 12:01:00 GMT
    // 116  13:       UTCTime 31/12/2030 08:30:00 GMT
    //        :       }
    let val4 = Validity::from_der(
        &hex!("3020180F32303032303130313132303130305A170D3330313233313038333030305A")[..],
    )
    .unwrap();
    let b4 = val4.to_der().unwrap();
    assert_eq!(
        b4,
        &hex!("3020180F32303032303130313132303130305A170D3330313233313038333030305A")[..]
    );
}
