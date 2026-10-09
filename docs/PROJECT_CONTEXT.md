# SMC — Project context

Background, business rules and the decisions taken while building the MVP. Read this before changing
resolution, calculation or export behaviour.

## Problem

SMC receives settlement-bill photos in Telegram groups (one group per dealer). Staff read each bill —
total, settlement date/time, lot number, merchant (HKD), card type, applicable fee — and type the values
into accounting Excel files. SMC automates that, keeps the original evidence, and leaves a full audit trail.

## Business rules (as implemented)

1. **Only settlement bills matter.** Labels such as SETTLEMENT / KẾT TOÁN / TOTAL / TỔNG. Child receipts
   (individual sale slips) are skipped when the model is confident; otherwise a human decides.
2. **One settlement = one transaction.** An image with two settlements produces two transactions
   (`transactions.source_index`). Daily totals aggregate later (Excel *Tổng hợp* sheet).
3. **Dealer ≠ merchant.** Dealers/groups (Anh Trân, Cường Duyên, Cherry, BMW) own several merchants/HKDs
   (001_ HỘ KINH DOANH THIÊN KIM GV, Cường Duyên 1, Cường Duyên 2, Trân 3).
4. **Dealer comes from configuration only**: Telegram chat → dealer mapping (or the dealer chosen on a manual
   upload). Never inferred from OCR. Unmapped chat → review.
5. **Merchants are never created from OCR.** Resolution order: MID/TID alias → exact receipt-name alias →
   normalized name (diacritics, numeric code prefix and legal form like "HỘ KINH DOANH" removed) → fuzzy
   *suggestion* (always reviewed). A merchant that belongs to a different dealer than the chat → review.
6. **Card type**: explicit Telegram tag (MB, Napas) → merchant default → dealer default → `normal`.
   Conflicting tags → review.
7. **Fee resolution** (`FeeRules::Resolver`), most specific first: merchant+card type, dealer+card type,
   merchant, dealer, card type only, system default. Inside a level the lowest `priority` number wins.
   Equal specificity and priority → review. The fee-rule form refuses overlapping rules with the same
   targeting and priority, so ambiguity is mostly prevented at configuration time.
8. **No hard-coded fees.** Observed values (0.88%, 1.10%, 1.25%, and 1.21/1.17/1.15/1.40% from the workflow)
   are only demo seeds.
9. **Snapshots.** Each transaction stores the applied rate(s), the fee rule id and a copy of the rule in
   `calculation_data`. Later rule changes never alter booked transactions.
10. **Calculation** in Ruby only: `amount_after_base_fee = amount × (1 − base_fee_rate)`, BigDecimal,
    rounded half-up to whole VND. Example: 10,000 × (1 − 0.0088) = 9,912.
    `base_fee_rate` here is the rate used in the formula: normally the winning rule's `base_fee_rate`,
    but a household rule that lists the card uses its `card_base_fee_rate`, and a household rule that
    does not list the card borrows another rule that does (stored in `applied_card_base_fee_rate`; see
    `docs/SPEC_TINH_PHI_THEO_THE.md`). `applied_base_fee_rate` always stays the winning rule's rate.
11. **Fail safe.** Low confidence, missing values, ambiguity or possible duplicates go to review.
    False positives are worse than review.

## Decisions taken without customer confirmation

| Topic | Decision | Where to change |
|---|---|---|
| Dealer rate meaning | If a rule has `dealer_rate`: `dealer_amount = amount × (1 − dealer_rate)`, `profit = amount_after_base_fee − dealer_amount`. Shown and stored, not exported. The `dealer_rate` comes from the same rule that supplied the formula rate (`FeeRules::Resolver.amount_dealer_rate`). | `Transactions::Calculator` |
| Priority direction | Lower number = higher precedence. | `FeeRules::Resolver` |
| New Telegram groups | Registered inactive; images are stored but not processed until mapped and activated, then processed on demand from the group page. The admin setting "Tự động kích hoạt nhóm Telegram mới" changes this. | `Telegram::UpdateReceiver` |
| Edited Telegram messages | The new text replaces `message_text` (original kept in `raw_payload` + audit). Bills not yet built use it. If the card-type tags changed, already-built transactions go back to a human (approved/exported → hold, reason `caption_edited`); nothing is re-booked automatically. | `Telegram::UpdateReceiver#handle_edit`, `Transactions::Flagger` |
| Deleted Telegram messages | Not observable through the Bot API; nothing happens. | — |
| Bill hold in exports | Listed with status `bill hold`; excluded from the success totals, shown separately. | `Exports::LegacyLayout`, `ExcelGenerator#totals` |
| Daily cutoff | Calendar day in Asia/Ho_Chi_Minh by transaction (settlement) time. | `Exports::ExcelGenerator#scope` |
| Old/future receipts | Older than the "maximum receipt age" setting (default 45 days) or more than 1 hour in the future → review. | `Transactions::Evaluator` |
| Approved → corrections | Approved/exported transactions must be put on hold before editing. Approval recomputes amounts from the rate snapshotted at processing time; the fee rule is re-resolved only when merchant, dealer, card type or time is corrected, when a reviewer picks a rule, or when no rate was ever applied. | `Transaction::EDITABLE_STATUSES`, `Transactions::Recalculator` |
| Reprocessing multi-settlement images | Re-read documents are matched to rows by content (amount, time, lot, merchant); settlements that already have a decided row are not booked twice; new settlements and every rebuilt row of a multi-settlement image go to review. | `Transactions::Builder#rebuild` |
| Concurrency | Status changes lock the row and re-check its status; review forms carry `lock_version` (optimistic locking); exports lock the rows they write; concurrent builds of the same merchant + amount are serialized for duplicate detection. | services in `app/services/transactions` |
| Duplicates | Hard: same chat+message, same Telegram file, same SHA256, same image+settlement index. Possible: same merchant+amount within 10 minutes, or same lot same day. | `Transactions::DuplicateDetector` |

## Open questions for the customer

- Exact meaning of some legacy Excel columns, and whether the unnamed last column is dealer, person or group.
- The complete fee matrix, and what 1.21 / 1.17 / 1.15 / 1.40% apply to.
- Whether bill hold participates in totals.
- Final daily cutoff time (midnight vs. end of shift).
- Handling of edited/deleted Telegram messages.
- Whether production should also update a Google Sheet directly.
- The exact Excel template to reproduce (styles, sheet names, extra columns).

All of these are configuration or isolated code changes; none require a schema rewrite.

## Language convention

- Code, schema, logs, tests, technical docs: English.
- Everything a user sees: Vietnamese, through `config/locales/vi.yml`. Enum values stay English in the database
  (`needs_review`) and are translated for display ("Cần kiểm tra").
- Raw OCR text and legacy Excel headers are kept exactly as they are.
