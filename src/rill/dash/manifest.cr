require "uri"

require "../errors"
require "../mime_type"

module Rill::Dash
  DURATION                    = /\AP(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?\z/
  DEFAULT_LIVE_WINDOW_SECONDS = 300.0
  TEMPLATE                    = /\$(\$|RepresentationID|Bandwidth|Number|Time)(?:%0(\d+)d)?\$/

  struct Segment
    getter url : URI
    getter duration_seconds : Float64?
    getter key : Int64?
    getter key_step : Int64

    def initialize(
      @url : URI,
      @duration_seconds : Float64? = nil,
      @key : Int64? = nil,
      @key_step : Int64 = 1_i64,
    )
    end
  end

  class SegmentList
    getter initialization : URI?
    getter segments : Array(Segment)

    def initialize(@initialization : URI?, @segments : Array(Segment))
    end
  end

  class SegmentTemplate
    getter initialization : String?
    getter media : String
    getter timescale : Int64
    getter duration : Int64?
    getter start_number : Int64
    getter presentation_time_offset : Int64
    getter timeline : Array(TimelineEntry)

    def initialize(
      @media : String,
      @initialization : String? = nil,
      @timescale : Int64 = 1,
      @duration : Int64? = nil,
      @start_number : Int64 = 1,
      @presentation_time_offset : Int64 = 0,
      @timeline : Array(TimelineEntry) = [] of TimelineEntry,
    )
    end

    def supported?(period_duration : Float64?, dynamic : Bool = false) : Bool
      return true unless @timeline.empty?

      duration = @duration
      return false unless duration && duration > 0

      dynamic || !period_duration.nil?
    end

    def time_based? : Bool
      media.includes?("$Time$")
    end

    def expand(
      base_url : URI,
      reference : String,
      bandwidth : Int64?,
      period_duration : Float64?,
    ) : Tuple(URI?, Array(Segment))
      init_url = if template = @initialization
                   Dash.resolve_url(
                     base_url,
                     Dash.expand_template(template, reference, bandwidth, @start_number, @presentation_time_offset),
                   )
                 end

      segments = if @timeline.empty?
                   expand_fixed(base_url, reference, bandwidth, period_duration)
                 else
                   expand_timeline(base_url, reference, bandwidth, period_duration)
                 end

      {init_url, segments}
    end

    def expand_live(
      base_url : URI,
      reference : String,
      bandwidth : Int64?,
      now : Time,
      availability_start_time : Time?,
      window : Float64?,
    ) : Tuple(URI?, Array(Segment))
      init_url = if template = @initialization
                   Dash.resolve_url(
                     base_url,
                     Dash.expand_template(template, reference, bandwidth, @start_number, @presentation_time_offset),
                   )
                 end

      segments = if @timeline.empty?
                   expand_live_fixed(base_url, reference, bandwidth, now, availability_start_time, window)
                 else
                   expand_live_timeline(
                     base_url,
                     reference,
                     bandwidth,
                     now,
                     availability_start_time,
                     window,
                   )
                 end

      {init_url, segments}
    end

    private def expand_live_fixed(
      base_url : URI,
      reference : String,
      bandwidth : Int64?,
      now : Time,
      availability_start_time : Time?,
      window : Float64?,
    ) : Array(Segment)
      duration = @duration
      unless duration && duration > 0
        raise UnsupportedManifestError.new("live DASH segment template needs a duration")
      end

      availability_start = availability_start_time
      unless availability_start
        raise UnsupportedManifestError.new("live DASH segment template needs availabilityStartTime")
      end

      elapsed = (now - availability_start).total_seconds
      return [] of Segment if elapsed < 0

      available = (elapsed * @timescale).floor.to_i64
      last_index = available // duration - 1
      return [] of Segment if last_index < 0

      effective_window = window && window > 0 ? window : DEFAULT_LIVE_WINDOW_SECONDS
      window_segments = (effective_window * @timescale / duration).ceil.to_i64
      first_index = last_index - Math.max(window_segments - 1, 0)
      first_index = 0_i64 if first_index < 0

      segments = [] of Segment
      (first_index..last_index).each do |index|
        number = @start_number + index
        time = @presentation_time_offset + index * duration
        value = Dash.expand_template(@media, reference, bandwidth, number, time)
        segments << Segment.new(
          Dash.resolve_url(base_url, value),
          duration.to_f / @timescale,
          time_based? ? time : number,
          time_based? ? duration : 1_i64,
        )
      end

      segments
    end

    private def expand_live_timeline(
      base_url : URI,
      reference : String,
      bandwidth : Int64?,
      now : Time,
      availability_start_time : Time?,
      window : Float64?,
    ) : Array(Segment)
      availability_start = availability_start_time
      unless availability_start
        raise UnsupportedManifestError.new("live DASH segment timeline needs availabilityStartTime")
      end

      now_ticks = ((now - availability_start).total_seconds * @timescale).to_i64 +
                  @presentation_time_offset
      effective_window = window && window > 0 ? window : DEFAULT_LIVE_WINDOW_SECONDS
      window_start = now_ticks - (effective_window * @timescale).to_i64

      first_entry_time = @timeline.first?.try(&.time) || @presentation_time_offset
      first_entry_duration = @timeline.first?.try(&.duration) || 1_i64
      segments = [] of Segment
      current_time = @presentation_time_offset

      @timeline.each do |entry|
        start_time = entry.time || current_time
        repeats = entry.repeat

        if repeats < 0
          repeats = (now_ticks - start_time) // entry.duration - 1
          repeats = 0_i64 if repeats < 0
        end

        number = @start_number + (start_time - first_entry_time) // first_entry_duration
        (repeats + 1).times do |index|
          time = start_time + index * entry.duration
          if time + entry.duration > window_start
            value = Dash.expand_template(@media, reference, bandwidth, number, time)
            segments << Segment.new(
              Dash.resolve_url(base_url, value),
              entry.duration.to_f / @timescale,
              time_based? ? time : number,
              time_based? ? entry.duration : 1_i64,
            )
          end
          number += 1
        end

        current_time = start_time + (repeats + 1) * entry.duration
      end

      segments
    end

    private def expand_fixed(
      base_url : URI,
      reference : String,
      bandwidth : Int64?,
      period_duration : Float64?,
    ) : Array(Segment)
      duration = @duration
      total = period_duration
      unless duration && duration > 0 && total
        raise UnsupportedManifestError.new("DASH segment template needs a duration and a period duration")
      end

      count = ((total * @timescale) / duration).ceil.to_i64
      segments = [] of Segment

      count.times do |index|
        number = @start_number + index
        time = @presentation_time_offset + index * duration
        value = Dash.expand_template(@media, reference, bandwidth, number, time)
        segments << Segment.new(
          Dash.resolve_url(base_url, value),
          duration.to_f / @timescale,
          time_based? ? time : number,
          time_based? ? duration : 1_i64,
        )
      end

      segments
    end

    private def expand_timeline(
      base_url : URI,
      reference : String,
      bandwidth : Int64?,
      period_duration : Float64?,
    ) : Array(Segment)
      segments = [] of Segment
      number = @start_number
      current_time = @presentation_time_offset
      period_ticks = period_duration.try { |seconds| (seconds * @timescale).ceil.to_i64 }

      @timeline.each do |entry|
        start_time = entry.time || current_time
        repeats = entry.repeat

        if repeats < 0
          total = period_ticks
          unless total
            raise UnsupportedManifestError.new("DASH timeline repeats need a period duration")
          end
          repeats = ((total - start_time) / entry.duration).ceil.to_i64 - 1
          repeats = 0 if repeats < 0
        end

        (repeats + 1).times do |index|
          time = start_time + index * entry.duration
          value = Dash.expand_template(@media, reference, bandwidth, number, time)
          segments << Segment.new(
            Dash.resolve_url(base_url, value),
            entry.duration.to_f / @timescale,
            time_based? ? time : number,
            time_based? ? entry.duration : 1_i64,
          )
          number += 1
        end

        current_time = start_time + (repeats + 1) * entry.duration
      end

      segments
    end
  end

  struct TimelineEntry
    getter time : Int64?
    getter duration : Int64
    getter repeat : Int64

    def initialize(@duration : Int64, @time : Int64? = nil, @repeat : Int64 = 0)
    end
  end

  class Representation
    getter reference : String
    getter id : String?
    getter bandwidth : Int64?
    getter mime : MimeType?
    getter codecs : String?
    getter width : Int32?
    getter height : Int32?
    getter fps : Float64?
    getter language : String?
    getter base_url : URI
    getter duration_seconds : Float64?
    getter template : SegmentTemplate?
    getter list : SegmentList?
    getter segment_base : Bool

    def initialize(
      @reference : String,
      @base_url : URI,
      @duration_seconds : Float64?,
      @id : String? = nil,
      @bandwidth : Int64? = nil,
      @mime : MimeType? = nil,
      @codecs : String? = nil,
      @width : Int32? = nil,
      @height : Int32? = nil,
      @fps : Float64? = nil,
      @language : String? = nil,
      @template : SegmentTemplate? = nil,
      @list : SegmentList? = nil,
      @segment_base : Bool = false,
    )
    end

    def supported?(dynamic : Bool = false) : Bool
      return false if @segment_base
      return true if @list

      @template.try(&.supported?(@duration_seconds, dynamic)) || false
    end

    def expand : Tuple(URI?, Array(Segment))
      if list = @list
        {list.initialization, list.segments}
      elsif template = @template
        template.expand(@base_url, @reference, @bandwidth, @duration_seconds)
      else
        raise UnsupportedManifestError.new("DASH representation has no segment information")
      end
    end

    def expand_live(
      now : Time,
      availability_start_time : Time?,
      window : Float64?,
    ) : Tuple(URI?, Array(Segment))
      if list = @list
        {list.initialization, list.segments}
      elsif template = @template
        template.expand_live(
          @base_url,
          @reference,
          @bandwidth,
          now,
          availability_start_time,
          window,
        )
      else
        raise UnsupportedManifestError.new("DASH representation has no segment information")
      end
    end
  end

  struct Manifest
    getter representations : Array(Representation)
    getter duration_seconds : Float64?
    getter? dynamic : Bool
    getter availability_start_time : Time?
    getter minimum_update_period : Float64?
    getter time_shift_buffer_depth : Float64?

    def initialize(
      @representations : Array(Representation),
      @duration_seconds : Float64? = nil,
      @dynamic : Bool = false,
      @availability_start_time : Time? = nil,
      @minimum_update_period : Float64? = nil,
      @time_shift_buffer_depth : Float64? = nil,
    )
    end
  end

  def self.parse_duration(value : String?) : Float64?
    return nil unless value

    match = DURATION.match(value.strip)
    return nil unless match

    days = match[1]?.try(&.to_f) || 0.0
    hours = match[2]?.try(&.to_f) || 0.0
    minutes = match[3]?.try(&.to_f) || 0.0
    seconds = match[4]?.try(&.to_f) || 0.0

    days * 86400 + hours * 3600 + minutes * 60 + seconds
  end

  def self.expand_template(
    template : String,
    reference : String,
    bandwidth : Int64?,
    number : Int64,
    time : Int64,
  ) : String
    String.build do |io|
      index = 0

      while match = TEMPLATE.match(template, index)
        io << template[index, match.begin(0) - index]
        value = case match[1]
                when "$"
                  "$"
                when "RepresentationID"
                  reference
                when "Bandwidth"
                  (bandwidth || 0).to_s
                when "Number"
                  number.to_s
                when "Time"
                  time.to_s
                else
                  ""
                end

        if width = match[2]?.try(&.to_i?)
          value = value.rjust(width, '0')
        end

        io << value
        index = match.end(0)
      end

      io << template[index, template.size - index]
    end
  end

  def self.resolve_url(base : URI, value : String) : URI
    uri = base.resolve(value)
    unless uri.scheme == "http" || uri.scheme == "https"
      raise UnsupportedManifestError.new("DASH segment URL is not HTTP")
    end
    return uri if uri.host

    raise UnsupportedManifestError.new("DASH segment URL has no host")
  rescue URI::Error
    raise ManifestError.new("invalid DASH segment URL: #{value}")
  end
end
