House style and one more nudge on task contacts, run as a confirmation pass.

Why: round two scored 63 of 63, so there is no failing behaviour left to fix and this round is not expected to move the score. It does two small things and checks that nothing regresses, which also gives a second full sample of the final chat.

- The task proposed in `v2/traces/followup-task-on-found-claim_rep0.json` had an en dash in its subject. Antsurance copy does not use em or en dashes, so the instructions now say so, for answers and for text in a proposal.
- "Call the customer about this claim" still sometimes came back without a contact although the claim's facts name one (seen in the browser on the burst pipe claim, where the subject named him and `contact_id` was left out). Two changes for that one behaviour: a sentence in the proposal instructions says who "the customer" is on a claim or request, and `contact_id` and `notes` on `propose_task` are now required fields that may be null, so leaving the contact out is a decision the model has to make and not an omission. In the browser the same request then came back with the contact.

Held to: no case that passed in round two fails here.
