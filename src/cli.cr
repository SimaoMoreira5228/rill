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

    media = ExtractorRegistry.default.extract(remaining.first, options)

    if json
      puts command == "formats" ? formats_json(media) : media.to_pretty_json
    else
      print_media(media, formats_only: command == "formats")
    end

    0
  rescue ex : OptionParser::Exception
    STDERR.puts ex.message
    STDERR.puts USAGE
    2
  rescue ex : Rill::Error
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
      options.user_agent = value
    end
  end

  private def self.run_download(args : Array(String)) : Int32
    options = RequestOptions.new
    output : String? = nil
    directory = "."
    directory_given = false
    format_id : String? = nil
    force = false
    resume = true
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
    parser.on("--force", "Overwrite an existing file") { force = true }
    parser.on("--no-resume", "Do not resume an existing part file") { resume = false }
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

    media = ExtractorRegistry.default.extract(remaining.first, options)
    format = if requested = format_id
               FormatSelector.by_id(media.formats, requested)
             else
               FormatSelector.best(media.formats)
             end

    unless format
      STDERR.puts format_id ? "unknown format: #{format_id}" : "no downloadable formats"
      return 1
    end

    target = if explicit = output
               Path.new(explicit)
             else
               Dir.mkdir_p(directory)
               OutputFileName.resolve(directory, media.title, format.container)
             end

    cancellation = Cancellation.new
    Signal::INT.trap { |_signal| cancellation.cancel! }
    Signal::TERM.trap { |_signal| cancellation.cancel! }

    downloader = Downloader.new(options, resume: resume, overwrite: force)
    on_progress = ->(progress : DownloadProgress) { print_progress(progress) }
    path = downloader.download(format, target, cancellation, on_progress)
    clear_progress_line

    if json
      puts download_json(path, format)
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

  private def self.download_json(path : Path, format : Format) : String
    JSON.build(indent: 2) do |json|
      json.object do
        json.field "path", path.to_s
        json.field "format_id", format.format_id
        json.field "url", format.url.to_s
      end
    end
  end

  private def self.add_header(options : RequestOptions, value : String) : Nil
    name, separator, header_value = value.partition(':')
    if separator.empty? || name.strip.empty?
      raise OptionParser::InvalidOption.new(value)
    end
    options.headers.add(name.strip, header_value.strip)
  end

  private def self.add_cookie(options : RequestOptions, value : String) : Nil
    name, separator, cookie_value = value.partition('=')
    if separator.empty? || name.strip.empty?
      raise OptionParser::InvalidOption.new(value)
    end
    options.cookies[name.strip] = cookie_value.strip
  end

  private def self.formats_json(media : Media) : String
    JSON.build(indent: 2) do |json|
      json.array do
        media.formats.each(&.to_json(json))
      end
    end
  end

  private def self.print_media(media : Media, formats_only : Bool) : Nil
    unless formats_only
      puts "Title: #{media.title}"
      puts "Extractor: #{media.extractor}"
      puts "ID: #{media.id}" if media.id
      puts "Uploader: #{media.uploader}" if media.uploader
      puts "Date: #{media.upload_date}" if media.upload_date
      if duration = human_duration(media.duration_seconds)
        puts "Duration: #{duration}"
      end
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
