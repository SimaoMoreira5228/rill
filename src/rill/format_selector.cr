require "./download_plan"
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

  def plan(formats : Array(Format), format_id : String? = nil) : DownloadPlan?
    return nil if formats.empty?

    if format_id
      selected = by_id(formats, format_id)
      return nil unless selected

      return plan_for(selected, formats)
    end

    combined = formats.select { |format| format.kind == FormatKind::Combined }
    unless combined.empty?
      return DownloadPlan.new(best_video(combined))
    end

    video = formats.select { |format| format.kind == FormatKind::Video }
    unless video.empty?
      primary = best_video(video)
      return DownloadPlan.new(primary, best_audio_for(primary, formats))
    end

    audio = best_audio(formats)
    audio ? DownloadPlan.new(audio) : nil
  end

  def by_id(formats : Array(Format), format_id : String) : Format?
    formats.find { |format| format.format_id == format_id }
  end

  private def plan_for(selected : Format, formats : Array(Format)) : DownloadPlan
    return DownloadPlan.new(selected) unless selected.kind == FormatKind::Video

    DownloadPlan.new(selected, best_audio_for(selected, formats))
  end

  private def best_audio_for(video : Format, formats : Array(Format)) : Format?
    audio = formats.select { |format| format.kind == FormatKind::Audio }
    return nil if audio.empty?

    audio.max_by? do |format|
      {
        video.container && format.container == video.container ? 1 : 0,
        (format.bitrate || 0).to_i64,
        (format.audio_bitrate || 0).to_i64,
        format.filesize || 0_i64,
      }
    end || audio.first
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
        (format.bitrate || 0).to_i64,
        (format.audio_bitrate || 0).to_i64,
        format.filesize || 0_i64,
      }
    end || formats.first
  end
end
