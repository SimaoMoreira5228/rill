require "set"
require "uri"
require "xml"

require "../errors"
require "../mime_type"
require "./manifest"

module Rill::Dash::Parser
  extend self

  def parse(source : String, base_url : URI) : Manifest
    document = begin
      XML.parse(source)
    rescue XML::Error
      raise ManifestError.new("DASH manifest is not valid XML")
    end

    root = document.root
    unless root && root.name == "MPD"
      raise ManifestError.new("DASH manifest has no MPD root")
    end

    if root["type"]? == "dynamic"
      raise UnsupportedManifestError.new("live DASH manifests are not supported")
    end

    duration = Dash.parse_duration(root["mediaPresentationDuration"]?)
    manifest_base = resolve_base(root, base_url)
    periods = element_children(root, "Period")

    if periods.empty?
      raise ManifestError.new("DASH manifest has no periods")
    end

    if periods.size > 1
      raise UnsupportedManifestError.new("multi-period DASH manifests are not supported")
    end

    period = periods.first
    period_start = Dash.parse_duration(period["start"]?) || 0.0
    period_duration = Dash.parse_duration(period["duration"]?)
    period_duration ||= duration.try { |value| value - period_start }
    period_base = resolve_base(period, manifest_base)

    representations = [] of Representation
    references = Set(String).new

    element_children(period, "AdaptationSet").each_with_index do |adaptation, adaptation_index|
      next if element_children(adaptation, "ContentProtection").any?

      adaptation_base = resolve_base(adaptation, period_base)
      adaptation_template = parse_template(adaptation, adaptation_base)
      adaptation_list = parse_list(adaptation, adaptation_base)
      adaptation_segment_base = element_children(adaptation, "SegmentBase").any?

      element_children(adaptation, "Representation").each_with_index do |node, representation_index|
        next if element_children(node, "ContentProtection").any?

        id = attribute(node, "id")
        reference = unique_reference(id, adaptation_index, representation_index, references)

        representation_base = resolve_base(node, adaptation_base)
        template = parse_template(node, representation_base) || adaptation_template
        list = parse_list(node, representation_base) || adaptation_list
        segment_base = adaptation_segment_base || element_children(node, "SegmentBase").any?

        mime_value = attribute(node, "mimeType") ||
                     attribute(adaptation, "mimeType") ||
                     mime_for_content_type(adaptation)
        mime = mime_value.try { |value| MimeType.parse(value) }
        next if mime.nil? || mime.empty?

        representations << Representation.new(
          reference: reference,
          base_url: representation_base,
          duration_seconds: period_duration,
          id: id,
          bandwidth: attribute(node, "bandwidth").try(&.to_i64?),
          mime: mime,
          codecs: attribute(node, "codecs") || attribute(adaptation, "codecs"),
          width: dimension(attribute(node, "width") || attribute(adaptation, "width")),
          height: dimension(attribute(node, "height") || attribute(adaptation, "height")),
          fps: frame_rate(attribute(node, "frameRate") || attribute(adaptation, "frameRate")),
          language: attribute(node, "lang") || attribute(adaptation, "lang"),
          template: template,
          list: list,
          segment_base: segment_base,
        )
      end
    end

    Manifest.new(representations, period_duration)
  end

  private def unique_reference(
    id : String?,
    adaptation_index : Int32,
    representation_index : Int32,
    references : Set(String),
  ) : String
    generated = "rep-#{adaptation_index}-#{representation_index}"
    reference = if id.nil? || id.empty?
                  generated
                elsif references.includes?(id)
                  "#{id}-#{adaptation_index}-#{representation_index}"
                else
                  id
                end
    references << reference
    reference
  end

  private def resolve_base(node : XML::Node, current : URI) : URI
    value = element_children(node, "BaseURL").first?.try(&.content.strip)
    return current if value.nil? || value.empty?

    Dash.resolve_url(current, value)
  end

  private def parse_template(node : XML::Node, base_url : URI) : SegmentTemplate?
    template_node = element_children(node, "SegmentTemplate").first?
    return nil unless template_node

    media = attribute(template_node, "media")
    return nil unless media

    timeline = [] of TimelineEntry
    if timeline_node = element_children(template_node, "SegmentTimeline").first?
      element_children(timeline_node, "S").each do |entry|
        duration = attribute(entry, "d").try(&.to_i64?)
        unless duration && duration > 0
          raise ManifestError.new("DASH timeline entry has no duration")
        end

        timeline << TimelineEntry.new(
          duration,
          attribute(entry, "t").try(&.to_i64?),
          attribute(entry, "r").try(&.to_i64?) || 0_i64,
        )
      end
    end

    SegmentTemplate.new(
      media: media,
      initialization: attribute(template_node, "initialization"),
      timescale: attribute(template_node, "timescale").try(&.to_i64?) || 1_i64,
      duration: attribute(template_node, "duration").try(&.to_i64?),
      start_number: attribute(template_node, "startNumber").try(&.to_i64?) || 1_i64,
      presentation_time_offset: attribute(template_node, "presentationTimeOffset").try(&.to_i64?) || 0_i64,
      timeline: timeline,
    )
  end

  private def parse_list(node : XML::Node, base_url : URI) : SegmentList?
    list_node = element_children(node, "SegmentList").first?
    return nil unless list_node

    initialization = element_children(list_node, "Initialization").first?
    init_url = if initialization
                 if initialization["range"]?
                   raise UnsupportedManifestError.new("DASH byte-range initialization is not supported")
                 end
                 source = attribute(initialization, "sourceURL")
                 source ? Dash.resolve_url(base_url, source) : nil
               end

    segments = [] of Segment
    element_children(list_node, "SegmentURL").each do |segment_node|
      if segment_node["mediaRange"]?
        raise UnsupportedManifestError.new("DASH byte-range segments are not supported")
      end

      media = attribute(segment_node, "media")
      next unless media

      segments << Segment.new(Dash.resolve_url(base_url, media))
    end

    SegmentList.new(init_url, segments)
  end

  private def mime_for_content_type(adaptation : XML::Node) : String?
    case attribute(adaptation, "contentType")
    when "audio"
      "audio/mp4"
    when "video"
      "video/mp4"
    else
      nil
    end
  end

  private def element_children(node : XML::Node, name : String) : Array(XML::Node)
    node.children.select { |child| child.element? && child.name == name }
  end

  private def attribute(node : XML::Node, name : String) : String?
    value = node[name]?.try(&.strip)
    return nil if value.nil? || value.empty?

    value
  end

  private def dimension(value : String?) : Int32?
    parsed = value.try(&.to_i64?)
    return nil unless parsed && 0 < parsed <= 100_000

    parsed.to_i32
  end

  private def frame_rate(value : String?) : Float64?
    return nil unless value

    if value.includes?('/')
      numerator, denominator = value.split('/', 2).map(&.to_f?)
      return nil unless numerator && denominator && denominator > 0

      rate = numerator / denominator
    else
      rate = value.to_f?
    end
    return nil unless rate && rate.finite? && rate > 0

    rate
  end
end
