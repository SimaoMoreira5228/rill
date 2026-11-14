require "./download_plan"
require "./format"

module Rill
  enum FormatPreference
    AudioAndVideo
    AudioOnly
    VideoOnly
  end
end

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

  def plan(
    formats : Array(Format),
    format_id : String? = nil,
    preference : FormatPreference = FormatPreference::AudioAndVideo,
  ) : DownloadPlan?
    return nil if formats.empty?

    if format_id
      selected = by_id(formats, format_id)
      return nil unless selected

      return plan_for(selected, formats)
    end

    case preference
    when .audio_only?
      audio = best_audio_only(formats)
      audio ? DownloadPlan.new(audio) : nil
    when .video_only?
      video = best_video_only(formats)
      video ? DownloadPlan.new(video) : nil
    else
      audio_and_video_plan(formats)
    end
  end

  private def audio_and_video_plan(formats : Array(Format)) : DownloadPlan?
    combined = formats.select { |format| format.kind == FormatKind::Combined }
    unless combined.empty?
      return DownloadPlan.new(best_video(combined))
    end

    video = best_video_only(formats)
    unless video.nil?
      return DownloadPlan.new(video, best_audio_for(video, formats))
    end

    audio = best_audio_only(formats)
    audio ? DownloadPlan.new(audio) : nil
  end

  private def best_video_only(formats : Array(Format)) : Format?
    video = formats.select { |format| format.kind == FormatKind::Video }
    return nil if video.empty?

    best_video(video)
  end

  private def best_audio_only(formats : Array(Format)) : Format?
    audio = formats.select { |format| format.kind == FormatKind::Audio }
    return nil if audio.empty?

    audio.max_by? do |format|
      {
        (format.bitrate || 0).to_i64,
        (format.audio_bitrate || 0).to_i64,
        format.filesize || 0_i64,
      }
    end || audio.first
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
