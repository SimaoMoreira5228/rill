require "c/stdlib"

require "./rill"
require "./rill/c_api/job"
require "./rill/c_api/memory"
require "./rill/c_api/status"
require "./rill/c_api/worker_pool"

module Rill::CAPI
  STATE_NEW           = 0
  STATE_INITIALIZING  = 1
  STATE_READY         = 2
  STATE_FAILED        = 3
  STATE_SHUTDOWN      = 4
  STATE_SHUTTING_DOWN = 5

  @@state = Atomic(Int32).new(STATE_NEW)

  def self.initialize(worker_count : LibC::SizeT) : Int32
    count = worker_count.zero? ? 1 : worker_count
    return Status::INVALID_ARGUMENT if count > WorkerPool::MAX_WORKERS

    if @@state.compare_and_set(STATE_NEW, STATE_INITIALIZING).last
      begin
        initialize_runtime
        WorkerPool.start(count.to_i32)
        @@state.set(STATE_READY)
        Status::OK
      rescue
        @@state.set(STATE_FAILED)
        Status::INTERNAL_ERROR
      end
    else
      wait_for_ready
    end
  end

  def self.shutdown : Int32
    loop do
      case @@state.get
      when STATE_NEW
        @@state.set(STATE_SHUTDOWN)
        return Status::OK
      when STATE_SHUTDOWN
        return Status::OK
      when STATE_SHUTTING_DOWN
        Crystal::System::Thread.yield_current
      when STATE_READY
        if @@state.compare_and_set(STATE_READY, STATE_SHUTTING_DOWN).last
          WorkerPool.shutdown
          @@state.set(STATE_SHUTDOWN)
          return Status::OK
        end
      else
        return Status::INTERNAL_ERROR
      end
    end
  end

  def self.extract_json(
    url : UInt8*,
    options_json : UInt8*,
    json_out : UInt8**,
    error_out : UInt8**,
    error_code_out : UInt8**,
  ) : Int32
    if json_out.null? || error_out.null? || error_code_out.null?
      return Status::INVALID_ARGUMENT
    end

    json_out.value = Pointer(UInt8).null
    error_out.value = Pointer(UInt8).null
    error_code_out.value = Pointer(UInt8).null

    job = WorkerPool.create_job(url, options_json)
    if job.null?
      error_out.value = Memory.copy_string("failed to create job")
      error_code_out.value = Memory.copy_string("internal")
      return Status::INTERNAL_ERROR
    end

    status = Job.wait(job, json_out, error_out, error_code_out)
    Job.free(job)
    status
  end

  private def self.wait_for_ready : Int32
    loop do
      case @@state.get
      when STATE_READY
        return Status::OK
      when STATE_FAILED, STATE_SHUTDOWN
        return Status::INTERNAL_ERROR
      when STATE_INITIALIZING
        Crystal::System::Thread.yield_current
      else
        return Status::INTERNAL_ERROR
      end
    end
  end

  private def self.initialize_runtime : Nil
    GC.init
    Crystal.init_runtime

    argv = Pointer(UInt8*).malloc(1)
    argv[0] = "rill".to_unsafe
    LibCrystalMain.__crystal_main(1, argv)
  end
end

fun rill_abi_version : Int32
  Rill::CAPI::ABI_VERSION
end

fun rill_init(worker_count : LibC::SizeT) : Int32
  Rill::CAPI.initialize(worker_count)
end

fun rill_shutdown : Int32
  Rill::CAPI.shutdown
end

fun rill_job_new(url : UInt8*, options_json : UInt8*) : Rill::CAPI::JobPtr
  Rill::CAPI::WorkerPool.create_job(url, options_json)
end

fun rill_job_wait(
  job : Rill::CAPI::JobPtr,
  json_out : UInt8**,
  error_out : UInt8**,
  error_code_out : UInt8**,
) : Int32
  Rill::CAPI::Job.wait(job, json_out, error_out, error_code_out)
end

fun rill_job_free(job : Rill::CAPI::JobPtr) : Void
  Rill::CAPI::Job.free(job)
end

fun rill_extract_json(
  url : UInt8*,
  options_json : UInt8*,
  json_out : UInt8**,
  error_out : UInt8**,
  error_code_out : UInt8**,
) : Int32
  Rill::CAPI.extract_json(url, options_json, json_out, error_out, error_code_out)
end

fun rill_free_string(value : UInt8*) : Void
  Rill::CAPI::Memory.free(value)
end

fun rill_download_start(
  url : UInt8*,
  output_path : UInt8*,
  options_json : UInt8*,
  error_out : UInt8**,
) : Rill::CAPI::JobPtr
  error_out.value = Pointer(UInt8).null unless error_out.null?

  job = Rill::CAPI::WorkerPool.create_download_job(url, output_path, options_json)
  if job.null? && !error_out.null?
    error_out.value = Rill::CAPI::Memory.copy_string("failed to create download job")
  end

  job
end

fun rill_download_poll(
  job : Rill::CAPI::JobPtr,
  state_out : Int32*,
  downloaded_out : Int64*,
  total_out : Int64*,
) : Int32
  Rill::CAPI::Job.poll(job, state_out, downloaded_out, total_out)
end

fun rill_download_error(job : Rill::CAPI::JobPtr) : UInt8*
  Rill::CAPI::Job.error_message(job)
end

fun rill_download_error_code(job : Rill::CAPI::JobPtr) : UInt8*
  Rill::CAPI::Job.error_code(job)
end

fun rill_download_cancel(job : Rill::CAPI::JobPtr) : Int32
  Rill::CAPI::Job.cancel(job)
end

fun rill_download_free(job : Rill::CAPI::JobPtr) : Void
  Rill::CAPI::Job.free(job)
end
