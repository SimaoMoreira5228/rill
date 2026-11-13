project(
  'rill-native',
  'c',
  meson_version: '>= 1.4.0',
  default_options: [
    'warning_level=2',
    'c_std=c17',
  ],
)

if get_option('ffmpeg') == 'system'
  avformat_dep = dependency('libavformat', required: true)
  avcodec_dep = dependency('libavcodec', required: true)
  avutil_dep = dependency('libavutil', required: true)
else
  ffmpeg = subproject(
    'ffmpeg',
    default_options: [
      'default_library=static',
      'programs=disabled',
      'network=disabled',
      'tests=disabled',
      'muxers=disabled',
      'demuxers=disabled',
      'parsers=enabled',
      'bsfs=enabled',
      'protocols=disabled',
      'decoders=disabled',
      'encoders=disabled',
      'filters=disabled',
      'avdevice=disabled',
      'avfilter=disabled',
      'swscale=disabled',
      'swresample=disabled',
      'zlib=disabled',
      'bzlib=disabled',
      'lzma=disabled',
      'iconv=disabled',
      'alsa=disabled',
      'vulkan=disabled',
      'mp4_muxer=enabled',
      'mov_muxer=enabled',
      'matroska_muxer=enabled',
      'mov_demuxer=enabled',
      'matroska_demuxer=enabled',
      'file_protocol=enabled',
      'aac_decoder=enabled',
    ],
  )

  avformat_dep = ffmpeg.get_variable('libavformat_dep')
  avcodec_dep = ffmpeg.get_variable('libavcodec_dep')
  avutil_dep = ffmpeg.get_variable('libavutil_dep')
endif

executable(
  'rill-media',
  'csrc/rill_media.c',
  include_directories: include_directories('include'),
  dependencies: [avformat_dep, avcodec_dep, avutil_dep],
  install: true,
)
