#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::path::PathBuf;

    use bgpkit_parser::models::BgpElem;
    use bgpkit_parser::BgpkitParser;
    use tempfile::TempDir;

    fn setup_test_dir() -> (TempDir, PathBuf) {
        let temp_dir = TempDir::new().unwrap();
        let temp_path = temp_dir.path().to_path_buf();

        // Do common setup here
        std::fs::create_dir_all(temp_path.join("update-example")).unwrap();

        (temp_dir, temp_path)
    }

    #[test]
    fn test_parser_as_paths_conversion() {
        let (_, temp_path) = setup_test_dir();
        let url = "https://spaces.bgpkit.org/parser/update-example.gz";

        let parser = BgpkitParser::new_cached(url, temp_path.to_str().unwrap())
            .unwrap()
            .add_filter("peer_ip", "185.1.8.50")
            .unwrap()
            .add_filter("type", "a")
            .unwrap();

        let elems = parser.into_elem_iter().collect::<Vec<BgpElem>>();
        assert_eq!(
            vec![200612, 174, 1299, 31027, 198622],
            elems
                .first()
                .unwrap()
                .as_path
                .as_ref()
                .unwrap()
                .to_u32_vec_opt(false)
                .unwrap()
        );
    }

    // Iterate over the file twice
    #[test]
    fn test_record_iter_raw_record_iter_types() {
        let (_, temp_path) = setup_test_dir();
        let url = "https://spaces.bgpkit.org/parser/update-example.gz";

        let mut record_types = HashMap::new();
        let mut raw_record_types = HashMap::new();

        for record in BgpkitParser::new_cached(url, temp_path.to_str().unwrap())
            .unwrap()
            .into_record_iter()
        {
            let entry = record_types
                .entry((
                    record.common_header.entry_type,
                    record.common_header.entry_subtype,
                ))
                .or_insert(0);
            *entry += record.common_header.length;
        }

        for record in BgpkitParser::new_cached(url, temp_path.to_str().unwrap())
            .unwrap()
            .into_raw_record_iter()
        {
            let entry = raw_record_types
                .entry((
                    record.common_header.entry_type,
                    record.common_header.entry_subtype,
                ))
                .or_insert(0);
            *entry += record.common_header.length;
        }

        // Same file -> same records -> same sizes.
        assert_eq!(record_types, raw_record_types);
    }
}
