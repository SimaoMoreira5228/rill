require "./format"

module Rill::FormatSelector
  extend self

  CONTAINER_RANK = {
    "mp4"  => 5,
    "webm" => 4,
    "mkv"  => 4,
    "m4v"  => 3,
    "mov"  => 3,
    "ogv"  => 2,
    "avi"  => 1,
  }

  def best(formats : Array(Format)) : Format?
    return nil if formats.empty?

    combined = formats.select { |format| format.kind == FormatKind::Combined }
    return best_video(combined) unless combined.empty?

    video = formats.select { |format| format.kind == FormatKind::Video }
    return best_video(video) unless video.empty?

    best_audio(formats)
  end

  def by_id(formats : Array(Format), format_id : String) : Format?
    formats.find { |format| format.format_id == format_id }
  end

  private def best_video(formats : Array(Format)) : Format
    formats.max_by? do |format|
      {
        format.height || 0,
        CONTAINER_RANK[format.container || ""]? || 0,
        (format.video_bitrate || 0).to_i64,
        format.bitrate || 0_i64,
        format.filesize || 0_i64,
      }
    end || formats.first
  end

  private def best_audio(formats : Array(Format)) : Format
    formats.max_by? do |format|
      {
        format.audio_bitrate || 0,
        format.filesize || 0_i64,
      }
    end || formats.first
  end
end
