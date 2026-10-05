# Where Claude puts a damage box

Measures how well Claude places the box around each damaged area in a photo, for four ways of asking.

- `cases.json`: twelve photos (vehicle body, glass, roof, interior water, and two with no damage), each
  with a short claim and the true damage boxes as fractions of the image. `optional` boxes are places
  where damage is plausible but cannot be confirmed from the photo.
- `run.py`: asks Claude through the org, one request per photo, and saves the answers under `runs/`.
- `score.py`: pairs each true box with Claude's, prints the table and draws a contact sheet per method.
- `photos/`: the four photos that are not sample static resources, with their licenses.

```
python3 run.py first  runs/v2                 # fractions, pixels, grid, pixels with a box per part
python3 run.py refine runs/v2                 # the second pass of the two-pass method
python3 score.py runs/v2 <folder of contact sheets>
```

A full run is 58 calls to Claude and 22 requests to the org (`sf api request rest`), so mind the
org's daily API allowance. `--only id,id` and `--methods a,b` narrow a run.

The photos go to `classes/AntsuranceAiTrial`, an endpoint that puts trial questions to Claude and
saves nothing; only someone with the Author Apex permission can call it.

## How the true boxes were made

By eye, on a copy of each photo with a grid every five percent, then checked on an overlay. They were
not drawn with the marker component: that runs only on a claim's photos in the org, and these photos
are not to be attached to claims. A person marking them in the org would be the better truth.

## What a run says

