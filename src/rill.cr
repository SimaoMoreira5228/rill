require "uri"

require "./rill/version"
require "./rill/errors"
require "./rill/request_options"
require "./rill/http_client"
require "./rill/format"
require "./rill/mime_type"
require "./rill/segment_assembly"
require "./rill/media"
require "./rill/extractor"
require "./rill/playlist"
require "./rill/extractors/dash"
require "./rill/extractors/direct_media"
require "./rill/extractors/hls"
require "./rill/extractors/internet_archive"
require "./rill/extractors/m3u"
require "./rill/extractors/media_ccc_de"
require "./rill/extractors/peer_tube"
require "./rill/extractors/spotify"
require "./rill/extractors/youtube"
require "./rill/extractor_registry"
require "./rill/format_selector"
require "./rill/cancellation"
require "./rill/cookie_jar"
require "./rill/download_progress"
require "./rill/output_file_name"
require "./rill/download_plan"
require "./rill/downloader"
require "./rill/client"
require "./rill/media_muxer"

module Rill
  def self.extract(url : String | URI, options : RequestOptions = RequestOptions.new) : Media | Playlist
    ExtractorRegistry.default.extract(url, options)
  end
end
