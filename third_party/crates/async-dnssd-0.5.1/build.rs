use std::env::{
	var,
	var_os,
};

fn cfg_arch() -> String {
	var("CARGO_CFG_TARGET_ARCH").expect("couldn't find target architecture")
}

fn cfg_family_is(family: &str) -> bool {
	var_os("CARGO_CFG_TARGET_FAMILY").unwrap() == *family
}

fn cfg_os_is(family: &str) -> bool {
	var_os("CARGO_CFG_TARGET_OS").unwrap() == *family
}

fn find_avahi_compat_dns_sd() {
	// on unix but not darwin link avahi compat
	if cfg_family_is("unix") && !(cfg_os_is("macos") || cfg_os_is("ios")) {
		pkg_config::probe_library("avahi-compat-libdns_sd").unwrap();
	}
}

fn find_windows_dns_sd() {
	if cfg_family_is("windows") {
		let platform = match cfg_arch().as_str() {
			"x86_64" => "x64",
			"x86" => "Win32",
			arch => panic!("unsupported target architecture: {:?}", arch),
		};

		match var("BONJOUR_SDK_HOME") {
			Ok(path) => println!("cargo:rustc-link-search=native={}{sep}Lib{sep}{}", path, platform, sep=std::path::MAIN_SEPARATOR),
			Err(e) => panic!("Can't find Bonjour SDK (download from https://developer.apple.com/opensource/) at BONJOUR_SDK_HOME: {}", e),
		}
		println!("cargo:rustc-link-lib=dnssd");
	}
}

fn main() {
	println!("cargo:rerun-if-changed=build.rs");
	find_avahi_compat_dns_sd();
	find_windows_dns_sd();
}
