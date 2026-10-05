# Photo assessment eval

Nine cases that check what Claude makes of a damage photograph against a claim described in words.
Each case names one of the `antsuranceDamage*` static resources (real photographs from Wikimedia
Commons; see `staticresources/antsuranceDamageSources/LICENSES.md`) and says what a correct read
contains: the kind of loss, where the damage is, how bad, whether it fits the report, and the next step.

```bash
python3 -I scripts/eval/photos/run.py <label>            # all nine, two Apex runs
python3 -I scripts/eval/photos/run.py <label> --only rear-quarter-scrape,too-dark-to-judge
```

It runs inside the org through `AntsuranceClaimsAssistantPhotos.assessResources`, which reads no
claim and writes nothing. Five cases share one Anonymous Apex run, so a full pass is two `sf` commands
and nine calls to Claude. Each run stays under Salesforce's 120 seconds of callout time because a case
takes about fifteen seconds; do not raise `--batch` above five.

What is checked by the script: the photo is called usable or not; consistency with the reported loss;
the loss Claude names; a damaged area that mentions the expected part; the vehicle panel; the worst
severity; the next step; that every box lies inside the image; and, for the torn-open roof, that the
rough range is far above the reported estimate.

What a person checks: whether the boxes land on the damage. The script draws them on a copy of each
photo (`runs/<label>-boxes/`, needs Pillow). Look at them; a box that is inside the image can still
be in the wrong place.

## Results

| Run | Passed | Notes |
|---|---|---|
| `v1` | 6 of 9 | Two of the three misses were faults in the cases, not in Claude: the claim said driver's side for a photo of the passenger side (Claude said so), and a hurricane-flooded room was offered as a clean-water pipe burst (Claude said the silt did not fit). The third was a stained ceiling called "unclear" because no roof photo came with it. |
| `v2` | 8 of 9 | After correcting those two cases and telling Claude that missing views belong in "photos still needed" and do not make a fitting set unclear. The one miss was an answer cut short by the token allowance, which was then raised; that case was confirmed afterwards on the real claim in the browser, not by a third run. |

Boxes, judged by eye on the `v2` copies: on the scraped pickup, the hail-broken window, the lifted
shingles and the dented quarter panel they sit on the damage. In `v1` several sat 10 to 15 percent
of the image height too high; the prompt now asks Claude to check a box's top and bottom edges. They
are still approximate, and the card says so.
