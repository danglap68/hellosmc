module BillAlbums
  # A close-up of one settlement is the primary source when the same receipt
  # also appears beside other receipts. Different settlements remain separate.
  class SettlementPreference
    Entry = Data.define(:image, :document)
    Pair = Data.define(:preferred, :secondary)
    IDENTITY_FIELDS = %w[merchant_id dealer_id card_type_id lot_number transaction_at transaction_amount_vnd].freeze

    attr_reader :pairs

    def self.call(album)
      new(album)
    end

    def initialize(album)
      @album = album
      entries = album.bill_images.analyzable.where(ocr_status: %w[completed needs_review]).order(:id).flat_map do |image|
        image.documents.filter_map do |document|
          Entry.new(image: image, document: document) if document["document_type"] == "settlement" && document["total_amount_vnd"].present?
        end
      end
      singles = entries.select { |entry| standalone?(entry) }
      @pairs = entries.reject { |entry| entry.image.documents.size == 1 }.filter_map do |entry|
        matches = singles.select { |single| same_receipt?(single.document, entry.document) }
        Pair.new(preferred: matches.sole, secondary: entry) if matches.one?
      end
    end

    def suppressed?(image, document)
      pairs.any? { |pair| pair.secondary.image.id == image.id && pair.secondary.document["index"] == document["index"] }
    end

    def already_represented?(image, document)
      return false unless pairs.any? { |pair| pair.preferred.image.id == image.id && pair.preferred.document["index"] == document["index"] }

      @album.transactions.where.not(bill_image_id: image.id).where(status: "approved")
        .where("source_data->>'preferred_bill_image_id' = ?", image.id.to_s)
        .where("source_data->>'preferred_document_index' = ?", document["index"].to_s)
        .any? { |row| same_accounting_identity?(row, Entry.new(image: image, document: document)) }
    end

    def metadata
      pairs.map do |pair|
        { "image_id" => pair.preferred.image.id, "source_index" => pair.preferred.document["index"],
          "secondary_image_id" => pair.secondary.image.id, "secondary_source_index" => pair.secondary.document["index"] }
      end
    end

    # The reconciler holds the album lock. Lock every existing row before
    # selecting a canonical record or retiring an unbooked duplicate.
    def apply_existing!
      rows = @album.transactions.order(:id).lock.to_a
      assignments = pairs.map do |pair|
        primary = row_for(rows, pair.preferred)
        secondary = row_for(rows, pair.secondary)
        canonical = [ primary, secondary ].compact.find(&:booked?) || [ primary, secondary ].compact.find(&:approved?)
        [ pair, primary, secondary, canonical ]
      end
      conflicts = assignments.group_by { |pair, _primary, _secondary, _canonical| [ pair.preferred.image.id, pair.preferred.document["index"] ] }
        .filter_map do |_identity, group|
        pair = group.first.first
        protected = group.flat_map { |_pair, primary, secondary, _canonical| [ primary, secondary ] }.compact.uniq.select { |row| protected?(row) }
        canonical = protected.find(&:booked?) || protected.find(&:approved?)
        group.each { |assignment| assignment[3] = canonical }
        if protected.size > 1 || (canonical && !same_accounting_identity?(canonical, pair.preferred)) ||
            protected.any? { |row| row != canonical }
          { "image_id" => pair.preferred.image.id, "transaction_ids" => protected.map(&:id) }
        end
      end
      return conflicts if conflicts.any?

      assignments.each do |pair, primary, secondary, canonical|
        if canonical
          prefer_evidence(canonical, pair.preferred)
          ([ primary, secondary ].compact - [ canonical ]).each { |row| retire(row, canonical.id, pair.preferred) }
        else
          retire(secondary, primary&.id, pair.preferred) if secondary
          reopen(primary) if primary&.status.in?(%w[needs_review failed])
        end
      end
      []
    end

    private

    def standalone?(entry)
      entry.image.documents.size == 1 && %w[document_type total_amount_vnd].all? do |field|
        entry.document.dig("confidence", field).to_f >= AppConfig.ocr_auto_approve_threshold
      end
    end

    def same_receipt?(single, mixed)
      name = VietnameseText.normalize(single["merchant_name"])
      return false if name.blank? || name != VietnameseText.normalize(mixed["merchant_name"])
      return false if single["transaction_at"].blank? || single["transaction_at"] != mixed["transaction_at"]
      return false if single["bill_bank_name"].present? && mixed["bill_bank_name"].present? &&
        VietnameseText.normalize(single["bill_bank_name"]) != VietnameseText.normalize(mixed["bill_bank_name"])
      return false if single["lot_number"].present? && mixed["lot_number"].present? && single["lot_number"] != mixed["lot_number"]

      true
    end

    def row_for(rows, entry)
      rows.find { |row| row.bill_image_id == entry.image.id && row.extraction.fetch("index", row.source_index) == entry.document["index"] }
    end

    def protected?(row)
      row.booked? || row.status.in?(%w[approved hold rejected]) || row.approved_by_id.present? ||
        row.reviews.where.not(reviewed_by_id: nil).exists? ||
        row.audit_logs.where(actor_type: "User", action: "transaction.corrected").exists?
    end

    def same_accounting_identity?(row, entry)
      evaluation = Transactions::Evaluator.call(document: entry.document, bill_image: entry.image)
      candidate = Transaction.new(evaluation.attributes)
      IDENTITY_FIELDS.all? { |field| row.public_send(field) == candidate.public_send(field) }
    end

    def prefer_evidence(row, entry)
      return if row.bill_image_id == entry.image.id || row.source_data["preferred_bill_image_id"] == entry.image.id

      before = row.source_data.slice("preferred_bill_image_id", "preferred_document_index")
      evidence = { "preferred_bill_image_id" => entry.image.id, "preferred_document_index" => entry.document["index"] }
      row.update!(source_data: row.source_data.merge(evidence))
      AuditLogger.log!(action: "transaction.evidence_prioritized", auditable: row, before_data: before,
                       after_data: evidence, metadata: { "trigger" => "album_standalone_settlement", "original_bill_image_id" => row.bill_image_id })
    end

    def retire(row, canonical_id, entry)
      return if row.excluded?

      before = row.audit_snapshot.merge("review_reasons" => row.review_reason_codes)
      row.transition_to!("processing") unless row.processing?
      row.assign_attributes(Transactions::Recalculator.blank_calculation.merge(fee_rule: nil))
      row.source_data = row.source_data.merge("review_reasons" => [], "possible_duplicate_ids" => [],
        "excluded_reason" => "album_duplicate", "canonical_transaction_id" => canonical_id,
        "preferred_bill_image_id" => entry.image.id)
      row.transition_to!("excluded")
      row.reviews.open.update_all(status: "superseded", updated_at: Time.current)
      AuditLogger.log!(action: "transaction.album_duplicate_excluded", auditable: row, before_data: before,
                       after_data: row.audit_snapshot, metadata: { "canonical_transaction_id" => canonical_id, "preferred_bill_image_id" => entry.image.id })
    end

    def reopen(row)
      before = row.audit_snapshot
      row.source_data = row.source_data.merge("review_reasons" => [], "possible_duplicate_ids" => [])
      row.transition_to!("processing")
      row.reviews.open.update_all(status: "superseded", updated_at: Time.current)
      AuditLogger.log!(action: "transaction.reprocess_requested", auditable: row, before_data: before,
                       after_data: row.audit_snapshot, metadata: { "trigger" => "album_standalone_settlement", "mode" => "rebuild" })
    end
  end
end
