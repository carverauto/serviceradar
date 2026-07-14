use super::*;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RedirectHeader {
    pub code: RedirectCode,
    pub gateway_internet_address: [u8; 4],
}

#[cfg(test)]
mod test {
    use crate::icmpv4::{RedirectCode::*, *};
    use alloc::format;

    #[test]
    fn clone_eq() {
        let v = RedirectHeader {
            code: RedirectForNetwork,
            gateway_internet_address: [0; 4],
        };
        assert_eq!(v.clone(), v);
    }

    #[test]
    fn debug() {
        let v = RedirectHeader {
            code: RedirectForNetwork,
            gateway_internet_address: [0; 4],
        };
        assert_eq!(
            format!("{:?}", v),
            format!(
                "RedirectHeader {{ code: {:?}, gateway_internet_address: {:?} }}",
                v.code, v.gateway_internet_address
            )
        );
    }
}
