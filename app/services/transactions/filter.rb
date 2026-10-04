module Transactions
  # Search and filters for the transaction list.
  class Filter
    KEYS = %i[q dealer_id merchant_id status card_type_id date_from date_to amount_min amount_max telegram_chat_id].freeze

    def initialize(params)
      raw = params.respond_to?(:permit) ? params.permit(*KEYS).to_h : params.to_h
      @values = raw.symbolize_keys.slice(*KEYS).transform_values { |value| value.to_s.strip }.compact_blank
    end

    def [](key)
      @values[key]
    end

    def active?
      @values.any?
    end

    def to_h
      @values
    end

    def apply(scope = Transaction.all)
      scope = scope.where(dealer_id: self[:dealer_id]) if self[:dealer_id]
      scope = scope.where(merchant_id: self[:merchant_id]) if self[:merchant_id]
      scope = scope.where(card_type_id: self[:card_type_id]) if self[:card_type_id]
      scope = scope.where(status: self[:status]) if self[:status].in?(Transaction::STATUSES)
      scope = apply_dates(scope)
      scope = apply_amounts(scope)
      if self[:telegram_chat_id]
        scope = scope.joins(:telegram_message).where(telegram_messages: { telegram_chat_id: self[:telegram_chat_id] })
      end
      apply_search(scope)
    end

    private

    def apply_dates(scope)
      from = parse_date(self[:date_from])
      to = parse_date(self[:date_to])
      scope = scope.where(transaction_at: Time.zone.local(from.year, from.month, from.day)..) if from
      scope = scope.where(transaction_at: ..Time.zone.local(to.year, to.month, to.day).end_of_day) if to
      scope
    end

    def apply_amounts(scope)
      min = parse_amount(self[:amount_min])
      max = parse_amount(self[:amount_max])
      scope = scope.where(transaction_amount_vnd: min..) if min
      scope = scope.where(transaction_amount_vnd: ..max) if max
      scope
    end

    def apply_search(scope)
      query = self[:q]
      return scope if query.blank?

      like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      conditions = scope.left_joins(:merchant).where(
        "merchants.name ILIKE :like OR transactions.lot_number ILIKE :like " \
        "OR transactions.source_data #>> '{extraction,merchant_name}' ILIKE :like",
        like: like
      )
      return conditions unless query.match?(/\A\d+\z/) && query.length <= 12

      conditions.or(scope.left_joins(:merchant).where(id: query.to_i))
    end

    def parse_date(value)
      Date.iso8601(value) if value.present?
    rescue Date::Error
      nil
    end

    def parse_amount(value)
      digits = value.to_s.gsub(/\D/, "")
      digits.present? ? digits.to_i : nil
    end
  end
end
