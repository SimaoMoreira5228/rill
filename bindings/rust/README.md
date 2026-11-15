# rill-media

Safe Rust bindings for [Rill](https://github.com/SimaoMoreira5228/rill), a media extractor and downloader.

The crate wraps the `librill` C ABI. When no library is found, the build script compiles the bundled Crystal source, so `cargo build` works without a separate native build step. That path needs Crystal 1.22 or newer, Meson, and Ninja. The QuickJS-NG source is bundled in the crate.

To reuse an existing build:

```sh
export RILL_LIB_DIR="$PWD/build"
# or: export RILL_LIBRARY="$PWD/build/librill.so"
cargo build
```

On macOS the library is `librill.dylib`; on Windows it is `rill.dll` plus its import library.

Merging separate video and audio uses a `rill-media` helper. Set `RILL_MEDIA_HELPER` to its path, or keep it beside the executable. The npm packages bundle a static helper; the crate does not ship platform binaries.

## Extract

```rust
fn main() -> Result<(), rill_media::Error> {
    rill_media::init(4)?;
    let json = rill_media::extract_json("https://example.com/clip.mp4", None)?;
    println!("{json}");
    rill_media::shutdown()?;
    Ok(())
}
```

## Download

```rust
use std::time::Duration;

fn main() -> Result<(), rill_media::Error> {
    rill_media::init(4)?;

    let download = rill_media::Download::start(
        "https://example.com/clip.mp4",
        "clip.mp4",
        Some(r#"{"overwrite":true}"#),
    )?;

    let progress = download.wait(Duration::from_millis(50))?;
    println!("{:?}", progress.state);

    rill_media::shutdown()?;
    Ok(())
}
```

## Tokio

Enable the `tokio` feature for `extract_json_async` and `Download::wait_async`:

```toml
[dependencies]
rill-media = { version = "2026.11.19", features = ["tokio"] }
```

The raw C declarations stay private. The public API uses opaque download handles and Rust-owned errors.

## License

Apache-2.0. See the repository [LICENSE](https://github.com/SimaoMoreira5228/rill/blob/main/LICENSE).
