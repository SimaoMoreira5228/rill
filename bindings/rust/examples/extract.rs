fn main() -> Result<(), rill_media::Error> {
    rill_media::init(4)?;

    let json = rill_media::extract_json("https://example.com/clip.mp4", None)?;
    println!("{json}");

    rill_media::shutdown()?;
    Ok(())
}
