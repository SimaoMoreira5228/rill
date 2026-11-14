require "./status"
require "./memory"
require "./sync"

lib LibRillJob
  struct Job
    next_job : Job*
    kind : Int32
    url : UInt8*
    output_path : UInt8*
    options_json : UInt8*
    json : UInt8*
    error_message : UInt8*
    error_code : UInt8*
    status : Int32
    done : Int32
    abandoned : Int32
    download_state : Int32
    downloaded : Int64
    total : Int64
    cancel_requested : Int32
    mutex : Rill::CAPI::Sync::Mutex*
    cond : Rill::CAPI::Sync::Cond*
  end
end

module Rill::CAPI
  alias JobPtr = Pointer(LibRillJob::Job)
end

module Rill::CAPI::Job
  extend self

  def create_extraction(url : UInt8*, options_json : UInt8*) : JobPtr
    job = allocate
    return JobPtr.null if job.null?

    job.value.kind = Rill::CAPI::Kind::EXTRACTION

    if url.null?
      finish(
        job,
        Status::INVALID_ARGUMENT,
        null_pointer,
        Memory.copy_string("URL is null"),
        Memory.copy_string("invalid_argument"),
      )
      return job
    end

    job.value.url = Memory.copy_c_string(url)
    unless options_json.null?
      job.value.options_json = Memory.copy_c_string(options_json)
    end

    if job.value.url.null?
      finish(job, Status::INTERNAL_ERROR, null_pointer, null_pointer, null_pointer)
    end

    job
  end

  def create_download(url : UInt8*, output_path : UInt8*, options_json : UInt8*) : JobPtr
    job = allocate
    return JobPtr.null if job.null?

    job.value.kind = Rill::CAPI::Kind::DOWNLOAD
    job.value.download_state = Rill::CAPI::DownloadState::QUEUED

    if url.null? || output_path.null?
      message = url.null? ? "URL is null" : "output path is null"
      finish_download(
        job,
        Status::INVALID_ARGUMENT,
        Rill::CAPI::DownloadState::FAILED,
        Memory.copy_string(message),
        Memory.copy_string("invalid_argument"),
      )
      return job
    end

    job.value.url = Memory.copy_c_string(url)
    job.value.output_path = Memory.copy_c_string(output_path)
    unless options_json.null?
      job.value.options_json = Memory.copy_c_string(options_json)
    end

    if job.value.url.null? || job.value.output_path.null?
      finish_download(
        job,
        Status::INTERNAL_ERROR,
        Rill::CAPI::DownloadState::FAILED,
        null_pointer,
        null_pointer,
      )
    end

    job
  end

  def done?(job : JobPtr) : Bool
    job.value.done != 0
  end

  def finish(
    job : JobPtr,
    status : Int32,
    json : UInt8*,
    error_message : UInt8*,
    error_code : UInt8*,
  ) : Nil
    Sync.lock(job.value.mutex)
    job.value.status = status
    job.value.json = json
    job.value.error_message = error_message
    job.value.error_code = error_code
    job.value.done = 1
    Sync.signal(job.value.cond)
    abandoned = job.value.abandoned != 0
    Sync.unlock(job.value.mutex)

    release(job) if abandoned
  end

  def finish_download(
    job : JobPtr,
    status : Int32,
    state : Int32,
    error_message : UInt8*,
    error_code : UInt8*,
  ) : Nil
    Sync.lock(job.value.mutex)
    job.value.status = status
    job.value.download_state = state
    job.value.error_message = error_message
    job.value.error_code = error_code
    job.value.done = 1
    Sync.signal(job.value.cond)
    abandoned = job.value.abandoned != 0
    Sync.unlock(job.value.mutex)

    release(job) if abandoned
  end

  def mark_running(job : JobPtr) : Nil
    Sync.lock(job.value.mutex)
    if job.value.done == 0
      job.value.download_state = Rill::CAPI::DownloadState::RUNNING
    end
    Sync.unlock(job.value.mutex)
  end

  def update_progress(job : JobPtr, downloaded : Int64, total : Int64?) : Nil
    Sync.lock(job.value.mutex)
    if job.value.done == 0
      job.value.downloaded = downloaded
      job.value.total = total if total
    end
    Sync.unlock(job.value.mutex)
  end

  def cancel(job : JobPtr) : Int32
    return Status::INVALID_ARGUMENT if job.null?

    Sync.lock(job.value.mutex)
    if job.value.done == 0
      job.value.cancel_requested = 1
    end
    Sync.unlock(job.value.mutex)

    Status::OK
  end

  def poll(
    job : JobPtr,
    state_out : Int32*,
    downloaded_out : Int64*,
    total_out : Int64*,
  ) : Int32
    return Status::INVALID_ARGUMENT if job.null?

    Sync.lock(job.value.mutex)
    state = job.value.download_state
    downloaded = job.value.downloaded
    total = job.value.total
    Sync.unlock(job.value.mutex)

    state_out.value = state unless state_out.null?
    downloaded_out.value = downloaded unless downloaded_out.null?
    total_out.value = total unless total_out.null?

    Status::OK
  end

  def error_message(job : JobPtr) : UInt8*
    return null_pointer if job.null?

    Sync.lock(job.value.mutex)
    pointer = if job.value.error_message.null?
                null_pointer
              else
                Memory.copy_string(String.new(job.value.error_message))
              end
    Sync.unlock(job.value.mutex)

    pointer
  end

  def error_code(job : JobPtr) : UInt8*
    return null_pointer if job.null?

    Sync.lock(job.value.mutex)
    pointer = if job.value.error_code.null?
                null_pointer
              else
                Memory.copy_string(String.new(job.value.error_code))
              end
    Sync.unlock(job.value.mutex)

    pointer
  end

  def wait(
    job : JobPtr,
    json_out : UInt8**,
    error_out : UInt8**,
    error_code_out : UInt8**,
  ) : Int32
    return Status::INVALID_ARGUMENT if job.null?

    Sync.lock(job.value.mutex)
    while job.value.done == 0
      Sync.wait(job.value.cond, job.value.mutex)
    end

    status = job.value.status

    unless json_out.null?
      json_out.value = job.value.json
      job.value.json = null_pointer
    end

    unless error_out.null?
      error_out.value = job.value.error_message
      job.value.error_message = null_pointer
    end

    unless error_code_out.null?
      error_code_out.value = job.value.error_code
      job.value.error_code = null_pointer
    end

    Sync.unlock(job.value.mutex)
    status
  end

  def free(job : JobPtr) : Nil
    return if job.null?

    Sync.lock(job.value.mutex)
    unless job.value.done != 0
      job.value.abandoned = 1
      Sync.unlock(job.value.mutex)
      return
    end
    Sync.unlock(job.value.mutex)

    release(job)
  end

  private def allocate : JobPtr
    job = LibC.malloc(sizeof(LibRillJob::Job)).as(JobPtr)
    return JobPtr.null if job.null?

    initialize_fields(job)

    unless initialize_sync(job)
      LibC.free(job)
      return JobPtr.null
    end

    job
  end

  private def release(job : JobPtr) : Nil
    Memory.free(job.value.url)
    Memory.free(job.value.output_path)
    Memory.free(job.value.options_json)
    Memory.free(job.value.json)
    Memory.free(job.value.error_message)
    Memory.free(job.value.error_code)

    Sync.destroy_cond(job.value.cond)
    Sync.destroy_mutex(job.value.mutex)
    LibC.free(job)
  end

  private def initialize_fields(job : JobPtr) : Nil
    job.value.next_job = JobPtr.null
    job.value.kind = Rill::CAPI::Kind::EXTRACTION
    job.value.url = null_pointer
    job.value.output_path = null_pointer
    job.value.options_json = null_pointer
    job.value.json = null_pointer
    job.value.error_message = null_pointer
    job.value.error_code = null_pointer
    job.value.status = Status::OK
    job.value.done = 0
    job.value.abandoned = 0
    job.value.download_state = Rill::CAPI::DownloadState::QUEUED
    job.value.downloaded = 0_i64
    job.value.total = 0_i64
    job.value.cancel_requested = 0
    job.value.mutex = Pointer(Sync::Mutex).null
    job.value.cond = Pointer(Sync::Cond).null
  end

  private def initialize_sync(job : JobPtr) : Bool
    mutex = Sync.create_mutex
    return false if mutex.null?

    cond = Sync.create_cond
    if cond.null?
      Sync.destroy_mutex(mutex)
      return false
    end

    job.value.mutex = mutex
    job.value.cond = cond
    true
  end

  private def null_pointer : UInt8*
    Pointer(UInt8).null
  end
end
