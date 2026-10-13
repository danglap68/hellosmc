# Public board of transfer codes (merchant_dealers.transfer_code).
# These are the same rows RemitterTransfers::Codes resolves when someone
# sends TK01. Only active rows are listed: an inactive row is rejected by
# Codes.merchant_dealer_for, so it is not offered for copying.
class RunnerCodesController < ApplicationController
  layout "codes"

  # Restrained household swatches. The index is a pure function of the HKD id
  # so a household keeps its color across boots (Ruby Hash#hash does not).
  TONE_COUNT = 8

  def index
    @query = params[:q].to_s
    @group = params[:nhom].to_s == "hkd" ? "hkd" : "person"
    links = MerchantDealer.active.where.not(transfer_code: nil).includes(:merchant, :dealer).to_a
    @people = people_groups(links)
    @households = household_groups(links)
    active = @group == "hkd" ? @households : @people
    @any_visible = active.any? { |group| group[:cards].any? { |card| card[:visible] } }
  end

  private

  def people_groups(links)
    links.group_by(&:dealer).sort_by { |dealer, _dealer_links| [ VietnameseText.normalize(dealer.name), dealer.id ] }
      .map do |dealer, dealer_links|
        cards = dealer_links.sort_by { |link| [ hkd_rank(link.merchant.code), tid_number(link), link.transfer_code ] }
          .map { |link| card_for(link, secondary: hkd_name(link)) }
        { title: dealer.name, meta: nil, tone: nil, cards: cards }
      end
  end

  def household_groups(links)
    links.group_by(&:merchant).sort_by { |merchant, _merchant_links| [ hkd_rank(merchant.code), merchant.id ] }
      .map do |merchant, merchant_links|
        cards = merchant_links.sort_by { |link| [ tid_number(link), VietnameseText.normalize(link.dealer.name), link.transfer_code ] }
          .map { |link| card_for(link, secondary: link.dealer.name) }
        name = merchant_links.filter_map { |link| hkd_name(link).presence }.first || merchant.name
        { title: name, meta: merchant.code, tone: tone_for(merchant.id), cards: cards }
      end
  end

  def card_for(link, secondary:)
    search = search_text(link)
    {
      code: link.transfer_code,
      person: link.dealer.name,
      hkd_name: hkd_name(link),
      secondary: secondary,
      tid: link.tid_key,
      tone: tone_for(link.merchant_id),
      search: search,
      visible: normalized_query.blank? || search.include?(normalized_query)
    }
  end

  def search_text(link)
    digits = link.tid_key.to_s[/\d+/]
    VietnameseText.normalize([
      link.transfer_code, link.dealer.name, link.merchant.name, link.merchant.code,
      link.ds_sheet_anchor, link.tid_key, link.tid_label,
      ("tid #{digits}" if digits.present?)
    ].compact.join(" "))
  end

  def hkd_name(link)
    link.ds_sheet_anchor.to_s.sub(/\A\s*HKD\s+/i, "").strip.presence || link.merchant.name
  end

  def hkd_rank(code)
    @hkd_rank ||= Workbook::Seed::HKD.each_with_index.to_h { |attrs, index| [ attrs[:code], index ] }
    @hkd_rank.fetch(code, @hkd_rank.length)
  end

  def tid_number(link)
    link.tid_key.to_s[/\d+/].to_i
  end

  def normalized_query
    @normalized_query ||= VietnameseText.normalize(@query)
  end

  def tone_for(merchant_id)
    # A plain multiply folds away the high digit, so id 1 and id 9 would share
    # a swatch. This mix uses the whole id and stays stable across boots.
    mixed = (merchant_id.to_i * 0x9E3779B1 + 116 * 0x85ebca6b) & 0xffffffff
    mixed ^= (mixed >> 16)
    mixed = (mixed * 0xc2b2ae35) & 0xffffffff
    (mixed ^ (mixed >> 13)) % TONE_COUNT
  end
end
