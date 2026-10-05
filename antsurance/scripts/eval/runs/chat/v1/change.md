Record facts up front, three proposal tools with a confirm step, a fuller data model note, and a query tool that no longer crashes on totals.

Why: the baseline's 15 failures were three behaviours, each with one root cause.

- Six questions asking for a total, an average or a household count ended in an Apex error instead of an answer. `runQuery` added `LIMIT 50` to every query, and SOQL rejects a LIMIT on a total without GROUP BY with an exception Apex cannot catch (`baseline/traces/sum-outstanding-reserve_rep0.json`: "Non-grouped query that uses overall aggregate functions cannot also use LIMIT"). One more grouped by a currency field, which fails the same way (`baseline/traces/top-loss-ratio_rep0.json`). Fix: no LIMIT on totals, and a GROUP BY field is checked with describe first so the problem goes back to Claude as a tool error.
- Seven action requests could only be answered with "I can't do that". Fix: `propose_task`, `propose_file_note` and `propose_case_status`, which return a card and write nothing.
- Two questions about who handles a claim missed `Handled_By__c`, which the data model note did not name (`baseline/traces/top-adjuster_rep0.json` answered from Owner). Fix: the note now covers it with the other new fields.

Also in this round, not aimed at a failure: the open record's facts go in a second system block, and the fixed instructions and tools are cached.
