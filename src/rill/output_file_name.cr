require "path"

require "./errors"

module Rill::OutputFileName
  extend self

  MAX_BYTES = 180

  INVALID_CHARACTERS      = /[<>:"\/\\|?*\x00-\x1f]/
  LEADING_DOTS_OR_SPACES  = /\A[.\s]+/
  TRAILING_DOTS_OR_SPACES = /[.\s]+\z/
  WHITESPACE              = /\s+/
  VALID_EXTENSION         = /\A[a-z0-9]+\z/

  RESERVED_NAMES = %w(
    con prn aux nul
    com1 com2 com3 com4 com5 com6 com7 com8 com9
    lpt1 lpt2 lpt3 lpt4 lpt5 lpt6 lpt7 lpt8 lpt9
  )

  def from_title(title : String, extension : String? = nil) : String
    extension = normalize_extension(extension)
    limit = MAX_BYTES - (extension ? extension.bytesize + 1 : 0)
    base = sanitize(title, limit)

    if extension && !base.downcase.ends_with?(".#{extension}")
      base = "#{base}.#{extension}"
    end

    reserved_name?(base) ? "_#{base}" : base
  end

  def resolve(directory : String | Path, title : String, extension : String? = nil) : Path
    resolve_path(directory, from_title(title, extension))
  end

  def resolve_path(directory : String | Path, file_name : String) : Path
    dir = Path.new(directory.to_s).expand
    target = (dir / file_name).expand

    unless target.parent == dir
      raise InvalidOutputPathError.new(target.to_s, dir.to_s)
    end

    target
  end

  private def sanitize(title : String, limit : Int32) : String
    value = title.gsub(INVALID_CHARACTERS, "_")
    value = value.gsub(WHITESPACE, " ")
    value = value.sub(LEADING_DOTS_OR_SPACES, "")
    value = value.sub(TRAILING_DOTS_OR_SPACES, "")
    value = truncate(value, limit)
    value = value.sub(TRAILING_DOTS_OR_SPACES, "")
    value.empty? ? "download" : value
  end

  private def truncate(value : String, limit : Int32) : String
    return value if value.bytesize <= limit

    builder = String::Builder.new
    bytes = 0

    value.each_char do |char|
      size = char.bytesize
      break if bytes + size > limit

      builder << char
      bytes += size
    end

    builder.to_s
  end

  private def normalize_extension(extension : String?) : String?
    return nil unless extension

    value = extension.lchop('.').downcase
    return nil if value.empty?
    return nil if value.bytesize > 16
    return nil unless VALID_EXTENSION.matches?(value)

    value
  end

  private def reserved_name?(value : String) : Bool
    base = value.split('.').first? || value
    RESERVED_NAMES.includes?(base.downcase)
  end
end
