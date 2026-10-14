# Telegram image download recovery

Production inspection on 14 October 2026 at 17:11 Vietnam time found 214 stale,
queued image messages with no stored BillImage, including 154 received that day.
These are a point-in-time count, not a fixed recovery target.

Worker logs showed DownloadTelegramAttachmentJob starting before the inbox
transaction committed a new TelegramMessage, raising RecordNotFound, and being
discarded. The inbox then committed with status `processed`; the message stayed
`queued`. Retrying the webhook inbox alone cannot recover these downloads.

The fix enables `enqueue_after_transaction_commit` on the download job. Tests
cover enqueueing after commit and not enqueueing after rollback.

After deploying the fix to both web and worker, run the preview inside the SMC
application container:

```sh
bundle exec rails hellosmc:retry_stuck_telegram_downloads
```

It only counts image messages from active chats that are still `queued`, have no
BillImage, and have not changed for at least five minutes. It does not download
images, call OCR, or write to Google Sheets.

Once recovery is authorized, enqueue those missing downloads:

```sh
APPLY=1 bundle exec rails hellosmc:retry_stuck_telegram_downloads
```

The existing pipeline downloads, deduplicates, performs OCR, and may automatically
approve transactions and write them to the configured sheet. Already stored
images, failed OCR runs, ignored messages, and inactive chats are skipped. Each
scheduled row is touched so repeating the command immediately does not queue it
again.

Verify worker logs show `telegram.attachment_stored` followed by OCR and transaction
or transfer processing. Re-run the preview after the queue drains. Inspect the
remaining queued messages and any download/OCR failures before retrying again.

The inspection did not trigger a deployment or run production recovery. A
deployment of commit `fbe836e` was triggered separately during local verification;
Coolify subsequently reported Success. The final UI refinements remain local.

## Authorized recovery on 14 October 2026

After the user requested recovery of all missed images from today, the running
production container was checked again: the commit-order fix was active and 155
image messages received today were queued without a BillImage. There were no
separate failed downloads from today. Recovery was limited to those 155 IDs;
older missed downloads were not included.

All 155 download jobs were enqueued. Fourteen associated albums had previously
failed with `waited too long for album OCR`. Once their images were downloaded
and OCR finished, each was reopened only after verifying it had no transactions
and no remaining download/OCR work. Each reopening was audited and its finalizer
was enqueued after the database commit.

Verified at 17:26 Vietnam time:

- 155 of 155 image messages have stored images; no missing or failed downloads.
- OCR: 98 completed, 53 requiring review, and 4 duplicate images; none failed or
  pending. OCR review counts refer to images, not accounting transactions.
- All 14 timed-out albums were finalized; no failed albums remain in the batch.
- 25 approved transactions have 25 WorkbookEntry records confirming sheet writes;
  6 transactions require review and 4 are excluded by existing business rules.
- 22 remitter transfers require review. Thirteen rejected transfer records are
  retained by the normal classification flow, including settlement handoffs.
- Telegram, OCR, default and export queues are empty; no busy or retrying jobs.
- Eighteen recovered messages still carry `queued`, but every one belongs to a
  finalized `skipped` / `no_transfer` album containing child receipts or unknown
  images. They have no outstanding download or OCR work. Their accounting
  classification and approval were not overridden.

The production recovery manifest is
`/tmp/smc-recovery-2026-10-14-today.json` inside the web container. A local copy is
stored in `tmp/recovery/2026-10-14-today-manifest.json` (ignored by Git).
