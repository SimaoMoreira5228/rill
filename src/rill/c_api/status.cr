module Rill::CAPI
  ABI_VERSION = 1

  module Status
    OK               = 0
    EXTRACTION_ERROR = 1
    INTERNAL_ERROR   = 2
    INVALID_ARGUMENT = 3
    SHUTDOWN         = 4
  end
end
