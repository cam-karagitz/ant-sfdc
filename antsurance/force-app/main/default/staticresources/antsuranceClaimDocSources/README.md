# Sample claim documents: sources

The six `antsuranceClaimDoc*` static resources are made from the HTML files here. Nothing reads this
folder at run time; it is kept so the documents can be re-made.

| Source | Resource | Goes on the claim |
|---|---|---|
| `mitigation-invoice.html` | `antsuranceClaimDocMitigationInvoice.pdf` | Burst pipe flooded finished basement |
| `rebuild-estimate.html` | `antsuranceClaimDocRebuildEstimate.pdf` | Burst pipe flooded finished basement |
| `crash-report.html` | `antsuranceClaimDocCrashReport.pdf` | Rear-ended at a red light on Harlem Ave |
| `repair-estimate.html` | `antsuranceClaimDocRepairEstimatePhoto.jpg` | Rear-ended at a red light on Harlem Ave |
| `first-report-of-injury.html` | `antsuranceClaimDocFirstReport.pdf` | Installer fell from second-story roof |
| `hospital-bill.html` | `antsuranceClaimDocHospitalBill.pdf` | Installer fell from second-story roof |

## Re-making them

Run `./render.sh` from this folder on a Mac with Google Chrome, `pdftoppm` (poppler) and Python with
Pillow. It prints each HTML file to PDF with headless Chrome, turns the repair estimate into a
"phone photo" JPEG, and copies the results over the resources one folder up. Then deploy the
resources and run `AntsuranceClaimsAssistantDemo.attachSampleDocuments()`. That method skips a
document whose title is already on the claim, so delete the old file from the claim first.

## Why you might need to

The dates printed on the documents are fixed: the burst pipe loss is 21 September 2026, the
roof fall is 26 September 2026 and the rear-end crash is 30 September 2026. Those match demo data
loaded on 4 October 2026, and `AntsuranceDemoData` pins those three claims to them for 60 days. The seed
data sets claim dates relative to the day it is loaded, so after a reload on another day Claude
will, correctly, point out that the document dates do not match the claim. Once the 60 days are up,
either move the pinned dates in the seed data (`DOCUMENT_LOSS_DATES`) or change the dates in the
HTML and run `render.sh`.

Figures the documents are built around, so they stay consistent with the file notes on the claim:
the mitigation invoice totals $9,971.20 against a $9,500 reserve line, the rebuild estimate
totals $27,450 against a $24,000 reserve line, and the repair estimate totals $6,451.03 against a
$6,800 estimated loss. The hospital's interim bill asks for $18,500, the fee schedule amount, which
is what the claim shows as paid; the employer's first report says the rented anchor is set aside
for our engineer, as the file note does. The injured installer is never named in the seed data: the
two documents call him Tomas Varga. Every business, person and reference number on them is invented, and each
carries a line saying it is a sample.
