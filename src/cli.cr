require "json"
require "option_parser"
require "path"
require "signal"

require "./rill"

module Rill::CLI
  USAGE = <<-TEXT
    Usage: rill <command> [options]

    Commands:
      extract URL    Print media metadata and available formats
      formats URL    Print available formats only
      download URL   Download a media format to a file
      merge VIDEO AUDIO -o OUTPUT
                     Remux separate video and audio files

    Options:
      -j, --json               Print JSON
      -H, --header NAME:VALUE  Add a request header
      -c, --cookie NAME=VALUE  Add a request cookie
      -t, --timeout SECONDS    Set the connect and read timeout
      -u, --user-agent AGENT   Set the request user agent
      -h, --help               Show this help
      -v, --version            Show the version
  TEXT

  def self.run(argv : Array(String)) : Int32
    args = argv.dup
    command = args.shift?

    case command
    when nil, "-h", "--help"
      puts USAGE
      0
    when "-v", "--version"
      puts "rill #{VERSION}"
      0
    when "extract", "formats"
      run_extraction(command, args)
    when "download"
      run_download(args)
    when "merge"
      run_merge(args)
    else
      STDERR.puts "unknown command: #{command}"
      STDERR.puts USAGE
      2
    end
  end

  private def self.run_extraction(command : String, args : Array(String)) : Int32
    options = RequestOptions.new
    json = false
    help = false

    parser = OptionParser.new
    parser.banner = USAGE
    parser.on("-j", "--json", "Print JSON") { json = true }
    add_request_options(parser, options)
    parser.on("-h", "--help", "Show this help") { help = true }

    remaining = args.dup
    parser.parse(remaining)

    if help
      puts parser
      return 0
    end

    if remaining.size != 1
      STDERR.puts "expected exactly one URL"
      STDERR.puts parser
      return 2
    end

    result = Client.new(options).extract(remaining.first)

    if json
      puts command == "formats" ? formats_json(result) : result.to_pretty_json
    else
      case result
      when Playlist
        print_playlist(result)
      when Media
        print_media(result, formats_only: command == "formats")
      end
    end

    0
  rescue ex : OptionParser::Exception
    STDERR.puts ex.message
    STDERR.puts USAGE
    2
  rescue ex : Rill::Error
    STDERR.puts ex.message
    1
  rescue ex : ArgumentError
    STDERR.puts ex.message
    1
  end

  private def self.run_merge(args : Array(String)) : Int32
    output : String? = nil
    force = false
    backend = MediaMuxer.backend_from_environment
    help = false

    parser = OptionParser.new
    parser.banner = USAGE
    parser.on("-o PATH", "--output PATH", "Write to this file") do |value|
      output = value
    end
    parser.on("--force", "Overwrite an existing file") { force = true }
    parser.on("--media-backend MODE", "auto, helper, system, or off") do |value|
      backend = MediaMuxer.parse_backend(value) || raise OptionParser::InvalidOption.new(value)
    end
    parser.on("-h", "--help", "Show this help") { help = true }

    remaining = args.dup
    parser.parse(remaining)

    if help
      puts parser
      return 0
    end

    if remaining.size != 2
      STDERR.puts "expected a video and an audio file"
      STDERR.puts parser
      return 2
    end

    unless output
      STDERR.puts "missing --output"
      return 2
    end

    muxer = MediaMuxer.new(backend)
    path = muxer.merge(remaining[0], remaining[1], output.not_nil!, force)
    puts path
    0
  rescue ex : OptionParser::Exception
    STDERR.puts ex.message
    STDERR.puts USAGE
    2
  rescue ex : Rill::Error
    STDERR.puts ex.message
    1
  rescue ex : ArgumentError
    STDERR.puts ex.message
    1
  end

  private def self.add_request_options(parser : OptionParser, options : RequestOptions) : Nil
    parser.on("-H NAME:VALUE", "Add a request header") do |value|
      add_header(options, value)
    end
    parser.on("-c NAME=VALUE", "Add a request cookie") do |value|
      add_cookie(options, value)
    end
    parser.on("-t SECONDS", "Set the connect and read timeout") do |value|
      seconds = value.to_f?
      unless seconds && seconds > 0
        raise OptionParser::InvalidOption.new(value)
      end

      options.connect_timeout = seconds.seconds
      options.read_timeout = seconds.seconds
    end
    parser.on("-u AGENT", "Set the request user agent") do |value|
      if value.empty?
        raise OptionParser::InvalidOption.new(value)
      end

      options.user_agent = value
    end
    parser.on("--po-token-provider URL", "Fetch YouTube PO tokens from a provider") do |value|
      if value.empty?
        raise OptionParser::InvalidOption.new(value)
      end

      options.po_token_provider = value
    end
  end

  private def self.run_download(args : Array(String)) : Int32
    options = RequestOptions.new
    output : String? = nil
    directory = "."
    directory_given = false
    format_id : String? = nil
    audio_only = false
    video_only = false
    force = false
    resume = true
    playlist_mode = false
    media_backend = MediaMuxer.backend_from_environment
    json = false
    help = false

    parser = OptionParser.new
    parser.banner = USAGE
    parser.on("-o PATH", "--output PATH", "Write to an explicit file path") do |value|
      output = value
    end
    parser.on("-P DIR", "--directory DIR", "Write into this directory") do |value|
      directory = value
      directory_given = true
    end
    parser.on("-f ID", "--format ID", "Use a specific format id") do |value|
      format_id = value
    end
    parser.on("-a", "--audio", "Download the best audio-only format") { audio_only = true }
    parser.on("--video-only", "Download the best video-only format") { video_only = true }
    parser.on("--force", "Overwrite an existing file") { force = true }
    parser.on("--no-resume", "Do not resume an existing part file") { resume = false }
    parser.on("--playlist", "Download every entry in a playlist") { playlist_mode = true }
    parser.on("--media-backend MODE", "auto, helper, system, or off") do |value|
      media_backend = MediaMuxer.parse_backend(value) || raise OptionParser::InvalidOption.new(value)
    end
    parser.on("-j", "--json", "Print JSON") { json = true }
    add_request_options(parser, options)
    parser.on("-h", "--help", "Show this help") { help = true }

    remaining = args.dup
    parser.parse(remaining)

    if help
      puts parser
      return 0
    end

    if remaining.size != 1
      STDERR.puts "expected exactly one URL"
      STDERR.puts parser
      return 2
    end

    if output && directory_given
      STDERR.puts "--output and --directory cannot be combined"
      return 2
    end

    if audio_only && video_only
      STDERR.puts "--audio and --video-only cannot be combined"
      return 2
    end

    if format_id && (audio_only || video_only)
      STDERR.puts "--format cannot be combined with --audio or --video-only"
      return 2
    end

    preference = if audio_only
                   FormatPreference::AudioOnly
                 elsif video_only
                   FormatPreference::VideoOnly
                 else
                   FormatPreference::AudioAndVideo
                 end

    client = Client.new(options)
    result = client.extract(remaining.first)

    if result.is_a?(Playlist)
      unless playlist_mode
        STDERR.puts "URL is a playlist; pass --playlist to download its entries"
        return 1
      end

      if output
        STDERR.puts "--output cannot be used with a playlist"
        return 2
      end

      cancellation = Cancellation.new
      Signal::INT.trap { |_signal| cancellation.cancel! }
      Signal::TERM.trap { |_signal| cancellation.cancel! }

      return download_playlist(
        client,
        result,
        directory,
        format_id,
        resume,
        force,
        media_backend,
        preference,
        cancellation,
      )
    end

    media = result
    media.warnings.each do |warning|
      STDERR.puts "warning: #{warning}"
    end

    plan = FormatSelector.plan(media.formats, format_id, preference)

    unless plan
      STDERR.puts format_plan_error(format_id, preference)
      return 1
    end

    if preference.audio_and_video? && plan.stream.kind.video? && plan.audio.nil?
      STDERR.puts "no audio track is available for this video"
    end

    target = if explicit = output
               Path.new(explicit)
             else
               Dir.mkdir_p(directory)
               OutputFileName.resolve(directory, media.title, plan.container)
             end

    cancellation = Cancellation.new
    Signal::INT.trap { |_signal| cancellation.cancel! }
    Signal::TERM.trap { |_signal| cancellation.cancel! }

    on_progress = ->(progress : DownloadProgress) { print_progress(progress) }
    path = client.download(
      plan,
      target,
      cancellation,
      on_progress,
      resume: resume,
      overwrite: force,
      media_backend: media_backend,
    )
    clear_progress_line

    if json
      puts download_json(path, plan)
    else
      puts path
    end

    0
  rescue ex : OptionParser::Exception
    STDERR.puts ex.message
    STDERR.puts USAGE
    2
  rescue ex : CancelledError
    clear_progress_line
    STDERR.puts "cancelled"
    130
  rescue ex : Rill::Error
    clear_progress_line
    STDERR.puts ex.message
    1
  rescue ex : File::Error
    clear_progress_line
    STDERR.puts ex.message
    1
  rescue ex : ArgumentError
    clear_progress_line
    STDERR.puts ex.message
    1
  end

  private def self.download_playlist(
    client : Client,
    playlist : Playlist,
    directory : String,
    format_id : String?,
    resume : Bool,
    force : Bool,
    media_backend : MediaMuxer::Backend,
    preference : FormatPreference,
    cancellation : Cancellation,
  ) : Int32
    Dir.mkdir_p(directory)
    failures = 0
    total = playlist.entries.size

    playlist.entries.each_with_index do |entry, index|
      if message = entry.error
        failures += 1
        STDERR.puts "[#{index + 1}/#{total}] skipped: #{message}"
        next
      end

      begin
        result = client.extract(entry.url)
        unless result.is_a?(Media)
          raise DownloadError.new("entry is another playlist")
        end

        result.warnings.each do |warning|
          STDERR.puts "  warning: #{warning}"
        end

        plan = FormatSelector.plan(result.formats, format_id, preference)
        unless plan
          raise DownloadError.new(format_plan_error(format_id, preference))
        end

        target = OutputFileName.resolve(directory, result.title, plan.container)
        STDERR.puts "[#{index + 1}/#{total}] #{result.title}"
        path = client.download(
          plan,
          target,
          cancellation,
          nil,
          resume: resume,
          overwrite: force,
          media_backend: media_backend,
        )
        puts path
      rescue ex : CancelledError
        raise ex
      rescue ex : Rill::Error
        failures += 1
        STDERR.puts "  failed: #{ex.message}"
      rescue ex : ArgumentError
        failures += 1
        STDERR.puts "  failed: #{ex.message}"
      end
    end

    if failures > 0
      STDERR.puts "completed with #{failures} failed #{failures == 1 ? "entry" : "entries"}"
    end

    failures.zero? ? 0 : 1
  rescue ex : CancelledError
    clear_progress_line
    STDERR.puts "cancelled"
    130
  end

  private def self.format_plan_error(
    format_id : String?,
    preference : FormatPreference,
  ) : String
    return "unknown format: #{format_id}" if format_id

    case preference
    when .audio_only?
      "no audio-only format is available"
    when .video_only?
      "no video-only format is available"
    else
      "no downloadable formats"
    end
  end

  private def self.print_progress(progress : DownloadProgress) : Nil
    return unless STDERR.tty?

    STDERR.print "\r\e[K#{progress_text(progress)}"
    STDERR.flush
  end

  private def self.clear_progress_line : Nil
    return unless STDERR.tty?

    STDERR.print "\r\e[K"
    STDERR.flush
  end

  private def self.progress_text(progress : DownloadProgress) : String
    downloaded = human_size(progress.downloaded_bytes).not_nil!

    if fraction = progress.fraction
      total = human_size(progress.total_bytes).not_nil!
      "#{(fraction * 100).round(1)}%  #{downloaded} / #{total}"
    else
      downloaded
    end
  end

  private def self.download_json(path : Path, plan : DownloadPlan) : String
    JSON.build(indent: 2) do |json|
      json.object do
        json.field "path", path.to_s
        json.field "format_id", plan.stream.format_id
        json.field "url", plan.stream.url.to_s
        json.field "audio_format_id", plan.audio.try(&.format_id)
      end
    end
  end

  private def self.add_header(options : RequestOptions, value : String) : Nil
    name, separator, header_value = value.partition(':')
    if separator.empty? || name.strip.empty?
      raise OptionParser::InvalidOption.new(value)
    end

    begin
      options.headers.add(name.strip, header_value.strip)
    rescue ArgumentError
      raise OptionParser::InvalidOption.new(value)
    end
  end

  private def self.add_cookie(options : RequestOptions, value : String) : Nil
    name, separator, cookie_value = value.partition('=')
    if separator.empty? || name.strip.empty?
      raise OptionParser::InvalidOption.new(value)
    end
    options.cookies[name.strip] = cookie_value.strip
  end

  private def self.formats_json(result : Media | Playlist) : String
    JSON.build(indent: 2) do |json|
      json.array do
        case result
        when Media
          result.formats.each(&.to_json(json))
        when Playlist
          result.entries.each do |entry|
            json.object do
              json.field "url", entry.url.to_s
              json.field "title", entry.title
              json.field "id", entry.id
            end
          end
        end
      end
    end
  end

  private def self.print_playlist(playlist : Playlist) : Nil
    puts "Title: #{playlist.title}"
    puts "Extractor: #{playlist.extractor}"
    puts "ID: #{playlist.id}" if playlist.id
    puts "Webpage: #{playlist.webpage_url}"
    puts
    puts "Entries: #{playlist.entries.size}"

    playlist.entries.each_with_index do |entry, index|
      puts "  [#{index + 1}] #{entry.title || entry.url}"
      puts "      #{entry.url}"
      puts "      error: #{entry.error}" if entry.error
    end
  end

  private def self.print_media(media : Media, formats_only : Bool) : Nil
    media.warnings.each do |warning|
      STDERR.puts "warning: #{warning}"
    end

    unless formats_only
      puts "Title: #{media.title}"
      puts "Extractor: #{media.extractor}"
      puts "ID: #{media.id}" if media.id
      puts "Uploader: #{media.uploader}" if media.uploader
      puts "Date: #{media.upload_date}" if media.upload_date
      if duration = human_duration(media.duration_seconds)
        puts "Duration: #{duration}"
      end
      puts "Live: yes" if media.is_live?
      puts "Thumbnail: #{media.thumbnail_url}" if media.thumbnail_url
      puts "Webpage: #{media.webpage_url}"
      puts
    end

    puts "Formats: #{media.formats.size}"
    media.formats.each_with_index do |format, index|
      puts "  [#{index + 1}] #{format.format_id}"
      details = format_details(format)
      puts "      #{details}" unless details.empty?
      puts "      #{format.url}"
    end
  end

  private def self.format_details(format : Format) : String
    details = [] of String
    details << format.kind.to_s.downcase
    details << format.protocol.to_s.downcase unless format.protocol.http?
    details << "live" if format.live?

    if container = format.container
      details << container
    end

    if width = format.width
      if height = format.height
        details << "#{width}x#{height}"
      end
    end

    if fps = human_fps(format.fps)
      details << "#{fps} fps"
    end

    if size = human_size(format.filesize)
      details << size
    end

    if note = format.note
      details << note
    end

    details.join(", ")
  end

  private def self.human_fps(fps : Float64?) : String?
    return nil unless fps

    if fps == fps.to_i
      fps.to_i.to_s
    else
      fps.round(2).to_s
    end
  end

  private def self.human_size(bytes : Int64?) : String?
    return nil unless bytes
    return nil if bytes < 0

    return "#{bytes} B" if bytes < 1024

    units = {"KiB", "MiB", "GiB", "TiB"}
    size = bytes.to_f / 1024
    unit = 0
    while size >= 1024 && unit < units.size - 1
      size /= 1024
      unit += 1
    end
    "#{size.round(1)} #{units[unit]}"
  end

  private def self.human_duration(seconds : Float64?) : String?
    return nil unless seconds
    return nil unless seconds.finite? && seconds >= 0

    total = seconds.to_i
    hours = total // 3600
    minutes = (total % 3600) // 60
    remaining = total % 60

    if hours > 0
      "#{hours}h #{minutes}m #{remaining}s"
    elsif minutes > 0
      "#{minutes}m #{remaining}s"
    else
      "#{remaining}s"
    end
  end
end

exit Rill::CLI.run(ARGV)
