#pragma once

#include <rill.h>

#include <chrono>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>

namespace rill {

class Error : public std::runtime_error {
public:
  Error(int code, std::string message)
      : std::runtime_error(std::move(message)), code_(code) {}

  int code() const noexcept { return code_; }

private:
  int code_;
};

namespace detail {

struct StringDeleter {
  void operator()(char *value) const noexcept { rill_free_string(value); }
};

using UniqueString = std::unique_ptr<char, StringDeleter>;

inline std::string take_string(char *value) {
  UniqueString owned(value);
  return value ? std::string(value) : std::string();
}

} // namespace detail

enum class DownloadState {
  Queued = RILL_DOWNLOAD_QUEUED,
  Running = RILL_DOWNLOAD_RUNNING,
  Completed = RILL_DOWNLOAD_COMPLETED,
  Failed = RILL_DOWNLOAD_FAILED,
  Cancelled = RILL_DOWNLOAD_CANCELLED,
};

struct DownloadProgress {
  DownloadState state;
  std::int64_t downloaded;
  std::int64_t total;
};

inline int abi_version() { return rill_abi_version(); }

inline void init(std::size_t workers = 0) {
  int status = rill_init(workers);
  if (status != RILL_OK) {
    throw Error(status, "rill_init failed");
  }
}

inline void shutdown() {
  int status = rill_shutdown();
  if (status != RILL_OK) {
    throw Error(status, "rill_shutdown failed");
  }
}

inline std::string extract_json(std::string_view url,
                                std::string_view options_json = {}) {
  std::string url_copy(url);
  std::string options_copy(options_json);

  char *json = nullptr;
  char *error = nullptr;
  char *error_code = nullptr;

  int status = rill_extract_json(
      url_copy.c_str(), options_copy.empty() ? nullptr : options_copy.c_str(),
      &json, &error, &error_code);

  detail::UniqueString owned_json(json);
  detail::UniqueString owned_error(error);
  detail::UniqueString owned_code(error_code);

  if (status != RILL_OK) {
    throw Error(status, error ? std::string(error) : std::string("extraction failed"));
  }

  return json ? std::string(json) : std::string();
}

class Download {
public:
  Download(std::string url, std::string output_path,
           std::string options_json = {}) {
    char *error = nullptr;
    handle_ = rill_download_start(
        url.c_str(), output_path.c_str(),
        options_json.empty() ? nullptr : options_json.c_str(), &error);

    if (handle_ == nullptr) {
      detail::UniqueString owned_error(error);
      throw Error(RILL_ERROR_INTERNAL,
                  error ? std::string(error) : std::string("download start failed"));
    }
  }

  Download(const Download &) = delete;
  Download &operator=(const Download &) = delete;

  Download(Download &&other) noexcept : handle_(std::exchange(other.handle_, nullptr)) {}

  Download &operator=(Download &&other) noexcept {
    if (this != &other) {
      reset();
      handle_ = std::exchange(other.handle_, nullptr);
    }
    return *this;
  }

  ~Download() { reset(); }

  DownloadProgress poll() const {
    int state = RILL_DOWNLOAD_QUEUED;
    std::int64_t downloaded = 0;
    std::int64_t total = 0;

    int status = rill_download_poll(handle_, &state, &downloaded, &total);
    if (status != RILL_OK) {
      throw Error(status, "rill_download_poll failed");
    }

    return {static_cast<DownloadState>(state), downloaded, total};
  }

  void cancel() {
    int status = rill_download_cancel(handle_);
    if (status != RILL_OK) {
      throw Error(status, "rill_download_cancel failed");
    }
  }

  std::string error() const {
    return detail::take_string(rill_download_error(handle_));
  }

  std::string error_code() const {
    return detail::take_string(rill_download_error_code(handle_));
  }

  DownloadProgress wait(std::chrono::milliseconds interval = std::chrono::milliseconds(50)) const {
    while (true) {
      DownloadProgress progress = poll();
      if (progress.state == DownloadState::Completed ||
          progress.state == DownloadState::Failed ||
          progress.state == DownloadState::Cancelled) {
        return progress;
      }

      std::this_thread::sleep_for(interval);
    }
  }

private:
  void reset() noexcept {
    if (handle_ != nullptr) {
      rill_download_free(handle_);
      handle_ = nullptr;
    }
  }

  rill_download *handle_ = nullptr;
};

} // namespace rill
