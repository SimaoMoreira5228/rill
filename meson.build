project(
  'rill-native',
  'c',
  meson_version: '>= 1.4.0',
  default_options: [
    'warning_level=2',
    'c_std=c17',
  ],
)

quickjs = subproject(
  'quickjs-ng',
  default_options: [
    'default_library=static',
    'libc=false',
    'tests=disabled',
    'examples=disabled',
  ],
)

qjs_lib = quickjs.get_variable('qjs_lib')
qjs_sys_deps = quickjs.get_variable('qjs_sys_deps')

rill_js = static_library(
  'rill-js',
  'csrc/rill_js.c',
  link_whole: qjs_lib,
  dependencies: qjs_sys_deps,
  include_directories: include_directories('include', 'subprojects/quickjs-ng'),
  c_args: ['-DQUICKJS_NG_BUILD'],
)

if get_option('media')
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
endif

crystal = find_program('crystal')
python = find_program('python3', 'python')
source_root = meson.project_source_root()
build_root = meson.current_build_dir()

source_list = run_command(
  python,
  '-c',
  'import pathlib; print("\\n".join(str(p) for p in pathlib.Path("src").rglob("*.cr")))',
  check: true,
).stdout().strip().split('\n')
rill_sources = files(source_list)

host_system = host_machine.system()

if host_system == 'windows'
  library_name = 'rill.dll'
  cli_name = 'rill.exe'
  shared_flags = '/DLL /DEF:' + join_paths(source_root, 'csrc/rill.def') + \
    ' /IMPLIB:' + join_paths(build_root, 'rill.lib') + ' msvcrt.lib'
  shared_defines = ['-Dwithout_main']
  js_system_libs = []
elif host_system == 'darwin'
  library_name = 'librill.dylib'
  cli_name = 'rill'
  shared_flags = '-dynamiclib'
  shared_defines = []
  js_system_libs = ['-lm']
else
  library_name = 'librill.so'
  cli_name = 'rill'
  shared_flags = '-shared'
  shared_defines = []
  js_system_libs = ['-lm', '-ldl', '-lpthread']
endif

js_link_flags = ' '.join([rill_js.full_path()] + js_system_libs)
library_link_flags = ' '.join([shared_flags, rill_js.full_path()] + js_system_libs)

librill = custom_target(
  'librill',
  input: rill_sources + files('shard.yml'),
  output: library_name,
  command: [
    crystal,
    'build',
    '--single-module',
  ] + shared_defines + [
    '--link-flags', library_link_flags,
    '-o', '@OUTPUT@',
    join_paths(source_root, 'src/c_api.cr'),
  ],
  build_by_default: true,
  depends: rill_js,
  install: true,
  install_dir: get_option('libdir'),
)

rill = custom_target(
  'rill',
  input: rill_sources + files('shard.yml'),
  output: cli_name,
  command: [
    crystal,
    'build',
    '--link-flags', js_link_flags,
    '-o', '@OUTPUT@',
    join_paths(source_root, 'src/cli.cr'),
  ],
  build_by_default: true,
  depends: rill_js,
  install: true,
  install_dir: get_option('bindir'),
)

install_headers('include/rill.h')
install_data(
  'bindings/cpp/rill.hpp',
  install_dir: join_paths(get_option('includedir'), 'rill'),
)
install_data(
  'README.md',
  'LICENSE',
  'NOTICE',
  install_dir: join_paths(get_option('datadir'), 'doc', 'rill'),
)

test_env = [
  'RILL_MEDIA_HELPER=' + join_paths(build_root, 'rill-media'),
]

test(
  'crystal',
  crystal,
  args: ['spec', '--link-flags', js_link_flags],
  workdir: source_root,
  env: test_env,
  timeout: 600,
)

if host_system == 'linux'
  test(
    'bindings',
    find_program('test/meson_bindings.sh'),
    args: [build_root, source_root],
    workdir: source_root,
    env: test_env,
    timeout: 900,
  )
endif

if host_system != 'windows'
  test(
    'targets',
    find_program('test/meson_targets.sh'),
    args: [source_root],
    workdir: source_root,
    timeout: 600,
  )
endif
