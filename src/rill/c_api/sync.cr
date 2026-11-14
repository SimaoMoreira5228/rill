{% if flag?(:windows) %}
  require "c/synchapi"
{% else %}
  require "c/pthread"
{% end %}

require "c/stdlib"

module Rill::CAPI::Sync
  extend self

  {% if flag?(:windows) %}
    alias Mutex = LibC::CRITICAL_SECTION
    alias Cond = LibC::CONDITION_VARIABLE

    def create_mutex : Mutex*
      pointer = LibC.malloc(sizeof(Mutex)).as(Mutex*)
      return Pointer(Mutex).null if pointer.null?

      status = LibC.InitializeCriticalSectionAndSpinCount(pointer, 4000)
      if status == 0
        LibC.free(pointer)
        return Pointer(Mutex).null
      end

      pointer
    end

    def create_cond : Cond*
      pointer = LibC.malloc(sizeof(Cond)).as(Cond*)
      return Pointer(Cond).null if pointer.null?

      LibC.InitializeConditionVariable(pointer)
      pointer
    end

    def destroy_mutex(mutex : Mutex*) : Nil
      LibC.DeleteCriticalSection(mutex)
      LibC.free(mutex)
    end

    def destroy_cond(cond : Cond*) : Nil
      LibC.free(cond)
    end

    def lock(mutex : Mutex*) : Nil
      LibC.EnterCriticalSection(mutex)
    end

    def unlock(mutex : Mutex*) : Nil
      LibC.LeaveCriticalSection(mutex)
    end

    def wait(cond : Cond*, mutex : Mutex*) : Nil
      LibC.SleepConditionVariableCS(cond, mutex, LibC::INFINITE)
    end

    def signal(cond : Cond*) : Nil
      LibC.WakeConditionVariable(cond)
    end

    def broadcast(cond : Cond*) : Nil
      LibC.WakeAllConditionVariable(cond)
    end
  {% else %}
    alias Mutex = LibC::PthreadMutexT
    alias Cond = LibC::PthreadCondT

    def create_mutex : Mutex*
      pointer = LibC.malloc(sizeof(Mutex)).as(Mutex*)
      return Pointer(Mutex).null if pointer.null?

      status = LibC.pthread_mutex_init(pointer, Pointer(LibC::PthreadMutexattrT).null)
      if status != 0
        LibC.free(pointer)
        return Pointer(Mutex).null
      end

      pointer
    end

    def create_cond : Cond*
      pointer = LibC.malloc(sizeof(Cond)).as(Cond*)
      return Pointer(Cond).null if pointer.null?

      status = LibC.pthread_cond_init(pointer, Pointer(LibC::PthreadCondattrT).null)
      if status != 0
        LibC.free(pointer)
        return Pointer(Cond).null
      end

      pointer
    end

    def destroy_mutex(mutex : Mutex*) : Nil
      LibC.pthread_mutex_destroy(mutex)
      LibC.free(mutex)
    end

    def destroy_cond(cond : Cond*) : Nil
      LibC.pthread_cond_destroy(cond)
      LibC.free(cond)
    end

    def lock(mutex : Mutex*) : Nil
      LibC.pthread_mutex_lock(mutex)
    end

    def unlock(mutex : Mutex*) : Nil
      LibC.pthread_mutex_unlock(mutex)
    end

    def wait(cond : Cond*, mutex : Mutex*) : Nil
      LibC.pthread_cond_wait(cond, mutex)
    end

    def signal(cond : Cond*) : Nil
      LibC.pthread_cond_signal(cond)
    end

    def broadcast(cond : Cond*) : Nil
      LibC.pthread_cond_broadcast(cond)
    end
  {% end %}
end
