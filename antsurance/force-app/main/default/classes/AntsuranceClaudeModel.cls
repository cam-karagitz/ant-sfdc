/**
 * @description What the chat knows about the org it is running in: who it is there for, which
 * objects and fields exist, what the facts and the card of a record are, which changes it may
 * prepare, and what to suggest asking. This class is the chat in any Salesforce org. It reads all
 * of that from the org's own schema at run time and names no custom object or field, so it
 * compiles and works in an org that has nothing else of ours.
 *
 * The full Antsurance app ships a subclass, AntsuranceClaudeInsurance, that knows the insurance
 * model: its data model note, its record cards, its file notes and its claim rules. When that class
 * is in the org the chat uses it; when it is not (Ask Claude installed alone) the chat uses this
 * one. It is found by name, so nothing here depends on it.
 */
public virtual with sharing class AntsuranceClaudeModel {
    private static final String FULL_APP_MODEL = 'AntsuranceClaudeInsurance';
    // Set by a test to choose the model whatever the org holds.
    @TestVisible
    private static AntsuranceClaudeModel standIn;
    @TestVisible
    private static AntsuranceClaudeModel found;

    // The standard objects the data model note covers when this user can read them, in this order.
    private static final List<String> STANDARD_OBJECTS = new List<String>{
        'Account',
        'Contact',
        'Lead',
        'Opportunity',
        'Case',
        'Task',
        'Event',
        'Campaign',
        'Quote',
        'Contract',
        'Order',
        'Product2'
    };
    // The standard picklists whose values an org usually changes, so Claude is told what they are here.
    private static final Map<String, List<String>> STANDARD_PICKLISTS = new Map<String, List<String>>{
        'Account' => new List<String>{ 'Type', 'Industry', 'Rating', 'AccountSource' },
        'Contact' => new List<String>{ 'LeadSource' },
        'Lead' => new List<String>{ 'Status', 'LeadSource', 'Rating', 'Industry' },
        'Opportunity' => new List<String>{ 'StageName', 'Type', 'LeadSource', 'ForecastCategoryName' },
        'Case' => new List<String>{ 'Status', 'Priority', 'Origin', 'Type', 'Reason' },
        'Task' => new List<String>{ 'Status', 'Priority' },
        'Campaign' => new List<String>{ 'Status', 'Type' },
        'Quote' => new List<String>{ 'Status' },
        'Contract' => new List<String>{ 'Status' },
        'Order' => new List<String>{ 'Status', 'Type' },
        'Product2' => new List<String>{ 'Family' }
    };
    // The standard fields that say most about a record of each kind, for its facts and its card. Custom fields follow them.
    private static final Map<String, List<String>> KEY_FIELDS = new Map<String, List<String>>{
        'Account' => new List<String>{ 'Type', 'Industry', 'Rating', 'AnnualRevenue', 'NumberOfEmployees', 'Phone', 'Website', 'BillingCity', 'BillingState', 'OwnerId', 'ParentId', 'Description' },
        'Contact' => new List<String>{ 'AccountId', 'Title', 'Email', 'Phone', 'MobilePhone', 'Department', 'MailingCity', 'OwnerId', 'Description' },
        'Lead' => new List<String>{ 'Company', 'Status', 'Rating', 'LeadSource', 'Title', 'Email', 'Phone', 'Industry', 'OwnerId', 'Description' },
        'Opportunity' => new List<String>{ 'StageName', 'Amount', 'CloseDate', 'AccountId', 'Type', 'Probability', 'NextStep', 'LeadSource', 'OwnerId', 'Description' },
        'Case' => new List<String>{ 'Status', 'Priority', 'Origin', 'Type', 'Reason', 'AccountId', 'ContactId', 'OwnerId', 'ClosedDate', 'Description' },
        'Task' => new List<String>{ 'Status', 'ActivityDate', 'Priority', 'WhatId', 'WhoId', 'OwnerId', 'Description' },
        'Event' => new List<String>{ 'StartDateTime', 'EndDateTime', 'Location', 'WhatId', 'WhoId', 'OwnerId', 'Description' }
    };
    private static final Map<String, String> STANDARD_ICONS = new Map<String, String>{
        'Account' => 'utility:company',
        'Contact' => 'utility:user',
        'Lead' => 'utility:lead',
        'Opportunity' => 'utility:opportunity',
        'Case' => 'utility:case',
        'Task' => 'utility:task',
        'Event' => 'utility:event',
        'Campaign' => 'utility:campaign',
        'Quote' => 'utility:quote'
    };
    // Fields every record has, or that say nothing to a reader. Lowercase, as a describe keys them.
    private static final Set<String> SYSTEM_FIELDS = new Set<String>{
        'id',
        'isdeleted',
        'createdbyid',
        'createddate',
        'lastmodifiedbyid',
        'lastmodifieddate',
        'systemmodstamp',
        'lastactivitydate',
        'lastvieweddate',
        'lastreferenceddate',
        'masterrecordid',
        'recordtypeid',
        'photourl',
        'jigsaw',
        'jigsawcompanyid',
        'jigsawcontactid',
        'cleanstatus',
        'dandbcompanyid',
        'isclosed',
        'iswon'
    };
    // The standard lookups worth reading on an object that has no list of key fields. Lowercase.
    private static final Set<String> PARENT_LOOKUPS = new Set<String>{ 'ownerid', 'accountid', 'contactid', 'parentid', 'opportunityid', 'whatid', 'whoid' };
    // What a task may be about besides a record with activities: a person, who becomes the task's Who.
    private static final Set<String> PEOPLE = new Set<String>{ 'Contact', 'Lead' };

    // The data model note is part of every request, so it stays small: this many custom objects in
    // full, this many more by name, and no more than this many custom objects read to choose them.
    private static final Integer MAX_CUSTOM_OBJECTS = 15;
    private static final Integer MAX_CUSTOM_NAMED = 30;
    private static final Integer MAX_CUSTOM_READ = 60;
    private static final Integer MAX_PICKLISTS = 8;
    private static final Integer MAX_VALUES = 12;
    private static final Integer MAX_LOOKUPS = 8;
    private static final Integer MAX_OTHER_FIELDS = 20;
    private static final Integer MAX_CHILDREN = 8;
    private static final Integer MAX_LINE = 1100;
    private static final Integer MAX_NOTE = 12000;
    private static final Integer MAX_FACT_FIELDS = 30;
    private static final Integer MAX_CARD_FIELDS = 14;
    private static final Integer MAX_CARD_FACTS = 8;
    private static final Integer MAX_FACT_VALUE = 80;
    private static final Integer MAX_CARD_BODY = 300;
    private static final Integer MAX_FORM_OBJECTS = 20;

    private static final String TASKS_STILL_OPEN =
        '(SELECT Id, Subject, ActivityDate, Status, Priority, Owner.Name, Who.Name FROM Tasks WHERE IsClosed = false ORDER BY ActivityDate NULLS LAST LIMIT 8)';

    // Worked out once in a request.
    private static List<Schema.DescribeSObjectResult> readable;
    private static List<String> alsoReadable;
    private static Map<String, String> nameFields = new Map<String, String>();

    /**
     * @description A starting point the chat offers before anything is asked.
     */
    public class Starter {
        /** summarize or next_step for the two the chat words itself from the open record; null otherwise. */
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String icon;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String detail;
        @AuraEnabled
        public String prompt;

        public Starter(String icon, String title, String detail, String prompt) {
            this.icon = icon;
            this.title = title;
            this.detail = detail;
            this.prompt = prompt;
        }
    }

    /**
     * @description The words the chat's components show that depend on what the org holds.
     */
    public class Words {
        /** What the empty question box says. */
        @AuraEnabled
        public String placeholder;
        /** Starting points with no record open, the first four of which fit the utility bar panel. */
        @AuraEnabled
        public List<Starter> starters = new List<Starter>();
        /** Starting points on a record page, by object API name. */
        @AuraEnabled
        public Map<String, List<Starter>> recordStarters = new Map<String, List<Starter>>();
        /** Starting points on a record page of any other object. */
        @AuraEnabled
        public List<Starter> anyRecordStarters = new List<Starter>();
        /** Questions to try, for the Ask Claude tab: title is the short label, detail is what Claude draws in reply. */
        @AuraEnabled
        public List<Starter> questions = new List<Starter>();
        /** What each object is called while Claude reads it, by object API name. */
        @AuraEnabled
        public Map<String, String> objectWords = new Map<String, String>();
    }

    /**
     * @description The model for this org. An org that has written its own (a class that extends this
     * one, named in the AI setting's Chat Model Class) gets that; otherwise the full app's when it is
     * installed; otherwise this one. A name that is not a class here, or not a model, is passed over.
     * @return The model the chat should use
     */
    public static AntsuranceClaudeModel current() {
        if (standIn != null) {
            return standIn;
        }
        if (found == null) {
            found = modelNamed(AntsuranceAiSettings.chatModelClass()) ?? modelNamed(FULL_APP_MODEL) ?? new AntsuranceClaudeModel();
        }
        return found;
    }

    private static AntsuranceClaudeModel modelNamed(String className) {
        Type named = String.isBlank(className) ? null : Type.forName(className);
        if (named == null) {
            return null;
        }
        try {
            Object made = named.newInstance();
            return made instanceof AntsuranceClaudeModel ? (AntsuranceClaudeModel) made : null;
        } catch (Exception e) {
            // A class that cannot be made here (abstract, or no constructor without arguments) is not a model the chat can use.
            return null;
        }
    }

    // ---------- What Claude is told ----------

    /**
     * @description Who Claude is here and whom it helps: the opening of its instructions.
     * @return The opening sentences, ending with a blank line
     */
    public virtual String intro() {
        return 'You are Claude, the AI assistant built into the Salesforce org of ' +
            UserInfo.getOrganizationName() +
            '. ' +
            'You help the people who work here with the records they keep in it: accounts, contacts, leads, opportunities, cases, tasks ' +
            'and the custom objects described in the data model note below.\n\n';
    }

    /**
     * @description How to write the kinds of record this org has, added to the rule on linking records.
     * @return A sentence starting with a space, or an empty string
     */
    public virtual String recordNamingRule() {
        return '';
    }

    /**
     * @description The things people here act on, as the instructions on drawing a work list name them.
     * @return A short list in words
     */
    public virtual String workToActOn() {
        return 'Tasks, cases, opportunities or other records';
    }

    /**
     * @description What "my records" means, by example.
     * @return Three quoted examples
     */
    public virtual String mineExamples() {
        return '"my accounts", "my cases", "my opportunities"';
    }

    /**
     * @description What Claude is told about preparing changes for the user to approve.
     * @return The paragraph, starting with a blank line
     */
    public virtual String actionsPrompt() {
        return '\n\nYou can prepare a follow-up task for the user to approve with one press (propose_task). Calling it writes nothing. ' +
            'It shows the user a card with Confirm and Cancel buttons, and the task is created only if they press Confirm. ' +
            'So never say a task has been created; say it is ready for them to confirm. ' +
            'A later user message may begin with a bracketed App note saying which cards they confirmed or canceled: only then is it done. ' +
            'Propose a task only when the user asks for one, propose exactly what they asked for, and look up any Id you need first. ' +
            'A task to call, write to or meet someone is about a person: pass their Id as contact_id when they are a contact. ' +
            'When you propose, the card shows the details, so add at most one short sentence. ' +
            'For any other new record or change to fields, on one of the objects show_form lists, ' +
            'draw a form with show_form: the user reviews it, edits it and saves it themselves, and until they do nothing has changed. ' +
            'You cannot delete anything, change many records at once, or change an object show_form does not list. ' +
            'When asked for one of those, say plainly that you cannot do it from here, and do not offer something else in its place unless they ask.';
    }

    /**
     * @description The note that teaches Claude this org's objects and fields. Built from the org's
     * own schema as the user sees it: the standard objects they can read, then their custom objects,
     * each with its record types, picklists and their values, lookups and custom fields.
     * @return The note, starting with a blank line
     */
    public virtual String dataModel() {
        String note =
            '\n\nData model: what this user can read in this org, with the API names to use in SOQL. ' +
            'Custom fields, record types and picklist values are listed because they cannot be guessed; the standard fields of a standard object are there too.\n';
        Integer listed = 0;
        for (Schema.DescribeSObjectResult description : readableObjects()) {
            String line = describeObject(description);
            if (note.length() + line.length() > MAX_NOTE) {
                break;
            }
            note += line + '\n';
            listed++;
        }
        List<String> named = new List<String>();
        List<Schema.DescribeSObjectResult> everyObject = readableObjects();
        for (Integer index = listed; index < everyObject.size(); index++) {
            named.add(everyObject[index].getName());
        }
        named.addAll(alsoReadable);
        if (!named.isEmpty()) {
            while (named.size() > MAX_CUSTOM_NAMED) {
                named.remove(named.size() - 1);
            }
            note += 'Also readable, not described here: ' + String.join(named, ', ') + '.\n';
        }
        return note +
            'A Task has OwnerId, Subject, ActivityDate (its due date), Status, Priority, IsClosed, WhatId (the record it is about) and WhoId (a contact or a lead). ' +
            'Other objects and fields can be queried by the API names you know. When a query names something that does not exist here, the error says so: correct it and run it again.';
    }

    /**
     * @description Rules for a line of business, such as how to read a claim's reserve.
     * @return The paragraph, starting with a blank line, or an empty string
     */
    public virtual String rules() {
        return '';
    }

    /**
     * @description What the query tool is for, in this org's words.
     * @return The kinds of record and question, with no full stop
     */
    public virtual String queryTopics() {
        return 'accounts, contacts, leads, opportunities, cases, tasks or any other records in this org, including broad ones such as what needs my attention this week';
    }

    /**
     * @description A SOQL statement that shows Claude the shape of a good query here.
     * @return One SELECT statement
     */
    public virtual String queryExample() {
        return isReadable('Opportunity')
            ? 'SELECT Id, Name, StageName, Amount, CloseDate, Account.Name, Owner.Name FROM Opportunity WHERE IsClosed = false ORDER BY CloseDate LIMIT 20'
            : 'SELECT Id, Name, Type, Industry, Owner.Name FROM Account ORDER BY LastModifiedDate DESC LIMIT 20';
    }

    /**
     * @description Headline numbers for the start of each request, where the org has some worked out.
     * @return A line starting with a line break, or an empty string
     */
    public virtual String snapshot() {
        return '';
    }

    /**
     * @description What Claude is told about the page the chat sits on when a record is open.
     * @return A sentence starting with a space
     */
    public virtual String openRecordPage() {
        return ' The page it sits on is the open record\'s own page, so never call show_record for the open record.';
    }

    /**
     * @description Why a card for the open record is refused.
     * @return The reason, as Claude is told it
     */
    public virtual String alreadyOpen() {
        return 'That record is already open on the user\'s screen. Answer in words instead of showing it again.';
    }

    // ---------- The open record's facts ----------

    /**
     * @description The query that reads a record's facts, without its WHERE clause.
     * @param objectName The record's object
     * @return A SELECT statement, or null when there are no facts to read for that object
     */
    public virtual String factsQuery(String objectName) {
        try {
            Schema.DescribeSObjectResult description = describe(objectName);
            if (description == null || !description.isAccessible() || !description.isQueryable()) {
                return null;
            }
            String selected = selectFor(description, keyFields(description, MAX_FACT_FIELDS));
            for (String stamp : new List<String>{ 'CreatedDate', 'LastModifiedDate' }) {
                if (description.fields.getMap().containsKey(stamp)) {
                    selected += ', ' + stamp;
                }
            }
            if (isReadable('Task') && hasChildren(description, 'Tasks')) {
                selected += ', ' + TASKS_STILL_OPEN;
            }
            return 'SELECT ' + selected + ' FROM ' + description.getName();
        } catch (Exception e) {
            // An object this class cannot describe has no facts; the chat still answers by querying.
            return null;
        }
    }

    /**
     * @description Adds what a plain read of the record does not carry.
     * @param facts The record's facts so far, to add to
     * @param record The record as the facts query returned it
     */
    public virtual void addFacts(Map<String, Object> facts, SObject record) {
        return;
    }

    // ---------- Changes Claude may prepare ----------

    /**
     * @description The proposal tools offered to Claude: here, a follow-up task.
     * @return The tool definitions
     */
    public virtual List<Object> actionTools() {
        return new List<Object>{
            AntsuranceClaudeActions.tool(
                AntsuranceClaudeActions.TASK_TOOL,
                'Propose a follow-up task for the user: a reminder or to-do with a due date, related to the record it is about. ' +
                'Use it when they ask to be reminded, to follow up, or to add a task. The task is assigned to the user. ' +
                AntsuranceClaudeActions.NOT_WRITTEN,
                new Map<String, Object>{
                    'subject' => AntsuranceClaudeActions.text('What to do, as a short imperative line, for example: Call Dana Whitfield about the proposal'),
                    'due_date' => AntsuranceClaudeActions.text('The due date as YYYY-MM-DD. Work it out from today\'s date when they say tomorrow, Friday or in three days.'),
                    'related_record_id' => AntsuranceClaudeActions.optionalText(
                        'The 18-character Id of the record the task is about: an account, an opportunity, a case, a lead, a contact or another record. ' +
                        'Use the open record when they say this or here. Null when the task is about no record.'
                    ),
                    'contact_id' => AntsuranceClaudeActions.optionalText(
                        'The Id of the contact the task is about. Set it whenever the task is to call, write to, meet or send something to a person who is a contact: ' +
                        'take the Id from the open record\'s facts when that person is there, otherwise query for it. Null when the task involves no contact.'
                    ),
                    'priority' => AntsuranceClaudeActions.choice(AntsuranceClaudeActions.PRIORITIES, 'Normal unless they say it is urgent or can wait.'),
                    'notes' => AntsuranceClaudeActions.optionalText('Comments for the task: context the user gave that does not fit the subject. Null when there is none.')
                },
                // Every field is required so that leaving one out is a decision, not an omission.
                new List<String>{ 'subject', 'due_date', 'related_record_id', 'contact_id', 'priority', 'notes' }
            )
        };
    }

    /**
     * @description Whether a task must be about a record.
     * @return False here: a reminder can stand alone
     */
    public virtual Boolean taskNeedsARecord() {
        return false;
    }

    /**
     * @description Whether a task may be about a record of this object.
     * @param objectName The object's API name
     * @return True for a person, and for any object Salesforce lets a task relate to
     */
    public virtual Boolean taskCanBeAbout(String objectName) {
        if (PEOPLE.contains(objectName)) {
            return true;
        }
        for (Schema.SObjectType allowed : Schema.SObjectType.Task.fields.WhatId.getReferenceTo()) {
            if (String.valueOf(allowed) == objectName) {
                return true;
            }
        }
        return false;
    }

    /**
     * @description What Claude is told when a task points at something a task cannot be about.
     * @return The rule in a sentence
     */
    public virtual String taskParentsRule() {
        return 'A task can be related to an account, an opportunity, a case, a lead, a contact or another record that keeps activities.';
    }

    /**
     * @description Whether a task about a record of this object is about a person rather than a thing.
     * @param objectName The object's API name
     * @return True for a contact or a lead
     */
    public Boolean isPerson(String objectName) {
        return PEOPLE.contains(objectName);
    }

    /**
     * @description What a record of this object is called in a sentence.
     * @param objectName The object's API name
     * @return The word, in lowercase
     */
    public virtual String wordFor(String objectName) {
        Schema.DescribeSObjectResult description = describe(objectName);
        return description == null ? 'record' : description.getLabel().toLowerCase();
    }

    /**
     * @description What a case is called, given its record type.
     * @param recordType The case's record type DeveloperName, or null
     * @return The word, in lowercase
     */
    public virtual String caseKind(String recordType) {
        return 'case';
    }

    /**
     * @description Builds the card for a proposal this model adds to the task.
     * @param toolName The propose tool Claude called
     * @param input The tool call's input
     * @return The card to show
     * @throws IllegalArgumentException when there is no such tool here
     */
    public virtual AntsuranceClaudeActions.Proposal propose(String toolName, Map<String, Object> input) {
        throw new IllegalArgumentException('There is no such tool.');
    }

    /**
     * @description Makes a change this model adds to the task, once the user confirmed it.
     * @param kind The proposal's kind
     * @param payload What the proposal kept for this
     * @return What was created or changed, or null when the kind is not one of this model's
     */
    public virtual AntsuranceClaudeActions.Outcome confirm(String kind, Map<String, Object> payload) {
        return null;
    }

    // ---------- What Claude may draw ----------

    /**
     * @description The objects a form in the chat may create or edit: the standard ones people work
     * in, then this org's custom objects, each only when this user may create or edit it.
     * @return Object API names
     */
    public virtual List<String> formObjects() {
        List<String> names = new List<String>();
        for (String name : new List<String>{ 'Task', 'Event', 'Lead', 'Contact', 'Account', 'Opportunity', 'Case' }) {
            Schema.DescribeSObjectResult description = describe(name);
            if (description != null && (description.isCreateable() || description.isUpdateable())) {
                names.add(name);
            }
        }
        for (Schema.DescribeSObjectResult description : readableObjects()) {
            if (description.isCustom() && (description.isCreateable() || description.isUpdateable()) && names.size() < MAX_FORM_OBJECTS) {
                names.add(description.getName());
            }
        }
        return names;
    }

    /**
     * @description What Salesforce's email composer can be opened against.
     * @return Object API names
     */
    public virtual Set<String> emailObjects() {
        return new Set<String>{ 'Account', 'Contact', 'Lead', 'Opportunity' };
    }

    /**
     * @description The country a new address starts with where states and countries are picklists.
     * @return A two-letter country code, or null to leave the country for the user
     */
    public virtual String defaultCountry() {
        String locale = UserInfo.getLocale();
        return locale != null && locale.contains('_') ? locale.substringAfter('_').left(2).toUpperCase() : null;
    }

    /**
     * @description The display tool definitions as JSON text, comma separated. See AntsuranceClaudeDisplay.
     * @return Eight tool definitions, worded for any org
     */
    public virtual String displayTools() {
        String say = AntsuranceClaudeDisplay.SAY;
        List<String> tones = AntsuranceClaudeDisplay.TONES;
        List<String> tools = new List<String>{
            AntsuranceClaudeDisplay.tool(
                AntsuranceClaudeDisplay.RECORD_TOOL,
                'Draw the summary card of one record of any object: its name, where it stands and its key fields, with a link to open it. ' +
                'Use it when the answer is one record the user wants to see (show me, pull up, find, what is the status of a named record). ' +
                'The card carries the record\'s key facts, so say only what matters about it in a sentence. ' +
                'Do not use it for the record the user already has open on screen.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    AntsuranceClaudeDisplay.text('say', say),
                    AntsuranceClaudeDisplay.text('record_id', 'The 18-character Id of the record. Query for it first if you do not have it.')
                }
            ),
            AntsuranceClaudeDisplay.tool(
                AntsuranceClaudeDisplay.METRICS_TOOL,
                'Draw one to four headline figures as tiles. Use it when the answer is a figure or a few related figures: a total, a count, an average, a ratio, ' +
                'or how the pipeline, a team or an account is doing in numbers. Work the figures out with COUNT, SUM or AVG in SOQL and pass them exactly.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    AntsuranceClaudeDisplay.text('say', say),
                    AntsuranceClaudeDisplay.listOf(
                        'tiles',
                        'One to four tiles, the most important first.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            AntsuranceClaudeDisplay.text('label', 'What the figure is, in two or three words, for example Open pipeline.'),
                            AntsuranceClaudeDisplay.text('value', 'The figure as it should read, for example $1,077,075, 28 or 63%.'),
                            AntsuranceClaudeDisplay.text('note', 'A few words that give it meaning, for example across 28 open opportunities. Empty string when there is none.'),
                            AntsuranceClaudeDisplay.choice('tone', tones, 'good for a healthy figure, watch for one to keep an eye on, alert for one that needs action, neutral otherwise.')
                        }
                    )
                }
            ),
            AntsuranceClaudeDisplay.tool(
                AntsuranceClaudeDisplay.CHART_TOOL,
                'Draw a chart from values you have queried. Use it for a breakdown by category or a trend over time: by stage, by status, by owner, by month. ' +
                'Group and total in SOQL and pass the exact figures; one series only.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    AntsuranceClaudeDisplay.text('say', say),
                    AntsuranceClaudeDisplay.text('title', 'What the chart shows, in a few words, for example Open pipeline by stage.'),
                    AntsuranceClaudeDisplay.choice(
                        'chart_type',
                        AntsuranceClaudeDisplay.CHART_TYPES,
                        'bar for a ranked breakdown by category, largest first. column for a few periods side by side. line for a trend over time, oldest first. ' +
                        'donut for shares of a whole, six slices at most.'
                    ),
                    AntsuranceClaudeDisplay.choice('unit', AntsuranceClaudeDisplay.UNITS, 'What the values are: dollars, a count of things, or percent.'),
                    AntsuranceClaudeDisplay.listOf(
                        'points',
                        'Two to twelve points, in the order to draw them.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            AntsuranceClaudeDisplay.text('label', 'The category or period, kept short, for example Negotiation or Sep 2026.'),
                            AntsuranceClaudeDisplay.numberOf('value', 'The value as a plain number, for example 184250.')
                        }
                    ),
                    AntsuranceClaudeDisplay.text('highlight_label', 'The label of the one point your sentence picks out, exactly as written in points. Empty string for none.'),
                    AntsuranceClaudeDisplay.text('caption', 'One line under the title saying what is counted and over what, for example Amount on open opportunities. No figures.')
                }
            ),
            AntsuranceClaudeDisplay.tool(
                AntsuranceClaudeDisplay.LIST_TOOL,
                'Draw a list of things to act on, each row with what it is, who it concerns, a few labeled facts and a link: overdue tasks, cases to chase, opportunities closing soon, leads waiting for a call. ' +
                'Use it instead of a table or bullets whenever the rows are work for someone to do. Up to eight rows, most urgent first; ' +
                'when there are more, show the eight most urgent and give the full count in say.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    AntsuranceClaudeDisplay.text('say', say),
                    AntsuranceClaudeDisplay.text('title', 'What the list is, for example Overdue tasks or Closing in the next 30 days.'),
                    AntsuranceClaudeDisplay.listOf(
                        'items',
                        'One to eight rows, most urgent first.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            AntsuranceClaudeDisplay.text('title', 'The task subject, the case subject, or the record\'s name.'),
                            AntsuranceClaudeDisplay.text(
                                'subtitle',
                                'Who or what it concerns, for example the account and the contact. A case is named by its subject, not its number alone. Empty string when there is nothing to add.'
                            ),
                            AntsuranceClaudeDisplay.text('record_id', 'The 18-character Id of the record the row opens. Empty string when you do not have it.'),
                            AntsuranceClaudeDisplay.text('amount', 'A formatted money amount when one matters for this row, for example $12,400. Empty string otherwise.'),
                            AntsuranceClaudeDisplay.listOf(
                                'chips',
                                'Up to three short labeled facts, each a few words that carry their own meaning, for example Due Oct 1, 3 days overdue, High priority, Negotiation.',
                                new List<AntsuranceClaudeDisplay.Prop>{
                                    AntsuranceClaudeDisplay.text('label', 'The fact, with its word, for example Due Oct 1.'),
                                    AntsuranceClaudeDisplay.choice('tone', tones, 'alert for overdue or severe, watch for due soon, good for done or healthy, neutral otherwise.')
                                }
                            )
                        }
                    )
                }
            ),
            AntsuranceClaudeDisplay.tool(
                AntsuranceClaudeDisplay.FORM_TOOL,
                'Draw a real Salesforce form in the chat, filled in with your suggested values, for the user to review, edit and save. ' +
                'Use it when they ask to create a record of one of the objects listed under object, or to change fields on one. ' +
                'Calling this writes nothing: the record is saved only if the user presses the form\'s button (Create, or Save changes), as them, ' +
                'so say the form is ready to review and never that a record was created or changed. ' +
                'When the request is exactly a follow-up task and you have every detail, use propose_task instead; ' +
                'use the form when they ask for a form, want to edit other fields, or should fill in details you do not have. ' +
                'Give three to eight fields that matter, by API name, with the fields a new record cannot be saved without. Look up any Id you need first.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    AntsuranceClaudeDisplay.text('say', say),
                    AntsuranceClaudeDisplay.choice('mode', new List<String>{ 'create', 'edit' }, 'create for a new record, edit to change an existing one.'),
                    AntsuranceClaudeDisplay.choice('object', formObjects(), 'The object\'s API name.'),
                    AntsuranceClaudeDisplay.text('record_id', 'When editing, the 18-character Id of the record. Empty string when creating.'),
                    AntsuranceClaudeDisplay.text(
                        'record_type',
                        'When creating a record of an object the data model note lists record types for: the DeveloperName of the one to use. Empty string otherwise.'
                    ),
                    AntsuranceClaudeDisplay.listOf(
                        'fields',
                        'The fields to show, in the order to show them.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            AntsuranceClaudeDisplay.text(
                                'name',
                                'The field\'s API name, for example Subject, Status or CloseDate. For a person use FirstName and LastName. ' +
                                'For an address use Street, City, State and PostalCode, with the Billing or Mailing prefix on an account or contact.'
                            ),
                            AntsuranceClaudeDisplay.text(
                                'value',
                                'Your suggested value as text: a date as YYYY-MM-DD, a number without symbols, true or false, a picklist value exactly as stored, a lookup as the 18-character Id. ' +
                                'Empty string to leave the field for the user to fill in (when editing, it then shows the current value).'
                            )
                        }
                    )
                }
            ),
            AntsuranceClaudeDisplay.tool(
                AntsuranceClaudeDisplay.DRAFT_TOOL,
                'Draw a ready-to-send email or letter on a letter card with Copy and Open as email buttons. ' +
                'Use it whenever the user asks you to draft, write or reply with something that will be sent to a customer, a partner or a colleague. ' +
                'Put the whole message in subject and body, and base every fact in it on the records.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    AntsuranceClaudeDisplay.text('say', say),
                    AntsuranceClaudeDisplay.choice('format', new List<String>{ 'email', 'letter' }, 'email unless they ask for a letter.'),
                    AntsuranceClaudeDisplay.text('to_name', 'Who it is addressed to, for example Dana Whitfield.'),
                    AntsuranceClaudeDisplay.text('to_email', 'Their email address when the records have it. Empty string otherwise.'),
                    AntsuranceClaudeDisplay.text('subject', 'The subject line. For a letter, the Re line.'),
                    AntsuranceClaudeDisplay.text('body', 'The message from greeting to sign-off, as plain text with a blank line between paragraphs. No Markdown. Sign off with the user\'s name.'),
                    AntsuranceClaudeDisplay.text('related_record_id', 'The Id of the account, contact, lead, opportunity or case it concerns, so the email is logged there. Empty string when there is none.')
                }
            ),
            AntsuranceClaudeDisplay.tool(
                AntsuranceClaudeDisplay.COMPARISON_TOOL,
                'Draw two to four options side by side with the same rows, one of them marked recommended. ' +
                'Use it to compare two or more records of the same kind, or choices the user must pick between.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    AntsuranceClaudeDisplay.text('say', say),
                    AntsuranceClaudeDisplay.text('title', 'What is being compared, for example The three largest open opportunities.'),
                    AntsuranceClaudeDisplay.listOf(
                        'columns',
                        'Two to four options, in the order to show them.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            AntsuranceClaudeDisplay.text('name', 'The option\'s name, kept short.'),
                            AntsuranceClaudeDisplay.text('record_id', 'The 18-character Id of the record this option is. Empty string when there is none.'),
                            AntsuranceClaudeDisplay.flag('recommended', 'True for the one option you recommend, false for the rest. All false when you recommend none.')
                        }
                    ),
                    AntsuranceClaudeDisplay.listOf(
                        'rows',
                        'Three to eight rows, the ones that differ first.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            AntsuranceClaudeDisplay.text('label', 'What the row compares, for example Amount.'),
                            AntsuranceClaudeDisplay.listOfText('values', 'One short value per option, in the same order as columns, for example $1,840.')
                        }
                    ),
                    AntsuranceClaudeDisplay.text('reason', 'Why the recommended option, in one short sentence. Empty string when you recommend none.')
                }
            ),
            AntsuranceClaudeDisplay.tool(
                AntsuranceClaudeDisplay.TIMELINE_TOOL,
                'Draw dated events in order. Use it for the history of a record: what happened and when, taken from its tasks, its related records and its own dates. ' +
                'Only things that have happened, oldest first, twelve at most; what is due next belongs in say.',
                new List<AntsuranceClaudeDisplay.Prop>{
                    AntsuranceClaudeDisplay.text('say', say),
                    AntsuranceClaudeDisplay.text('title', 'Whose history this is, for example Case 00001038 so far.'),
                    AntsuranceClaudeDisplay.listOf(
                        'events',
                        'Two to twelve events, oldest first.',
                        new List<AntsuranceClaudeDisplay.Prop>{
                            AntsuranceClaudeDisplay.text('date', 'The date as YYYY-MM-DD.'),
                            AntsuranceClaudeDisplay.text('title', 'What happened, in a few words, for example Proposal sent.'),
                            AntsuranceClaudeDisplay.text('detail', 'One line of detail: who did it or what was found. Empty string when there is none.'),
                            AntsuranceClaudeDisplay.choice('tone', tones, 'alert for a setback or a problem, watch for something pending, good for progress, neutral otherwise.')
                        }
                    )
                }
            )
        };
        return String.join(tools, ',');
    }

    /**
     * @description The content of a record's summary card: its name, where it stands, a headline
     * figure where it has one, and its key fields, read as the user from whatever the object holds.
     * @param recordId The record to show
     * @param objectName Its object
     * @return The card's content, for AntsuranceClaudeDisplay to hand to the chat
     * @throws IllegalArgumentException with a message for Claude when the record cannot be shown
     */
    public virtual Map<String, Object> recordCard(Id recordId, String objectName) {
        Schema.DescribeSObjectResult description = recordId.getSObjectType().getDescribe();
        Map<String, Schema.SObjectField> fieldMap = description.fields.getMap();
        List<Schema.DescribeFieldResult> fields = keyFields(description, MAX_CARD_FIELDS);
        SObject record;
        try {
            record = AntsuranceClaudeDisplay.readOne('SELECT ' + selectFor(description, fields) + ' FROM ' + objectName, recordId);
        } catch (IllegalArgumentException e) {
            // A field that cannot be read this way must not cost the whole card: fall back to the record's name.
            fields = new List<Schema.DescribeFieldResult>();
            record = AntsuranceClaudeDisplay.readOne('SELECT ' + selectFor(description, fields) + ' FROM ' + objectName, recordId);
        }

        String nameField = nameFieldOf(description);
        Boolean numbered = nameField != null && fieldMap.get(nameField).getDescribe().isAutoNumber() && read(record, 'Subject') != null;
        String label = description.getLabel();
        if (fieldMap.containsKey('RecordTypeId') && record.getSObject('RecordType') != null) {
            label = (String) record.getSObject('RecordType').get('Name');
        }
        String name = nameField == null ? label : String.valueOf(record.get(nameField));
        Boolean closed = read(record, 'IsClosed') == true;
        Map<String, Object> spec = new Map<String, Object>{
            'recordId' => recordId,
            'objectApiName' => objectName,
            'card' => 'compact',
            'icon' => STANDARD_ICONS.containsKey(objectName) ? STANDARD_ICONS.get(objectName) : 'utility:record',
            'eyebrow' => numbered ? label + ' ' + name : label,
            'name' => numbered ? String.valueOf(read(record, 'Subject')) : name,
            'tone' => !fieldMap.containsKey('IsClosed') ? 'neutral' : !closed ? 'watch' : !fieldMap.containsKey('IsWon') || read(record, 'IsWon') == true ? 'good' : 'neutral'
        };
        List<Object> facts = new List<Object>();
        for (Schema.DescribeFieldResult field : fields) {
            Schema.DisplayType fieldType = field.getType();
            String fieldName = field.getName();
            Object value = record.get(fieldName);
            String shown = show(field, record);
            if (String.isBlank(shown)) {
                continue;
            }
            Boolean saysWhereItStands = fieldType == Schema.DisplayType.PICKLIST && (fieldName.containsIgnoreCase('status') || fieldName.containsIgnoreCase('stage'));
            if (saysWhereItStands && !spec.containsKey('status')) {
                spec.put('status', shown);
            } else if (fieldType == Schema.DisplayType.CURRENCY && !spec.containsKey('figure')) {
                spec.put('figure', shown);
                spec.put('figureLabel', field.getLabel());
            } else if (fieldType == Schema.DisplayType.TEXTAREA) {
                // A description reads as a paragraph under the facts, and one is enough.
                if (!spec.containsKey('body')) {
                    spec.put('body', String.valueOf(value).abbreviate(MAX_CARD_BODY));
                }
            } else if (facts.size() < MAX_CARD_FACTS) {
                AntsuranceClaudeDisplay.addFact(facts, labelOf(field), shown);
            }
        }
        if (objectName == 'Task' && !closed && read(record, 'ActivityDate') != null && (Date) read(record, 'ActivityDate') < Date.today()) {
            spec.put('status', 'Overdue');
            spec.put('tone', 'alert');
        }
        // The narrow panel shows three facts: the headline figure, when there is one, then the first of the rest.
        List<Object> keyFacts = new List<Object>();
        if (spec.containsKey('figure')) {
            AntsuranceClaudeDisplay.addFact(keyFacts, (String) spec.get('figureLabel'), (String) spec.get('figure'));
        }
        for (Object fact : facts) {
            if (keyFacts.size() < 3) {
                keyFacts.add(fact);
            }
        }
        spec.put('facts', facts);
        spec.put('keyFacts', keyFacts);
        return spec;
    }

    // ---------- What the chat's components say ----------

    /**
     * @description The starting points, the questions to try and the words for objects that the
     * chat's components show, chosen from what this user can read.
     * @return The words
     */
    public virtual Words words() {
        Boolean sales = isReadable('Opportunity');
        Boolean service = isReadable('Case');
        Boolean leads = isReadable('Lead');
        Boolean tasks = isReadable('Task');
        Words words = new Words();
        words.placeholder = 'Ask about your records in Salesforce';

        // Between them these show what the chat can draw: a chart, a work list, a record card, a draft and a form.
        if (sales) {
            words.starters.add(new Starter('utility:chart', 'Chart the pipeline', 'Open opportunities by stage', 'Chart the amount of open opportunities by stage'));
        } else {
            words.starters.add(new Starter('utility:chart', 'Chart the accounts', 'How many of each type', 'Chart the number of accounts by type'));
        }
        if (tasks) {
            words.starters.add(new Starter('utility:task', 'My overdue tasks', 'What is past due, most urgent first', 'Which of my tasks are overdue?'));
        }
        if (service) {
            words.starters.add(new Starter('utility:case', 'Open cases', 'The ones to look at first', 'Which open cases need attention first?'));
        }
        if (sales) {
            words.starters.add(new Starter('utility:record_lookup', 'Pull up a record', 'The largest open opportunity', 'Show me the open opportunity with the largest amount'));
            words.starters.add(new Starter('utility:email', 'Draft an email', 'A follow-up on the next deal to close', 'Draft a follow-up email to the main contact on the open opportunity that closes next'));
        } else {
            words.starters.add(new Starter('utility:record_lookup', 'Pull up a record', 'The account changed most recently', 'Show me the account that was changed most recently'));
        }
        if (leads && Schema.SObjectType.Lead.isCreateable()) {
            words.starters.add(
                new Starter('utility:new', 'Start a record', 'A new lead from a phone call', 'Start a new lead: Dana Whitfield of Whitfield Design called and asked for a call back next week')
            );
        } else if (tasks) {
            words.starters.add(new Starter('utility:new', 'Start a record', 'A task for next week', 'Open a form for a new task to review my open work next Monday'));
        }

        Starter history = new Starter('utility:date_time', 'History so far', 'What happened, in order', 'Show what has happened here as a timeline');
        Starter openItems = new Starter('utility:task', 'Open items', 'Tasks and overdue work', 'What is open or overdue here?');
        words.anyRecordStarters = new List<Starter>{ summarize(), openItems, nextStep() };
        words.recordStarters.put('Account', new List<Starter>{ summarize(), history, openItems });
        words.recordStarters.put(
            'Opportunity',
            new List<Starter>{ summarize(), nextStep(), new Starter('utility:email', 'Follow up', 'An email to the main contact', 'Draft a follow-up email to the main contact on this opportunity') }
        );
        words.recordStarters.put(
            'Case',
            new List<Starter>{ summarize(), history, new Starter('utility:email', 'Update the customer', 'An email saying where things stand', 'Draft an email to the contact saying where this case stands') }
        );
        words.recordStarters.put(
            'Lead',
            new List<Starter>{ summarize(), nextStep(), new Starter('utility:email', 'Introduce yourself', 'A first email to this lead', 'Draft a first email to this lead') }
        );
        words.recordStarters.put(
            'Contact',
            new List<Starter>{ summarize(), openItems, new Starter('utility:new', 'Log a call', 'A task, ready to save', 'I just spoke with this person. Open a form to log the call.') }
        );

        // These go further than the starting points inside the chat and repeat none of them.
        words.questions.add(new Starter(null, 'New this quarter', 'Figures', 'How many accounts, contacts and leads were created this quarter?'));
        if (sales) {
            words.questions.add(new Starter(null, 'Closing this month', 'List', 'Which open opportunities are due to close this month?'));
            words.questions.add(new Starter(null, 'Won by month', 'Chart', 'Show the amount of opportunities won by month for the last six months as a line chart'));
        }
        if (service) {
            words.questions.add(new Starter(null, 'Cases by status', 'Chart', 'Chart open cases by status'));
        }
        words.questions.add(new Starter(null, 'History of an account', 'Timeline', 'Show what has happened with the account that was changed most recently as a timeline'));

        for (Schema.DescribeSObjectResult description : readableObjects()) {
            words.objectWords.put(description.getName(), description.getLabelPlural().toLowerCase());
        }
        words.objectWords.putAll(new Map<String, String>{ 'User' => 'people', 'ContentDocumentLink' => 'files', 'ContentVersion' => 'files', 'RecordType' => 'record types' });
        return words;
    }

    /**
     * @description The starting point that asks for a summary of the open record.
     * @return The starter; the chat words its question from the record
     */
    public static Starter summarize() {
        Starter starter = new Starter('utility:summary', 'Summarize', 'The key facts in a few lines', null);
        starter.key = 'summarize';
        return starter;
    }

    /**
     * @description The starting point that asks what to do next on the open record.
     * @return The starter; the chat words its question from the record
     */
    public static Starter nextStep() {
        Starter starter = new Starter('utility:forward', 'Next step', 'What to do now, and why', null);
        starter.key = 'next_step';
        return starter;
    }

    // ---------- Reading the org's schema ----------

    private static Schema.DescribeSObjectResult describe(String objectName) {
        Schema.SObjectType token = Schema.getGlobalDescribe().get(objectName.toLowerCase());
        return token == null ? null : token.getDescribe();
    }

    private static Boolean isReadable(String objectName) {
        Schema.DescribeSObjectResult description = describe(objectName);
        return description != null && description.isAccessible() && description.isQueryable();
    }

    /**
     * The objects the data model note describes: the standard ones this user can read, then custom
     * objects, those with a tab first, since a tab is what people work from. The custom objects past
     * the cap are kept by name in alsoReadable.
     */
    private static List<Schema.DescribeSObjectResult> readableObjects() {
        if (readable != null) {
            return readable;
        }
        readable = new List<Schema.DescribeSObjectResult>();
        alsoReadable = new List<String>();
        for (String name : STANDARD_OBJECTS) {
            if (isReadable(name)) {
                readable.add(describe(name));
            }
        }
        Integer custom = 0;
        Integer looked = 0;
        for (String name : customObjectNames()) {
            if (looked == MAX_CUSTOM_READ) {
                break;
            }
            looked++;
            Schema.DescribeSObjectResult description = describe(name);
            if (description == null || !description.isAccessible() || !description.isQueryable() || description.isCustomSetting() || description.isDeprecatedAndHidden()) {
                continue;
            }
            if (custom < MAX_CUSTOM_OBJECTS) {
                readable.add(description);
                custom++;
            } else {
                alsoReadable.add(description.getName());
            }
        }
        return readable;
    }

    /** Custom object API names: those with a tab, then the org's own by name, then those from installed packages. */
    private static List<String> customObjectNames() {
        List<String> tabbed = new List<String>();
        try {
            for (Schema.DescribeTabSetResult app : Schema.describeTabs()) {
                for (Schema.DescribeTabResult tab : app.getTabs()) {
                    String name = tab.getSobjectName();
                    if (name != null && name.endsWithIgnoreCase('__c') && !tabbed.contains(name)) {
                        tabbed.add(name);
                    }
                }
            }
        } catch (Exception e) {
            // Without the tabs the objects are taken in name order.
            tabbed.clear();
        }
        List<String> own = new List<String>();
        List<String> packaged = new List<String>();
        for (String key : Schema.getGlobalDescribe().keySet()) {
            if (!key.endsWith('__c')) {
                continue;
            }
            // A packaged object carries its namespace: namespace__Name__c.
            if (key.removeEnd('__c').contains('__')) {
                packaged.add(key);
            } else {
                own.add(key);
            }
        }
        own.sort();
        packaged.sort();
        List<String> names = new List<String>(tabbed);
        Set<String> taken = new Set<String>();
        for (String name : tabbed) {
            taken.add(name.toLowerCase());
        }
        for (List<String> more : new List<List<String>>{ own, packaged }) {
            for (String key : more) {
                if (!taken.contains(key)) {
                    names.add(key);
                }
            }
        }
        return names;
    }

    /** One object's line in the data model note. */
    private static String describeObject(Schema.DescribeSObjectResult description) {
        String name = description.getName();
        Boolean custom = description.isCustom();
        Map<String, Schema.SObjectField> fieldMap = description.fields.getMap();
        String line = '- ' + name;
        if (custom) {
            line += ' (' + description.getLabel() + ', a custom object)';
        } else if (description.getLabel() != name && !description.getLabel().equalsIgnoreCase(name.replace('2', ''))) {
            line += ' (called ' + description.getLabel() + ' here)';
        }
        line += ':';

        List<String> recordTypes = new List<String>();
        for (Schema.RecordTypeInfo info : description.getRecordTypeInfos()) {
            if (info.isAvailable() && info.isActive() && !info.isMaster()) {
                recordTypes.add(info.getDeveloperName());
            }
        }
        if (!recordTypes.isEmpty()) {
            recordTypes.sort();
            line += ' RecordType.DeveloperName is ' + joined(recordTypes, MAX_VALUES) + '.';
        }

        // A standard object's own fields are known; its picklists that orgs change and its custom fields are not.
        List<String> keys = new List<String>();
        if (custom) {
            keys.addAll(fieldMap.keySet());
        } else {
            for (String picklist : STANDARD_PICKLISTS.containsKey(name) ? STANDARD_PICKLISTS.get(name) : new List<String>()) {
                keys.add(picklist.toLowerCase());
            }
            for (String key : fieldMap.keySet()) {
                if (key.endsWith('__c')) {
                    keys.add(key);
                }
            }
        }
        keys.sort();
        List<String> picklists = new List<String>();
        List<String> lookups = new List<String>();
        List<String> others = new List<String>();
        for (String key : keys) {
            Schema.SObjectField token = fieldMap.get(key);
            if (token == null || SYSTEM_FIELDS.contains(key) || key == 'ownerid') {
                continue;
            }
            Schema.DescribeFieldResult field = token.getDescribe();
            if (!field.isAccessible() || field.isDeprecatedAndHidden()) {
                continue;
            }
            Schema.DisplayType fieldType = field.getType();
            if (field.isNameField()) {
                line += ' ' + field.getName() + ' is its name' + (field.isAutoNumber() ? ', an automatic number.' : '.');
            } else if (fieldType == Schema.DisplayType.PICKLIST || fieldType == Schema.DisplayType.MULTIPICKLIST) {
                List<String> values = new List<String>();
                for (Schema.PicklistEntry entry : field.getPicklistValues()) {
                    if (entry.isActive()) {
                        values.add(entry.getValue());
                    }
                }
                // A picklist nobody has given values to says nothing.
                if (!values.isEmpty()) {
                    picklists.add(field.getName() + ' (' + joined(values, MAX_VALUES) + ')');
                }
            } else if (fieldType == Schema.DisplayType.REFERENCE) {
                List<String> targets = new List<String>();
                for (Schema.SObjectType target : field.getReferenceTo()) {
                    targets.add(String.valueOf(target));
                }
                lookups.add(field.getName() + ' to ' + joined(targets, 3) + (field.getRelationshipName() == null ? '' : ', read as ' + field.getRelationshipName()));
            } else {
                others.add(field.getName() + ' (' + typeWord(field) + ')');
            }
        }
        if (!picklists.isEmpty()) {
            line += ' Picklists: ' + joined(picklists, MAX_PICKLISTS) + '.';
        }
        if (!lookups.isEmpty()) {
            line += ' Lookups: ' + joined(lookups, MAX_LOOKUPS) + '.';
        }
        if (!others.isEmpty()) {
            line += (custom ? ' Fields: ' : ' Custom fields: ') + joined(others, MAX_OTHER_FIELDS) + '.';
        }

        // Children that cannot be guessed: custom objects that look up to this one.
        List<String> children = new List<String>();
        for (Schema.ChildRelationship child : description.getChildRelationships()) {
            String childName = String.valueOf(child.getChildSObject());
            if (child.getRelationshipName() != null && childName.endsWithIgnoreCase('__c') && !child.isDeprecatedAndHidden()) {
                children.add(child.getRelationshipName() + ' (' + childName + ')');
            }
        }
        if (!children.isEmpty()) {
            children.sort();
            line += ' Child relationships: ' + joined(children, MAX_CHILDREN) + '.';
        }
        return line.endsWith(':') ? line.removeEnd(':') + ': no custom fields.' : line.abbreviate(MAX_LINE);
    }

    private static String typeWord(Schema.DescribeFieldResult field) {
        Schema.DisplayType fieldType = field.getType();
        String word = 'text';
        if (fieldType == Schema.DisplayType.CURRENCY) {
            word = 'currency';
        } else if (fieldType == Schema.DisplayType.DOUBLE || fieldType == Schema.DisplayType.INTEGER || fieldType == Schema.DisplayType.LONG) {
            word = 'number';
        } else if (fieldType == Schema.DisplayType.PERCENT) {
            word = 'percent';
        } else if (fieldType == Schema.DisplayType.DATE) {
            word = 'date';
        } else if (fieldType == Schema.DisplayType.DATETIME) {
            word = 'date and time';
        } else if (fieldType == Schema.DisplayType.BOOLEAN) {
            word = 'checkbox';
        } else if (fieldType == Schema.DisplayType.TEXTAREA && !field.isFilterable()) {
            word = 'long text, cannot be filtered on';
        }
        return field.isCalculated() ? word + ', a formula' : word;
    }

    /** The first so many of a list, in words, saying how many were left out. */
    private static String joined(List<String> values, Integer most) {
        if (values.size() <= most) {
            return String.join(values, ', ');
        }
        List<String> kept = new List<String>();
        for (Integer index = 0; index < most; index++) {
            kept.add(values[index]);
        }
        return String.join(kept, ', ') + ' and ' + (values.size() - most) + ' more';
    }

    private static Boolean hasChildren(Schema.DescribeSObjectResult description, String relationshipName) {
        for (Schema.ChildRelationship child : description.getChildRelationships()) {
            if (child.getRelationshipName() == relationshipName) {
                return true;
            }
        }
        return false;
    }

    /**
     * @description The field that names a record of an object, such as Name, CaseNumber or Subject.
     * @param description The object
     * @return The field's API name, or null when the object has none this user can read
     */
    public static String nameFieldOf(Schema.DescribeSObjectResult description) {
        String objectName = description.getName();
        if (!nameFields.containsKey(objectName)) {
            String nameField;
            Map<String, Schema.SObjectField> fieldMap = description.fields.getMap();
            if (fieldMap.containsKey('Name') && fieldMap.get('Name').getDescribe().isNameField()) {
                nameField = 'Name';
            } else {
                for (Schema.SObjectField token : fieldMap.values()) {
                    Schema.DescribeFieldResult field = token.getDescribe();
                    if (field.isNameField()) {
                        nameField = field.getName();
                        break;
                    }
                }
            }
            if (nameField != null && !fieldMap.get(nameField).getDescribe().isAccessible()) {
                nameField = null;
            }
            nameFields.put(objectName, nameField);
        }
        return nameFields.get(objectName);
    }

    /**
     * The fields that say most about a record, for its facts and its card: the ones listed for a
     * standard object, then the object's custom fields, and for an object with no list of its own
     * its other fields too, leaving out the lookups Salesforce adds for its own bookkeeping. Only
     * fields this user can read, and never the name, which is read apart.
     */
    private static List<Schema.DescribeFieldResult> keyFields(Schema.DescribeSObjectResult description, Integer most) {
        Map<String, Schema.SObjectField> fieldMap = description.fields.getMap();
        List<String> wanted = new List<String>();
        Boolean listed = KEY_FIELDS.containsKey(description.getName());
        if (listed) {
            for (String name : KEY_FIELDS.get(description.getName())) {
                wanted.add(name.toLowerCase());
            }
        }
        List<String> keys = new List<String>(fieldMap.keySet());
        keys.sort();
        for (String key : keys) {
            if (key.endsWith('__c')) {
                wanted.add(key);
            }
        }
        if (!listed) {
            for (String key : keys) {
                if (!key.endsWith('__c') && !key.endsWith('__s')) {
                    wanted.add(key);
                }
            }
        }
        List<Schema.DescribeFieldResult> kept = new List<Schema.DescribeFieldResult>();
        Set<String> seen = new Set<String>();
        for (String key : wanted) {
            Schema.SObjectField token = fieldMap.get(key);
            if (kept.size() == most || token == null || seen.contains(key) || SYSTEM_FIELDS.contains(key)) {
                continue;
            }
            seen.add(key);
            Schema.DescribeFieldResult field = token.getDescribe();
            Schema.DisplayType fieldType = field.getType();
            if (!listed && fieldType == Schema.DisplayType.REFERENCE && !field.isCustom() && !PARENT_LOOKUPS.contains(key)) {
                continue;
            }
            Boolean plain =
                fieldType != Schema.DisplayType.ADDRESS &&
                fieldType != Schema.DisplayType.LOCATION &&
                fieldType != Schema.DisplayType.BASE64 &&
                fieldType != Schema.DisplayType.ENCRYPTEDSTRING &&
                fieldType != Schema.DisplayType.ID &&
                fieldType != Schema.DisplayType.ANYTYPE;
            if (plain && field.isAccessible() && !field.isNameField() && !field.isDeprecatedAndHidden()) {
                kept.add(field);
            }
        }
        return kept;
    }

    /** What to select to read a record's name, where it stands and these fields, with the name behind each lookup. */
    private static String selectFor(Schema.DescribeSObjectResult description, List<Schema.DescribeFieldResult> fields) {
        Map<String, Schema.SObjectField> fieldMap = description.fields.getMap();
        List<String> selected = new List<String>{ 'Id' };
        String nameField = nameFieldOf(description);
        if (nameField != null) {
            selected.add(nameField);
        }
        for (String extra : new List<String>{ 'Subject', 'IsClosed', 'IsWon' }) {
            if (fieldMap.containsKey(extra) && extra != nameField && fieldMap.get(extra).getDescribe().isAccessible()) {
                selected.add(extra);
            }
        }
        if (fieldMap.containsKey('RecordTypeId')) {
            selected.add('RecordType.Name');
        }
        for (Schema.DescribeFieldResult field : fields) {
            if (!selected.contains(field.getName())) {
                selected.add(field.getName());
            }
            String path = namePath(field);
            if (path != null && !selected.contains(path)) {
                selected.add(path);
            }
        }
        return String.join(selected, ', ');
    }

    /** For a lookup, the path to the name of the record it points at, such as Account.Name; null when there is none to read. */
    private static String namePath(Schema.DescribeFieldResult field) {
        if (field.getType() != Schema.DisplayType.REFERENCE || field.getRelationshipName() == null) {
            return null;
        }
        List<Schema.SObjectType> targets = field.getReferenceTo();
        if (targets.size() != 1) {
            // An owner, or what a task is about, can be one of several objects, which all answer to Name.
            return field.getRelationshipName() + '.Name';
        }
        Schema.DescribeSObjectResult target = targets[0].getDescribe();
        String nameField = target.isAccessible() ? nameFieldOf(target) : null;
        return nameField == null ? null : field.getRelationshipName() + '.' + nameField;
    }

    /** A field's value as a card shows it, or null when there is nothing to show. */
    private static String show(Schema.DescribeFieldResult field, SObject record) {
        Schema.DisplayType fieldType = field.getType();
        if (fieldType == Schema.DisplayType.REFERENCE) {
            String path = namePath(field);
            SObject parent = path == null ? null : record.getSObject(field.getRelationshipName());
            return parent == null ? null : String.valueOf(parent.get(path.substringAfter('.')));
        }
        Object value = record.get(field.getName());
        if (value == null) {
            return null;
        }
        if (fieldType == Schema.DisplayType.BOOLEAN) {
            return value == true ? 'Yes' : null;
        }
        if (fieldType == Schema.DisplayType.DATE) {
            return AntsuranceClaudeDisplay.shortDate((Date) value);
        }
        if (fieldType == Schema.DisplayType.DATETIME) {
            return AntsuranceClaudeDisplay.shortDate(((Datetime) value).date());
        }
        if (fieldType == Schema.DisplayType.CURRENCY) {
            return AntsuranceClaudeDisplay.money((Decimal) value);
        }
        if (fieldType == Schema.DisplayType.PERCENT) {
            return ((Decimal) value).stripTrailingZeros().toPlainString() + '%';
        }
        if (fieldType == Schema.DisplayType.DOUBLE || fieldType == Schema.DisplayType.INTEGER || fieldType == Schema.DisplayType.LONG) {
            return Decimal.valueOf(String.valueOf(value)).stripTrailingZeros().format();
        }
        return String.valueOf(value).abbreviate(MAX_FACT_VALUE);
    }

    /** A field's value, or null when the field was not read because this user cannot see it. */
    private static Object read(SObject record, String fieldName) {
        try {
            return record.get(fieldName);
        } catch (SObjectException e) {
            return null;
        }
    }

    /** A field's label as a card shows it: a lookup is named for what it points at, not for its Id. */
    private static String labelOf(Schema.DescribeFieldResult field) {
        return field.getType() == Schema.DisplayType.REFERENCE ? field.getLabel().removeEnd(' ID') : field.getLabel();
    }
}
