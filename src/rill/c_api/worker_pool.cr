require "c/pthread"

require "../errors"
require "../extractor_registry"
require "../request_options"
require "./job"
require "./memory"
require "./status"

module Rill::CAPI::WorkerPool
  extend self

  MAX_WORKERS = 64

  @@pool : Pool?

  def start(worker_count : Int32) : Nil
    pool = Pool.new(worker_count)
    @@pool = pool
    pool.start
  end

  def create_job(url : UInt8*, options_json : UInt8*) : JobPtr
    job = Job.create(url, options_json)
    return job if job.null? || Job.done?(job)

    pool = @@pool
    if pool
      pool.submit(job)
    else
      Job.finish(
        job,
        Status::SHUTDOWN,
        Pointer(UInt8).null,
        Pointer(UInt8).null,
        Pointer(UInt8).null,
      )
    end

    job
  end

  def shutdown : Nil
    pool = @@pool
    @@pool = nil
    pool.try(&.shutdown)
  end

  class Pool
    @head : JobPtr
    @tail : JobPtr
    @mutex : LibC::PthreadMutexT*
    @cond : LibC::PthreadCondT*
    @done_cond : LibC::PthreadCondT*

    def initialize(@worker_count : Int32)
      @head = JobPtr.null
      @tail = JobPtr.null
      @shutdown = false
      @running = @worker_count
      @workers = [] of Thread
      @mutex = allocate_mutex
      @cond = allocate_cond
      @done_cond = allocate_cond
    end

    def start : Nil
      @worker_count.times do
        @workers << Thread.new { work }
      end
    end

    def submit(job : JobPtr) : Nil
      lock

      unless @shutdown
        enqueue(job)
        LibC.pthread_cond_signal(@cond)
        unlock
        return
      end

      unlock
      Job.finish(
        job,
        Status::SHUTDOWN,
        Pointer(UInt8).null,
        Pointer(UInt8).null,
        Pointer(UInt8).null,
      )
    end

    def shutdown : Nil
      lock

      unless @shutdown
        @shutdown = true
        LibC.pthread_cond_broadcast(@cond)
        fail_pending
      end

      while @running > 0
        LibC.pthread_cond_wait(@done_cond, @mutex)
      end

      unlock
    end

    private def work : Nil
      loop do
        job = pop
        break if job.null?

        begin
          process(job)
        rescue ex
          finish_error(job, ex)
        end
      end
    ensure
      worker_finished
    end

    private def pop : JobPtr
      lock

      while @head.null? && !@shutdown
        LibC.pthread_cond_wait(@cond, @mutex)
      end

      job = @head
      unless job.null?
        dequeue
      end

      unlock
      job
    end

    private def process(job : JobPtr) : Nil
      options = options_for(job)
      media = ExtractorRegistry.default.extract(String.new(job.value.url), options)
      Job.finish(
        job,
        Status::OK,
        Memory.copy_string(media.to_pretty_json),
        Pointer(UInt8).null,
        Pointer(UInt8).null,
      )
    rescue ex
      finish_error(job, ex)
    end

    private def options_for(job : JobPtr) : RequestOptions
      if job.value.options_json.null?
        RequestOptions.new
      else
        RequestOptions.from_json(String.new(job.value.options_json))
      end
    end

    private def finish_error(job : JobPtr, error : Exception) : Nil
      message = error.message || error.class.name
      Job.finish(
        job,
        status_for(error),
        Pointer(UInt8).null,
        Memory.copy_string(message),
        Memory.copy_string(error_code_for(error)),
      )
    end

    private def status_for(error : Exception) : Int32
      case error
      when Rill::InvalidOptionsError, Rill::InvalidUrlError, ArgumentError
        Status::INVALID_ARGUMENT
      when Rill::Error
        Status::EXTRACTION_ERROR
      else
        Status::INTERNAL_ERROR
      end
    end

    private def error_code_for(error : Exception) : String
      case error
      when Rill::UnsupportedUrlError
        "unsupported_url"
      when Rill::MediaUnavailableError
        "media_unavailable"
      when Rill::InvalidExtractionError
        "invalid_extraction"
      when Rill::HTTPError
        "http_error"
      when Rill::InvalidUrlError
        "invalid_url"
      when Rill::ResponseTooLargeError
        "response_too_large"
      when Rill::TooManyRedirectsError
        "too_many_redirects"
      when Rill::NetworkError
        "network_error"
      when Rill::InvalidOptionsError, ArgumentError
        "invalid_options"
      else
        "internal"
      end
    end

    private def enqueue(job : JobPtr) : Nil
      job.value.next_job = JobPtr.null

      if @tail.null?
        @head = job
      else
        @tail.value.next_job = job
      end

      @tail = job
    end

    private def dequeue : Nil
      job = @head
      return if job.null?

      @head = job.value.next_job
      @tail = JobPtr.null if @head.null?
    end

    private def fail_pending : Nil
      loop do
        job = @head
        break if job.null?

        dequeue

        LibC.pthread_mutex_lock(job.value.mutex)
        job.value.status = Status::SHUTDOWN
        job.value.done = 1
        LibC.pthread_cond_signal(job.value.cond)
        LibC.pthread_mutex_unlock(job.value.mutex)
      end
    end

    private def worker_finished : Nil
      lock
      @running -= 1
      LibC.pthread_cond_broadcast(@done_cond)
      unlock
    end

    private def lock : Nil
      LibC.pthread_mutex_lock(@mutex)
    end

    private def unlock : Nil
      LibC.pthread_mutex_unlock(@mutex)
    end

    private def allocate_mutex : LibC::PthreadMutexT*
      pointer = LibC.malloc(sizeof(LibC::PthreadMutexT)).as(LibC::PthreadMutexT*)
      raise "failed to allocate pthread mutex" if pointer.null?

      status = LibC.pthread_mutex_init(pointer, Pointer(LibC::PthreadMutexattrT).null)
      raise "failed to initialize pthread mutex" unless status == 0

      pointer
    end

    private def allocate_cond : LibC::PthreadCondT*
      pointer = LibC.malloc(sizeof(LibC::PthreadCondT)).as(LibC::PthreadCondT*)
      raise "failed to allocate pthread condition" if pointer.null?

      status = LibC.pthread_cond_init(pointer, Pointer(LibC::PthreadCondattrT).null)
      raise "failed to initialize pthread condition" unless status == 0

      pointer
    end
  end
end
