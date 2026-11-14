use std::env;
use std::fs;
use std::time::Duration;

#[test]
fn smoke() {
    assert_eq!(rill_media::abi_version(), 2);

    rill_media::init(4).expect("init");

    let json = rill_media::extract_json("https://example.com/clip.mp4", None).expect("extract");
    assert!(json.contains("\"title\": \"clip\""));

    let error = rill_media::extract_json("ftp://example.com/page.html", None).expect_err("error");
    assert_eq!(error.kind(), Some("unsupported_url"));

    let url = env::var("RILL_C_API_TEST_URL").ok();
    let slow_url = env::var("RILL_C_API_TEST_SLOW_URL").ok();
    let output = env::var("RILL_C_API_TEST_OUTPUT").ok();
    let cancel_output = env::var("RILL_C_API_TEST_CANCEL_OUTPUT").ok();

    if let (Some(url), Some(output)) = (url, output) {
        let download = rill_media::Download::start(&url, &output, Some("{\"overwrite\":true}"))
            .expect("start");
        let progress = download.wait(Duration::from_millis(50)).expect("wait");

        assert_eq!(progress.state, rill_media::DownloadState::Completed);
        assert!(progress.downloaded > 0);
        assert!(download.error().is_empty());
        assert_eq!(
            fs::read_to_string(&output).expect("output"),
            "c-api-download"
        );

        if let (Some(slow_url), Some(cancel_output)) = (slow_url, cancel_output) {
            let download =
                rill_media::Download::start(&slow_url, &cancel_output, None).expect("start");
            download.cancel().expect("cancel");

            let progress = download.wait(Duration::from_millis(50)).expect("wait");

            assert_eq!(progress.state, rill_media::DownloadState::Cancelled);
            assert!(!download.error().is_empty());
        }
    }

    #[cfg(feature = "tokio")]
    {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        runtime.block_on(async {
            let json =
                rill_media::extract_json_async("https://example.com/clip.mp4".to_string(), None)
                    .await
                    .expect("async extract");
            assert!(json.contains("\"title\": \"clip\""));
        });
    }

    rill_media::shutdown().expect("shutdown");
}
