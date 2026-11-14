use std::env;
use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=RILL_LIB_DIR");
    println!("cargo:rerun-if-env-changed=RILL_LIBRARY");

    let library_names: &[&str] = if cfg!(target_os = "windows") {
        &["rill.dll", "librill.dll", "rill.lib"]
    } else if cfg!(target_os = "macos") {
        &["librill.dylib"]
    } else {
        &["librill.so"]
    };

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

    if let Ok(manifest) = env::var("CARGO_MANIFEST_DIR") {
        directories.push(PathBuf::from(manifest).join("../../build"));
    }

    directories.push(PathBuf::from("/usr/local/lib"));
    directories.push(PathBuf::from("/usr/lib"));
    directories.push(PathBuf::from("/usr/lib64"));

    for directory in directories {
        if library_names
            .iter()
            .any(|name| directory.join(name).is_file())
        {
            link(&directory);
            return;
        }
    }

    panic!("librill not found; set RILL_LIB_DIR to the directory containing librill.so/dylib/dll");
}

fn link(directory: &Path) {
    println!("cargo:rustc-link-search=native={}", directory.display());
    println!("cargo:rustc-link-lib=dylib=rill");
}
