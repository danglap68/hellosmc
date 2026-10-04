# SMC — Settlement Bill Automation

Internal tool for SMC that turns settlement-bill photos posted in Telegram groups into
auditable accounting transactions:

```
Telegram photo (+ "MB"/"Napas" caption)
  → store message + image (Cloudflare R2, private)
  → vision OCR extracts facts only (amount, lot, date/time, merchant, MID/TID)
  → Ruby resolves dealer → merchant (HKD) → card type → fee rule
  → Ruby calculates amounts (BigDecimal, half-up to whole VND)
  → auto-approve, or send to the OCR review queue
  → Excel export in the legacy accounting layout
```

It is not an ERP. PostgreSQL is the source of truth; Excel is an output.

- Code, database, logs, tests: **English**. Admin UI: **100% Vietnamese** (Rails I18n, `config/locales/vi.yml`).
- Business context, decisions and open questions: [docs/PROJECT_CONTEXT.md](docs/PROJECT_CONTEXT.md).

## Architecture

| Layer | Where | Notes |
|---|---|---|
| Telegram ingestion | `app/services/telegram/*`, `bin/telegram_bot`, `Webhooks::TelegramController` | Normalize, persist, enqueue. No business logic. Polling locally, webhook in production; both call `Telegram::UpdateReceiver`. |
| Storage | Active Storage → R2 | Private bucket. Admin UI serves images via `Admin::BillImagesController` (auth required, 5-minute presigned URLs). Active Storage public routes are disabled. |
| OCR | `app/services/bill_vision/*` | `BillVision::Extractor.call(image:)`; providers `openai` (default), `gemini`, `fake` (offline). Strict JSON schema; output normalized by `BillVision::Normalizer`. Raw provider output is always kept. |
| Rule engine | `Dealers::Resolver`, `Merchants::Resolver`, `CardTypes::Resolver`, `FeeRules::Resolver` | Deterministic. Ambiguity never resolves silently. |
| Accounting | `Transactions::Calculator`, `Evaluator`, `Builder` | One settlement = one transaction (`bill_image_id + source_index` is unique). Applied rates are snapshotted. |
| Review | `Transactions::Corrector`, `Approver`, `StatusUpdater`, `Reprocessor` | Every correction recalculates and is audited (before/after). |
| Export | `Exports::ExcelGenerator`, `Exports::LegacyLayout` | Mapping layer keeps legacy headers out of the domain model. |
| Audit | `AuditLogger.log!` → `audit_logs` | Append-only; explicit calls, no blanket callbacks. |
| Jobs | Sidekiq: `ProcessTelegramUpdateJob`, `DownloadTelegramAttachmentJob`, `AnalyzeBillImageJob`, `BuildTransactionJob`, `GenerateDailyExcelJob`, `RetryFailedExtractionJob` | All idempotent. Transient errors retry; permanent errors are recorded and surfaced. |

### Transaction statuses

`pending → processing → approved | needs_review | failed`;
`needs_review → approved | rejected | hold | processing`;
`hold → approved | needs_review | rejected | processing`;
`approved → exported | hold`; `exported → hold`; `failed → processing | needs_review`; `rejected` is terminal.
Defined in `Transaction::TRANSITIONS`; anything else raises.

### When is a bill auto-approved?

All of these must hold, otherwise it goes to review with the reasons listed on the page:

- document is a settlement, and amount, merchant, date and time are present with confidence ≥ the
  auto-approve threshold (below the review threshold the field is flagged *unreadable*);
- the Telegram chat is mapped to an active dealer;
- the merchant matched exactly (MID/TID alias, receipt-name alias, or normalized name) and belongs to that dealer;
  fuzzy matches are only suggestions;
- exactly one card type (conflicting tags like "MB Napas" → review);
- exactly one applicable fee rule;
- no possible duplicate (same merchant + amount within the duplicate window, or same lot on the same day);
- transaction date is not in the future and not older than the maximum receipt age.

Thresholds, windows and the other knobs above are admin settings (see [Configuration](#configuration)).

Confident child receipts (individual sale slips) are skipped, per the customer's request.

Each transaction keeps the rate applied when it was processed. Approving later recomputes the amounts from
that snapshot; the fee rule is looked up again only if a reviewer changes merchant, dealer, card type or time,
or picks a rule explicitly.

### Roles

| | admin | operator | viewer |
|---|---|---|---|
| Dashboard, transactions (read), exports (download) | ✓ | ✓ | ✓ |
| Review queue, approve/hold/reject/edit/reprocess, manual upload, generate exports | ✓ | ✓ | |
| Configuration (dealers, Telegram groups, merchants, fee rules, card types) | manage | read | |
| Audit log | ✓ | ✓ | |
| Users, settings, Sidekiq UI | ✓ | | |

No public sign-up. Inactive users cannot sign in; accounts lock for 1 hour after 10 failed attempts.

## Prerequisites

- Ruby 3.4 (`.ruby-version`), Bundler
- PostgreSQL 17 (16+ works) and Redis 7+ — native or via `docker compose up -d`
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- An OpenAI API key (or Gemini) for OCR
- A Cloudflare R2 bucket (optional locally; disk storage works)

## Local setup

```bash
bundle install
cp .env.example .env            # fill in the keys you have; see "Configuration"
docker compose up -d            # or use your own PostgreSQL/Redis
bin/rails db:prepare            # create + migrate
SEED_ADMIN_PASSWORD='choose-a-long-password' bin/rails db:seed
```

Seeds create the card types (`normal`, `mb`, `napas`) and the first admin (`SEED_ADMIN_EMAIL`, default
`admin@example.com`). In development they also create demo dealers, merchants, a demo Telegram group and
**demo** fee rules (0.88% default, MB 1.10%, Napas 1.25%). Real rates are configured in the UI.

To see the full pipeline without Telegram or an OCR key:

```bash
bin/rails hellosmc:demo         # pushes spec/fixtures/bills through the real pipeline with the offline provider
```

### Run

```bash
bin/dev                         # web + Sidekiq + Telegram poller (Procfile.dev, uses foreman)
```

or separately:

```bash
bin/rails server                          # http://localhost:3000
bundle exec sidekiq -C config/sidekiq.yml # background jobs (queues: telegram, ocr, default, exports)
bin/telegram_bot                          # Telegram long polling (local development only)
```

Sign in at `/users/sign_in`. Sidekiq UI: `/admin/sidekiq` (admins). Health: `/health`.

In development, emails (e.g. password resets) are not sent: each one opens in a new browser tab
(letter_opener) and all of them are listed at `/letter_opener`. To send them for real through Resend,
fill `SMTP_*` in `.env` and swap the two email blocks in `config/environments/development.rb`.

### Telegram bot setup

1. Create a bot with @BotFather, put the token in `TELEGRAM_BOT_TOKEN`.
2. In @BotFather run `/setprivacy` → **Disable**, so the bot receives photos in groups.
3. Add the bot to a dealer's group and post anything. The group appears under **Nhóm Telegram**,
   registered as *inactive* (unless **Cài đặt → Telegram → Tự động kích hoạt nhóm mới** is on).
4. Map the group to its dealer and activate it. From then on, photos are processed.
   Photos posted while a group was inactive are stored; process them from the group page
   (**Xử lý các ảnh này**) once it is mapped and active.
5. If a webhook was registered earlier, polling fails with a conflict; run `bin/rails telegram:delete_webhook`.

Card type tags are read from the photo caption (or the album's caption). Matching is whole-word and
ignores case and diacritics; tags are configurable per card type under **Loại thẻ**.

### Vision provider setup

Put `OPENAI_API_KEY` (and/or `GEMINI_API_KEY`) in the environment, then choose the provider and model under
**Cài đặt → Đọc bill (OCR)** (defaults: OpenAI, `gpt-4.1`). The page refuses a provider whose key is missing.

Check OCR quality on real bills before relying on auto-approval (nothing is saved):

```bash
bin/rails 'hellosmc:ocr[path/to/bill.jpg]'
```

The prompt and JSON schema live in `app/services/bill_vision/prompt.rb`.

### Cloudflare R2 setup

1. Create a bucket and keep it **private** (no public access, no custom public domain).
2. Create an R2 API token with *Object Read & Write* on that bucket.
3. Set `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`,
   `R2_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com`.
4. Check the credentials: **Cài đặt → Kiểm tra kết nối R2**, or `bin/rails hellosmc:check_r2`. Both write, read,
   fetch through a presigned URL and delete a test object under `healthchecks/`, and name the failing step.

Production always stores on R2; development uses R2 as soon as `R2_BUCKET` is set, local disk otherwise.
Bill images are stored under `bills/YYYY/MM/DD/`, exports under `exports/YYYY/MM/`. The app refuses to boot
when R2 is used but incomplete. Using R2 in development early is recommended so production behaviour is exercised.

## Configuration

Two places, on purpose:

**Environment** ([.env.example](.env.example)) holds only secrets of external services and the infrastructure
needed before the app can reach its database:

| Variable | Purpose |
|---|---|
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET` | Telegram bot; webhook secret is required in production |
| `OPENAI_API_KEY`, `GEMINI_API_KEY` | OCR providers |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, `R2_ENDPOINT` | Image storage |
| `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` | Password-reset emails, e.g. Resend (`smtp.resend.com`, user `resend`, password = API key). Required in production; in development only used when real sending is switched on in `config/environments/development.rb`. |
| `DATABASE_URL`, `REDIS_URL`, `SECRET_KEY_BASE` (`bin/rails secret`), `APP_HOST` | Infrastructure (production). Development/test use the local PostgreSQL socket; optional `DB_HOST`/`DB_PORT`/`DB_USERNAME`/`DB_PASSWORD` override it (see `docker-compose.yml`). |

**Admin settings** (**Cài đặt**, admins only, stored in `app_settings`, every change audited, applied within
30 seconds by web and workers):

| Setting | Default |
|---|---|
| OCR provider / OpenAI model / Gemini model | OpenAI / `gpt-4.1` / `gemini-2.5-flash` |
| Auto-approve threshold / minimum readable threshold | 92% / 70% |
| OCR timeout / maximum OCR runs per bill | 60 s / 3 |
| Fuzzy merchant suggestion threshold | 88% |
| Duplicate window / maximum receipt age | 10 min / 45 days |
| Auto-activate new Telegram groups | off |
| Maximum image size | 20 MB |
| Email sender | `no-reply@hellosmc.local` |

The settings page also shows which secrets are configured (never their values). The business timezone is fixed
to Asia/Ho_Chi_Minh; timestamps are stored in UTC. Definitions live in `app/models/app_setting.rb`.

## Tests

```bash
bundle exec rspec
```

Models, services (resolvers, calculator, duplicate detector, builder, normalizer, providers via WebMock,
Telegram receiver/downloader, Excel generator), jobs, request specs (auth, roles, webhook, every admin page)
and system specs (OCR review, fee rules, approval → export). The suite never calls a paid API: OCR is stubbed
with JSON fixtures in `spec/fixtures/extractions/`; sample images are in `spec/fixtures/bills/`.

Also available: `bin/rubocop`, `bin/brakeman`.

## Excel export

**Xuất Excel → Tạo file Excel**, pick a date range (by transaction date, Vietnam time). The workbook has:

- sheet *Giao dịch* with the legacy columns: `Tên Đại lý` (holds the HKD name, as in the current file),
  `Số tiền sau khi trừ phí gốc`, `Số tiền giao dịch`, `Phí gốc` (rate, e.g. 0.0088), `Ngày giao dịch`,
  `Trạng thái`, and an unnamed last column with the dealer;
- sheet *Tổng hợp* with totals per dealer.

Approved and exported transactions are written as `Thành công`, held ones as `bill hold`. Approved
transactions become `exported`. Change the mapping in `app/services/exports/legacy_layout.rb`.

Scheduled daily export (yesterday): `bin/rails hellosmc:export_daily` from cron.

## Production notes

Target: one VPS (2 vCPU / 4 GB / 40 GB) — OCR runs on an external API, images live on R2.

Processes (see `Procfile`):

- **web** — Puma behind Thruster (`bundle exec thrust ./bin/rails server`); also receives the Telegram webhook
- **worker** — `bundle exec sidekiq -C config/sidekiq.yml`
- PostgreSQL and Redis, local or managed

`docker-compose.production.yml` is a working single-VPS example (web, worker, postgres, redis). Put a TLS
reverse proxy in front of it. `RAILS_FORCE_SSL` / `RAILS_ASSUME_SSL` default to `true`; `/health` is exempt
from the HTTPS redirect.

Switching Telegram to webhook mode:

```bash
TELEGRAM_WEBHOOK_SECRET=$(openssl rand -hex 32)     # required in production
bin/rails 'telegram:set_webhook[https://your-host/webhooks/telegram]'
bin/rails telegram:webhook_info
```

Do not run `bin/telegram_bot` in production; the webhook replaces it.

The webhook verifies `X-Telegram-Bot-Api-Secret-Token`, enqueues the update and returns 200 immediately.

Recommended cron jobs:

```
5 0 * * *    cd /app && bin/rails hellosmc:export_daily
*/15 * * * * cd /app && bin/rails hellosmc:retry_failed_extractions
```

Logs are one JSON line per business event (`telegram.update_received`, `ocr.request`, `ocr.result`,
`transaction.built`, `transaction.review_decision`, `export.generated`, …) with `telegram_chat_id`,
`telegram_message_id`, `bill_image_id`, `transaction_id`, `job_id`. Secrets are never logged; the bot token is
scrubbed from Telegram errors.

Back up PostgreSQL daily. R2 holds the original images; keep object versioning or lifecycle rules in mind
before deleting anything.
