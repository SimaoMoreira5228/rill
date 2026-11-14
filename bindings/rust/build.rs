use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=RILL_LIB_DIR");
    println!("cargo:rerun-if-env-changed=RILL_LIBRARY");
    println!("cargo:rerun-if-env-changed=CRYSTAL");
    println!("cargo:rerun-if-changed=src");

    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let library_name = match target_os.as_str() {
        "windows" => "rill.dll",
        "macos" => "librill.dylib",
        _ => "librill.so",
    };

    let manifest = env::var("CARGO_MANIFEST_DIR").map(PathBuf::from).ok();

    if let Ok(library) = env::var("RILL_LIBRARY") {
        let path = PathBuf::from(library);
        if let Some(parent) = path.parent() {
            link(parent);
            return;
        }
    }

    let mut directories = Vec::new();
    if let Ok(directory) = env::var("RILL_LIB_DIR") {
        directories.push(PathBuf::from(directory));
    }
    if let Some(ref manifest) = manifest {
        directories.push(manifest.join("build"));
    }
    directories.push(PathBuf::from("/usr/local/lib"));
    directories.push(PathBuf::from("/usr/lib"));
    directories.push(PathBuf::from("/usr/lib64"));

    for directory in directories {
        if directory.join(library_name).is_file() {
            link(&directory);
            return;
        }
    }

    let manifest = manifest.expect("CARGO_MANIFEST_DIR is not set");
    build_from_source(&manifest, &target_os, library_name);
}

fn build_from_source(manifest: &Path, target_os: &str, library_name: &str) {
    let source = manifest.join("src/c_api.cr");
    assert!(
        source.is_file(),
        "librill was not found and src/c_api.cr is missing; set RILL_LIB_DIR or RILL_LIBRARY"
    );

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is not set"));
    let library = out_dir.join(library_name);
    let crystal = env::var("CRYSTAL").unwrap_or_else(|_| "crystal".to_string());
    let link_flag = if target_os == "windows" {
        "/DLL"
    } else {
        "-shared"
    };

    let status = Command::new(crystal)
        .current_dir(manifest)
        .args(["build", "--single-module", "--link-flags", link_flag, "-o"])
        .arg(&library)
        .arg(&source)
        .status()
        .expect("failed to run crystal; install Crystal 1.22 or set RILL_LIB_DIR");

    assert!(status.success(), "crystal build failed");
    assert!(
        library.is_file(),
        "crystal did not produce {}",
        library.display()
    );

    link(&out_dir);
}

fn link(directory: &Path) {
    println!("cargo:rustc-link-search=native={}", directory.display());
    println!("cargo:rustc-link-lib=dylib=rill");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", directory.display());
    }
}
