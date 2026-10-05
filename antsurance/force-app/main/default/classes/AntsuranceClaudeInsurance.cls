/**
 * @description The chat's knowledge of the Antsurance insurance model: the data model note and the
 * claim rules Claude is given, the facts and the card of a customer, policy, claim, sale and quote,
 * the file note and the status change it may prepare, and what to suggest asking. It ships with the
 * full app only. AntsuranceClaudeModel finds it by name, so the chat's own classes do not depend on
 * it, and an org that installed Ask Claude alone gets the model that reads any org's schema instead.
 *
 * What the chat tells Claude in this org is exactly what is written here: change a word and the
 * chat's eval in scripts/eval should be run again.
 */
public with sharing class AntsuranceClaudeInsurance extends AntsuranceClaudeModel {
    // ---------- What Claude is told ----------

    // Added for the chat panel, which can show a proposal as a card. Other callers get the query tool only.
    private static final String ACTIONS_PROMPT =
        '\n\nYou can prepare three kinds of change for the user to approve with one press: a follow-up task (propose_task), a file note (propose_file_note) ' +
        'and a status change on a claim or service request (propose_case_status). Calling one of these tools writes nothing. ' +
        'It shows the user a card with Confirm and Cancel buttons, and the record is created or changed only if they press Confirm. ' +
        'So never say a task, note or status change has been made; say it is ready for them to confirm. ' +
        'A later user message may begin with a bracketed App note saying which cards they confirmed or canceled: only then is it done. ' +
        'Propose a change only when the user asks for one, propose exactly what they asked for, and look up any Id you need first. ' +
        'A task to call, write to or meet the customer is about a person: on a claim or service request that person is its Contact, so pass their Id as contact_id. ' +
        'When you propose, the card shows the details, so add at most one short sentence. ' +
        'For any other new record or change to fields, on a task, file note, claim, service request, lead, contact, customer account, policy sale or policy, ' +
        'draw a form with show_form: the user reviews it, edits it and saves it themselves, and until they do nothing has changed. ' +
        'You cannot delete anything, change many records at once, or change what a form does not cover (quotes, coverages, endorsements, insured assets, drivers, payments). ' +
        'When asked for one of those, say plainly that you cannot do it from here, and do not offer something else in its place unless they ask.';

    // The custom objects and fields Claude cannot guess. AntsuranceClaudeInsuranceTest fails to compile
    // if a field named here is removed, so keep the two in step.
    @TestVisible
    private static final String DATA_MODEL =
        '\n\nData model, with the API names to use in SOQL:\n' +
        '- Account: RecordType.DeveloperName is Household (personal lines), Business (commercial lines) or Agency (a broker that places policies). ' +
        'Customer_Segment__c, Customer_Since__c, Active_Policies__c and Premium_in_Force__c (both count policies in force), Customer_Brief__c (a written brief). ' +
        'A household\'s members are its Contacts: Household_Role__c, Primary_Member__c, Licensed_Driver__c, Preferred_Contact_Method__c.\n' +
        '- Policy__c: Name is the policy number. Account__c is the policyholder (Account__r.Name), Primary_Insured__c is a Contact, Producer__c is the agency Account. ' +
        'Line_of_Business__c, Status__c (Quoted, Active, Pending Renewal, Lapsed, Cancelled, Expired; in force means Active or Pending Renewal), ' +
        'Effective_Date__c, Expiration_Date__c, Days_to_Renewal__c, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Billing_Frequency__c, ' +
        'Payment_Status__c (Current, Past Due, Paid in Full), Insured_Item__c, Underwriting_Notes__c, ' +
        'Incurred_Losses__c (paid plus outstanding reserve on its claims) and Loss_Ratio__c (incurred losses as a percentage of annual premium; 150 means 150%). Child relationships: ' +
        'Coverages__r (Policy_Coverage__c: Name, Category__c, Limit_Amount__c, Limit_Type__c, Deductible_Amount__c, Premium_Amount__c, What_Is_Covered__c), ' +
        'Participants__r (Policy_Participant__c: Name, Contact__c, Role__c such as Named Insured or Driver, Status__c, Relationship_to_Insured__c, and for drivers ' +
        'License_State__c, Years_Licensed__c, Driver_Rating__c, Violations_Past_3_Years__c, Accidents_Past_3_Years__c), ' +
        'Assets__r (Policy_Asset__c, what the policy insures: Name, Asset_Type__c of Vehicle, Dwelling, Rented Residence, Commercial Building, Business Property, Fleet or Operations, ' +
        'Identifier__c which is the VIN for a vehicle, Model_Year__c, Location__c, Use__c, Details__c, Insured_Value__c, Lienholder__c), ' +
        'Endorsements__r (Policy_Endorsement__c, the forms attached to the policy: Name, Form_Number__c, Type__c of Endorsement, Exclusion, Benefit, Discount or Lienholder or Mortgagee, ' +
        'Status__c, Effective_Date__c, Premium_Change__c, Limit_Amount__c, Description__c), ' +
        'Cases__r and File_Notes__r.\n' +
        '- Case: RecordType.DeveloperName is Claim or Policy_Service. Both have Policy__c, Reported_Date__c, Subject, Description, Status, Priority, IsClosed, ' +
        'Handled_By__c (the name of the adjuster or service rep working it; use this, not Owner, for who is handling it) and Days_Open__c (days since it was reported, or until it closed). ' +
        'A claim has Date_of_Loss__c, Loss_Type__c, Loss_Location__c, Severity__c (Low, Medium, High, Catastrophic), Estimated_Loss__c, Reserve_Amount__c, ' +
        'Paid_Amount__c, Outstanding_Reserve__c, Coverage_Check__c (whether the policy covered the date of loss), SIU_Referral__c (possible fraud), Subrogation_Potential__c, ' +
        'and Claude_Brief__c with Claude_Brief_At__c (a stored written brief of the claim and when it was written; long text, so select it but do not filter on it), and moves through New, Under Investigation, Appraisal, ' +
        'Approved, Payment Issued, then Closed or Denied. A service request has Request_Type__c (for example Add Driver) and moves through New, In Progress, Waiting on Customer, Closed.\n' +
        '- File_Note__c: the dated notes handlers write on a file. Case__c, Policy__c and Account__c say whose file; Note_Type__c, Note_Date__c, Author_Name__c, Body__c (long text: select it, but it cannot be filtered on). ' +
        'Read these when asked what has happened on a claim, policy or customer.\n' +
        '- Opportunity: a policy sale. Line_of_Business__c, Type (New Business, Renewal, Cross-Sell), Policy__c, and Amount is annual premium. ' +
        'Stages: Submission Received, Underwriting Review, Quote Issued, Bind Requested, then Bound or Declined.\n' +
        '- Quote: the priced options under a policy sale (child relationship Quotes on Opportunity). Name is the option, OpportunityId, Status (Draft, Issued, Presented, Accepted, Bound, Declined, Expired), ' +
        'Annual_Premium__c, Coverage_Limit__c, Deductible__c, Issued_Date__c, Days_Since_Issued__c, ExpirationDate (valid until), Underwriter__c (a name), Description. ' +
        'A quote is waiting on the customer while Issued or Presented. ' +
        'Submission_Channel__c (Phone, Online, Agent, In Person: how the request came in), Needs_Underwriting_Review__c (true when an answer needs an underwriter). ' +
        'Configuration__c holds the configurator answers as JSON; do not select it unless asked what the customer answered.\n' +
        '- Lead: Product_Interest__c. Task: OwnerId, Subject, ActivityDate (due date), Status, Priority, IsClosed, WhatId (a claim, request, policy, sale or quote) and WhoId (a contact).\n' +
        'Naming a Case: it is a claim only when RecordType.DeveloperName is Claim; when it is Policy_Service call it a service request. ' +
        'Never guess which from a number, and name it as the pages do, by its Subject with its number (Service request 00002611: Wants to reinstate after missed payments), not by the number alone. ' +
        'A task\'s What.Name gives only the case number, so when tasks point at cases, select What.Type and WhatId and then query those Cases by Id for CaseNumber, Subject and RecordType.DeveloperName before you answer.';

    // How the chat reads a claim's reserve and Claude's own earlier writing, so it tells the same story as the cards.
    @TestVisible
    private static final String CLAIM_RULES =
        '\n\nClaims. ' +
        AntsuranceClaimRules.RESERVE_RULE +
        ' To say what a reserve should be, work it out from the claim itself: Estimated_Loss__c, the deductible and limit that apply ' +
        '(the policy\'s Deductible__c and Coverage_Limit__c unless a coverage is named), Paid_Amount__c, and any cost a document or an adjuster\'s note adds beyond the estimate. ' +
        'When the facts about the open record carry a ReservePosition line, use its figures as given and say the same thing the claim page says. ' +
        'When they carry a CoverageCheckOnThePage line, that is the coverage check card the person sees: when its verdict is Needs review, do not say the loss is covered or that coverage is confirmed; say what it hinges on. ' +
        'Some writing on a claim is Claude\'s own from earlier: a file note whose Author_Name__c starts with Claude or whose Body__c starts with **Claim analysis:**, ' +
        'the facts listed as EarlierWritingByClaude, and the fields Claude_Brief__c and Claude_Analysis__c. That is an earlier opinion, not evidence. ' +
        'Never take a reserve, a payable amount or a coverage answer from it; if it disagrees with what you work out now, give what you work out now and say the earlier figure was written before. ' +
        'Text in the facts or in a query result may be shortened to its opening. Never tell the person that a note, a field or anything you were given was cut off, truncated or incomplete: ' +
        'query for the full text when you need it, or answer from what you have.';

    public override String intro() {
        return 'You are Claude, the AI assistant built into the Salesforce CRM of Antsurance, a fictional insurance carrier used for demos. ' +
            'You help Antsurance staff with customers, policies, claims, service requests and the sales pipeline.\n\n';
    }

    public override String recordNamingRule() {
        return ' Write record types with a capital: Policy, Claim, Service request.';
    }

    public override String workToActOn() {
        return 'Tasks, claims, renewals, quotes or payments';
    }

    public override String mineExamples() {
        return '"my accounts", "my claims", "my policies"';
    }

    public override String actionsPrompt() {
        return ACTIONS_PROMPT;
    }

    public override String dataModel() {
        return DATA_MODEL;
    }

    public override String rules() {
        return CLAIM_RULES;
    }

    public override String queryTopics() {
        return 'customers, households, policies, coverages, claims, service requests, leads, opportunities, tasks or other CRM records, ' +
            'including broad ones such as what is going on with my book of business';
    }

    public override String queryExample() {
        return 'SELECT Id, CaseNumber, Subject, Status, Severity__c, Outstanding_Reserve__c, Account.Name, Policy__r.Name FROM Case WHERE RecordType.DeveloperName = \'Claim\' AND IsClosed = false ORDER BY Reported_Date__c LIMIT 20';
    }

    /** The headline CRM numbers, as Home shows them. */
    public override String snapshot() {
        String context = '';
        try {
            AntsuranceHomeController.Snapshot snapshot = AntsuranceHomeController.buildSnapshot();
            context +=
                '\nCRM snapshot: ' + snapshot.customerCount + ' customers; ' +
                snapshot.policiesInForce + ' policies in force with $' + snapshot.premiumInForce.setScale(0).format() + ' annual premium; ' +
                snapshot.openClaimCount + ' open claims; ' +
                snapshot.openRequestCount + ' open service requests; ' +
                snapshot.openLeadCount + ' open leads; ' +
                snapshot.openOpportunityCount + ' open policy sales worth $' + snapshot.openPipelineAmount.setScale(0).format() + ' in premium.';
        } catch (QueryException e) {
            context += '\nNo CRM snapshot is available for this user.';
        }
        return context;
    }

    public override String openRecordPage() {
        return ' The page it sits on is the open record\'s own page, which already shows that record\'s summary card, so never call show_record for the open record.';
    }

    public override String alreadyOpen() {
        return 'That record is already open on the user\'s screen, with this card on its page. Answer in words instead of showing it again.';
    }

    // ---------- The open record's facts ----------

    // What Claude wrote earlier is an opinion, so its opening is enough.
    private static final Integer MAX_EARLIER = 300;
    private static final String EARLIER_STANDING = 'Written by Claude earlier and kept by a person. An earlier opinion, not evidence: do not take figures from it.';

    private static final String OPEN_TASKS =
        '(SELECT Id, Subject, ActivityDate, Status, Priority, Owner.Name, Who.Name FROM Tasks WHERE IsClosed = false ORDER BY ActivityDate NULLS LAST LIMIT 8)';
    private static final String RECENT_NOTES =
        '(SELECT Id, Note_Type__c, Note_Date__c, Author_Name__c, Body__c FROM File_Notes__r ORDER BY Note_Date__c DESC NULLS LAST LIMIT 5)';

    // One query per kind of record. AntsuranceClaudeRecordFactsTest runs each, so a renamed field fails there.
    @TestVisible
    private static final Map<String, String> QUERIES = new Map<String, String>{
        'Case' =>
            'SELECT Id, CaseNumber, Subject, RecordType.Name, Status, Priority, IsClosed, Origin, Description, CreatedDate, ClosedDate, ' +
            'Reported_Date__c, Days_Open__c, Handled_By__c, Owner.Name, Account.Id, Account.Name, Contact.Id, Contact.Name, ' +
            'Policy__r.Id, Policy__r.Name, Policy__r.Line_of_Business__c, Policy__r.Status__c, Policy__r.Effective_Date__c, Policy__r.Expiration_Date__c, ' +
            'Policy__r.Coverage_Limit__c, Policy__r.Deductible__c, Policy__r.Payment_Status__c, ' +
            'Request_Type__c, Date_of_Loss__c, Loss_Type__c, Loss_Location__c, Severity__c, Estimated_Loss__c, Reserve_Amount__c, Paid_Amount__c, ' +
            'Outstanding_Reserve__c, Coverage_Check__c, SIU_Referral__c, Subrogation_Potential__c, ' +
            RECENT_NOTES + ', ' + OPEN_TASKS + ' FROM Case',
        'Policy__c' =>
            'SELECT Id, Name, Line_of_Business__c, Status__c, Effective_Date__c, Expiration_Date__c, Days_to_Renewal__c, Annual_Premium__c, Coverage_Limit__c, ' +
            'Deductible__c, Billing_Frequency__c, Payment_Status__c, Insured_Item__c, Underwriting_Notes__c, Incurred_Losses__c, Loss_Ratio__c, ' +
            'Account__r.Id, Account__r.Name, Primary_Insured__r.Id, Primary_Insured__r.Name, Producer__r.Name, ' +
            '(SELECT Name, Category__c, Limit_Amount__c, Limit_Type__c, Deductible_Amount__c, Premium_Amount__c FROM Coverages__r ORDER BY Name LIMIT 20), ' +
            '(SELECT Name, Role__c, Status__c, Driver_Rating__c, Violations_Past_3_Years__c, Accidents_Past_3_Years__c FROM Participants__r ORDER BY Name LIMIT 12), ' +
            '(SELECT Name, Asset_Type__c, Identifier__c, Model_Year__c, Location__c, Use__c, Insured_Value__c, Lienholder__c FROM Assets__r ORDER BY Name LIMIT 10), ' +
            '(SELECT Name, Form_Number__c, Type__c, Status__c, Effective_Date__c, Premium_Change__c FROM Endorsements__r ORDER BY Name LIMIT 15), ' +
            '(SELECT Id, CaseNumber, Subject, RecordType.Name, Status, IsClosed, Reported_Date__c, Outstanding_Reserve__c, Paid_Amount__c FROM Cases__r ORDER BY IsClosed, Reported_Date__c DESC NULLS LAST LIMIT 10), ' +
            RECENT_NOTES + ', ' + OPEN_TASKS + ' FROM Policy__c',
        'Account' =>
            'SELECT Id, Name, RecordType.Name, Customer_Segment__c, Customer_Since__c, Active_Policies__c, Premium_in_Force__c, Customer_Brief__c, Industry, Phone, BillingCity, BillingState, ' +
            '(SELECT Id, Name, Household_Role__c, Primary_Member__c, Licensed_Driver__c, Preferred_Contact_Method__c, Email, Phone FROM Contacts ORDER BY Name LIMIT 10), ' +
            '(SELECT Id, Name, Line_of_Business__c, Status__c, Annual_Premium__c, Effective_Date__c, Expiration_Date__c, Days_to_Renewal__c, Payment_Status__c, Loss_Ratio__c FROM Policies__r ORDER BY Expiration_Date__c LIMIT 15), ' +
            '(SELECT Id, CaseNumber, Subject, RecordType.Name, Status, IsClosed, Severity__c, Reported_Date__c, Outstanding_Reserve__c, Handled_By__c FROM Cases ORDER BY IsClosed, Reported_Date__c DESC NULLS LAST LIMIT 10), ' +
            '(SELECT Id, Name, StageName, Amount, CloseDate, Line_of_Business__c FROM Opportunities WHERE IsClosed = false ORDER BY CloseDate LIMIT 8), ' +
            RECENT_NOTES + ', ' + OPEN_TASKS + ' FROM Account',
        'Opportunity' =>
            'SELECT Id, Name, StageName, Amount, CloseDate, Type, Line_of_Business__c, NextStep, Description, IsClosed, IsWon, Owner.Name, ' +
            'Account.Id, Account.Name, Policy__r.Id, Policy__r.Name, Policy__r.Status__c, ' +
            '(SELECT Id, Name, Status, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Issued_Date__c, Days_Since_Issued__c, ExpirationDate, ' +
            'Submission_Channel__c, Needs_Underwriting_Review__c, Underwriter__c FROM Quotes ORDER BY Annual_Premium__c LIMIT 8), ' +
            OPEN_TASKS + ' FROM Opportunity',
        'Quote' =>
            'SELECT Id, Name, QuoteNumber, Status, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Issued_Date__c, Days_Since_Issued__c, ExpirationDate, ' +
            'Submission_Channel__c, Needs_Underwriting_Review__c, Underwriter__c, Description, Configuration__c, ' +
            'Opportunity.Id, Opportunity.Name, Opportunity.StageName, Opportunity.Line_of_Business__c, Account.Id, Account.Name, ' +
            OPEN_TASKS + ' FROM Quote',
        'Contact' =>
            'SELECT Id, Name, Email, Phone, Household_Role__c, Primary_Member__c, Licensed_Driver__c, Preferred_Contact_Method__c, Account.Id, Account.Name, ' +
            '(SELECT Name, Role__c, Status__c, Policy__r.Id, Policy__r.Name, Policy__r.Line_of_Business__c, Policy__r.Status__c FROM Policy_Roles__r ORDER BY Name LIMIT 12), ' +
            '(SELECT Id, CaseNumber, Subject, RecordType.Name, Status FROM Cases WHERE IsClosed = false ORDER BY CreatedDate DESC LIMIT 8) FROM Contact',
        'Lead' =>
            'SELECT Id, Name, Company, Status, Rating, LeadSource, Product_Interest__c, Email, Phone, Description, Owner.Name, CreatedDate FROM Lead'
    };
    // The other options under the same sale, so "which quote is cheaper" needs no lookup.
    private static final String SIBLING_QUOTES =
        'SELECT Id, Name, Status, Annual_Premium__c, Coverage_Limit__c, Deductible__c FROM Quote WHERE OpportunityId = :saleId AND Id != :recordId ORDER BY Annual_Premium__c LIMIT 8';


    public override String factsQuery(String objectName) {
        return QUERIES.get(objectName);
    }

    public override void addFacts(Map<String, Object> facts, SObject record) {
        String objectName = record.getSObjectType().getDescribe().getName();
        separateClaudeNotes(facts, record);
        if (objectName == 'Case') {
            addReservePosition(facts, record.Id);
        }
        if (objectName == 'Quote') {
            addSiblingQuotes(facts, record);
        }
    }

    private static void addSiblingQuotes(Map<String, Object> facts, SObject quote) {
        SObject sale = quote.getSObject('Opportunity');
        if (sale == null) {
            return;
        }
        List<Object> others = new List<Object>();
        for (SObject other : Database.queryWithBinds(SIBLING_QUOTES, new Map<String, Object>{ 'saleId' => sale.Id, 'recordId' => quote.Id }, AccessLevel.USER_MODE)) {
            others.add(AntsuranceClaudeRecordFacts.toPlainMap(other));
        }
        if (!others.isEmpty()) {
            facts.put('OtherQuotesOnThisSale', others);
        }
    }

    /**
     * Notes saved from Claude's own analysis are taken out of the file notes and listed apart, marked
     * as an earlier opinion, so the chat does not read its own past conclusion as evidence.
     */
    private static void separateClaudeNotes(Map<String, Object> facts, SObject record) {
        List<SObject> notes;
        try {
            notes = record.getSObjects('File_Notes__r');
        } catch (SObjectException e) {
            // This kind of record has no file notes.
            return;
        }
        if (notes == null || notes.isEmpty()) {
            return;
        }
        List<Object> written = new List<Object>();
        List<Object> earlier = new List<Object>();
        for (SObject note : notes) {
            File_Note__c fileNote = (File_Note__c) note;
            if (AntsuranceClaimRules.isClaudeNote(fileNote)) {
                earlier.add(
                    new Map<String, Object>{
                        'Kind' => 'File note saved from Claude\'s claim analysis',
                        'Note_Date__c' => fileNote.Note_Date__c,
                        'Standing' => EARLIER_STANDING,
                        'Opening' => AntsuranceClaudeRecordFacts.excerpt(fileNote.Body__c, MAX_EARLIER)
                    }
                );
            } else {
                written.add(AntsuranceClaudeRecordFacts.toPlainMap(note));
            }
        }
        if (written.isEmpty()) {
            facts.remove('File_Notes__r');
        } else {
            facts.put('File_Notes__r', written);
        }
        if (!earlier.isEmpty()) {
            facts.put('EarlierWritingByClaude', earlier);
        }
    }

    /** On a claim, where the reserve stands against what is payable, worked out by the rule every card uses. */
    private static void addReservePosition(Map<String, Object> facts, Id recordId) {
        List<Case> claims = [
            SELECT Reserve_Amount__c, Estimated_Loss__c, Coverage_Read__c, Policy__r.Deductible__c, Policy__r.Coverage_Limit__c, RecordType.DeveloperName
            FROM Case
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
        if (claims.isEmpty() || claims[0].RecordType?.DeveloperName != 'Claim') {
            return;
        }
        AntsuranceClaimRules.Terms terms = AntsuranceClaimRules.termsFor(claims[0]);
        AntsuranceClaimRules.Position at = AntsuranceClaimRules.position(claims[0].Reserve_Amount__c, claims[0].Estimated_Loss__c, terms.deductible, terms.limitAmount);
        facts.put('ReservePosition', AntsuranceClaimRules.payableLine(at) + (at.payable == null ? '' : ' The limit and deductible are from ' + terms.source + '.'));
        String check = coverageCheckLine(claims[0].Coverage_Read__c);
        if (check != null) {
            facts.put('CoverageCheckOnThePage', check);
        }
    }

    /** What the coverage check card on the claim page says, so the chat does not call coverage settled when the card does not. */
    private static String coverageCheckLine(String stored) {
        if (String.isBlank(stored)) {
            return null;
        }
        try {
            Map<String, Object> check = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(stored)).get('check');
            if (check == null || String.isBlank((String) check.get('verdict'))) {
                return null;
            }
            String summary = (String) check.get('summary');
            return 'Verdict: ' + check.get('verdict') + '.' + (String.isBlank(summary) ? '' : ' ' + AntsuranceClaudeRecordFacts.excerpt(summary, MAX_EARLIER));
        } catch (Exception e) {
            // A check this class cannot read is the same as no check.
            return null;
        }
    }

    // ---------- Changes Claude may prepare ----------

    public static final String NOTE_TOOL = 'propose_file_note';
    public static final String STATUS_TOOL = 'propose_case_status';
    private static final String KIND_NOTE = 'file_note';
    private static final String KIND_STATUS = 'case_status';
    private static final Integer MAX_NOTE_BODY = 32000;
    @TestVisible
    private static final List<String> NOTE_TYPES = new List<String>{ 'Contact', 'Investigation', 'Coverage', 'Reserve', 'Payment', 'Underwriting', 'Service', 'General' };
    // The statuses each kind of case moves through, as the chat's data model note describes them.
    @TestVisible
    private static final Map<String, List<String>> STATUSES = new Map<String, List<String>>{
        'Claim' => new List<String>{ 'New', 'Under Investigation', 'Appraisal', 'Approved', 'Payment Issued', 'Closed', 'Denied' },
        'Policy_Service' => new List<String>{ 'New', 'In Progress', 'Waiting on Customer', 'Closed' }
    };
    // What a task may be related to, and the words the card uses for each.
    private static final Map<String, String> TASK_PARENTS = new Map<String, String>{
        'Case' => 'case',
        'Policy__c' => 'policy',
        'Opportunity' => 'policy sale',
        'Quote' => 'quote',
        'Account' => 'customer'
    };
    private static final Map<String, String> NOTE_PARENT_FIELDS = new Map<String, String>{ 'Case' => 'Case__c', 'Policy__c' => 'Policy__c', 'Account' => 'Account__c' };

    /** A follow-up task, a file note, and a status change on a claim or service request. */
    public override List<Object> actionTools() {
        return new List<Object>{
            tool(
                AntsuranceClaudeActions.TASK_TOOL,
                'Propose a follow-up task for the user: a reminder or to-do with a due date, related to a claim, service request, policy, policy sale, quote or customer. ' +
                'Use it when they ask to be reminded, to follow up, or to add a task. The task is assigned to the user. ' + AntsuranceClaudeActions.NOT_WRITTEN,
                new Map<String, Object>{
                    'subject' => text('What to do, as a short imperative line, for example: Call Maria Reyes about the contractor estimate'),
                    'due_date' => text('The due date as YYYY-MM-DD. Work it out from today\'s date when they say tomorrow, Friday or in three days.'),
                    'related_record_id' => text('The 18-character Id of the claim, service request, policy, policy sale, quote or customer account the task is about. Use the open record when they say this or here.'),
                    'contact_id' => optionalText(
                        'The Id of the contact the task is about. Set it whenever the task is to call, write to, meet or send something to a person, named or not (the customer, him, her): ' +
                        'take the Id from the open record\'s facts when that person is there, otherwise query for it. Null only when the task involves no person.'
                    ),
                    'priority' => choice(AntsuranceClaudeActions.PRIORITIES, 'Normal unless they say it is urgent or can wait.'),
                    'notes' => optionalText('Comments for the task: context the user gave that does not fit the subject. Null when there is none.')
                },
                // Every field is required so that leaving the contact out is a decision, not an omission.
                new List<String>{ 'subject', 'due_date', 'related_record_id', 'contact_id', 'priority', 'notes' }
            ),
            tool(
                NOTE_TOOL,
                'Propose a dated note on the file of a claim, service request, policy or customer. Use it when the user asks to add, log or record a note. ' +
                'Write the note as the user would, in their words, without adding facts they did not give. ' + AntsuranceClaudeActions.NOT_WRITTEN,
                new Map<String, Object>{
                    'record_id' => text('The 18-character Id of the claim or service request (Case), policy or customer account the note belongs on.'),
                    'note_type' => choice(
                        NOTE_TYPES,
                        'Contact for a conversation with someone, Investigation for findings on a claim, Coverage for a coverage question, Reserve and Payment for money on a claim, ' +
                        'Underwriting for risk details on a policy, Service for a policy change, General otherwise.'
                    ),
                    'body' => text('The note text. Plain sentences; Markdown is allowed.')
                },
                new List<String>{ 'record_id', 'note_type', 'body' }
            ),
            tool(
                STATUS_TOOL,
                'Propose moving a claim or service request to another status. Use it when the user asks to move, mark, close or reopen one. ' +
                'A claim moves through New, Under Investigation, Appraisal, Approved, Payment Issued, then Closed or Denied. ' +
                'A service request moves through New, In Progress, Waiting on Customer, Closed. ' + AntsuranceClaudeActions.NOT_WRITTEN,
                new Map<String, Object>{
                    'case_id' => text('The 18-character Id of the claim or service request (Case).'),
                    'new_status' => choice(allStatuses(), 'The status to move it to, valid for that kind of case.')
                },
                new List<String>{ 'case_id', 'new_status' }
            )
        };
    }

    public override Boolean taskNeedsARecord() {
        return true;
    }

    public override Boolean taskCanBeAbout(String objectName) {
        return TASK_PARENTS.containsKey(objectName);
    }

    public override String taskParentsRule() {
        return 'A task can be related to a claim, service request, policy, policy sale, quote or customer account.';
    }

    public override String wordFor(String objectName) {
        return TASK_PARENTS.containsKey(objectName) ? TASK_PARENTS.get(objectName) : 'contact';
    }

    public override String caseKind(String recordType) {
        return recordType == 'Claim' ? 'claim' : recordType == 'Policy_Service' ? 'service request' : 'case';
    }

    public override AntsuranceClaudeActions.Proposal propose(String toolName, Map<String, Object> input) {
        if (toolName == NOTE_TOOL) {
            return proposeNote(input);
        }
        if (toolName == STATUS_TOOL) {
            return proposeStatus(input);
        }
        throw new IllegalArgumentException('There is no such tool.');
    }

    public override AntsuranceClaudeActions.Outcome confirm(String kind, Map<String, Object> payload) {
        return kind == KIND_NOTE ? createNote(payload) : kind == KIND_STATUS ? changeStatus(payload) : null;
    }

    private static AntsuranceClaudeActions.Proposal proposeNote(Map<String, Object> input) {
        String body = AntsuranceClaudeActions.required(input, 'body', MAX_NOTE_BODY);
        AntsuranceClaudeActions.Target parent = AntsuranceClaudeActions.findTarget((String) input.get('record_id'), NOTE_PARENT_FIELDS.keySet(), 'A file note can be added to a claim, service request, policy or customer account.');
        String noteType = NOTE_TYPES.contains((String) input.get('note_type')) ? (String) input.get('note_type') : 'General';

        AntsuranceClaudeActions.Proposal proposal = new AntsuranceClaudeActions.Proposal();
        proposal.kind = KIND_NOTE;
        proposal.title = 'Add a file note';
        proposal.confirmLabel = 'Add note';
        proposal.details.add(new AntsuranceClaudeActions.Detail('On', parent.name, parent.recordId));
        proposal.details.add(new AntsuranceClaudeActions.Detail('Type', noteType, null));
        proposal.body = body;
        proposal.payloadJson = JSON.serialize(new Map<String, Object>{ 'kind' => KIND_NOTE, 'recordId' => parent.recordId, 'noteType' => noteType, 'body' => body });
        return proposal;
    }

    private static AntsuranceClaudeActions.Proposal proposeStatus(Map<String, Object> input) {
        AntsuranceClaudeActions.Target target = AntsuranceClaudeActions.findTarget((String) input.get('case_id'), new Set<String>{ 'Case' }, 'case_id must be the Id of a claim or service request.');
        String status = (String) input.get('new_status');
        List<String> allowed = STATUSES.get(target.recordType);
        if (allowed == null) {
            throw new IllegalArgumentException('Only claims and service requests can be moved from the chat.');
        }
        if (!allowed.contains(status)) {
            throw new IllegalArgumentException('A ' + target.kindLabel + ' cannot be ' + status + '. Its statuses are: ' + String.join(allowed, ', ') + '.');
        }
        if (status == target.status) {
            throw new IllegalArgumentException('That ' + target.kindLabel + ' is already ' + status + '. Tell the user; there is nothing to change.');
        }

        AntsuranceClaudeActions.Proposal proposal = new AntsuranceClaudeActions.Proposal();
        proposal.kind = KIND_STATUS;
        // Short enough to sit on one line in the utility bar panel; the first row says which kind of case.
        proposal.title = 'Change the status';
        proposal.confirmLabel = 'Change status';
        // The label already says what kind of case it is.
        proposal.details.add(new AntsuranceClaudeActions.Detail(target.kindLabel.capitalize(), target.shortName, target.recordId));
        proposal.details.add(new AntsuranceClaudeActions.Detail('From', target.status, null));
        proposal.details.add(new AntsuranceClaudeActions.Detail('To', status, null));
        proposal.payloadJson = JSON.serialize(new Map<String, Object>{ 'kind' => KIND_STATUS, 'caseId' => target.recordId, 'status' => status, 'fromStatus' => target.status });
        return proposal;
    }

    private static AntsuranceClaudeActions.Outcome createNote(Map<String, Object> payload) {
        AntsuranceClaudeActions.Target parent = AntsuranceClaudeActions.findTarget((String) payload.get('recordId'), NOTE_PARENT_FIELDS.keySet(), AntsuranceClaudeActions.INVALID_ACTION);
        File_Note__c note = new File_Note__c(
            Note_Type__c = NOTE_TYPES.contains((String) payload.get('noteType')) ? (String) payload.get('noteType') : 'General',
            Body__c = AntsuranceClaudeActions.required(payload, 'body', MAX_NOTE_BODY),
            Note_Date__c = Datetime.now()
        );
        note.put(NOTE_PARENT_FIELDS.get(parent.objectName), parent.recordId);
        // A note on a case or policy also belongs to the records above it, as in the file notes timeline.
        if (parent.objectName == 'Case') {
            Case parentCase = [SELECT Policy__c, AccountId FROM Case WHERE Id = :parent.recordId WITH USER_MODE];
            note.Policy__c = parentCase.Policy__c;
            note.Account__c = parentCase.AccountId;
        } else if (parent.objectName == 'Policy__c') {
            note.Account__c = [SELECT Account__c FROM Policy__c WHERE Id = :parent.recordId WITH USER_MODE].Account__c;
        }
        insert as user note;

        AntsuranceClaudeActions.Outcome outcome = new AntsuranceClaudeActions.Outcome();
        outcome.recordId = parent.recordId;
        outcome.message = note.Note_Type__c + ' note added.';
        outcome.linkLabel = 'Open ' + parent.kindLabel;
        outcome.touchedIds.add(parent.recordId);
        return outcome;
    }

    private static AntsuranceClaudeActions.Outcome changeStatus(Map<String, Object> payload) {
        AntsuranceClaudeActions.Target target = AntsuranceClaudeActions.findTarget((String) payload.get('caseId'), new Set<String>{ 'Case' }, AntsuranceClaudeActions.INVALID_ACTION);
        String status = (String) payload.get('status');
        List<String> allowed = STATUSES.get(target.recordType);
        if (allowed == null || !allowed.contains(status)) {
            throw new IllegalArgumentException(AntsuranceClaudeActions.INVALID_ACTION);
        }
        update as user new Case(Id = target.recordId, Status = status);

        AntsuranceClaudeActions.Outcome outcome = new AntsuranceClaudeActions.Outcome();
        outcome.recordId = target.recordId;
        outcome.message = 'Status changed to ' + status + '.';
        outcome.linkLabel = 'Open ' + target.kindLabel;
        outcome.touchedIds.add(target.recordId);
        return outcome;
    }

    private static List<String> allStatuses() {
        // Apex names ignore case, so this list cannot be called statuses beside STATUSES.
        List<String> everyStatus = new List<String>();
        for (String recordType : STATUSES.keySet()) {
            for (String status : STATUSES.get(recordType)) {
                if (!everyStatus.contains(status)) {
                    everyStatus.add(status);
                }
            }
        }
        return everyStatus;
    }

    // ---------- What Claude may draw ----------

    private static final Map<String, String> ICONS = new Map<String, String>{
        'Case' => 'utility:case',
        'Policy__c' => 'utility:shield',
        'Account' => 'utility:company',
        'Contact' => 'utility:user',
        'Quote' => 'utility:quote',
        'Opportunity' => 'utility:opportunity',
        'Lead' => 'utility:lead',
        'Task' => 'utility:task'
    };
    // The page cards the chat can embed where it has the room, by object. Everything also gets the
    // facts for a compact card, which is what the narrow panel draws.
    private static final Map<String, String> PAGE_CARDS = new Map<String, String>{
        'Case' => 'case',
        'Policy__c' => 'policy',
        'Account' => 'customer',
        'Contact' => 'contact',
        'Quote' => 'quote'
    };
    @TestVisible
    private static final Map<String, String> CARD_QUERIES = new Map<String, String>{
        'Case' =>
            'SELECT Id, CaseNumber, Subject, Status, IsClosed, RecordType.Name, RecordType.DeveloperName, Severity__c, Loss_Type__c, Request_Type__c, Reported_Date__c, ' +
            'Handled_By__c, Outstanding_Reserve__c, Paid_Amount__c, Days_Open__c, Account.Name, Policy__r.Name FROM Case',
        'Policy__c' =>
            'SELECT Id, Name, Line_of_Business__c, Status__c, Effective_Date__c, Expiration_Date__c, Annual_Premium__c, Coverage_Limit__c, Deductible__c, ' +
            'Payment_Status__c, Account__r.Name FROM Policy__c',
        'Account' => 'SELECT Id, Name, RecordType.Name, Customer_Segment__c, Customer_Since__c, Active_Policies__c, Premium_in_Force__c, Phone, BillingCity, BillingState FROM Account',
        'Contact' => 'SELECT Id, Name, Email, Phone, Household_Role__c, Licensed_Driver__c, Preferred_Contact_Method__c, Account.Name FROM Contact',
        'Quote' => 'SELECT Id, Name, Status, Annual_Premium__c, Coverage_Limit__c, Deductible__c, ExpirationDate, Underwriter__c, Opportunity.Name, Account.Name FROM Quote',
        'Opportunity' => 'SELECT Id, Name, StageName, Amount, CloseDate, Type, Line_of_Business__c, NextStep, IsClosed, IsWon, Account.Name, Owner.Name FROM Opportunity',
        'Lead' => 'SELECT Id, Name, Company, Status, Rating, LeadSource, Product_Interest__c, Email, Phone, Owner.Name, CreatedDate FROM Lead',
        'Task' => 'SELECT Id, Subject, ActivityDate, Status, Priority, IsClosed, Description, Owner.Name, What.Name, Who.Name FROM Task'
    };
    // What a form may create or edit. Anything else is refused with a reason Claude sees.
    @TestVisible
    private static final List<String> FORM_OBJECTS = new List<String>{ 'Task', 'File_Note__c', 'Case', 'Lead', 'Contact', 'Account', 'Opportunity', 'Policy__c' };

    // What Salesforce's email composer can be opened against.
    private static final Set<String> EMAIL_OBJECTS = new Set<String>{ 'Account', 'Contact', 'Lead', 'Opportunity', 'Policy__c' };


    public override List<String> formObjects() {
        return FORM_OBJECTS;
    }

    public override Set<String> emailObjects() {
        return EMAIL_OBJECTS;
    }

    /** A new address starts in the United States, which is where Antsurance writes business. */
    public override String defaultCountry() {
        return 'US';
    }

    public override String displayTools() {
        List<String> tools = new List<String>{
            tool(
                AntsuranceClaudeDisplay.RECORD_TOOL,
                'Draw the summary card of one record: a claim or service request, policy, customer account, contact, quote, policy sale, lead or task. ' +
                'Use it when the answer is one record the user wants to see (show me, pull up, find, what is the status of a named record). ' +
                'The card carries the record\'s key facts, so say only what matters about it in a sentence. ' +
                'Do not use it for the record the user already has open on screen.',
                new List<AntsuranceClaudeDisplay.Prop>{ text('say', AntsuranceClaudeDisplay.SAY), text('record_id', 'The 18-character Id of the record. Query for it first if you do not have it.') }
            ),
            tool(
                AntsuranceClaudeDisplay.METRICS_TOOL,
                'Draw one to four headline figures as tiles. Use it when the answer is a figure or a few related figures: a total, a count, an average, a ratio, ' +
                'or how the book, the pipeline or a customer is doing in numbers. Work the figures out with COUNT, SUM or AVG in SOQL and pass them exactly.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    text('say', AntsuranceClaudeDisplay.SAY),
                    listOf(
                        'tiles',
                        'One to four tiles, the most important first.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            text('label', 'What the figure is, in two or three words, for example Outstanding reserve.'),
                            text('value', 'The figure as it should read, for example $1,077,075, 28 or 63%.'),
                            text('note', 'A few words that give it meaning, for example across 28 open claims. Empty string when there is none.'),
                            choice('tone', AntsuranceClaudeDisplay.TONES, 'good for a healthy figure, watch for one to keep an eye on, alert for one that needs action, neutral otherwise.')
                        }
                    )
                }
            ),
            tool(
                AntsuranceClaudeDisplay.CHART_TOOL,
                'Draw a chart from values you have queried. Use it for a breakdown by category or a trend over time: by line of business, by status, by adjuster, by month. ' +
                'Group and total in SOQL and pass the exact figures; one series only.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    text('say', AntsuranceClaudeDisplay.SAY),
                    text('title', 'What the chart shows, in a few words, for example Premium in force by line.'),
                    choice(
                        'chart_type',
                        AntsuranceClaudeDisplay.CHART_TYPES,
                        'bar for a ranked breakdown by category, largest first. column for a few periods side by side. line for a trend over time, oldest first. ' +
                        'donut for shares of a whole, six slices at most.'
                    ),
                    choice('unit', AntsuranceClaudeDisplay.UNITS, 'What the values are: dollars, a count of things, or percent.'),
                    listOf(
                        'points',
                        'Two to twelve points, in the order to draw them.',
                        new List<AntsuranceClaudeDisplay.Prop>{ text('label', 'The category or period, kept short, for example Homeowners or Sep 2026.'), numberOf('value', 'The value as a plain number, for example 184250.') }
                    ),
                    text('highlight_label', 'The label of the one point your sentence picks out, exactly as written in points. Empty string for none.'),
                    text('caption', 'One line under the title saying what is counted and over what, for example Annual premium on policies in force. No figures.')
                }
            ),
            tool(
                AntsuranceClaudeDisplay.LIST_TOOL,
                'Draw a list of things to act on, each row with what it is, who it concerns, a few labeled facts and a link: overdue tasks, claims to chase, policies renewing, quotes waiting, payments past due. ' +
                'Use it instead of a table or bullets whenever the rows are work for someone to do. Up to eight rows, most urgent first; ' +
                'when there are more, show the eight most urgent and give the full count in say.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    text('say', AntsuranceClaudeDisplay.SAY),
                    text('title', 'What the list is, for example Overdue tasks or Renewing in the next 30 days.'),
                    listOf(
                        'items',
                        'One to eight rows, most urgent first.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            text('title', 'The task subject, the claim or request subject, or the policy number.'),
                            text(
                                'subtitle',
                                'Who or what it concerns, for example Reyes Household, Homeowners. A claim or service request is named by which it is and its subject, not its number alone, ' +
                                'for example Lucia Castellano, Service request: Wants to reinstate after missed payments. Empty string when there is nothing to add.'
                            ),
                            text('record_id', 'The 18-character Id of the record the row opens. Empty string when you do not have it.'),
                            text('amount', 'A formatted money amount when one matters for this row (a reserve, a premium), for example $12,400. Empty string otherwise.'),
                            listOf(
                                'chips',
                                'Up to three short labeled facts, each a few words that carry their own meaning, for example Due Oct 1, 3 days overdue, High severity, Under Investigation.',
                                new List<AntsuranceClaudeDisplay.Prop>{ text('label', 'The fact, with its word, for example Due Oct 1.'), choice('tone', AntsuranceClaudeDisplay.TONES, 'alert for overdue or severe, watch for due soon, good for done or healthy, neutral otherwise.') }
                            )
                        }
                    )
                }
            ),
            tool(
                AntsuranceClaudeDisplay.FORM_TOOL,
                'Draw a real Salesforce form in the chat, filled in with your suggested values, for the user to review, edit and save. ' +
                'Use it when they ask to create a record (a lead, contact, customer account, claim, service request, policy sale, policy, task or file note) or to change fields on one. ' +
                'Calling this writes nothing: the record is saved only if the user presses the form\'s button (Create, or Save changes), as them, ' +
                'so say the form is ready to review and never that a record was created or changed. ' +
                'When the request is exactly a follow-up task, a file note or a status move and you have every detail, use propose_task, propose_file_note or propose_case_status instead; ' +
                'use the form when they ask for a form, want to edit other fields, or should fill in details you do not have. ' +
                'Give three to eight fields that matter, by API name, with the fields a new record cannot be saved without. Look up any Id you need first.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    text('say', AntsuranceClaudeDisplay.SAY),
                    choice('mode', new List<String>{ 'create', 'edit' }, 'create for a new record, edit to change an existing one.'),
                    choice('object', FORM_OBJECTS, 'The object\'s API name. A claim or service request is a Case, a customer or agency is an Account, a policy sale is an Opportunity.'),
                    text('record_id', 'When editing, the 18-character Id of the record. Empty string when creating.'),
                    text('record_type', 'When creating a Case: Claim or Policy_Service. When creating an Account: Household, Business or Agency. Empty string otherwise.'),
                    listOf(
                        'fields',
                        'The fields to show, in the order to show them.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            text(
                                'name',
                                'The field\'s API name, for example Subject, Status, Policy__c or Date_of_Loss__c. For a person use FirstName and LastName. ' +
                                'For an address use Street, City, State (two letters, for example IL) and PostalCode, with the Billing or Mailing prefix on an account or contact.'
                            ),
                            text(
                                'value',
                                'Your suggested value as text: a date as YYYY-MM-DD, a number without symbols, true or false, a picklist value exactly as stored, a lookup as the 18-character Id. ' +
                                'Empty string to leave the field for the user to fill in (when editing, it then shows the current value).'
                            )
                        }
                    )
                }
            ),
            tool(
                AntsuranceClaudeDisplay.DRAFT_TOOL,
                'Draw a ready-to-send email or letter on a letter card with Copy and Open as email buttons. ' +
                'Use it whenever the user asks you to draft, write or reply with something that will be sent to a customer, agent or colleague. ' +
                'Put the whole message in subject and body, and base every fact in it on the records.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    text('say', AntsuranceClaudeDisplay.SAY),
                    choice('format', new List<String>{ 'email', 'letter' }, 'email unless they ask for a letter.'),
                    text('to_name', 'Who it is addressed to, for example Maria Reyes.'),
                    text('to_email', 'Their email address when the records have it. Empty string otherwise.'),
                    text('subject', 'The subject line. For a letter, the Re line.'),
                    text('body', 'The message from greeting to sign-off, as plain text with a blank line between paragraphs. No Markdown. Sign off with the user\'s name.'),
                    text('related_record_id', 'The Id of the claim, policy, policy sale or customer it concerns, so the email is logged there. Empty string when there is none.')
                }
            ),
            tool(
                AntsuranceClaudeDisplay.COMPARISON_TOOL,
                'Draw two to four options side by side with the same rows, one of them marked recommended. ' +
                'Use it to compare quote options, two policies or customers, or choices the user must pick between.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    text('say', AntsuranceClaudeDisplay.SAY),
                    text('title', 'What is being compared, for example Quote options for the Dubois auto policy.'),
                    listOf(
                        'columns',
                        'Two to four options, in the order to show them.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            text('name', 'The option\'s name, kept short, for example Standard or ANT-HO-204534.'),
                            text('record_id', 'The 18-character Id of the record this option is. Empty string when there is none.'),
                            flag('recommended', 'True for the one option you recommend, false for the rest. All false when you recommend none.')
                        }
                    ),
                    listOf(
                        'rows',
                        'Three to eight rows, the ones that differ first.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            text('label', 'What the row compares, for example Annual premium.'),
                            listOfText('values', 'One short value per option, in the same order as columns, for example $1,840.')
                        }
                    ),
                    text('reason', 'Why the recommended option, in one short sentence. Empty string when you recommend none.')
                }
            ),
            tool(
                AntsuranceClaudeDisplay.TIMELINE_TOOL,
                'Draw dated events in order. Use it for the history of a claim, request, policy, sale or customer: what happened and when, taken from file notes, tasks and the record\'s own dates. ' +
                'Only things that have happened, oldest first, twelve at most; what is due next belongs in say.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    text('say', AntsuranceClaudeDisplay.SAY),
                    text('title', 'Whose history this is, for example Claim 00002038 so far.'),
                    listOf(
                        'events',
                        'Two to twelve events, oldest first.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            text('date', 'The date as YYYY-MM-DD.'),
                            text('title', 'What happened, in a few words, for example Reserve set at $40,000.'),
                            text('detail', 'One line of detail: who did it or what was found. Empty string when there is none.'),
                            choice('tone', AntsuranceClaudeDisplay.TONES, 'alert for a setback or a problem, watch for something pending, good for progress or a payment, neutral otherwise.')
                        }
                    )
                }
            )
        };
        return String.join(tools, ',');
    }

    /** A record's own page card where it has one, with the facts for a compact card, which is what the narrow panel draws. */
    public override Map<String, Object> recordCard(Id recordId, String objectName) {
        if (!CARD_QUERIES.containsKey(objectName)) {
            throw new IllegalArgumentException('show_record can show a claim, service request, policy, customer, contact, quote, policy sale, lead or task. Answer in words for anything else.');
        }
        SObject record = AntsuranceClaudeDisplay.readOne(CARD_QUERIES.get(objectName), recordId);
        Map<String, Object> spec = new Map<String, Object>{
            'recordId' => recordId,
            'objectApiName' => objectName,
            'card' => PAGE_CARDS.containsKey(objectName) ? PAGE_CARDS.get(objectName) : 'compact',
            'eyebrow' => recordId.getSObjectType().getDescribe().getLabel(),
            'name' => objectName == 'Case' || objectName == 'Task' ? record.get('Subject') : record.get('Name'),
            'tone' => 'neutral',
            'icon' => ICONS.get(objectName)
        };
        List<Object> facts = new List<Object>();
        // The three facts the narrow panel shows for this kind of record.
        List<Object> keyFacts = new List<Object>();
        if (objectName == 'Case') {
            Boolean claim = AntsuranceClaudeDisplay.relatedField(record, 'RecordType', 'DeveloperName') == 'Claim';
            Boolean severe = record.get('Severity__c') == 'High' || record.get('Severity__c') == 'Catastrophic';
            spec.put('eyebrow', AntsuranceClaudeDisplay.relatedName(record, 'RecordType', 'Case') + ' ' + record.get('CaseNumber'));
            spec.put('name', record.get('Subject') == null ? record.get('CaseNumber') : record.get('Subject'));
            spec.put('status', record.get('Status'));
            spec.put('tone', record.get('IsClosed') == true ? 'good' : severe ? 'alert' : 'watch');
            if (claim) {
                spec.put('figure', AntsuranceClaudeDisplay.money((Decimal) record.get('Outstanding_Reserve__c')));
                spec.put('figureLabel', 'Outstanding reserve');
            }
            AntsuranceClaudeDisplay.addFact(facts, 'Customer', AntsuranceClaudeDisplay.relatedName(record, 'Account', null));
            AntsuranceClaudeDisplay.addFact(facts, 'Policy', AntsuranceClaudeDisplay.relatedName(record, 'Policy__r', null));
            AntsuranceClaudeDisplay.addFact(facts, claim ? 'Loss type' : 'Request', (String) record.get(claim ? 'Loss_Type__c' : 'Request_Type__c'));
            AntsuranceClaudeDisplay.addFact(facts, 'Severity', (String) record.get('Severity__c'));
            AntsuranceClaudeDisplay.addFact(facts, 'Reported', AntsuranceClaudeDisplay.shortDate((Date) record.get('Reported_Date__c')));
            AntsuranceClaudeDisplay.addFact(facts, 'Handled by', (String) record.get('Handled_By__c'));
            if (claim) {
                AntsuranceClaudeDisplay.addFact(keyFacts, 'Outstanding reserve', AntsuranceClaudeDisplay.money((Decimal) record.get('Outstanding_Reserve__c')));
                AntsuranceClaudeDisplay.addFact(keyFacts, 'Paid', AntsuranceClaudeDisplay.money((Decimal) record.get('Paid_Amount__c')));
                AntsuranceClaudeDisplay.addFact(keyFacts, 'Days open', record.get('Days_Open__c') == null ? null : ((Decimal) record.get('Days_Open__c')).setScale(0).format());
            } else {
                AntsuranceClaudeDisplay.addFact(keyFacts, 'Request', (String) record.get('Request_Type__c'));
                AntsuranceClaudeDisplay.addFact(keyFacts, 'Received', AntsuranceClaudeDisplay.shortDate((Date) record.get('Reported_Date__c')));
                AntsuranceClaudeDisplay.addFact(keyFacts, 'Handled by', (String) record.get('Handled_By__c'));
            }
        } else if (objectName == 'Policy__c') {
            String status = (String) record.get('Status__c');
            spec.put('status', status);
            spec.put('tone', status == 'Active' ? 'good' : status == 'Pending Renewal' || status == 'Quoted' ? 'watch' : status == 'Lapsed' || status == 'Cancelled' ? 'alert' : 'neutral');
            spec.put('figure', AntsuranceClaudeDisplay.money((Decimal) record.get('Annual_Premium__c')));
            spec.put('figureLabel', 'Annual premium');
            AntsuranceClaudeDisplay.addFact(facts, 'Customer', AntsuranceClaudeDisplay.relatedName(record, 'Account__r', null));
            AntsuranceClaudeDisplay.addFact(facts, 'Line', (String) record.get('Line_of_Business__c'));
            AntsuranceClaudeDisplay.addFact(facts, 'Effective', AntsuranceClaudeDisplay.shortDate((Date) record.get('Effective_Date__c')));
            AntsuranceClaudeDisplay.addFact(facts, 'Expires', AntsuranceClaudeDisplay.shortDate((Date) record.get('Expiration_Date__c')));
            AntsuranceClaudeDisplay.addFact(facts, 'Coverage limit', AntsuranceClaudeDisplay.money((Decimal) record.get('Coverage_Limit__c')));
            AntsuranceClaudeDisplay.addFact(facts, 'Deductible', AntsuranceClaudeDisplay.money((Decimal) record.get('Deductible__c')));
            AntsuranceClaudeDisplay.addFact(facts, 'Payment', (String) record.get('Payment_Status__c'));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Annual premium', AntsuranceClaudeDisplay.money((Decimal) record.get('Annual_Premium__c')));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Expires', AntsuranceClaudeDisplay.shortDate((Date) record.get('Expiration_Date__c')));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Coverage limit', AntsuranceClaudeDisplay.money((Decimal) record.get('Coverage_Limit__c')));
        } else if (objectName == 'Account') {
            spec.put('eyebrow', AntsuranceClaudeDisplay.relatedName(record, 'RecordType', 'Customer'));
            spec.put('status', record.get('Customer_Segment__c'));
            spec.put('figure', AntsuranceClaudeDisplay.money((Decimal) record.get('Premium_in_Force__c')));
            spec.put('figureLabel', 'Premium in force');
            AntsuranceClaudeDisplay.addFact(facts, 'Policies in force', record.get('Active_Policies__c') == null ? null : ((Decimal) record.get('Active_Policies__c')).setScale(0).format());
            AntsuranceClaudeDisplay.addFact(facts, 'Customer since', AntsuranceClaudeDisplay.shortDate((Date) record.get('Customer_Since__c')));
            AntsuranceClaudeDisplay.addFact(facts, 'Phone', (String) record.get('Phone'));
            AntsuranceClaudeDisplay.addFact(facts, 'Location', String.join(AntsuranceClaudeDisplay.nonBlank(new List<String>{ (String) record.get('BillingCity'), (String) record.get('BillingState') }), ', '));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Policies in force', record.get('Active_Policies__c') == null ? null : ((Decimal) record.get('Active_Policies__c')).setScale(0).format());
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Premium in force', AntsuranceClaudeDisplay.money((Decimal) record.get('Premium_in_Force__c')));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Open claims', String.valueOf(openClaims(recordId)));
        } else if (objectName == 'Contact') {
            spec.put('status', record.get('Household_Role__c'));
            AntsuranceClaudeDisplay.addFact(facts, 'Customer', AntsuranceClaudeDisplay.relatedName(record, 'Account', null));
            AntsuranceClaudeDisplay.addFact(facts, 'Email', (String) record.get('Email'));
            AntsuranceClaudeDisplay.addFact(facts, 'Phone', (String) record.get('Phone'));
            AntsuranceClaudeDisplay.addFact(facts, 'Prefers', (String) record.get('Preferred_Contact_Method__c'));
            AntsuranceClaudeDisplay.addFact(facts, 'Licensed driver', record.get('Licensed_Driver__c') == true ? 'Yes' : null);
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Customer', AntsuranceClaudeDisplay.relatedName(record, 'Account', null));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Phone', (String) record.get('Phone'));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Prefers', (String) record.get('Preferred_Contact_Method__c'));
        } else if (objectName == 'Quote') {
            String status = (String) record.get('Status');
            spec.put('status', status);
            spec.put('tone', status == 'Accepted' || status == 'Bound' ? 'good' : status == 'Declined' || status == 'Expired' ? 'neutral' : 'watch');
            spec.put('figure', AntsuranceClaudeDisplay.money((Decimal) record.get('Annual_Premium__c')));
            spec.put('figureLabel', 'Annual premium');
            AntsuranceClaudeDisplay.addFact(facts, 'Policy sale', AntsuranceClaudeDisplay.relatedName(record, 'Opportunity', null));
            AntsuranceClaudeDisplay.addFact(facts, 'Customer', AntsuranceClaudeDisplay.relatedName(record, 'Account', null));
            AntsuranceClaudeDisplay.addFact(facts, 'Coverage limit', AntsuranceClaudeDisplay.money((Decimal) record.get('Coverage_Limit__c')));
            AntsuranceClaudeDisplay.addFact(facts, 'Deductible', AntsuranceClaudeDisplay.money((Decimal) record.get('Deductible__c')));
            AntsuranceClaudeDisplay.addFact(facts, 'Valid until', AntsuranceClaudeDisplay.shortDate((Date) record.get('ExpirationDate')));
            AntsuranceClaudeDisplay.addFact(facts, 'Underwriter', (String) record.get('Underwriter__c'));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Annual premium', AntsuranceClaudeDisplay.money((Decimal) record.get('Annual_Premium__c')));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Deductible', AntsuranceClaudeDisplay.money((Decimal) record.get('Deductible__c')));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Valid until', AntsuranceClaudeDisplay.shortDate((Date) record.get('ExpirationDate')));
        } else if (objectName == 'Opportunity') {
            spec.put('status', record.get('StageName'));
            spec.put('tone', record.get('IsWon') == true ? 'good' : record.get('IsClosed') == true ? 'neutral' : 'watch');
            spec.put('figure', AntsuranceClaudeDisplay.money((Decimal) record.get('Amount')));
            spec.put('figureLabel', 'Annual premium');
            AntsuranceClaudeDisplay.addFact(facts, 'Customer', AntsuranceClaudeDisplay.relatedName(record, 'Account', null));
            AntsuranceClaudeDisplay.addFact(facts, 'Line', (String) record.get('Line_of_Business__c'));
            AntsuranceClaudeDisplay.addFact(facts, 'Type', (String) record.get('Type'));
            AntsuranceClaudeDisplay.addFact(facts, record.get('IsClosed') == true ? 'Closed' : 'Expected close', AntsuranceClaudeDisplay.shortDate((Date) record.get('CloseDate')));
            AntsuranceClaudeDisplay.addFact(facts, 'Next step', (String) record.get('NextStep'));
            AntsuranceClaudeDisplay.addFact(facts, 'Owner', AntsuranceClaudeDisplay.relatedName(record, 'Owner', null));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Annual premium', AntsuranceClaudeDisplay.money((Decimal) record.get('Amount')));
            AntsuranceClaudeDisplay.addFact(keyFacts, record.get('IsClosed') == true ? 'Closed' : 'Expected close', AntsuranceClaudeDisplay.shortDate((Date) record.get('CloseDate')));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Line', (String) record.get('Line_of_Business__c'));
        } else if (objectName == 'Lead') {
            spec.put('status', record.get('Status'));
            spec.put('tone', 'watch');
            AntsuranceClaudeDisplay.addFact(facts, 'Company', (String) record.get('Company'));
            AntsuranceClaudeDisplay.addFact(facts, 'Interested in', (String) record.get('Product_Interest__c'));
            AntsuranceClaudeDisplay.addFact(facts, 'Source', (String) record.get('LeadSource'));
            AntsuranceClaudeDisplay.addFact(facts, 'Rating', (String) record.get('Rating'));
            AntsuranceClaudeDisplay.addFact(facts, 'Email', (String) record.get('Email'));
            AntsuranceClaudeDisplay.addFact(facts, 'Phone', (String) record.get('Phone'));
            AntsuranceClaudeDisplay.addFact(facts, 'Received', AntsuranceClaudeDisplay.shortDate(((Datetime) record.get('CreatedDate')).date()));
            AntsuranceClaudeDisplay.addFact(facts, 'Owner', AntsuranceClaudeDisplay.relatedName(record, 'Owner', null));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Interested in', (String) record.get('Product_Interest__c'));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Rating', (String) record.get('Rating'));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Source', (String) record.get('LeadSource'));
        } else {
            Date due = (Date) record.get('ActivityDate');
            Boolean closed = record.get('IsClosed') == true;
            Boolean overdue = !closed && due != null && due < Date.today();
            spec.put('status', overdue ? 'Overdue' : (String) record.get('Status'));
            spec.put('tone', closed ? 'good' : overdue ? 'alert' : 'watch');
            AntsuranceClaudeDisplay.addFact(facts, 'Due', AntsuranceClaudeDisplay.shortDate(due));
            AntsuranceClaudeDisplay.addFact(facts, 'Priority', (String) record.get('Priority'));
            AntsuranceClaudeDisplay.addFact(facts, 'Related to', AntsuranceClaudeDisplay.relatedName(record, 'What', null));
            AntsuranceClaudeDisplay.addFact(facts, 'Contact', AntsuranceClaudeDisplay.relatedName(record, 'Who', null));
            AntsuranceClaudeDisplay.addFact(facts, 'Assigned to', AntsuranceClaudeDisplay.relatedName(record, 'Owner', null));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Due', AntsuranceClaudeDisplay.shortDate(due));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Priority', (String) record.get('Priority'));
            AntsuranceClaudeDisplay.addFact(keyFacts, 'Related to', AntsuranceClaudeDisplay.relatedName(record, 'What', null));
            String notes = (String) record.get('Description');
            if (!String.isBlank(notes)) {
                spec.put('body', notes.abbreviate(400));
            }
        }
        spec.put('facts', facts);
        spec.put('keyFacts', keyFacts);
        return spec;
    }

    /** A customer's open claims, counted as the user. */
    private static Integer openClaims(Id accountId) {
        return Database.countQueryWithBinds(
            'SELECT COUNT() FROM Case WHERE AccountId = :accountId AND IsClosed = false AND RecordType.DeveloperName = \'Claim\'',
            new Map<String, Object>{ 'accountId' => accountId },
            AccessLevel.USER_MODE
        );
    }

    // ---------- What the chat's components say ----------

    private static AntsuranceClaudeModel.Starter starter(String icon, String title, String detail, String prompt) {
        return new AntsuranceClaudeModel.Starter(icon, title, detail, prompt);
    }

    public override AntsuranceClaudeModel.Words words() {
        AntsuranceClaudeModel.Starter summarize = AntsuranceClaudeModel.summarize();
        AntsuranceClaudeModel.Starter nextStep = AntsuranceClaudeModel.nextStep();
        AntsuranceClaudeModel.Starter openItems = starter('utility:task', 'Open items', 'Tasks, requests and overdue work', 'What is open or overdue here?');
        AntsuranceClaudeModel.Words words = new AntsuranceClaudeModel.Words();
        words.placeholder = 'Ask about customers, policies or claims';
        // Starting points with no record open. Between them they show what the chat can draw: a chart,
        // a work list, a record card, a draft, a comparison and a form. The utility bar panel has room for the first four.
        words.starters = new List<AntsuranceClaudeModel.Starter>{
            starter('utility:chart', 'Chart the book', 'Premium in force by line of business', 'Chart premium in force by line of business'),
            starter('utility:case', 'Claims triage', 'The open claims to look at first', 'Which open claims need attention first?'),
            starter('utility:record_lookup', 'Pull up a record', 'The largest open claim', 'Show me the open claim with the largest outstanding reserve'),
            starter('utility:email', 'Draft an email', 'An update on the oldest open claim', 'Draft an update to the customer on the oldest open claim'),
            starter('utility:side_list', 'Compare options', 'The quotes on the Dubois auto sale', 'Compare the quote options on the Dubois Household auto sale'),
            starter('utility:new', 'Start a record', 'A new lead from a phone call', 'Start a new lead: Dana Whitfield called about a homeowners policy for her house in Naperville')
        };
        // Starting points on a record page, by object.
        words.anyRecordStarters = new List<AntsuranceClaudeModel.Starter>{ summarize, openItems, nextStep };
        words.recordStarters = new Map<String, List<AntsuranceClaudeModel.Starter>>{
            'Case' => new List<AntsuranceClaudeModel.Starter>{
                summarize,
                starter('utility:date_time', 'History so far', 'What happened, in order', 'Show what has happened on this file as a timeline'),
                starter('utility:email', 'Update the customer', 'An email saying where things stand', 'Draft an email to the customer saying where this stands')
            },
            'Policy__c' => new List<AntsuranceClaudeModel.Starter>{
                summarize,
                starter('utility:chart', 'Premium by coverage', 'Where the premium goes', 'Chart the premium on this policy by coverage'),
                openItems
            },
            'Account' => new List<AntsuranceClaudeModel.Starter>{
                summarize,
                starter('utility:side_list', 'Compare policies', 'Premium, limits and renewal dates', 'Compare this customer\'s policies side by side'),
                openItems
            },
            'Opportunity' => new List<AntsuranceClaudeModel.Starter>{
                starter('utility:side_list', 'Compare quotes', 'The options on this sale, side by side', 'Compare the quote options on this sale'),
                nextStep,
                starter('utility:email', 'Follow up', 'An email to the customer about the quotes', 'Draft a follow-up email to the customer about these quotes')
            },
            'Quote' => new List<AntsuranceClaudeModel.Starter>{
                summarize,
                starter('utility:side_list', 'Compare options', 'This quote beside the others', 'Compare this quote with the other options on the sale'),
                nextStep
            },
            'Lead' => new List<AntsuranceClaudeModel.Starter>{
                summarize,
                nextStep,
                starter('utility:email', 'Introduce yourself', 'A first email to this lead', 'Draft a first email to this lead')
            },
            'Contact' => new List<AntsuranceClaudeModel.Starter>{
                summarize,
                starter('utility:task', 'Their policies', 'What they are on, and in what role', 'Which policies is this person on?'),
                starter('utility:new', 'Log a call', 'A task or note, ready to save', 'I just spoke with this person. Open a form to log the call.')
            }
        };
        // The Ask Claude tab's questions to try: a short label, what Claude draws in reply, and the full question.
        // These go further than the starting points inside the chat and repeat none of them.
        words.questions = new List<AntsuranceClaudeModel.Starter>{
            starter(null, 'Outstanding reserve', 'Figures', 'What is the total outstanding reserve across open claims, and how many claims is that?'),
            starter(null, 'My overdue tasks', 'List', 'Which of my tasks are overdue?'),
            starter(null, 'Renewing in 30 days', 'List', 'What renews in the next 30 days?'),
            starter(null, 'Claims by month', 'Chart', 'Show claims reported by month for the last six months as a line chart'),
            starter(null, 'History of a claim', 'Timeline', 'Show what has happened on the burst pipe claim as a timeline')
        };
        // What each object is called while Claude reads it. The API name is never shown.
        words.objectWords = new Map<String, String>{
            'Case' => 'claims and requests',
            'Account' => 'customers',
            'Contact' => 'contacts',
            'Policy__c' => 'policies',
            'Policy_Coverage__c' => 'coverages',
            'Policy_Participant__c' => 'people on policies',
            'Policy_Asset__c' => 'insured assets',
            'Policy_Endorsement__c' => 'endorsements',
            'File_Note__c' => 'file notes',
            'Opportunity' => 'policy sales',
            'Quote' => 'quotes',
            'Lead' => 'leads',
            'Task' => 'tasks',
            'Event' => 'events',
            'User' => 'people',
            'ContentDocumentLink' => 'files',
            'ContentVersion' => 'files',
            'RecordType' => 'record types'
        };
        return words;
    }
    // ---------- Schema helpers, so the tool definitions above read as they are sent ----------

    private static Map<String, Object> tool(String name, String description, Map<String, Object> properties, List<String> requiredKeys) {
        return AntsuranceClaudeActions.tool(name, description, properties, requiredKeys);
    }

    private static Map<String, Object> text(String description) {
        return AntsuranceClaudeActions.text(description);
    }

    private static Map<String, Object> optionalText(String description) {
        return AntsuranceClaudeActions.optionalText(description);
    }

    private static Map<String, Object> choice(List<String> options, String description) {
        return AntsuranceClaudeActions.choice(options, description);
    }

    private static String tool(String name, String description, List<AntsuranceClaudeDisplay.Prop> properties) {
        return AntsuranceClaudeDisplay.tool(name, description, properties);
    }

    private static AntsuranceClaudeDisplay.Prop text(String name, String description) {
        return AntsuranceClaudeDisplay.text(name, description);
    }

    private static AntsuranceClaudeDisplay.Prop numberOf(String name, String description) {
        return AntsuranceClaudeDisplay.numberOf(name, description);
    }

    private static AntsuranceClaudeDisplay.Prop flag(String name, String description) {
        return AntsuranceClaudeDisplay.flag(name, description);
    }

    private static AntsuranceClaudeDisplay.Prop choice(String name, List<String> options, String description) {
        return AntsuranceClaudeDisplay.choice(name, options, description);
    }

    private static AntsuranceClaudeDisplay.Prop listOf(String name, String description, List<AntsuranceClaudeDisplay.Prop> itemProperties) {
        return AntsuranceClaudeDisplay.listOf(name, description, itemProperties);
    }

    private static AntsuranceClaudeDisplay.Prop listOfText(String name, String description) {
        return AntsuranceClaudeDisplay.listOfText(name, description);
    }
}
