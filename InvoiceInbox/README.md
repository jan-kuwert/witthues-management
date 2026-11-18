# Invoice Inbox

A Mac menu bar app that reads new mail over IMAP, keeps only invoices, renames them and files them into a folder (for example inside OneDrive). When an invoice is marked as paid, it moves into the archive folder.

- **E-invoices first:** ZUGFeRD / Factur-X XML embedded in PDFs, and XRechnung / Peppol (CII or UBL) XML, are read exactly, without AI.
- **Other PDFs:** the PDF text, or Apple Vision OCR for scans, is read by Apple's on-device model (Foundation Models, typed `@Generable` output) and cross-checked with text rules in German, English, French, Spanish, Italian and Dutch. Fields that don't agree are flagged under "Needs a look".
- **Not invoices:** terms and conditions, offers, delivery notes and similar files are listed under "Not invoices" and can be filed by hand.
- **Mail is only read:** never moved, deleted or marked as read. The password is stored in the macOS Keychain.
- **Checking:** on launch, then every 5 minutes (adjustable) while the app runs, plus "Check now" (⌘R). An option starts the app at login.

Requirements: macOS 26 or later on Apple Silicon. Apple Intelligence must be turned on for the AI step; without it, the text rules still work.

## Settings

Folders, file names and the archive are templates with variables such as `{yyyy}`, `{yy}`, `{mm}`, `{dd}`, `{paid_yyyy}`, `{paid_mm}`, `{customer}` and `{invoice}`. The full list is in the settings window. Defaults:

| | Template | Example |
|---|---|---|
| Unpaid folder | `00 Offen` | `00 Offen/` |
| Paid folder | `{yyyy}-{mm}` | `2026-03/` |
| File name | `{yy}-{mm}-{dd} {customer} {invoice}` | `26-03-07 Telekom Deutschland 19 5683 1701 2621.pdf` |

Use `/` in a folder template for subfolders, for example `Archiv/{paid_yyyy}-{paid_mm}`.

## Build

```sh
./build-app.sh          # builds dist/Invoice Inbox.app
swift test              # core tests
swift run invoice-cli extract some-invoice.pdf   # shows what would be extracted and the file name
```
