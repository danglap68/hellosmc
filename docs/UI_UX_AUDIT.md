# SMC operational UI audit — 2026-10-15

The interface should help staff identify a record, understand its state and perform a relevant
accounting action. A control must have a clear effect in that workflow. Tables are not automatically
selectable or exportable merely because they contain rows.

## Changes

| Finding | Result |
| --- | --- |
| A shared controller injected selection, CSV export and batch controls into every table, including service configuration and history. | Removed the frontend controller, CSV module, templates, import-map entry, helper and all 32 table hooks across 25 views. |
| General settings repeated the card-types management section. | Removed that summary and its query. The dedicated fees/card-types section retains management actions. |
| Empty dashboard queues looked like work waiting to be processed. | Show positive queues and a completed empty state when none remain. |
| Pinned pages appeared twice; an empty pin section consumed navigation space. | Show pinned pages once, hide the empty section and retain keyboard focus when toggling a pin. |
| Wide transaction and transfer tables obscured status behind sticky actions. | Group secondary bill, fee, confidence and sheet-reference information with its record; retain amount, status and direct actions. |
| Detailed OCR and raw message data competed with the operational information. | Put diagnostics in native expandable sections with explicit keyboard focus and disclosure affordances. Preserve their contents and the original evidence. |
| Some settings copy exposed development instructions rather than explaining the action. | Clarify the image-store check, bot connection and accounting-sheet labels. |

## Functions retained

| Area | Relevant controls |
| --- | --- |
| Incoming transactions and OCR review | Search/filter/sort, original images, amount and fee information, OCR confidence and image-analysis labels, individual review decisions, correction and OCR retry. |
| Outgoing transfers | Code/remitter matching, amount/status, duplicate evidence, review, retry and accounting-sheet references. |
| Messages | Conversation search, scoped sender/text search, image preview, reply context, processing-result links and optional collection diagnostics. |
| Reports | Date/layout selection, real Excel generation and download. CSV export of arbitrary visible rows is removed. |
| Organization and pricing | Relevant record creation/editing, activation fields, aliases, transfer codes and fee rules. |
| Settings and access | Operational switches, connection configuration, deliberate connection checks, role permissions and user administration. Purposeful form checkboxes remain. |
| Audit and history | Stored evidence, changes, financial calculation snapshots and permission-controlled diagnostic access. |

## Verification scope

- Rendered and inspected controls in 57 route states covering indexes, details, configuration forms,
  filters, reviews, transfers, reports, permissions and audit history.
- Checked that those responses contain no generic table-selection hooks, CSV controls or module imports.
- Browser checks cover the representative settings, transaction, transfer, dashboard, card-type,
  OCR-review, transaction-detail and Excel screens at desktop/mobile sizes and both appearances.
- Tested filters, disclosure controls and pin/unpin behavior without submitting accounting or configuration changes.
- Full validation passed: 1,174 Rails examples through `bin/parallel_rspec` and 16 JavaScript tests.
- Production read-only rendering verified settings, transactions, transfers, dashboard, card types and
  Excel creation. The deployed web is healthy and serves the reviewed assets; the worker remained running.
- Business calculations, approval rules, original records and authorization remain governed by their existing services.

The existing administrative batch endpoint is unchanged for compatibility; this audit removes its
generic frontend controls. It does not advertise or introduce another batch workflow.
