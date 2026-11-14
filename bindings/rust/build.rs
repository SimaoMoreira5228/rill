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

fn build_from_source(manifest: &Path, _target_os: &str, library_name: &str) {
    let source = manifest.join("src/c_api.cr");
    assert!(
        source.is_file(),
        "librill was not found and src/c_api.cr is missing; set RILL_LIB_DIR or RILL_LIBRARY"
    );

    let meson = env::var("MESON").unwrap_or_else(|_| "meson".to_string());
    let build_dir = manifest.join("build");

    if !build_dir.join("build.ninja").is_file() {
        let status = Command::new(&meson)
            .current_dir(manifest)
            .args(["setup", "build", "--buildtype=release", "-Dmedia=false"])
            .status()
            .expect("failed to run meson; install Meson and Ninja or set RILL_LIB_DIR");

        assert!(status.success(), "meson setup failed");
    }

    let status = Command::new(&meson)
        .current_dir(manifest)
        .args(["compile", "-C", "build", "librill"])
        .status()
        .expect("failed to run meson; install Meson and Ninja or set RILL_LIB_DIR");

    assert!(status.success(), "meson compile failed");

    let library = build_dir.join(library_name);
    assert!(
        library.is_file(),
        "meson did not produce {}",
        library.display()
    );

    link(&build_dir);
}

fn link(directory: &Path) {
    println!("cargo:rustc-link-search=native={}", directory.display());
    println!("cargo:rustc-link-lib=dylib=rill");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", directory.display());
    }
}
