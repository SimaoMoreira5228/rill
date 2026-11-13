require "path"
require "process"

require "./cancellation"
require "./errors"

module Rill
  class MediaMuxer
    enum Backend
      Auto
      Helper
      System
      Off
    end

    HELPER_NAME = {% if flag?(:win32) %} "rill-media.exe" {% else %} "rill-media" {% end %}

    @backend : Backend
    @helper_path : String?
    @ffmpeg_path : String

    def initialize(
      @backend : Backend = self.class.backend_from_environment,
      @helper_path : String? = nil,
      @ffmpeg_path : String = ENV["RILL_FFMPEG"]? || "ffmpeg",
    )
    end

    def self.backend_from_environment : Backend
      case ENV["RILL_MEDIA_BACKEND"]?.try(&.downcase)
      when "helper"
        Backend::Helper
      when "system"
        Backend::System
      when "off", "none", "disabled"
        Backend::Off
      else
        Backend::Auto
      end
    end

    def self.parse_backend(value : String) : Backend?
      case value.downcase
      when "auto"
        Backend::Auto
      when "helper"
        Backend::Helper
      when "system"
        Backend::System
      when "off", "none", "disabled"
        Backend::Off
      else
        nil
      end
    end

    def merge(
      video : String | Path,
      audio : String | Path,
      output : String | Path,
      overwrite : Bool = false,
      cancellation : Cancellation? = nil,
    ) : Path
      video_path = Path.new(video.to_s)
      audio_path = Path.new(audio.to_s)
      output_path = Path.new(output.to_s)

      validate_paths!(video_path, audio_path, output_path, overwrite)
      backend = resolve_backend
      temporary_path = temporary_output_path(output_path)
      File.delete(temporary_path) if File.exists?(temporary_path)

      begin
        case backend
        when :helper
          run_helper(video_path, audio_path, temporary_path, overwrite, cancellation)
        when :system
          run_system(video_path, audio_path, temporary_path, overwrite, cancellation)
        else
          raise MediaBackendUnavailableError.new("no media backend is available")
        end

        publish(temporary_path, output_path, overwrite)
      ensure
        File.delete(temporary_path) if File.exists?(temporary_path)
      end

      output_path
    end

    private def temporary_output_path(output : Path) : Path
      extension = output.extension
      stem = output.basename.chomp(extension)
      output.parent / "#{stem}.part#{extension}"
    end

    private def publish(temporary : Path, output : Path, overwrite : Bool) : Nil
      if !overwrite && File.exists?(output)
        raise FileExistsError.new(output.to_s)
      end

      begin
        File.rename(temporary, output)
      rescue ex : File::Error
        unless overwrite && File.exists?(output)
          raise ex
        end

        File.delete(output)
        File.rename(temporary, output)
      end
    end

    private def resolve_backend : Symbol
      case @backend
      when .off?
        raise MediaBackendUnavailableError.new("media processing is disabled")
      when .helper?
        unless find_helper
          raise MediaBackendUnavailableError.new("media helper not found: #{HELPER_NAME}")
        end
        :helper
      when .system?
        unless find_ffmpeg
          raise MediaBackendUnavailableError.new("ffmpeg not found: #{@ffmpeg_path}")
        end
        :system
      when .auto?
        if find_helper
          :helper
        elsif find_ffmpeg
          :system
        else
          raise MediaBackendUnavailableError.new("no media helper or ffmpeg was found")
        end
      else
        raise MediaBackendUnavailableError.new("unknown media backend")
      end
    end

    private def validate_paths!(
      video : Path,
      audio : Path,
      output : Path,
      overwrite : Bool,
    ) : Nil
      unless File.file?(video)
        raise MediaMuxError.new("video input not found: #{video}")
      end

      unless File.file?(audio)
        raise MediaMuxError.new("audio input not found: #{audio}")
      end

      if File.directory?(output)
        raise MediaMuxError.new("output is a directory: #{output}")
      end

      if File.exists?(output) && !overwrite
        raise FileExistsError.new(output.to_s)
      end

      expanded_output = output.expand
      if video.expand == expanded_output || audio.expand == expanded_output
        raise MediaMuxError.new("output must differ from the inputs")
      end
    end

    private def run_helper(
      video : Path,
      audio : Path,
      output : Path,
      overwrite : Bool,
      cancellation : Cancellation?,
    ) : Nil
      helper = find_helper.not_nil!
      args = [
        "merge",
        "--video", video.to_s,
        "--audio", audio.to_s,
        "--output", output.to_s,
      ]
      args << "--overwrite" if overwrite

      run_process(helper, args, cancellation, "media helper")
    end

    private def run_system(
      video : Path,
      audio : Path,
      output : Path,
      overwrite : Bool,
      cancellation : Cancellation?,
    ) : Nil
      ffmpeg = find_ffmpeg.not_nil!
      args = [
        "-hide_banner",
        "-loglevel", "error",
        "-nostdin",
        overwrite ? "-y" : "-n",
        "-i", video.to_s,
        "-i", audio.to_s,
        "-map", "0:v:0?",
        "-map", "1:a:0?",
        "-c", "copy",
      ]

      if {".mp4", ".m4v", ".mov"}.includes?(output.extension.downcase)
        args.concat(["-movflags", "+faststart"])
      end

      args << output.to_s
      run_process(ffmpeg, args, cancellation, "ffmpeg")
    end

    private def run_process(
      command : String,
      args : Array(String),
      cancellation : Cancellation?,
      label : String,
    ) : Nil
      error_io = IO::Memory.new
      process = begin
        Process.new(
          command,
          args,
          input: Process::Redirect::Close,
          output: Process::Redirect::Close,
          error: error_io,
        )
      rescue File::NotFoundError
        raise MediaBackendUnavailableError.new("#{label} not found: #{command}")
      end

      status : Process::Status? = nil

      begin
        loop do
          if cancellation.try(&.cancelled?)
            process.terminate unless process.terminated?
            status = process.wait
            raise CancelledError.new
          end

          break if process.terminated?
          sleep 50.milliseconds
        end

        status = process.wait
      ensure
        if status.nil?
          process.terminate unless process.terminated?
          process.wait
        end
      end

      unless status.not_nil!.success?
        message = error_io.to_s.strip
        message = "#{label} exited with status #{status.not_nil!.exit_code}" if message.empty?
        raise MediaMuxError.new(message)
      end
    end

    private def find_helper : String?
      candidates = [] of String

      if value = ENV["RILL_MEDIA_HELPER"]?
        candidates << value
      end

      if value = @helper_path
        candidates << value
      end

      if executable = Process.executable_path
        executable_directory = File.dirname(executable)
        candidates << File.join(executable_directory, HELPER_NAME)
        candidates << File.join(executable_directory, "..", "build", HELPER_NAME)
      end

      candidates << File.join("build", HELPER_NAME)

      candidates.each do |candidate|
        if candidate.includes?('/') || candidate.includes?('\\')
          return candidate if executable_file?(candidate)
        elsif found = find_in_path(candidate)
          return found
        end
      end

      nil
    end

    private def find_ffmpeg : String?
      if @ffmpeg_path.includes?('/') || @ffmpeg_path.includes?('\\')
        return @ffmpeg_path if executable_file?(@ffmpeg_path)
        return nil
      end

      find_in_path(@ffmpeg_path)
    end

    private def executable_file?(path : String) : Bool
      {% if flag?(:win32) %}
        File.file?(path)
      {% else %}
        info = File.info?(path)
        return false unless info && info.file?

        permissions = info.permissions
        permissions.owner_execute? || permissions.group_execute? || permissions.other_execute?
      {% end %}
    rescue File::Error
      false
    end

    private def find_in_path(name : String) : String?
      path = ENV["PATH"]?
      return nil unless path

      separator = {% if flag?(:win32) %} ';' {% else %} ':' {% end %}
      path.split(separator).each do |directory|
        next if directory.empty?

        candidate = File.join(directory, name)
        return candidate if executable_file?(candidate)
      end

      nil
    end
  end
end
