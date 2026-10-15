# SMC

SMC helps accounting and operations staff review settlement bills and outgoing transfer evidence
received in Telegram groups. PostgreSQL holds the records; Excel and configured workbook outputs
present accounting results. User-facing screens and labels are in Vietnamese.

## Existing product and visual system

The administration application uses Rails, Tabler components, a restrained blue accent, system
typography, and persistent light/dark appearances. Operational screens prioritize readable amounts,
original evidence, exact statuses and quick navigation. Changes to one screen inherit this system.
User-facing branding is SMC.

## Messages workspace

- Displays collected Telegram history, attached images and links to processing results.
- Telegram is the implemented message source. The workspace does not claim other integrations
  or provide reply sending.
- Group activation controls bill processing. A paused group can still have stored messages;
  activation is not an online, unread or connection indicator.
- A group without new messages for 24 hours may simply be quiet. Collection diagnostics belong
  in optional conversation information rather than a persistent warning across the inbox.
- Staff can filter groups, search content or senders within a selected group, review older windows,
  inspect image evidence and follow permission-checked links to accounting records.
- Desktop opens the newest matching conversation. Mobile separates the inbox and thread with
  an explicit route back to the list.

## Accounting boundaries

Interface changes preserve calculation rules, selected reporting periods, reconciliation formulas,
approval requirements and audit records. Unknown amounts remain distinguishable from zero. The
dashboard's approved and waiting subtotals must reconcile with its headline total.

## Operational interface

- Tables show records and relevant actions. Generic row selection and CSV export do not belong
  on settings, history, summaries or operational record lists.
- Accounting exports use the dedicated Excel workflow, with explicit dates and file layout.
- Configuration editing, permissions and filters retain their purposeful form controls.
- A pinned navigation item appears once. Empty pin sections and zero-work queues stay out of the way.
- Financial lists prioritize amount, status and review actions; secondary bill details stay with their row.
- AI image-screening labels belong on transaction and review detail pages; lists retain OCR confidence.
- Diagnostic data remains available in expandable sections; originals and audit history are preserved.

Detailed rules and implementation decisions are recorded in [docs/PROJECT_CONTEXT.md](docs/PROJECT_CONTEXT.md).
