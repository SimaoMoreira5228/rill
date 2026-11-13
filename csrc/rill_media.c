#include "rill_media.h"

#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void set_error(char *buffer, size_t size, const char *format, ...) {
  if (!buffer || size == 0) {
    return;
  }

  va_list args;
  va_start(args, format);
  vsnprintf(buffer, size, format, args);
  va_end(args);
}

static int fail_av(char *buffer, size_t size, int error, const char *context) {
  char detail[AV_ERROR_MAX_STRING_SIZE] = {0};

  if (error < 0) {
    av_strerror(error, detail, sizeof(detail));
  }

  if (detail[0] != '\0') {
    set_error(buffer, size, "%s: %s", context, detail);
  } else {
    set_error(buffer, size, "%s", context);
  }

  return error < 0 ? error : AVERROR_EXTERNAL;
}

static int file_exists(const char *path) {
  FILE *file = fopen(path, "rb");
  if (!file) {
    return 0;
  }

  fclose(file);
  return 1;
}

static int open_input(AVFormatContext **context, const char *path, char *error,
                      size_t error_size) {
  int result = avformat_open_input(context, path, NULL, NULL);
  if (result < 0) {
    return fail_av(error, error_size, result, "cannot open input");
  }

  result = avformat_find_stream_info(*context, NULL);
  if (result < 0) {
    return fail_av(error, error_size, result, "cannot read input streams");
  }

  return 0;
}

static int add_stream(AVFormatContext *output, AVStream *input, char *error,
                      size_t error_size) {
  AVStream *stream = avformat_new_stream(output, NULL);
  if (!stream) {
    set_error(error, error_size, "cannot allocate output stream");
    return AVERROR(ENOMEM);
  }

  int result = avcodec_parameters_copy(stream->codecpar, input->codecpar);
  if (result < 0) {
    return fail_av(error, error_size, result, "cannot copy codec parameters");
  }

  stream->codecpar->codec_tag = 0;
  stream->time_base = input->time_base;
  stream->avg_frame_rate = input->avg_frame_rate;
  stream->sample_aspect_ratio = input->sample_aspect_ratio;
  av_dict_copy(&stream->metadata, input->metadata, 0);

  return stream->index;
}

static int read_stream_packet(AVFormatContext *context, int stream_index,
                              AVPacket *packet, int *eof, char *error,
                              size_t error_size) {
  while (!*eof) {
    int result = av_read_frame(context, packet);
    if (result == AVERROR_EOF) {
      *eof = 1;
      return 0;
    }

    if (result < 0) {
      return fail_av(error, error_size, result, "cannot read packet");
    }

    if (packet->stream_index == stream_index) {
      return 1;
    }

    av_packet_unref(packet);
  }

  return 0;
}

static int64_t packet_time(const AVPacket *packet, const AVStream *stream) {
  int64_t timestamp = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
  if (timestamp == AV_NOPTS_VALUE) {
    return INT64_MAX;
  }

  return av_rescale_q(timestamp, stream->time_base, AV_TIME_BASE_Q);
}

static int write_stream_packet(AVFormatContext *output, AVPacket *packet,
                               AVStream *input_stream, AVStream *output_stream,
                               char *error, size_t error_size) {
  packet->stream_index = output_stream->index;
  av_packet_rescale_ts(packet, input_stream->time_base,
                       output_stream->time_base);

  int result = av_interleaved_write_frame(output, packet);
  if (result < 0) {
    return fail_av(error, error_size, result, "cannot write packet");
  }

  return 0;
}

int rill_media_merge(const char *video_path, const char *audio_path,
                     const char *output_path, int overwrite, char *error,
                     size_t error_size) {
  if (!video_path || !audio_path || !output_path) {
    set_error(error, error_size, "missing input or output path");
    return AVERROR(EINVAL);
  }

  if (error && error_size > 0) {
    error[0] = '\0';
  }

  if (!file_exists(video_path)) {
    set_error(error, error_size, "video input not found: %s", video_path);
    return AVERROR(ENOENT);
  }

  if (!file_exists(audio_path)) {
    set_error(error, error_size, "audio input not found: %s", audio_path);
    return AVERROR(ENOENT);
  }

  if (!overwrite && file_exists(output_path)) {
    set_error(error, error_size, "output already exists: %s", output_path);
    return AVERROR(EEXIST);
  }

  AVFormatContext *video_context = NULL;
  AVFormatContext *audio_context = NULL;
  AVFormatContext *output_context = NULL;
  AVPacket *video_packet = NULL;
  AVPacket *audio_packet = NULL;
  int result = 0;
  int header_written = 0;

  result = open_input(&video_context, video_path, error, error_size);
  if (result < 0) {
    goto end;
  }

  result = open_input(&audio_context, audio_path, error, error_size);
  if (result < 0) {
    goto end;
  }

  int video_index =
      av_find_best_stream(video_context, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (video_index < 0) {
    result = fail_av(error, error_size, video_index, "video input has no video stream");
    goto end;
  }

  int audio_index =
      av_find_best_stream(audio_context, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  if (audio_index < 0) {
    result = fail_av(error, error_size, audio_index, "audio input has no audio stream");
    goto end;
  }

  result = avformat_alloc_output_context2(&output_context, NULL, NULL, output_path);
  if (result < 0 || !output_context) {
    result = fail_av(error, error_size, result, "cannot create output container");
    goto end;
  }

  AVStream *input_video = video_context->streams[video_index];
  AVStream *input_audio = audio_context->streams[audio_index];

  int output_video_index = add_stream(output_context, input_video, error, error_size);
  if (output_video_index < 0) {
    result = output_video_index;
    goto end;
  }

  int output_audio_index = add_stream(output_context, input_audio, error, error_size);
  if (output_audio_index < 0) {
    result = output_audio_index;
    goto end;
  }

  AVStream *output_video = output_context->streams[output_video_index];
  AVStream *output_audio = output_context->streams[output_audio_index];

  av_dict_copy(&output_context->metadata, video_context->metadata, 0);
  output_context->flags |= AVFMT_FLAG_AUTO_BSF;
  output_context->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_ZERO;

  if (!(output_context->oformat->flags & AVFMT_NOFILE)) {
    result = avio_open(&output_context->pb, output_path, AVIO_FLAG_WRITE);
    if (result < 0) {
      result = fail_av(error, error_size, result, "cannot open output");
      goto end;
    }
  }

  result = avformat_write_header(output_context, NULL);
  if (result < 0) {
    result = fail_av(error, error_size, result, "cannot write output header");
    goto end;
  }
  header_written = 1;

  video_packet = av_packet_alloc();
  audio_packet = av_packet_alloc();
  if (!video_packet || !audio_packet) {
    set_error(error, error_size, "cannot allocate packets");
    result = AVERROR(ENOMEM);
    goto end;
  }

  int video_eof = 0;
  int audio_eof = 0;
  int video_ready = 0;
  int audio_ready = 0;

  while (1) {
    if (!video_ready && !video_eof) {
      result = read_stream_packet(video_context, video_index, video_packet,
                                  &video_eof, error, error_size);
      if (result < 0) {
        goto end;
      }
      video_ready = result == 1;
    }

    if (!audio_ready && !audio_eof) {
      result = read_stream_packet(audio_context, audio_index, audio_packet,
                                  &audio_eof, error, error_size);
      if (result < 0) {
        goto end;
      }
      audio_ready = result == 1;
    }

    if (!video_ready && !audio_ready) {
      if (video_eof && audio_eof) {
        break;
      }
      continue;
    }

    int write_video;
    if (video_ready && audio_ready) {
      write_video = packet_time(video_packet, input_video) <=
                    packet_time(audio_packet, input_audio);
    } else {
      write_video = video_ready;
    }

    if (write_video) {
      result = write_stream_packet(output_context, video_packet, input_video,
                                   output_video, error, error_size);
      video_ready = 0;
    } else {
      result = write_stream_packet(output_context, audio_packet, input_audio,
                                   output_audio, error, error_size);
      audio_ready = 0;
    }

    if (result < 0) {
      goto end;
    }
  }

  result = av_write_trailer(output_context);
  if (result < 0) {
    result = fail_av(error, error_size, result, "cannot finish output file");
    goto end;
  }

end:
  av_packet_free(&video_packet);
  av_packet_free(&audio_packet);

  if (output_context) {
    if (header_written && result < 0) {
      av_write_trailer(output_context);
    }
    if (output_context->pb) {
      avio_closep(&output_context->pb);
    }
    avformat_free_context(output_context);
  }

  if (video_context) {
    avformat_close_input(&video_context);
  }

  if (audio_context) {
    avformat_close_input(&audio_context);
  }

  return result;
}

const char *rill_media_version(void) {
  return av_version_info();
}

static void print_usage(const char *program) {
  fprintf(stderr,
          "Usage: %s merge --video PATH --audio PATH --output PATH "
          "[--overwrite]\n",
          program);
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--version") == 0) {
    printf("%s\n", rill_media_version());
    return 0;
  }

  if (argc < 2 || strcmp(argv[1], "merge") != 0) {
    print_usage(argv[0]);
    return 2;
  }

  const char *video_path = NULL;
  const char *audio_path = NULL;
  const char *output_path = NULL;
  int overwrite = 0;

  for (int index = 2; index < argc; index++) {
    if (strcmp(argv[index], "--video") == 0 && index + 1 < argc) {
      video_path = argv[++index];
    } else if (strcmp(argv[index], "--audio") == 0 && index + 1 < argc) {
      audio_path = argv[++index];
    } else if (strcmp(argv[index], "--output") == 0 && index + 1 < argc) {
      output_path = argv[++index];
    } else if (strcmp(argv[index], "--overwrite") == 0) {
      overwrite = 1;
    } else {
      fprintf(stderr, "unknown argument: %s\n", argv[index]);
      print_usage(argv[0]);
      return 2;
    }
  }

  if (!video_path || !audio_path || !output_path) {
    print_usage(argv[0]);
    return 2;
  }

  char error[1024] = {0};
  int result = rill_media_merge(video_path, audio_path, output_path, overwrite,
                                error, sizeof(error));
  if (result < 0) {
    fprintf(stderr, "%s\n", error[0] ? error : "media merge failed");
    return 1;
  }

  return 0;
}
