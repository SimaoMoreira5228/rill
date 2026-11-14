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
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is not set"));
    let source_dir = out_dir.join("source");
    let build_dir = out_dir.join("build");

    if source_dir.exists() {
        std::fs::remove_dir_all(&source_dir).expect("failed to clear the Meson source copy");
    }
    if build_dir.exists() {
        std::fs::remove_dir_all(&build_dir).expect("failed to clear the Meson build directory");
    }

    copy_source_tree(manifest, &source_dir);

    let status = Command::new(&meson)
        .current_dir(&source_dir)
        .arg("setup")
        .arg(&build_dir)
        .args([
            "--buildtype=release",
            "-Dmedia=false",
            "-Dtests=false",
            "--wrap-mode=nodownload",
        ])
        .status()
        .expect("failed to run meson; install Meson and Ninja or set RILL_LIB_DIR");

    assert!(status.success(), "meson setup failed");

    let status = Command::new(&meson)
        .current_dir(&source_dir)
        .arg("compile")
        .arg("-C")
        .arg(&build_dir)
        .arg("librill")
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

fn copy_source_tree(manifest: &Path, destination: &Path) {
    std::fs::create_dir_all(destination).expect("failed to create the Meson source copy");

    for name in ["src", "include", "csrc"] {
        copy_dir(&manifest.join(name), &destination.join(name));
    }
    copy_dir(
        &manifest.join("bindings/cpp"),
        &destination.join("bindings/cpp"),
    );
    copy_dir(
        &manifest.join("subprojects/quickjs-ng"),
        &destination.join("subprojects/quickjs-ng"),
    );

    for name in [
        "meson.build",
        "meson_options.txt",
        "shard.yml",
        "README.md",
        "LICENSE",
        "NOTICE",
        "subprojects/quickjs-ng.wrap",
        "subprojects/ffmpeg.wrap",
    ] {
        let source = manifest.join(name);
        let target = destination.join(name);
        if source.is_file() {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).expect("failed to create a Meson source directory");
            }
            std::fs::copy(&source, &target).expect("failed to copy a Meson source file");
        }
    }
}

fn copy_dir(source: &Path, destination: &Path) {
    if !source.is_dir() {
        return;
    }

    std::fs::create_dir_all(destination).expect("failed to create a Meson source directory");
    for entry in std::fs::read_dir(source).expect("failed to read a Meson source directory") {
        let entry = entry.expect("failed to read a Meson source entry");
        let path = entry.path();
        let target = destination.join(entry.file_name());

        if path.is_dir() {
            copy_dir(&path, &target);
        } else if path.is_file() {
            std::fs::copy(&path, &target).expect("failed to copy a Meson source file");
        }
    }
}

fn link(directory: &Path) {
    println!("cargo:rustc-link-search=native={}", directory.display());
    println!("cargo:rustc-link-lib=dylib=rill");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", directory.display());
    }
}
