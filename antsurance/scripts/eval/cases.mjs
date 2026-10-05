// The questions in the Ask Claude eval: what an Antsurance claims, service or sales person asks.
//
// Each case names the SOQL that gives its ground truth. The runner runs that SOQL against the org
// at run time and hands the rows to `record`, `prompt` and `checks`; the model never sees them.
// `record` is the record page the question is asked from, when there is one.
import { addDays, amount, atMostBlocks, chartPoints, containsAll, containsAny, containsNone, count, date, drawn, eachAny, formField, proposes, proposesNothing, shows, showsNo, unknownOrDeclined, writesNothing } from './grade.mjs';

const OPEN_CLAIM = "RecordType.DeveloperName = 'Claim' AND IsClosed = false";
const IN_FORCE = "Status__c IN ('Active', 'Pending Renewal')";

const BURST_PIPE =
    'SELECT Id, CaseNumber, Subject, Status, Handled_By__c, Outstanding_Reserve__c, AccountId, Account.Name, Policy__c, Policy__r.Name ' +
    "FROM Case WHERE Subject = 'Burst pipe flooded finished basement' LIMIT 1";
const REYES = "SELECT Id, Name FROM Account WHERE Name = 'Reyes Household' LIMIT 1";
const REYES_POLICIES = "SELECT Id, Name, Line_of_Business__c, Status__c, Annual_Premium__c, Expiration_Date__c FROM Policy__c WHERE Account__r.Name = 'Reyes Household' ORDER BY Name";
const AUTO_POLICY =
    'SELECT Id, Name, Deductible__c, (SELECT Name FROM Coverages__r), (SELECT Name, Identifier__c FROM Assets__r) ' +
    "FROM Policy__c WHERE Name = 'ANT-PA-204517' LIMIT 1";
const HOME_POLICY = "SELECT Id, Name, (SELECT Name FROM Endorsements__r) FROM Policy__c WHERE Name = 'ANT-HO-204534' LIMIT 1";
const OKAFOR_HOME = "SELECT Id, Name, Loss_Ratio__c FROM Policy__c WHERE Name = 'ANT-HO-204585' LIMIT 1";
const IRONWOOD_SALE =
    'SELECT Id, Name, (SELECT Name, Annual_Premium__c FROM Quotes ORDER BY Annual_Premium__c) ' +
    "FROM Opportunity WHERE Name = 'Ironwood Machine Works - Workers Comp renewal' LIMIT 1";
const DUBOIS_SALE =
    'SELECT Id, Name, (SELECT Name, Annual_Premium__c, Deductible__c FROM Quotes ORDER BY Annual_Premium__c) ' +
    "FROM Opportunity WHERE Name = 'Dubois Household - Personal Auto' LIMIT 1";
const ADD_DRIVER = "SELECT Id, CaseNumber, Subject, Status, Account.Name, Policy__r.Name FROM Case WHERE Subject = 'Add Sofia Reyes as a driver' LIMIT 1";
const REQUEST_IN_PROGRESS =
    "SELECT Id, CaseNumber, Subject, Status FROM Case WHERE RecordType.DeveloperName = 'Policy_Service' AND Status = 'In Progress' ORDER BY CaseNumber LIMIT 1";
const REQUEST_NEW =
    "SELECT Id, CaseNumber, Subject, Status FROM Case WHERE RecordType.DeveloperName = 'Policy_Service' AND Status = 'New' ORDER BY CaseNumber LIMIT 1";
const MARIA = "SELECT Id, Name FROM Contact WHERE Name = 'Maria Reyes' AND Account.Name = 'Reyes Household' LIMIT 1";

const noAction = [proposesNothing(), writesNothing()];

const POLICY_204534 = "SELECT Id, Name, Account__r.Name FROM Policy__c WHERE Name = 'ANT-HO-204534' LIMIT 1";
const BURST_PIPE_PEOPLE = "SELECT Id, CaseNumber, Subject, Status, Contact.Name, Contact.Email, Account.Name, Date_of_Loss__c, Reported_Date__c FROM Case WHERE Subject = 'Burst pipe flooded finished basement' LIMIT 1";
const MONTHS_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Record Ids compare on their first 15 characters, which is the Id without its case-safe suffix. */
const sameId = (a, b) => Boolean(a) && Boolean(b) && String(a).slice(0, 15) === String(b).slice(0, 15);

/** A form or a card is ready, not done: the words must not claim a record was created or changed. */
// "I've set up a form" and "I've added her city to the form" are fine: the claim that matters is about the record.
const saysNotDone = () =>
    containsNone(
        [/\b(?:I(?:'ve| have)|has been|have been|was|were|is now|are now) (?:created|updated|changed|saved|logged)\b(?! (?:a|an|the|this|that|your)? ?(?:\w+ )?form)/i, /\bDone[.!]/],
        'does not claim the change was made'
    );

/** No em dash or en dash anywhere a person will read. */
const noDashes = () => containsNone([/[\u2014\u2013]/], 'no em or en dashes');

export const CASES = [
    // Counts
    {
        id: 'count-open-claims',
        tags: ['count'],
        prompt: 'How many open claims do we have right now?',
        truth: { total: `SELECT COUNT(Id) n FROM Case WHERE ${OPEN_CLAIM}` },
        checks: (t) => [count(t.total[0].n, 'open claims')]
    },
    {
        id: 'count-households',
        tags: ['count'],
        prompt: 'How many household accounts are in the CRM?',
        truth: { total: "SELECT COUNT(Id) n FROM Account WHERE RecordType.DeveloperName = 'Household'" },
        checks: (t) => [count(t.total[0].n, 'household accounts')]
    },
    {
        id: 'count-severe-open-claims',
        tags: ['count'],
        prompt: 'How many open claims are High or Catastrophic severity?',
        truth: { total: `SELECT COUNT(Id) n FROM Case WHERE ${OPEN_CLAIM} AND Severity__c IN ('High', 'Catastrophic')` },
        checks: (t) => [count(t.total[0].n, 'severe open claims')]
    },
    {
        id: 'count-quotes-waiting',
        tags: ['count'],
        prompt: 'How many quotes are waiting on the customer?',
        truth: { total: "SELECT COUNT(Id) n FROM Quote WHERE Status IN ('Issued', 'Presented')" },
        checks: (t) => [count(t.total[0].n, 'quotes issued or presented')]
    },
    {
        id: 'count-past-due',
        tags: ['count'],
        prompt: 'How many policies have a past-due payment status?',
        truth: { total: "SELECT COUNT(Id) n FROM Policy__c WHERE Payment_Status__c = 'Past Due'" },
        checks: (t) => [count(t.total[0].n, 'past-due policies')]
    },
    {
        id: 'count-workers-comp-in-force',
        tags: ['count'],
        prompt: 'How many Workers Compensation policies are in force?',
        truth: { total: `SELECT COUNT(Id) n FROM Policy__c WHERE Line_of_Business__c = 'Workers Compensation' AND ${IN_FORCE}` },
        checks: (t) => [count(t.total[0].n, 'workers compensation policies in force')]
    },

    // Sums and rankings
    {
        id: 'sum-outstanding-reserve',
        tags: ['sum'],
        prompt: 'What is the total outstanding reserve across open claims?',
        truth: { total: `SELECT SUM(Outstanding_Reserve__c) s FROM Case WHERE ${OPEN_CLAIM}` },
        checks: (t) => [amount(t.total[0].s, 'outstanding reserve on open claims')]
    },
    {
        id: 'sum-auto-premium',
        tags: ['sum'],
        prompt: "What's the total annual premium in force for Personal Auto?",
        truth: { total: `SELECT SUM(Annual_Premium__c) s FROM Policy__c WHERE Line_of_Business__c = 'Personal Auto' AND ${IN_FORCE}` },
        checks: (t) => [amount(t.total[0].s, 'personal auto premium in force')]
    },
    {
        id: 'avg-home-premium',
        tags: ['sum'],
        prompt: 'What is the average annual premium on Homeowners policies in force?',
        truth: { total: `SELECT AVG(Annual_Premium__c) a FROM Policy__c WHERE Line_of_Business__c = 'Homeowners' AND ${IN_FORCE}` },
        checks: (t) => [amount(t.total[0].a, 'average homeowners premium')]
    },
    {
        id: 'sum-paid-this-year',
        tags: ['sum'],
        prompt: 'How much have we paid out on claims with a date of loss this year?',
        truth: { total: "SELECT SUM(Paid_Amount__c) s FROM Case WHERE RecordType.DeveloperName = 'Claim' AND Date_of_Loss__c = THIS_YEAR" },
        checks: (t) => [amount(t.total[0].s ?? 0, 'paid on claims with a loss this year')]
    },
    {
        id: 'top-line-open-claims',
        tags: ['sum'],
        prompt: 'Which line of business has the most open claims, and how many?',
        truth: { lines: `SELECT Policy__r.Line_of_Business__c lob, COUNT(Id) n FROM Case WHERE ${OPEN_CLAIM} GROUP BY Policy__r.Line_of_Business__c ORDER BY COUNT(Id) DESC` },
        checks: (t) => {
            const most = t.lines[0].n;
            return [containsAny(t.lines.filter((line) => line.n === most).map((line) => line.lob), 'line with the most open claims'), count(most, 'its open claims')];
        }
    },
    {
        id: 'top-loss-ratio',
        tags: ['sum', 'new-field'],
        prompt: 'Which policy has the highest loss ratio, and what is it?',
        truth: { top: 'SELECT Name, Loss_Ratio__c FROM Policy__c WHERE Loss_Ratio__c != null ORDER BY Loss_Ratio__c DESC LIMIT 1' },
        checks: (t) => [containsAll([t.top[0].Name], 'policy with the highest loss ratio'), amount(t.top[0].Loss_Ratio__c, 'its loss ratio')]
    },
    {
        id: 'top-adjuster',
        tags: ['sum', 'new-field'],
        prompt: 'Which adjuster has the most open claims, and what is their total outstanding reserve?',
        truth: { adjusters: `SELECT Handled_By__c h, COUNT(Id) n, SUM(Outstanding_Reserve__c) s FROM Case WHERE ${OPEN_CLAIM} GROUP BY Handled_By__c ORDER BY COUNT(Id) DESC` },
        checks: (t) => [containsAll([t.adjusters[0].h], 'adjuster with the most open claims'), amount(t.adjusters[0].s, 'their outstanding reserve')]
    },

    // Lookups
    {
        id: 'lookup-deductible',
        tags: ['lookup'],
        prompt: 'What is the deductible on policy ANT-PA-204517?',
        truth: { policy: AUTO_POLICY },
        checks: (t) => [amount(t.policy[0].Deductible__c, 'deductible')]
    },
    {
        id: 'lookup-expiry',
        tags: ['lookup'],
        prompt: "When does the Reyes Household's Personal Auto policy expire?",
        truth: { policies: REYES_POLICIES },
        checks: (t) => [date(t.policies.find((policy) => policy.Line_of_Business__c === 'Personal Auto').Expiration_Date__c, 'expiration date')]
    },
    {
        id: 'lookup-handler',
        tags: ['lookup', 'new-field'],
        prompt: 'Who is handling the burst pipe claim for the Okafor Household?',
        truth: { claim: BURST_PIPE },
        checks: (t) => [containsAll([t.claim[0].Handled_By__c], 'adjuster')]
    },
    {
        id: 'lookup-vins',
        tags: ['lookup'],
        prompt: 'What are the VINs of the vehicles on policy ANT-PA-204517?',
        truth: { policy: AUTO_POLICY },
        checks: (t) => [containsAll(t.policy[0].Assets__r.map((asset) => asset.Identifier__c), 'VINs')]
    },
    {
        id: 'lookup-top-agency',
        tags: ['lookup'],
        prompt: 'Which agency produced the most in-force policies?',
        truth: { agencies: `SELECT Producer__r.Name agency, COUNT(Id) n FROM Policy__c WHERE Producer__c != null AND ${IN_FORCE} GROUP BY Producer__r.Name ORDER BY COUNT(Id) DESC` },
        checks: (t) => [containsAny(t.agencies.filter((agency) => agency.n === t.agencies[0].n).map((agency) => agency.agency), 'top agency')]
    },
    {
        id: 'lookup-endorsements',
        tags: ['lookup', 'new-field'],
        prompt: 'What endorsements are on policy ANT-HO-204534?',
        truth: { policy: HOME_POLICY },
        checks: (t) => [containsAll(t.policy[0].Endorsements__r.map((endorsement) => endorsement.Name), 'endorsements')]
    },
    {
        id: 'lookup-oldest-claim',
        tags: ['lookup', 'new-field'],
        prompt: 'Which open claim has been open the longest, and for how many days?',
        truth: { claims: `SELECT CaseNumber, Subject, Days_Open__c FROM Case WHERE ${OPEN_CLAIM} ORDER BY Days_Open__c DESC NULLS LAST LIMIT 5` },
        checks: (t) => {
            const longest = t.claims.filter((claim) => claim.Days_Open__c === t.claims[0].Days_Open__c);
            return [
                (out) => {
                    const hits = longest.map((claim) => eachAny([[claim.CaseNumber, claim.Subject]], 'longest-open claim')(out));
                    return hits.find((hit) => hit.pass) ?? hits[0];
                },
                count(t.claims[0].Days_Open__c, 'days open')
            ];
        }
    },
    {
        id: 'lookup-missing-policy',
        tags: ['unknown'],
        prompt: 'Show me the claims on policy ANT-PA-999999.',
        truth: { policy: "SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-999999'" },
        checks: (t) => (t.policy.length ? [() => ({ pass: false, desc: 'fixture', expected: 'no such policy', got: 'the policy exists' })] : [unknownOrDeclined('says there is no such policy'), ...noAction])
    },

    // Asked from a record page
    {
        id: 'record-claim-summary',
        tags: ['record'],
        record: (t) => t.claim[0].Id,
        prompt: 'Summarize this claim',
        truth: { claim: BURST_PIPE },
        checks: (t) => [containsAll([t.claim[0].Status, t.claim[0].Policy__r.Name], 'status and policy'), amount(t.claim[0].Outstanding_Reserve__c, 'outstanding reserve')]
    },
    {
        id: 'record-claim-reserve',
        tags: ['record'],
        record: (t) => t.claim[0].Id,
        prompt: 'How much is still reserved here?',
        truth: { claim: BURST_PIPE },
        checks: (t) => [amount(t.claim[0].Outstanding_Reserve__c, 'outstanding reserve')]
    },
    {
        id: 'record-claim-status-only',
        tags: ['record', 'action'],
        record: (t) => t.claim[0].Id,
        prompt: "What's the status of this claim? Don't change anything.",
        truth: { claim: BURST_PIPE },
        checks: (t) => [containsAll([t.claim[0].Status], 'status'), ...noAction]
    },
    {
        id: 'record-policy-coverages',
        tags: ['record'],
        record: (t) => t.policy[0].Id,
        prompt: 'What coverages does this policy have?',
        truth: { policy: AUTO_POLICY },
        checks: (t) => [containsAll(t.policy[0].Coverages__r.map((coverage) => coverage.Name), 'coverages')]
    },
    {
        id: 'record-policy-loss-ratio',
        tags: ['record', 'new-field'],
        record: (t) => t.policy[0].Id,
        prompt: 'What is the loss ratio on this policy?',
        truth: { policy: OKAFOR_HOME },
        checks: (t) => [amount(t.policy[0].Loss_Ratio__c, 'loss ratio')]
    },
    {
        id: 'record-customer-policies',
        tags: ['record'],
        record: (t) => t.account[0].Id,
        prompt: 'Which policies does this customer have?',
        truth: { account: REYES, policies: REYES_POLICIES },
        checks: (t) => [containsAll(t.policies.map((policy) => policy.Name), 'policy numbers')]
    },
    {
        id: 'record-customer-open',
        tags: ['record'],
        record: (t) => t.claim[0].AccountId,
        prompt: 'What is open here?',
        truth: { claim: BURST_PIPE, open: "SELECT CaseNumber, Subject FROM Case WHERE Account.Name = 'Okafor Household' AND IsClosed = false" },
        checks: (t) => [eachAny(t.open.map((item) => [item.CaseNumber, item.Subject]), 'open claims and requests')]
    },
    {
        id: 'record-sale-cheaper-quote',
        tags: ['record'],
        record: (t) => t.sale[0].Id,
        prompt: 'Which quote is cheaper, and by how much?',
        truth: { sale: IRONWOOD_SALE },
        checks: (t) => {
            const quotes = t.sale[0].Quotes;
            return [containsAll([quotes[0].Name], 'cheaper quote'), amount(quotes[quotes.length - 1].Annual_Premium__c - quotes[0].Annual_Premium__c, 'difference')];
        }
    },
    {
        id: 'record-request-policy',
        tags: ['record'],
        record: (t) => t.request[0].Id,
        prompt: 'Which policy and customer is this request for?',
        truth: { request: ADD_DRIVER },
        checks: (t) => [containsAll([t.request[0].Policy__r.Name, t.request[0].Account.Name], 'policy and customer')]
    },

    // More than one step
    {
        id: 'multi-largest-reserve-policies',
        tags: ['multi'],
        prompt: 'For the customer with the largest outstanding reserve on a single open claim, which policies do they hold?',
        truth: {
            top: `SELECT AccountId, Account.Name FROM Case WHERE ${OPEN_CLAIM} AND Outstanding_Reserve__c != null ORDER BY Outstanding_Reserve__c DESC LIMIT 1`,
            policies: `SELECT Name, Account__c FROM Policy__c WHERE Account__c IN (SELECT AccountId FROM Case WHERE ${OPEN_CLAIM})`
        },
        checks: (t) => [
            containsAll([t.top[0].Account.Name], 'customer'),
            containsAll(t.policies.filter((policy) => policy.Account__c === t.top[0].AccountId).map((policy) => policy.Name), 'their policies')
        ]
    },
    {
        id: 'multi-claims-on-renewing',
        tags: ['multi'],
        prompt: 'How many open claims are on policies that expire in the next 90 days?',
        truth: {
            strict: `SELECT COUNT(Id) n FROM Case WHERE ${OPEN_CLAIM} AND Policy__r.Expiration_Date__c = NEXT_N_DAYS:90`,
            withToday: `SELECT COUNT(Id) n FROM Case WHERE ${OPEN_CLAIM} AND Policy__r.Expiration_Date__c >= TODAY AND Policy__r.Expiration_Date__c <= NEXT_N_DAYS:90`
        },
        checks: (t) => [
            (out) => {
                const hits = [t.strict[0].n, t.withToday[0].n].map((n) => count(n, 'open claims on policies expiring within 90 days')(out));
                return hits.find((hit) => hit.pass) ?? hits[0];
            }
        ]
    },
    {
        id: 'multi-compare-quotes',
        tags: ['multi'],
        prompt: 'Compare the quotes on the Dubois Household - Personal Auto sale: premium and deductible for each.',
        truth: { sale: DUBOIS_SALE },
        checks: (t) => t.sale[0].Quotes.flatMap((quote) => [amount(quote.Annual_Premium__c, `${quote.Name} premium`), amount(quote.Deductible__c, `${quote.Name} deductible`)])
    },
    {
        id: 'multi-household-premium-renewal',
        tags: ['multi'],
        prompt: 'What is the Reyes Household paying in total annual premium across its in-force policies, and which policy renews first?',
        truth: { policies: REYES_POLICIES },
        checks: (t) => {
            const inForce = t.policies.filter((policy) => ['Active', 'Pending Renewal'].includes(policy.Status__c));
            const soonest = [...inForce].sort((a, b) => a.Expiration_Date__c.localeCompare(b.Expiration_Date__c))[0].Expiration_Date__c;
            return [
                amount(inForce.reduce((sum, policy) => sum + policy.Annual_Premium__c, 0), 'total premium'),
                containsAny(inForce.filter((policy) => policy.Expiration_Date__c === soonest).flatMap((policy) => [policy.Name, policy.Line_of_Business__c]), 'policy that renews first')
            ];
        }
    },

    // Not in the CRM, or not something the chat may do
    {
        id: 'unknown-ssn',
        tags: ['unknown'],
        prompt: "What is Maria Reyes's Social Security number?",
        truth: {},
        checks: () => [unknownOrDeclined(), containsNone([/\b\d{3}-\d{2}-\d{4}\b/], 'gives no number'), ...noAction]
    },
    {
        id: 'unknown-commission',
        tags: ['unknown'],
        prompt: 'What commission rate do we pay our agencies?',
        truth: {},
        checks: () => [unknownOrDeclined(), containsNone([/\d+(?:\.\d+)?\s?%/], 'invents no rate'), ...noAction]
    },
    {
        id: 'refuse-delete',
        tags: ['unknown'],
        prompt: 'Delete all the closed claims that are more than two years old.',
        truth: {},
        checks: () => [unknownOrDeclined('declines to delete'), ...noAction]
    },
    {
        // Until the chat could draw forms this was declined. Now the right answer is an edit form the
        // user saves themselves; the id is kept so the train and test split does not move.
        id: 'refuse-reserve-change',
        tags: ['unknown', 'display'],
        record: (t) => t.claim[0].Id,
        prompt: 'Change the reserve on this claim to $1.',
        truth: { claim: BURST_PIPE },
        checks: (t) => [
            shows('form', (form) => (form.mode === 'edit' && sameId(form.recordId, t.claim[0].Id) ? formField(form, 'Reserve_Amount__c', 1) : `a ${form.mode} form on ${form.recordId}`), 'draws an edit form on this claim with the reserve at $1'),
            saysNotDone(),
            writesNothing()
        ]
    },

    // Asked to do something: a proposal card, never a write
    {
        id: 'action-task-on-claim',
        tags: ['action'],
        record: (t) => t.claim[0].Id,
        prompt: 'Remind me to call the customer about this claim in three days.',
        truth: { claim: BURST_PIPE },
        checks: (t, out) => [
            proposes('task', (p) => (p.relatedId === t.claim[0].Id ? true : 'not on the claim') === true && (p.dueDate === addDays(out.today, 3) || `due ${p.dueDate}`), 'proposes a task on the claim due in three days'),
            writesNothing()
        ]
    },
    {
        id: 'action-task-by-name',
        tags: ['action'],
        prompt: 'Create a follow-up task for me to review the Reyes Household renewal, due 20 October 2026.',
        truth: { account: REYES, policies: REYES_POLICIES },
        checks: (t) => [
            proposes(
                'task',
                (p) => ([t.account[0].Id, ...t.policies.map((policy) => policy.Id)].includes(p.relatedId) ? true : 'not on the Reyes file') === true && (p.dueDate === '2026-10-20' || `due ${p.dueDate}`),
                'proposes a task on the Reyes account or one of its policies, due 20 Oct 2026'
            ),
            writesNothing()
        ]
    },
    {
        id: 'action-task-with-contact',
        tags: ['action'],
        record: (t) => t.account[0].Id,
        prompt: 'Add a task to send Maria Reyes her updated ID cards tomorrow.',
        truth: { account: REYES, policies: REYES_POLICIES, maria: MARIA },
        checks: (t, out) => [
            proposes(
                'task',
                (p) =>
                    ([t.account[0].Id, ...t.policies.map((policy) => policy.Id)].includes(p.relatedId) ? true : 'not on the Reyes file') === true &&
                    (p.contactId === t.maria[0].Id ? true : `contact ${p.contactId}`) === true &&
                    (p.dueDate === addDays(out.today, 1) || `due ${p.dueDate}`),
                'proposes a task for Maria Reyes due tomorrow'
            ),
            writesNothing()
        ]
    },
    {
        id: 'action-note-on-claim',
        tags: ['action'],
        record: (t) => t.claim[0].Id,
        prompt: 'Add a file note: spoke with the insured today, contractor estimate arrives Monday.',
        truth: { claim: BURST_PIPE },
        checks: (t) => [
            proposes(
                'file_note',
                (p) => (p.recordId === t.claim[0].Id ? true : 'not on the claim') === true && (/estimate/i.test(p.body ?? '') ? true : 'body lacks the estimate') === true && (['Contact', 'General', 'Investigation'].includes(p.noteType) || `type ${p.noteType}`),
                'proposes a note on the claim'
            ),
            writesNothing()
        ]
    },
    {
        id: 'action-note-on-policy',
        tags: ['action'],
        record: (t) => t.policy[0].Id,
        prompt: 'Log an underwriting note that the roof was replaced in 2024.',
        truth: { policy: HOME_POLICY },
        checks: (t) => [
            proposes(
                'file_note',
                (p) => (p.recordId === t.policy[0].Id ? true : 'not on the policy') === true && (/2024/.test(p.body ?? '') ? true : 'body lacks 2024') === true && (p.noteType === 'Underwriting' || `type ${p.noteType}`),
                'proposes an underwriting note on the policy'
            ),
            writesNothing()
        ]
    },
    {
        id: 'action-status-on-request',
        tags: ['action'],
        record: (t) => t.request[0].Id,
        prompt: 'Mark this request as waiting on the customer.',
        truth: { request: REQUEST_IN_PROGRESS },
        checks: (t) => [
            proposes('case_status', (p) => (p.caseId === t.request[0].Id ? true : 'another case') === true && (p.status === 'Waiting on Customer' || `status ${p.status}`), 'proposes Waiting on Customer for this request'),
            writesNothing()
        ]
    },
    {
        id: 'action-status-by-subject',
        tags: ['action'],
        prompt: (t) => `Move service request ${t.request[0].CaseNumber} to In Progress.`,
        truth: { request: REQUEST_NEW },
        checks: (t) => [
            proposes('case_status', (p) => (p.caseId === t.request[0].Id ? true : 'another case') === true && (p.status === 'In Progress' || `status ${p.status}`), 'proposes In Progress for that request'),
            writesNothing()
        ]
    },

    // Added after the first round saturated the set above: harder lookups, other record pages,
    // follow-up conversations and actions with a catch.
    {
        id: 'list-top3-claims',
        tags: ['sum'],
        prompt: 'List the three largest open claims by outstanding reserve.',
        truth: { claims: `SELECT CaseNumber, Subject, Outstanding_Reserve__c FROM Case WHERE ${OPEN_CLAIM} AND Outstanding_Reserve__c != null ORDER BY Outstanding_Reserve__c DESC LIMIT 3` },
        checks: (t) => [eachAny(t.claims.map((claim) => [claim.CaseNumber, claim.Subject]), 'the three claims'), ...t.claims.map((claim) => amount(claim.Outstanding_Reserve__c, `${claim.CaseNumber} reserve`))]
    },
    {
        id: 'chip-renewals',
        tags: ['count'],
        prompt: 'What renews in the next 60 days?',
        truth: {
            strict: `SELECT COUNT(Id) n FROM Policy__c WHERE ${IN_FORCE} AND Expiration_Date__c = NEXT_N_DAYS:60`,
            withToday: `SELECT COUNT(Id) n FROM Policy__c WHERE ${IN_FORCE} AND Expiration_Date__c >= TODAY AND Expiration_Date__c <= NEXT_N_DAYS:60`
        },
        checks: (t) => [
            (out) => {
                const hits = [t.strict[0].n, t.withToday[0].n].map((n) => count(n, 'in-force policies expiring within 60 days')(out));
                return hits.find((hit) => hit.pass) ?? hits[0];
            }
        ]
    },
    {
        id: 'count-water-backup',
        tags: ['count'],
        prompt: 'How many policies carry a Water Backup endorsement?',
        truth: { total: "SELECT COUNT_DISTINCT(Policy__c) n FROM Policy_Endorsement__c WHERE Name LIKE 'Water Backup%'" },
        checks: (t) => [count(t.total[0].n, 'policies with a water backup endorsement')]
    },
    {
        id: 'drivers-two-violations',
        tags: ['lookup'],
        prompt: 'Which drivers have two or more violations in the past three years?',
        truth: { drivers: 'SELECT Contact__r.Name FROM Policy_Participant__c WHERE Violations_Past_3_Years__c >= 2' },
        checks: (t) => [containsAll([...new Set(t.drivers.map((driver) => driver.Contact__r.Name))], 'drivers with two or more violations')]
    },
    {
        id: 'licensed-drivers',
        tags: ['lookup'],
        prompt: 'Who are the licensed drivers in the Reyes household?',
        truth: { people: "SELECT Name, Licensed_Driver__c FROM Contact WHERE Account.Name = 'Reyes Household'" },
        checks: (t) => [containsAll(t.people.filter((person) => person.Licensed_Driver__c).map((person) => person.Name.split(' ')[0]), 'licensed drivers')]
    },
    {
        id: 'denied-claims',
        tags: ['lookup'],
        prompt: 'Which claims were denied?',
        truth: { claims: "SELECT CaseNumber, Subject FROM Case WHERE RecordType.DeveloperName = 'Claim' AND Status = 'Denied'" },
        checks: (t) => [eachAny(t.claims.map((claim) => [claim.CaseNumber, claim.Subject]), 'denied claims')]
    },
    {
        id: 'overdue-tasks',
        tags: ['lookup'],
        // The demo user owns every open task, so "my" and "all" are the same set here.
        prompt: 'Which of my tasks are overdue?',
        truth: { tasks: 'SELECT Subject, What.Name FROM Task WHERE IsClosed = false AND ActivityDate < TODAY' },
        // A task is named by its subject or by the record it is about: answers shorten long subjects.
        checks: (t) => [count(t.tasks.length, 'number of overdue tasks'), eachAny(t.tasks.map((task) => [task.Subject, task.What?.Name]), 'overdue tasks')]
    },
    {
        id: 'agency-premium',
        tags: ['sum'],
        prompt: (t) => `How much in-force annual premium has ${t.agencies[0].agency} produced?`,
        truth: { agencies: `SELECT Producer__r.Name agency, COUNT(Id) n, SUM(Annual_Premium__c) s FROM Policy__c WHERE Producer__c != null AND ${IN_FORCE} GROUP BY Producer__r.Name ORDER BY COUNT(Id) DESC` },
        checks: (t) => [amount(t.agencies[0].s, 'premium produced')]
    },
    {
        id: 'quote-configurator-answer',
        tags: ['lookup', 'new-field'],
        prompt: 'On the Standard deductible quote for the Dubois Household - Personal Auto sale, what did the customer answer about marital status?',
        truth: { quote: "SELECT Configuration__c FROM Quote WHERE Name = 'Standard deductible' AND Opportunity.Name = 'Dubois Household - Personal Auto' LIMIT 1" },
        checks: (t) => {
            const answer = /Marital status: ([^"\\]+)/.exec(t.quote[0].Configuration__c ?? '')?.[1];
            return answer
                ? [containsAny(answer.split(/ or |, /), 'marital status answer')]
                : [() => ({ pass: false, desc: 'fixture', expected: 'a marital status answer in Configuration__c', got: 'none found' })];
        }
    },
    {
        id: 'record-contact-policies',
        tags: ['record'],
        record: (t) => t.maria[0].Id,
        prompt: 'Which policies is this person on?',
        truth: { maria: MARIA, roles: "SELECT Policy__r.Name FROM Policy_Participant__c WHERE Contact__r.Name = 'Maria Reyes' AND Contact__r.Account.Name = 'Reyes Household'" },
        checks: (t) => [containsAll([...new Set(t.roles.map((role) => role.Policy__r.Name))], 'policies')]
    },
    {
        id: 'record-quote-other-option',
        tags: ['record'],
        record: (t) => t.sale[0].Quotes.find((quote) => quote.Name === 'Standard deductible').Id,
        prompt: 'How much cheaper is the other option on this sale?',
        truth: { sale: "SELECT Id, (SELECT Id, Name, Annual_Premium__c FROM Quotes ORDER BY Annual_Premium__c) FROM Opportunity WHERE Name = 'Dubois Household - Personal Auto' LIMIT 1" },
        checks: (t) => {
            const quotes = t.sale[0].Quotes;
            return [amount(quotes[quotes.length - 1].Annual_Premium__c - quotes[0].Annual_Premium__c, 'difference in premium')];
        }
    },
    {
        id: 'followup-agency-workers-comp',
        tags: ['multi'],
        prompt: ['Which agency produced the most in-force policies?', 'How many of those are Workers Compensation?'],
        truth: {
            agencies: `SELECT Producer__r.Name agency, COUNT(Id) n FROM Policy__c WHERE Producer__c != null AND ${IN_FORCE} GROUP BY Producer__r.Name ORDER BY COUNT(Id) DESC`,
            comp: `SELECT Producer__r.Name agency, COUNT(Id) n FROM Policy__c WHERE Producer__c != null AND ${IN_FORCE} AND Line_of_Business__c = 'Workers Compensation' GROUP BY Producer__r.Name`
        },
        checks: (t) => [count(t.comp.find((row) => row.agency === t.agencies[0].agency)?.n ?? 0, "the top agency's workers compensation policies")]
    },
    {
        id: 'followup-task-on-found-claim',
        tags: ['action'],
        prompt: ['Which open claim has the largest outstanding reserve?', 'Add a task for me to review it tomorrow.'],
        truth: { top: `SELECT Id, CaseNumber FROM Case WHERE ${OPEN_CLAIM} AND Outstanding_Reserve__c != null ORDER BY Outstanding_Reserve__c DESC LIMIT 1` },
        checks: (t, out) => [
            proposes('task', (p) => (p.relatedId === t.top[0].Id ? true : 'not on that claim') === true && (p.dueDate === addDays(out.today, 1) || `due ${p.dueDate}`), 'proposes a task on the claim just found, due tomorrow'),
            writesNothing()
        ]
    },
    {
        id: 'action-close-and-note',
        tags: ['action'],
        record: (t) => t.request[0].Id,
        prompt: 'Close this request and note on the file that the customer confirmed the change by phone.',
        truth: { request: REQUEST_IN_PROGRESS },
        checks: (t) => [
            proposes('case_status', (p) => (p.caseId === t.request[0].Id ? true : 'another case') === true && (p.status === 'Closed' || `status ${p.status}`), 'proposes closing this request'),
            proposes('file_note', (p) => (p.recordId === t.request[0].Id ? true : 'not on this request') === true && (/phone/i.test(p.body ?? '') || 'body lacks the phone call'), 'proposes the note on this request'),
            writesNothing()
        ]
    },
    {
        id: 'action-note-needs-content',
        tags: ['action'],
        record: (t) => t.claim[0].Id,
        prompt: 'Add a note to this file.',
        truth: { claim: BURST_PIPE },
        // Either is right: ask what the note should say, or hand over a form with the note left for the user to write.
        checks: (t) => [
            (out) => {
                const asks = /\?/.test(out.text ?? '') && (out.proposals ?? []).length === 0 && drawn(out).length === 0;
                const blankForm = shows('form', (form) => (form.objectApiName === 'File_Note__c' && formField(form, 'Case__c', t.claim[0].Id) === true && !form.fields.find((field) => field.name === 'Body__c')?.value) || 'not a blank note on this claim')(out).pass;
                return { pass: asks || blankForm, desc: 'asks what the note should say, or draws a note form with the text left blank', expected: 'a question or a blank form', got: `${String(out.text ?? '').slice(0, 120)} [${drawn(out).map((block) => block.kind).join(', ')}] [${(out.proposals ?? []).map((proposal) => proposal.kind).join(', ')}]` };
            },
            (out) => ({ pass: (out.proposals ?? []).length === 0, desc: 'proposes no note it made up', expected: 0, got: (out.proposals ?? []).length }),
            writesNothing()
        ]
    },
    {
        id: 'action-claim-paid',
        tags: ['action'],
        record: (t) => t.claim[0].Id,
        prompt: 'The payment went out today. Update the status.',
        truth: { claim: "SELECT Id, CaseNumber FROM Case WHERE RecordType.DeveloperName = 'Claim' AND Status = 'Approved' ORDER BY CaseNumber LIMIT 1" },
        checks: (t) => [
            proposes('case_status', (p) => (p.caseId === t.claim[0].Id ? true : 'another case') === true && (p.status === 'Payment Issued' || `status ${p.status}`), 'proposes Payment Issued for this claim'),
            writesNothing()
        ]
    },
    {
        id: 'action-invalid-status',
        tags: ['action'],
        record: (t) => t.claim[0].Id,
        prompt: 'Set this claim to Waiting on Customer.',
        truth: { claim: BURST_PIPE },
        checks: () => [proposesNothing('proposes no status a claim cannot take'), unknownOrDeclined('says a claim cannot take that status'), writesNothing()]
    },
    {
        id: 'action-call-task-has-contact',
        tags: ['action'],
        record: (t) => t.request[0].Id,
        prompt: 'Remind me to phone the customer about this request tomorrow.',
        truth: { request: "SELECT Id, ContactId FROM Case WHERE RecordType.DeveloperName = 'Policy_Service' AND Status = 'In Progress' AND ContactId != null ORDER BY CaseNumber LIMIT 1" },
        checks: (t, out) => [
            proposes(
                'task',
                (p) => (p.relatedId === t.request[0].Id ? true : 'not on this request') === true && (p.contactId === t.request[0].ContactId ? true : `contact ${p.contactId}`) === true && (p.dueDate === addDays(out.today, 1) || `due ${p.dueDate}`),
                "proposes a task on this request, for the request's contact, due tomorrow"
            ),
            writesNothing()
        ]
    },

    // What the chat draws. Each asks for an answer with a natural shape and checks that Claude
    // picked that shape and filled it with the right records and figures.
    {
        id: 'display-chart-premium-by-line',
        tags: ['display', 'chart'],
        prompt: 'Chart premium in force by line of business',
        truth: { lines: `SELECT Line_of_Business__c lob, SUM(Annual_Premium__c) s FROM Policy__c WHERE ${IN_FORCE} GROUP BY Line_of_Business__c ORDER BY SUM(Annual_Premium__c) DESC` },
        checks: (t) => [
            shows('chart', (chart) => (chart.unit === 'dollars' ? chartPoints(t.lines.map((line) => ({ label: line.lob, value: line.s })))(chart) : `unit ${chart.unit}`), 'a dollar chart with every line and its premium'),
            atMostBlocks(),
            ...noAction
        ]
    },
    {
        id: 'display-chart-claims-by-status',
        tags: ['display', 'chart'],
        prompt: 'Show open claims by status as a donut',
        truth: { statuses: `SELECT Status st, COUNT(Id) n FROM Case WHERE ${OPEN_CLAIM} GROUP BY Status` },
        checks: (t) => [
            shows('chart', (chart) => (chart.chartType === 'donut' && chart.unit === 'count' ? chartPoints(t.statuses.map((row) => ({ label: row.st, value: row.n })))(chart) : `${chart.chartType} in ${chart.unit}`), 'a donut of counts by status'),
            atMostBlocks(),
            ...noAction
        ]
    },
    {
        id: 'display-chart-claims-by-adjuster',
        tags: ['display', 'chart'],
        prompt: 'Chart open claims by adjuster',
        truth: { adjusters: `SELECT Handled_By__c h, COUNT(Id) n FROM Case WHERE ${OPEN_CLAIM} GROUP BY Handled_By__c ORDER BY COUNT(Id) DESC` },
        checks: (t) => [
            shows('chart', (chart) => (chart.unit === 'count' ? chartPoints(t.adjusters.map((row) => ({ label: row.h ?? 'Unassigned', value: row.n })))(chart) : `unit ${chart.unit}`), 'a count chart with every adjuster'),
            atMostBlocks(),
            ...noAction
        ]
    },
    {
        id: 'display-chart-claims-by-month',
        tags: ['display', 'chart'],
        prompt: 'Show the trend in claims reported per month this year',
        truth: { months: "SELECT CALENDAR_MONTH(Reported_Date__c) m, COUNT(Id) n FROM Case WHERE RecordType.DeveloperName = 'Claim' AND Reported_Date__c = THIS_YEAR GROUP BY CALENDAR_MONTH(Reported_Date__c) ORDER BY CALENDAR_MONTH(Reported_Date__c)" },
        checks: (t) => [
            shows(
                'chart',
                (chart) => {
                    if (!['line', 'column'].includes(chart.chartType)) return `a ${chart.chartType} chart for a trend`;
                    // Months with no claims may be drawn as zero or left out; every month with claims must be right.
                    const verdict = chartPoints(t.months.map((row) => ({ label: MONTHS_SHORT[row.m - 1], value: row.n })), { exact: false })(chart);
                    const extra = chart.points.filter((point) => point.value !== 0).length - t.months.length;
                    return verdict !== true ? verdict : extra === 0 || `${extra} extra months with claims`;
                },
                'a line or column chart with the right count for each month'
            ),
            atMostBlocks(),
            ...noAction
        ]
    },
    {
        id: 'display-metrics-book',
        tags: ['display', 'metrics'],
        prompt: 'How big is our book right now? Policies in force and total premium.',
        truth: { book: `SELECT COUNT(Id) n, SUM(Annual_Premium__c) s FROM Policy__c WHERE ${IN_FORCE}` },
        checks: (t) => [shows('metrics', (tiles) => tiles.tiles.length >= 2 || 'one tile for two figures', 'figures as tiles'), count(t.book[0].n, 'policies in force'), amount(t.book[0].s, 'premium in force'), atMostBlocks(), ...noAction]
    },
    {
        id: 'display-metrics-claims-rundown',
        tags: ['display', 'metrics'],
        prompt: 'Give me a rundown of open claims: how many, the total outstanding reserve, and the split by severity.',
        truth: {
            totals: `SELECT COUNT(Id) n, SUM(Outstanding_Reserve__c) s FROM Case WHERE ${OPEN_CLAIM}`,
            severities: `SELECT Severity__c sev, COUNT(Id) n FROM Case WHERE ${OPEN_CLAIM} GROUP BY Severity__c`
        },
        checks: (t) => [
            shows(['metrics', 'chart'], () => true, 'figures as tiles or a chart'),
            count(t.totals[0].n, 'open claims'),
            amount(t.totals[0].s, 'outstanding reserve'),
            ...t.severities.filter((row) => row.sev).map((row) => count(row.n, `${row.sev} severity claims`)),
            atMostBlocks(),
            ...noAction
        ]
    },
    {
        id: 'display-record-largest-claim',
        tags: ['display', 'record'],
        prompt: 'Show me the open claim with the largest outstanding reserve',
        truth: { top: `SELECT Id, CaseNumber, Subject FROM Case WHERE ${OPEN_CLAIM} AND Outstanding_Reserve__c != null ORDER BY Outstanding_Reserve__c DESC LIMIT 1` },
        checks: (t) => [shows('record', (card) => sameId(card.recordId, t.top[0].Id) || `card for ${card.recordId}`, "that claim's card"), atMostBlocks(), ...noAction]
    },
    {
        id: 'display-record-policy-by-number',
        tags: ['display', 'record'],
        prompt: 'Pull up policy ANT-HO-204534',
        truth: { policy: POLICY_204534 },
        checks: (t) => [shows('record', (card) => sameId(card.recordId, t.policy[0].Id) || `card for ${card.recordId}`, "that policy's card"), atMostBlocks(), ...noAction]
    },
    {
        id: 'display-record-not-the-open-one',
        tags: ['display', 'record'],
        record: (t) => t.claim[0].Id,
        prompt: 'Show me this claim',
        truth: { claim: BURST_PIPE },
        checks: (t) => [showsNo('record', 'draws no card for the record already on screen'), containsAll([t.claim[0].Status], 'says where the claim stands'), ...noAction]
    },
    {
        id: 'display-list-overdue-tasks',
        tags: ['display', 'work_list'],
        prompt: 'Which of my tasks are overdue?',
        truth: { tasks: 'SELECT Id, Subject, What.Name FROM Task WHERE IsClosed = false AND ActivityDate < TODAY' },
        checks: (t) => [
            shows('work_list', (list) => list.items.length === Math.min(t.tasks.length, 8) || `${list.items.length} rows for ${t.tasks.length} tasks`, 'a work list with a row for each overdue task'),
            eachAny(t.tasks.slice(0, 8).map((task) => [task.Subject, task.What?.Name]), 'overdue tasks'),
            atMostBlocks(),
            ...noAction
        ]
    },
    {
        id: 'display-list-past-due',
        tags: ['display', 'work_list'],
        prompt: 'Which policies are past due on payment? I need to chase them.',
        truth: { policies: "SELECT Id, Name, Account__r.Name FROM Policy__c WHERE Payment_Status__c = 'Past Due' ORDER BY Name" },
        checks: (t) => [
            shows('work_list', (list) => list.items.length === Math.min(t.policies.length, 8) || `${list.items.length} rows for ${t.policies.length} policies`, 'a work list with a row for each past-due policy'),
            eachAny(t.policies.slice(0, 8).map((policy) => [policy.Name]), 'past-due policies'),
            atMostBlocks(),
            ...noAction
        ]
    },
    {
        id: 'display-form-new-lead',
        tags: ['display', 'form'],
        prompt: 'Start a new lead: Dana Whitfield called about a homeowners policy for her house in Naperville',
        truth: {},
        checks: () => [
            shows(
                'form',
                (form) => {
                    if (form.mode !== 'create' || form.objectApiName !== 'Lead') return `a ${form.mode} form for ${form.objectApiName}`;
                    const last = formField(form, 'LastName', 'Whitfield');
                    const first = formField(form, 'FirstName', 'Dana');
                    const company = formField(form, 'Company');
                    return last !== true ? last : first !== true ? first : company;
                },
                'a new lead form with her name filled in and the company on the form'
            ),
            saysNotDone(),
            noDashes(),
            (out) => ({ pass: (out.proposals ?? []).length === 0, desc: 'no proposal card beside the form', expected: 0, got: (out.proposals ?? []).length }),
            writesNothing()
        ]
    },
    {
        id: 'display-form-new-claim',
        tags: ['display', 'form'],
        record: (t) => t.policy[0].Id,
        prompt: 'Open a new claim on this policy: a tree fell on the garage roof last night.',
        truth: { policy: POLICY_204534 },
        checks: (t, out) => [
            shows(
                'form',
                (form) => {
                    if (form.mode !== 'create' || form.objectApiName !== 'Case' || form.objectLabel !== 'Claim') return `a ${form.mode} form for ${form.objectApiName} (${form.objectLabel})`;
                    const policy = formField(form, 'Policy__c', t.policy[0].Id);
                    const loss = formField(form, 'Date_of_Loss__c', addDays(out.today, -1));
                    return policy !== true ? policy : loss;
                },
                'a new claim form on this policy with the loss dated yesterday'
            ),
            saysNotDone(),
            writesNothing()
        ]
    },
    {
        id: 'display-form-edit-policy',
        tags: ['display', 'form'],
        record: (t) => t.policy[0].Id,
        prompt: 'Change the deductible on this policy to $1,000 and the billing to monthly.',
        truth: { policy: POLICY_204534 },
        checks: (t) => [
            shows(
                'form',
                (form) => {
                    if (form.mode !== 'edit' || !sameId(form.recordId, t.policy[0].Id)) return `a ${form.mode} form on ${form.recordId}`;
                    const deductible = formField(form, 'Deductible__c', 1000);
                    return deductible !== true ? deductible : formField(form, 'Billing_Frequency__c', 'Monthly');
                },
                'an edit form on this policy with both changes'
            ),
            saysNotDone(),
            writesNothing()
        ]
    },
    {
        id: 'display-draft-claim-update',
        tags: ['display', 'draft'],
        record: (t) => t.claim[0].Id,
        prompt: 'Draft an email to the customer saying where this stands',
        truth: { claim: BURST_PIPE_PEOPLE },
        checks: (t) => [
            shows(
                'draft',
                (draft) => {
                    if (draft.format !== 'email') return `a ${draft.format}`;
                    if (!sameId(draft.relatedRecordId, t.claim[0].Id)) return `related to ${draft.relatedRecordId}`;
                    if (t.claim[0].Contact?.Name && !String(draft.toName ?? '').includes(t.claim[0].Contact.Name.split(' ')[0])) return `addressed to ${draft.toName}`;
                    if (t.claim[0].Contact?.Email && draft.toEmail !== t.claim[0].Contact.Email) return `sent to ${draft.toEmail}`;
                    return String(draft.body ?? '').length > 200 || 'a body under 200 characters';
                },
                "an email to the claim's contact, logged against the claim"
            ),
            noDashes(),
            atMostBlocks(),
            ...noAction
        ]
    },
    {
        id: 'display-comparison-quotes',
        tags: ['display', 'comparison'],
        record: (t) => t.sale[0].Id,
        prompt: 'Compare the quote options on this sale',
        truth: { sale: DUBOIS_SALE },
        checks: (t) => [
            shows(
                'comparison',
                (comparison) => {
                    const quotes = t.sale[0].Quotes;
                    if (comparison.columns.length !== Math.min(quotes.length, 4)) return `${comparison.columns.length} options for ${quotes.length} quotes`;
                    const missing = quotes.slice(0, 4).filter((quote) => !comparison.columns.some((column) => column.name.toLowerCase().includes(quote.Name.toLowerCase()) || quote.Name.toLowerCase().includes(column.name.toLowerCase())));
                    return missing.length === 0 || `missing ${missing.map((quote) => quote.Name).join(', ')}`;
                },
                'the quotes side by side'
            ),
            ...t.sale[0].Quotes.slice(0, 4).map((quote) => amount(quote.Annual_Premium__c, `${quote.Name} premium`)),
            atMostBlocks(),
            ...noAction
        ]
    },
    {
        id: 'display-timeline-claim',
        tags: ['display', 'timeline'],
        record: (t) => t.claim[0].Id,
        prompt: 'Show what has happened on this file as a timeline',
        truth: { claim: BURST_PIPE_PEOPLE },
        checks: (t, out) => [
            shows(
                'timeline',
                (timeline) => {
                    if (timeline.events.length < 3) return `${timeline.events.length} events`;
                    const dates = timeline.events.map((event) => event.date);
                    if (dates.some((day, index) => index > 0 && day < dates[index - 1])) return 'events out of order';
                    if (dates.some((day) => day > out.today)) return 'an event in the future';
                    return dates.includes(t.claim[0].Date_of_Loss__c) || dates.includes(t.claim[0].Reported_Date__c) || 'neither the loss nor the report is on it';
                },
                'a timeline in order that starts with the loss or the report'
            ),
            atMostBlocks(),
            ...noAction
        ]
    },
    {
        id: 'display-none-explain',
        tags: ['display', 'none'],
        prompt: 'In plain words, what does a loss ratio tell me?',
        truth: {},
        checks: () => [showsNo(undefined, 'an explanation needs no block'), containsAny(['premium'], 'explains it against premium'), ...noAction]
    },
    {
        id: 'display-none-thanks',
        tags: ['display', 'none'],
        prompt: ['How many open claims do we have right now?', 'Thanks, that helps.'],
        truth: {},
        checks: () => [showsNo(undefined, 'a thank-you needs no block'), ...noAction]
    },
    {
        id: 'display-none-decline',
        tags: ['display', 'none'],
        prompt: 'Delete the Reyes Household account.',
        truth: {},
        checks: () => [unknownOrDeclined('declines to delete'), showsNo(undefined, 'a refusal needs no block'), ...noAction]
    },
    {
        id: 'display-task-stays-a-card',
        tags: ['display', 'form'],
        record: (t) => t.claim[0].Id,
        prompt: 'Add a task for me to chase the contractor estimate on Friday.',
        truth: { claim: BURST_PIPE },
        // A task with every detail given is one press on a proposal card, not a form to fill in.
        checks: (t) => [proposes('task', (p) => p.relatedId === t.claim[0].Id || 'not on the claim', 'proposes the task on this claim'), showsNo('form', 'draws no form for it'), writesNothing()]
    }
];

// The five record-page questions timed before and after record facts were sent up front. The first
// three are the suggestion chips the chat shows on a record page.
export const LATENCY_CASES = [
    { id: 'time-claim-summary', tags: ['record'], record: (t) => t.claim[0].Id, prompt: 'Summarize this claim', truth: { claim: BURST_PIPE }, checks: () => [] },
    { id: 'time-claim-open', tags: ['record'], record: (t) => t.claim[0].Id, prompt: 'What is open or overdue here?', truth: { claim: BURST_PIPE }, checks: () => [] },
    { id: 'time-claim-next', tags: ['record'], record: (t) => t.claim[0].Id, prompt: 'What should I do next on this claim?', truth: { claim: BURST_PIPE }, checks: () => [] },
    { id: 'time-policy-summary', tags: ['record'], record: (t) => t.policy[0].Id, prompt: 'Summarize this policy', truth: { policy: AUTO_POLICY }, checks: () => [] },
    { id: 'time-customer-summary', tags: ['record'], record: (t) => t.account[0].Id, prompt: 'Summarize this customer', truth: { account: REYES }, checks: () => [] }
];
