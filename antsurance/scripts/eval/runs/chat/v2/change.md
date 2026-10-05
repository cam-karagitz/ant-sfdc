Tasks about a person carry that person as the contact.

Why: in `v1/traces/action-task-with-contact_rep0.json` the task to "send Maria Reyes her updated ID cards" came back with the right account and date but no contact, although the open account's facts list her with her Id. The same thing showed in the browser on a claim ("remind me to call him Tuesday"). One train case shows it, so the most this can gain is 1 of 62 (1.6 points), well inside the noise floor of about 6 points on a split. It is kept or dropped on whether that case and the other task cases hold, not on the headline.

Change: the `contact_id` description on `propose_task` now says to set it whenever the task is to reach a person, and where to find the Id. The error message for a save Salesforce refuses also gained a plain lead-in; that text is not seen by the model.
