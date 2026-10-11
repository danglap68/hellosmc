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

    # Returns the merchant name without the trailing TID marker, so the HKD can
    # be matched while the TID is read separately. "… GV-1" → "… GV".
    # A bare space-separated number is NOT stripped here (it may be part of the
    # merchant name, e.g. "CƯỜNG DUYÊN 1"); the evaluator resolves that case.
    def strip(text)
      raw = text.to_s
      return raw if raw.blank?

      raw = raw.sub(/\s*[-–]\s*\d+\s*\z/, "")
      raw.sub(/\s*\(?\s*(?:tid|terminal)\s*[:#-]?\s*\d+\s*\)?\s*\z/i, "").strip
    end
  end
end
