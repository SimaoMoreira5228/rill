require "file"
require "path"

require "../errors"

module Rill
  class Downloader
    LIVE_STALL_POLLS = 12

    private def publish_live_part(part_path : Path, target_path : Path, overwrite : Bool) : Nil
      return unless File.exists?(part_path)

      if File.size(part_path) == 0
        remove_part(part_path)
        return
      end

      publish(part_path, target_path, overwrite)
    rescue Rill::Error
      # Keep the part file when the final name is already taken.
    end

    private def truncate_part(part_path : Path, size : Int64) : Nil
      return unless File.exists?(part_path)
      return if File.size(part_path) <= size

      File.open(part_path, "r+b") do |file|
        file.truncate(size)
      end
    end
  end
end
