//! # FTP Regex
//!
//! Regular expressions to parse FTP response

use lazy_regex::{Lazy, Regex};

/// This regex extracts IP and Port details from PASV command response.
/// The regex looks for the pattern (h1,h2,h3,h4,p1,p2).
pub static PASV_PORT_RE: Lazy<Regex> = lazy_regex!(r"\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)");

/// This regex extract the port number from EPSV command response.
/// The regex looks for the pattern (|||port_number|)
pub static EPSV_PORT_RE: Lazy<Regex> = lazy_regex!(r"\(\|\|\|(\d+)\|\)");

/// This regex extracts modification time from MDTM command response.
pub static MDTM_RE: Lazy<Regex> = lazy_regex!(r"\b(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\b");

/// This regex extracts file size from SIZE command response.
pub static SIZE_RE: Lazy<Regex> = lazy_regex!(r"\s+(\d+)\s*$");

#[cfg(test)]
mod test {

    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn should_match_pasv_port() {
        let response = "227 Entering Passive Mode (213,229,112,130,216,4)";
        let caps = PASV_PORT_RE.captures(response).unwrap();
        let (oct1, oct2, oct3, oct4) = (
            caps[1].parse::<u8>().unwrap(),
            caps[2].parse::<u8>().unwrap(),
            caps[3].parse::<u8>().unwrap(),
            caps[4].parse::<u8>().unwrap(),
        );
        let (msb, lsb) = (
            caps[5].parse::<u8>().unwrap(),
            caps[6].parse::<u8>().unwrap(),
        );
        assert_eq!(oct1, 213);
        assert_eq!(oct2, 229);
        assert_eq!(oct3, 112);
        assert_eq!(oct4, 130);
        assert_eq!(msb, 216);
        assert_eq!(lsb, 4);
    }

    #[test]
    fn should_match_epsv_port() {
        let response = "Entering Extended Passive Mode (|||6446|)";
        let caps = EPSV_PORT_RE.captures(response).unwrap();
        let port = caps[1].parse::<u16>().unwrap();
        assert_eq!(port, 6446);
    }

    #[test]
    fn should_match_mdtm() {
        let response = "stocazzo 20230201111632 stocazzo";
        let caps = MDTM_RE.captures(response).unwrap();
        let year = caps[1].parse::<isize>().unwrap();
        let month = caps[2].parse::<isize>().unwrap();
        let day = caps[3].parse::<isize>().unwrap();
        let hour = caps[4].parse::<isize>().unwrap();
        let minute = caps[5].parse::<isize>().unwrap();
        let seconds = caps[6].parse::<isize>().unwrap();
        assert_eq!(year, 2023);
        assert_eq!(month, 2);
        assert_eq!(day, 1);
        assert_eq!(hour, 11);
        assert_eq!(minute, 16);
        assert_eq!(seconds, 32);
    }

    #[test]
    fn should_match_size() {
        let response = " 512 1024 2048";
        let caps = SIZE_RE.captures(response).unwrap();
        let size = caps[1].parse::<usize>().unwrap();
        assert_eq!(size, 2048);
    }
}
