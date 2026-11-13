require "c/pthread"

require "./status"
require "./memory"

lib LibRillJob
  struct Job
    next_job : Job*
    url : UInt8*
    options_json : UInt8*
    json : UInt8*
    error_message : UInt8*
    error_code : UInt8*
    status : Int32
    done : Int32
    mutex : LibC::PthreadMutexT*
    cond : LibC::PthreadCondT*
  end
end

module Rill::CAPI
  alias JobPtr = Pointer(LibRillJob::Job)
end

module Rill::CAPI::Job
  extend self

  def create(url : UInt8*, options_json : UInt8*) : JobPtr
    job = LibC.malloc(sizeof(LibRillJob::Job)).as(JobPtr)
    return JobPtr.null if job.null?

    initialize_fields(job)

    unless initialize_sync(job)
      LibC.free(job)
      return JobPtr.null
    end

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
    LibC.pthread_mutex_lock(job.value.mutex)
    job.value.status = status
    job.value.json = json
    job.value.error_message = error_message
    job.value.error_code = error_code
    job.value.done = 1
    LibC.pthread_cond_signal(job.value.cond)
    LibC.pthread_mutex_unlock(job.value.mutex)
  end

  def wait(
    job : JobPtr,
    json_out : UInt8**,
    error_out : UInt8**,
    error_code_out : UInt8**,
  ) : Int32
    return Status::INVALID_ARGUMENT if job.null?

    LibC.pthread_mutex_lock(job.value.mutex)
    while job.value.done == 0
      LibC.pthread_cond_wait(job.value.cond, job.value.mutex)
    end

    status = job.value.status
    json = job.value.json
    error_message = job.value.error_message
    error_code = job.value.error_code

    job.value.json = null_pointer
    job.value.error_message = null_pointer
    job.value.error_code = null_pointer
    LibC.pthread_mutex_unlock(job.value.mutex)

    json_out.value = json unless json_out.null?
    error_out.value = error_message unless error_out.null?
    error_code_out.value = error_code unless error_code_out.null?

    status
  end

  def free(job : JobPtr) : Nil
    return if job.null?

    Memory.free(job.value.url)
    Memory.free(job.value.options_json)
    Memory.free(job.value.json)
    Memory.free(job.value.error_message)
    Memory.free(job.value.error_code)

    LibC.pthread_cond_destroy(job.value.cond)
    LibC.pthread_mutex_destroy(job.value.mutex)
    LibC.free(job.value.cond)
    LibC.free(job.value.mutex)
    LibC.free(job)
  end

  private def initialize_fields(job : JobPtr) : Nil
    job.value.next_job = JobPtr.null
    job.value.url = null_pointer
    job.value.options_json = null_pointer
    job.value.json = null_pointer
    job.value.error_message = null_pointer
    job.value.error_code = null_pointer
    job.value.status = Status::OK
    job.value.done = 0
    job.value.mutex = Pointer(LibC::PthreadMutexT).null
    job.value.cond = Pointer(LibC::PthreadCondT).null
  end

  private def initialize_sync(job : JobPtr) : Bool
    mutex = LibC.malloc(sizeof(LibC::PthreadMutexT)).as(LibC::PthreadMutexT*)
    return false if mutex.null?

    mutex_status = LibC.pthread_mutex_init(
      mutex,
      Pointer(LibC::PthreadMutexattrT).null,
    )
    if mutex_status != 0
      LibC.free(mutex)
      return false
    end

    cond = LibC.malloc(sizeof(LibC::PthreadCondT)).as(LibC::PthreadCondT*)
    if cond.null?
      LibC.pthread_mutex_destroy(mutex)
      LibC.free(mutex)
      return false
    end

    cond_status = LibC.pthread_cond_init(
      cond,
      Pointer(LibC::PthreadCondattrT).null,
    )
    if cond_status != 0
      LibC.free(cond)
      LibC.pthread_mutex_destroy(mutex)
      LibC.free(mutex)
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
