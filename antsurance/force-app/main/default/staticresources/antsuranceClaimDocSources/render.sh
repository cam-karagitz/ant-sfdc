#!/bin/zsh
# Re-makes the sample claim documents from the HTML in this folder. See README.md.
set -e
here=${0:A:h}
out=$(mktemp -d)
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
profile=$(mktemp -d /tmp/claimdocs.XXXXXX)   # Chrome needs a short profile path for its lock socket

for name in mitigation-invoice rebuild-estimate crash-report repair-estimate first-report-of-injury hospital-bill; do
    "$chrome" --headless=new --disable-gpu --no-pdf-header-footer --user-data-dir="$profile" \
        --print-to-pdf="$out/$name.pdf" "file://$here/$name.html"
done
pdftoppm -r 150 -png "$out/repair-estimate.pdf" "$out/repair-estimate"
python3 "$here/make_photo.py" "$out/repair-estimate-1.png" "$out/repair-estimate.jpg"

cp "$out/mitigation-invoice.pdf" "$here/../antsuranceClaimDocMitigationInvoice.pdf"
cp "$out/rebuild-estimate.pdf" "$here/../antsuranceClaimDocRebuildEstimate.pdf"
cp "$out/crash-report.pdf" "$here/../antsuranceClaimDocCrashReport.pdf"
cp "$out/repair-estimate.jpg" "$here/../antsuranceClaimDocRepairEstimatePhoto.jpg"
cp "$out/first-report-of-injury.pdf" "$here/../antsuranceClaimDocFirstReport.pdf"
cp "$out/hospital-bill.pdf" "$here/../antsuranceClaimDocHospitalBill.pdf"
echo "Done. Deploy the antsuranceClaimDoc* static resources next."
