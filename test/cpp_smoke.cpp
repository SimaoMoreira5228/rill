#include "rill.hpp"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <thread>

static void check_file(const char *path) {
  std::ifstream file(path);
  assert(file.good());

  std::string content((std::istreambuf_iterator<char>(file)),
                      std::istreambuf_iterator<char>());
  assert(content == "c-api-download");
}

int main() {
  assert(rill::abi_version() == RILL_ABI_VERSION);
  rill::init(4);

  std::string json = rill::extract_json("https://example.com/clip.mp4");
  assert(json.find("\"title\": \"clip\"") != std::string::npos);

  bool failed = false;
  try {
    rill::extract_json("ftp://example.com/page.html");
  } catch (const rill::Error &error) {
    failed = true;
    assert(error.code() == RILL_ERROR_EXTRACTION);
  }
  assert(failed);

  const char *url = std::getenv("RILL_C_API_TEST_URL");
  const char *slow_url = std::getenv("RILL_C_API_TEST_SLOW_URL");
  const char *output = std::getenv("RILL_C_API_TEST_OUTPUT");
  const char *cancel_output = std::getenv("RILL_C_API_TEST_CANCEL_OUTPUT");

  if (url != nullptr && output != nullptr) {
    rill::Download download(url, output, "{\"overwrite\":true}");
    rill::DownloadProgress progress = download.wait();

    assert(progress.state == rill::DownloadState::Completed);
    assert(progress.downloaded > 0);
    assert(download.error().empty());
    check_file(output);
  }

  if (slow_url != nullptr && cancel_output != nullptr) {
    rill::Download download(slow_url, cancel_output);
    download.cancel();

    rill::DownloadProgress progress = download.wait();
    assert(progress.state == rill::DownloadState::Cancelled);
    assert(!download.error().empty());
  }

  rill::shutdown();
  printf("c++ api smoke: ok\n");
  return 0;
}
