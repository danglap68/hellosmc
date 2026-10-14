module RemitterTransfers
  # Caption and visible bank-transfer memo are separate factual sources. Only
  # configured codes are matched; conflicting sources always need a person.
  module CodeResolver
    Result = Data.define(:code, :source, :issue)
    module_function

    def call(caption:, image:)
      caption_match = CodeMatcher.call(caption)
      documents = image.documents.select { |doc| doc["document_type"] == "transfer" && doc["transfer_memo"].present? }
      image_match = CodeMatcher.call(documents.map { |doc| doc["transfer_memo"] }.join("\n"), strict: true)
      if caption_match.issue == "code_ambiguous" || image_match.issue == "code_ambiguous"
        return Result.new(code: nil, source: nil, issue: "code_ambiguous")
      end
      if caption_match.found?
        if image_match.found? && Codes.canonical(caption_match.code) != Codes.canonical(image_match.code)
          return Result.new(code: nil, source: nil, issue: "code_conflict")
        end
        return Result.new(code: caption_match.code, source: "caption", issue: nil)
      end
      return Result.new(code: nil, source: nil, issue: "code_missing") unless image_match.found?
      if conflicting_unconfigured_code?(caption, image_match.code)
        return Result.new(code: nil, source: nil, issue: "code_conflict")
      end

      issue = if documents.any? { |doc| Array(doc["vision_review_reasons"]).include?("model_disagreement") }
        "code_ocr_disagreement"
      elsif documents.any? { |doc| doc["transfer_memo_confidence"].to_f < AppConfig.ocr_auto_approve_threshold }
        "code_low_confidence"
      end
      Result.new(code: image_match.code, source: "image", issue: issue)
    end

    def conflicting_unconfigured_code?(caption, image_code)
      prefixes = Codes.codes.filter_map { |code| Codes.canonical(code)&.sub(/\d+\z/, "") }.uniq
      text = VietnameseText.strip_diacritics(caption).upcase
      text.scan(/\b([A-Z]+)\s*(\d+)\b/).any? do |letters, digits|
        prefixes.include?(letters) && Codes.canonical("#{letters}#{digits}") != Codes.canonical(image_code)
      end
    end
  end
end
