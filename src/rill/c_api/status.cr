module Rill::CAPI
  ABI_VERSION = 2

  module Status
    OK               = 0
    EXTRACTION_ERROR = 1
    INTERNAL_ERROR   = 2
    INVALID_ARGUMENT = 3
    SHUTDOWN         = 4
    CANCELLED        = 5
  end

  module Kind
    EXTRACTION = 0
    DOWNLOAD   = 1
  end

  module DownloadState
    QUEUED    = 0
    RUNNING   = 1
    COMPLETED = 2
    FAILED    = 3
    CANCELLED = 4
  end
end
