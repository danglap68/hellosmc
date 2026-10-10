module Workbook
  # Pulls a terminal id off an OCR merchant name or a DS MB header.
  # "HỘ KINH DOANH THIÊN KIM GV-1" → tid1. "TID 127" → tid127.
  module TidParser
    module_function

    def call(text)
      normalize(text)
    end

    def normalize(text)
      raw = text.to_s
      return nil if raw.blank?

      if (match = raw.match(/(?:tid|terminal)\s*[:#-]?\s*(\d+)/i))
        return "tid#{match[1].to_i}"
      end
      if (match = raw.match(/[-–]\s*(\d+)\s*\z/))
        return "tid#{match[1].to_i}"
      end
      if (match = raw.match(/\btid\s*(\d+)\b/i))
        return "tid#{match[1].to_i}"
      end

      nil
    end
  end
end
