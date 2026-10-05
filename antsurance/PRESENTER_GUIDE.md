# Presenting the Antsurance org

Three stories carry the demo: Home and Claude's desk, one claim end to end, and the customer portal.
Each takes three to four minutes. Shorter stops for when you have more time are at the end.

This guide is internal. Do not share it with a customer. Records are named here, not linked, because
a data reload gives every record a new Id. Find them from Home, a list or search. Everything below is
the org as it stood on 2026-10-05.

## Before a demo

Do these in order, at least ten minutes ahead.

| Check | Why |
|---|---|
| Open the org at full laptop width, 1,440 pixels or wider, and leave the window alone | The pages were audited and fixed at full width and at 1,024 on Oct 5, by measurement and by eye. Narrower than 1,024 was not looked at. Do not drag the window narrow in front of a room. |
| Hard-reload each tab you will use (cmd+shift+r) | Many components changed on Oct 4, and a browser holding an old copy can show an error or an old layout. The quote page did this once. |
| Run `scripts/prepare_demo.sh --check` | It changes nothing. It says what each of the five showcase claims carries (its files, its estimate, each piece of Claude's work), then lists anything Claude wrote on ANY open claim that is missing or out of date: a brief whose claim has moved on, a stale coverage check or analysis, photos not assessed, words like "today" written on an earlier day. It should end "Nothing: Claude's work on all open claims is current". If it lists something, press the button it names on that claim, or run the script without `--check`. The evening before a demo, add `--tomorrow`: it reads as the next day and also lists what was written today and will be stale by then. |
| Check the pinned lists | Each object tab should open on a real list, not "Recently Viewed": Open Claims, All Customers, Open Policy Sales, All Policies, Open Quotes, Open Leads. They were pinned for the owner's user on Oct 5. A pin is per person, so another presenter pins their own: open the list, wait for it to finish loading, press the pin twice if the first press only shows its tip. |
| Open these in tabs first: Home, the claim "Burst pipe flooded finished basement" (00002566), the claim "Parking lot scrape, rear quarter panel" (00002574), the portal signed in as Maria Reyes, and the Executive Overview dashboard | Nothing should load cold in front of the room. |
| Open each dashboard you will show once and press Refresh twice | A dashboard shows stored results. Renewals and Retention needs one Refresh after its last deploy. A tile caught mid-refresh reads "No data". |
| On Home, press Refresh on the briefing if it is not from today | The briefing is stored. Writing a new one takes 5 to 20 seconds. |
| Know what claim 00002566 says | Every card on "Burst pipe flooded finished basement" gives one answer: the documents total $48,921, less the $2,500 deductible that is $46,421 payable, and the $45,000 reserve is $1,421 short; coverage needs the water source confirmed. The owner decided on Oct 5 to keep it this way. |
| Check the brief on any other claim you plan to open | A brief written before Oct 4 may still call a reserve short. The financials card on the same claim is right. Press Rewrite where they disagree. |
| Know the mismatch photo on claim 00002562 | "Rear-ended at a red light on Harlem Ave" is a Honda CR-V claim that carries a photo of a white sedan, on purpose. Claude says "Something to check". It is step 7 of Story 2. The claim also holds two marked areas and a moved box. |
| Have two photos on your desktop | For the portal claim and for the chat's attach button. The real file picker and a drag from the desktop were never driven by an agent, so try both yourself first. |
| Mind the storage | The org had about 1 MB of data storage free on Oct 4. Every claim or quote you file in a demo adds records. Do not rehearse the sending steps more than you need. |
| Do not reload the data | A reload empties the org for a minute or two, breaks every open tab, and now has to deactivate the portal user first. It is the owner's call, well before a demo. |
| After a reload, run `scripts/prepare_demo.sh` | A reload leaves the showcase claims bare. The script attaches the sample files, raises the burst pipe estimate to $48,921 and has Claude redo its work, about a dozen calls. It prints what each claim says when it is done. It has been run against the org as it stood, where it changed nothing; it has not been run after a reload, so read what it prints. |
| Outside Anthropic | Household pages show real street addresses paired with invented families and claims. Stay on the commercial accounts and the screens that carry no address, or ask the owner for a reload with the invented addresses. |

Two habits for the whole demo: pause a second after a page loads before you click (the first click
on some buttons only focuses them, so click again), and say what Claude is reading while it works,
because a call takes 5 to 20 seconds.

## Story 1: Home to Claude's desk (3 minutes)

The point: Claude has already done the routine work, and a person approves it.

| Step | Where to click | Say | Avoid |
|---|---|---|---|
| 1 | Home. Point at the six figures, then the briefing's headline and its first item. | "This is my cockpit. Claude read my tasks, claims, renewals and pipeline and tells me where to start, and why." | Pressing Refresh on the briefing live unless you want to fill 20 seconds. |
| 2 | The band under the headline: "On Claude's desk". Press "Open the desk". | "Overnight, Claude prepared the routine work. I am not asking it for help. I am approving what it already did." | Nothing. One press brings the desk to the top. |
| 3 | Open a reserve review, for example "Deer strike on Route 20: raise the reserve by $9,500". Show the sum and "Why this figure". | "It shows its arithmetic: the estimate less the deductible, plus fifteen rental days from the file note." The claim's own analysis reaches the same $9,500. | Approve, unless you mean to change that claim's reserve. |
| 4 | "What Claude may do". Show a locked row. | "I set how much rope each kind of work gets. Money and anything that goes to a customer always waits for a person." | Save, unless you changed something on purpose. |
| 5 | A workspace tab, Claims or Renewals. Open one row in place. | "Everything else on Home opens where it is. I do not leave the page to see a claim's reserve." | "Run Claude's shift". It takes minutes and writes new work. |

## Story 2: A claim, end to end (4 minutes)

The point: Claude reads everything on the file, shows its evidence, and the adjuster decides.

Use "Burst pipe flooded finished basement" (00002566) for the brief, the coverage check and the
report, "Parking lot scrape, rear quarter panel" (00002574) for photos whose boxes fit the loss, and
"Rear-ended at a red light on Harlem Ave" (00002562) for the photo that does not fit its claim.

| Step | Where to click | Say | Avoid |
|---|---|---|---|
| 1 | 00002566. The financials card on the right. | "Severity says why it is High. The line under the bar does the sum: the reserve is $1,421 below the estimate less the deductible." | Record a Payment. |
| 2 | The claim brief. Click through Where it stands, Coverage, The money, Watch, Next steps. | "Claude wrote where this file stands and what to do next. Each step can become a task." | Rewrite, unless you want to wait for it. |
| 3 | The coverage check. Open "Show the reasoning". | "It reads the loss against the policy as it stood that day. It says Needs review, because the photo shows silt and mud, which a clean supply line burst would not leave. The adjuster confirms, not Claude." | Confirm. Saying the photo is a stock picture. |
| 4 | Analysis tab. The headline and three figures, then the Evidence and Damage tabs. | "One button worked through nine pieces of evidence and wrote one report. Every row links to what it read." | "Analyze again" live: it takes a minute or more. "Set the reserve": it was never pressed in this org, and pressing it ends the "$1,421 short" story. |
| 5 | 00002574, Documents tab, Photos. Select a box, then its finding. | "Claude drew these boxes. Select one and it shows what it saw there and whether it fits the reported loss." | Promising the boxes are exact. Say they are approximate, as the card does. |
| 6 | "Mark an area". Drag a box on the photo, type a note, press "Ask Claude about this area". | "If I want a second look at something, I mark it and ask. My areas are kept apart from Claude's." | Marking more than one or two. Each ask is a Claude call of 10 to 20 seconds. |
| 7 | The mismatch. Open "Rear-ended at a red light on Harlem Ave" (00002562), Documents tab, Photos. Point at the photo, then read the "Something to check" callout aloud. | "This claim is for a Honda CR-V hit from behind. The photo that came in shows a sedan's rear corner. Claude says it is something to check and asks which vehicle is pictured. The adjuster makes the call." | The words fraud or fake: Claude says "something to check" and does not accuse anyone. "Assess again" live, which changes the wording. Showing this straight after the photo on 00002574: it is the same picture, there as that claim's own car. |

If you plan to show step 7, do steps 5 and 6 on 00002562 as well, so the room sees that picture on
one claim only.

## Story 3: The customer portal (4 minutes)

The point: the same Claude serves the customer, inside their own records only, and what they send
arrives as normal work for an agent.

Sign in as the sample customer with no password: in the Lightning app open the contact Maria Reyes
(Reyes Household), then press "Log in to Experience as User", the button at the top right of her page. Do this before the demo
and keep the tab.

| Step | Where to click | Say | Avoid |
|---|---|---|---|
| 1 | Portal Home. | "Maria sees her household and nothing else. That is tested as two customers: the other one's policy, claim, quote, photo and document are refused." | The forgot-password page. It is still the stock one. |
| 2 | Press the first suggestion, "What do I pay, and when?". Then type "why did my bill increase?" and press Auto. | "Claude answers in a sentence and draws the rest: her three policies with the total and the next payment. When it needs to know which policy, it offers them as buttons, and the price comes back as a receipt, line by line. Every figure is read from her record by the server; none comes from the model." | Promising billing history: the org holds what is due and what was paid this term, not past bills. |
| 3 | Type "I backed into a post last night and dented my rear bumper." | "Claude opens the claim form and fills it in. Every field it filled is marked and she can change it. Claude never sends anything." | |
| 4 | Add one or two photos to the claim form. | "Each photo is checked as she adds it. A dark one is refused in plain words, and it says what is still missing." | More than five photos. Photos straight from a phone camera were not tried. |
| 5 | Send the claim. Switch to the Lightning app, Claims and Service, open the new claim, Documents tab. | "It arrives as an ordinary claim, with her photos on the adjuster's Photos card, ready to assess." | Sending more than once. Each one uses storage. |
| 6 | Back on the portal: Get a quote, Renters. Answer two questions, then press "What does this mean?" on one. | "The price follows every answer, from the same pricing code the agents use. Claude explains a question where she is." | Tabbing through the form by keyboard: Tab walks every step tab first. |
| 7 | Optional: send the quote, then find it under Policy Sales. | "It arrives as a draft quote at the same price, for an agent to confirm." | The ID cards print on an auto policy: only the declarations page was seen printing. |

After the demo, tell the owner which claims and quotes you sent so they can be removed.

## With more time

Each of these still works as it did. Check the record before you rely on it.

| Stop | Where | What to show |
|---|---|---|
| A customer and a policy | Customers, Reyes Household, then the personal auto policy | The household card, the policy's grouped coverages with their share of premium, and the Documents tab: the declarations page prints from the live record. |
| Claude files a claim internally | Reyes Household, "File a Claim with Claude" | Paste a customer's email. Claude picks the policy and says why, sets date, type and severity, and lists what is missing. |
| Underwriting a referred quote | The quote "Standard limits" on Ironwood Machine Works' general liability renewal | The Configuration tab's build-up, then the underwriting review: why it was referred, Claude's memo and "Approve with conditions". The underwriter decides. |
| Quote and bind | Policy Sales, Dubois Household - Personal Auto | Quotes side by side, Generate Quote's guided questions with "Claude suggests", then Bind Policy. Binding builds the policy from the quote's answers. |
| A renewal at risk | The Nakamura Household homeowners policy | "Draft outreach with Claude", then Open as email. Close it without sending. |
| Ask Claude | The Ask Claude tab, then the bar at the bottom right of a record (its panel opens over the sidebar, leaving the record's main cards in view) | A starter card, then attach a photo or a PDF with the paperclip and ask what it shows. On a claim: "Use this claim's files". |
| Tasks | The Tasks tab | Overdue, Today, This week and Later, six a page, tick to complete. |
| The executive view | Dashboards, Executive Overview | Premium and policies in force, open claims and reserve, loss ratio by line. The figures agree with Home. |
| How the loss ratio built | Home, the card beside the six figures | Run the pointer along the line: each day shows the ratio so far, what had been incurred and what that day added. Say what it is: a running total of losses to date over today's premium in force, ending at the 63 percent in the figures. It climbs steeply in September because that is when the demo's large open claims are dated. Do not call it a trend or a history. |
| Claude at Work | The Claude at Work tab | The nine jobs Claude does here and how each one runs. One is an agent on a harness; the rest are single calls, pipelines and one tool loop. Each job opens with "How to start it" and a button that goes to a record to try it on: on First notice of loss it opens File a Claim with Claude on a customer, with sample messages to paste. Click Claims coverage, then "On a harness". |
| The coverage agent | A claim's coverage check card, "Investigate with the coverage agent" | It works the coverage question step by step, each step shown, in under a minute and for a few cents, then leaves a finding for the adjuster to confirm. Run it on "Deer strike on Route 20" (00002563), not on the burst pipe claim, so that claim's story stays as it is. |
| A storm | The Events tab | The hail footprint over the map of insured locations, the insured value inside it, and "Ask Claude who to call". The events are samples set up for the demo. |
| A broker's submission | Policy Sales, "Lakeshore Dental Group - Workers Comp", the Read a submission card | "Use the sample submission", then "Read 3 with Claude" (about 40 seconds). Thirteen answers filled, each with the page it came from; the Missing tab catches that the application says three claims and the loss run shows four. Do not save the quote: storage is short. |
| A letter | A claim's Documents tab, Letters | "Draft with Claude" on the acknowledgment: the letter appears on letterhead beside an editor. Change a word and watch the page follow. Approve only if you want the PDF and a file note left on that claim. |
| Adding evidence | A claim's Analysis tab, "Add evidence" | Drop a photo or a PDF: it goes to the claim's Salesforce Files and joins the evidence as "Not looked at yet". Or write a file note there. Then "Analyze again" if you have a minute. |
| Salesforce's own Notes | A claim's File Notes tab | A note written in Salesforce Notes shows in the same timeline as the file notes, drawn the same way, with "Open in Notes". "Deer strike on Route 20" carries one, "Body shop call". In the composer, the type "Salesforce note" saves a note there. |

## Known rough edges

Steer around these.

| Where | What you will see | What to do |
|---|---|---|
| Claim 00002574, coverage check | It may say "Documents added or removed since this was checked", left by a test photo that was added and removed | Press "Check again" beforehand. |
| Claim 00002566, photo | Silt and mud, which Claude flags as not fitting a burst supply line | Present it as Claude questioning the evidence. No better-fitting licensed photo was found. |
| Claude's boxes | Tight on a dent or broken glass, loose on spread-out damage like shingles or a stain, and a little different each time the assessment runs | Say "approximate". A person can drag any box. |
| A marked area and the analysis | The analysis picks up a marked area only when Claude found damage in it | Do not promise that every marked area shows in the report. |
| The photos card | A hover highlight can stay on when the page scrolls under a still pointer. Touch was never driven. | Move the pointer. Use a mouse. |
| Record pages | A blank band at the top of the Activity panel on claims; cents on a sale's Amount; dates as 9/21/2026 in Salesforce's own fields and "Sep 21" in our cards; "Incurred Losses" blank beside "Loss Ratio 0.0%"; the policy Details tab repeats the card | These are Salesforce's or were left on purpose. Do not draw attention to them. |
| Completed work | Several finished tasks are dated "Today" | The platform sets that date. |
| The navigation bar | Opening a coverage or an asset adds a temporary tab and can push Reports and Dashboards under More; the three custom tabs read "Lightning Experience" in the browser's tab title | Open dashboards from a tab you prepared. |
| App Launcher | Seven stock apps listed ahead of Antsurance | Start already inside the app. |
| The chat | After new files are attached, Claude no longer has the earlier ones and says so | Attach what you need in one message. |
| The chat, on the Ask Claude tab | The utility bar shows a short note there, not a second chat | Use the bar on a record page. |
| Insured to value, on a home | Every seeded home reads 100 percent | Do not go looking for an under-insured home. |
| Locked quotes | Seven presented, accepted or bound quotes would price $1 off if priced again | They cannot be saved again, so nothing shows. Do not claim every quote reprices exactly. |
| The portal | The forgot-password page is stock; the bill for a policy that is behind was never checked; a real phone was never used | Stay on the paths in Story 3. |
| Not seen by anyone | The Tasks and File Notes empty states, the Documents menu that replaces two buttons when very narrow, a related list long enough to page, a drafted renewal outreach after the redesign, the over-1.2 MB refusal in the chat | Try any of these yourself before you show it. |
| Evals | The chat's 84 questions and the photo assessment's nine cases were not rerun after their prompts changed on Oct 4 | Quote the results with their date. |

## What to say about how it is built

| Topic | Line |
|---|---|
| Salesforce | Standard objects where they exist (Account, Contact, Case, Opportunity, Quote, Task, Lead) and a few custom ones for policies. Lightning Web Components, Apex, screen flows, Visualforce PDFs, an Experience Cloud site. Everything is in source. |
| Claude | Apex calls the Messages API through a Named Credential. The key is in the org's credential store and not in code. Each feature is one call with a typed answer, or a short tool loop for the chat. Nothing is saved without a click. |
| Measured, not asserted | The chat passed 84 of 84 test questions and claim intake 36 of 36. Claude's damage boxes overlap the true damage by 0.69 on average across twelve test photos, up from 0.59. Small sets, each written by one person: they show it is reliable on demo-style input. |
| Taking it home | There is a kit a customer's own Claude Code installs, starting in a throwaway scratch org. It is proven in clean scratch orgs, with and without address picklists, and not yet in a customer's sandbox. The owner signed off on Oct 5 on handing it to customers, and hands it over himself. |

## If something goes wrong

| What you see | What to do |
|---|---|
| A button does nothing | Click it again. The first click after load can only focus it. |
| A page shows the old layout, or a component error | Hard-reload the tab (cmd+shift+r). |
| "Couldn't find the record" | The data was reloaded and the link is old. Go in from a list or Home. |
| Home shows zeros | A reload is in progress. Wait two minutes and refresh. |
| A Claude button returns an error or says time ran out | Try once more. If it repeats, the API key or the model is the cause; move on and show the stored brief, memo or report on another record. |
| A dashboard tile is empty or says "No data" | Press Refresh on the dashboard, twice. |
| The portal shows a sign-in page | The session ended. Use "Log in to Experience as User" on Maria Reyes's contact again. Never type a password. |
| The portal looks unchanged after a deploy | The site was not published. See the README. |
| An insert fails with a storage error | The org is full. Stop filing new records and tell the owner. |
