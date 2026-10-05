/**
 * @description The changes Claude can prepare in the chat. Claude only ever proposes one. A proposal
 * is checked and shown to the user as a card; nothing is written until they press Confirm, which
 * calls confirm(), and that write runs as the user. A follow-up task is offered in every org and is
 * handled here. An org's data model can add its own (the full Antsurance app adds a file note and a
 * status change on a claim or service request): those come from AntsuranceClaudeModel.
 */
public with sharing class AntsuranceClaudeActions {
    public static final String TASK_TOOL = 'propose_task';
    // Every proposal tool's name starts this way, whichever model offers it.
    private static final String PROPOSE_PREFIX = 'propose_';

    private static final String KIND_TASK = 'task';
    private static final Integer MAX_SUBJECT = 255;
    private static final Integer MAX_TASK_NOTES = 2000;
    public static final List<String> PRIORITIES = new List<String>{ 'High', 'Normal', 'Low' };
    public static final String NOT_WRITTEN = 'This only shows the user a card with Confirm and Cancel buttons. Nothing is written unless they press Confirm, so never say it has been done.';
    public static final String INVALID_ACTION = 'That action could not be read. Ask Claude to propose it again.';
    private static final String NO_ACCESS = 'You do not have access to make that change.';

    /**
     * @description A change Claude prepared, ready to show as a card.
     */
    public class Proposal {
        /** The tool call this answers; the chat uses it as the card's key. */
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String confirmLabel;
        @AuraEnabled
        public List<Detail> details = new List<Detail>();
        /** The note text, or a task's comments. May use Markdown. */
        @AuraEnabled
        public String body;
        /** What confirm() needs to make the change, kept by the chat and sent back unchanged. */
        @AuraEnabled
        public String payloadJson;
    }

    /**
     * @description One labelled line on a proposal card. recordId makes the value a link.
     */
    public class Detail {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String value;
        @AuraEnabled
        public Id recordId;

        public Detail(String label, String value, Id recordId) {
            this.label = label;
            this.value = value;
            this.recordId = recordId;
        }
    }

    /**
     * @description What a confirmed change did.
     */
    public class Outcome {
        /** The record to open from the result card: the new task, or the file the note or status change is on. */
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public String linkLabel;
        /** Records whose pages should refresh. */
        @AuraEnabled
        public List<Id> touchedIds = new List<Id>();
    }

    /**
     * @description A record a proposal points at, as the user sees it.
     */
    public class Target {
        public Id recordId;
        public String objectName;
        public String name;
        /** The name without the kind of record in front, for where a label already says it. */
        public String shortName;
        public String kindLabel;
        public String status;
        public String recordType;
    }

    /**
     * @description The tool definitions offered to Claude alongside the query tool: the ones this org's model has.
     * @return Client tools, each with a strict input schema
     */
    public static List<Object> toolDefinitions() {
        return AntsuranceClaudeModel.current().actionTools();
    }

    /**
     * @description Whether a tool call is a proposal.
     * @param toolName The tool Claude called
     * @return True for the propose tools
     */
    public static Boolean isActionTool(String toolName) {
        return toolName != null && toolName.startsWith(PROPOSE_PREFIX);
    }

    /**
     * @description Checks a proposal against the org and builds the card for it. Writes nothing.
     * @param toolName The propose tool Claude called
     * @param toolUseId The tool call's id
     * @param input The tool call's input
     * @return The card to show
     * @throws IllegalArgumentException with a message for Claude when the proposal cannot be made as given
     */
    public static Proposal propose(String toolName, String toolUseId, Map<String, Object> input) {
        Proposal proposal = toolName == TASK_TOOL ? proposeTask(input) : AntsuranceClaudeModel.current().propose(toolName, input);
        proposal.id = toolUseId;
        return proposal;
    }

    /**
     * @description Makes a change the user confirmed on a proposal card. Runs as the user, so their
     * object, field and record access and every validation rule apply.
     * @param payloadJson The payloadJson of the proposal that was confirmed
     * @return What was created or changed
     * @throws AuraHandledException when the payload is not a known action or the write is refused
     */
    @AuraEnabled
    public static Outcome confirm(String payloadJson) {
        Map<String, Object> payload;
        try {
            payload = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
        } catch (Exception e) {
            throw handled(INVALID_ACTION);
        }
        String kind = payload == null ? null : (String) payload.get('kind');
        try {
            if (kind == KIND_TASK) {
                return createTask(payload);
            }
            Outcome made = AntsuranceClaudeModel.current().confirm(kind, payload);
            if (made != null) {
                return made;
            }
        } catch (IllegalArgumentException e) {
            throw handled(e.getMessage());
        } catch (DmlException e) {
            throw handled('Salesforce did not save this: ' + e.getDmlMessage(0));
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        } catch (System.NoAccessException e) {
            throw handled(NO_ACCESS);
        }
        throw handled(INVALID_ACTION);
    }

    private static Proposal proposeTask(Map<String, Object> input) {
        String subject = required(input, 'subject', MAX_SUBJECT);
        Date dueDate = parseDate((String) input.get('due_date'));
        Target parent = taskTarget((String) input.get('related_record_id'), AntsuranceClaudeModel.current().taskParentsRule());
        Target contact = String.isBlank((String) input.get('contact_id')) ? null : findTarget((String) input.get('contact_id'), new Set<String>{ 'Contact' }, 'contact_id must be the Id of a Contact.');
        String priority = PRIORITIES.contains((String) input.get('priority')) ? (String) input.get('priority') : 'Normal';
        String notes = String.isBlank((String) input.get('notes')) ? null : ((String) input.get('notes')).trim().abbreviate(MAX_TASK_NOTES);

        Proposal proposal = new Proposal();
        proposal.kind = KIND_TASK;
        proposal.title = 'Create a follow-up task';
        proposal.confirmLabel = 'Create task';
        proposal.details.add(new Detail('Subject', subject, null));
        proposal.details.add(new Detail('Due', formatDate(dueDate), null));
        if (parent != null) {
            proposal.details.add(new Detail('Related to', parent.name, parent.recordId));
        }
        if (contact != null) {
            proposal.details.add(new Detail('Contact', contact.name, contact.recordId));
        }
        proposal.details.add(new Detail('Priority', priority, null));
        proposal.details.add(new Detail('Assigned to', UserInfo.getName(), null));
        proposal.body = notes;
        proposal.payloadJson = JSON.serialize(
            new Map<String, Object>{
                'kind' => KIND_TASK,
                'subject' => subject,
                'dueDate' => String.valueOf(dueDate),
                'relatedId' => parent?.recordId,
                'contactId' => contact?.recordId,
                'priority' => priority,
                'notes' => notes
            }
        );
        return proposal;
    }

    private static Outcome createTask(Map<String, Object> payload) {
        AntsuranceClaudeModel model = AntsuranceClaudeModel.current();
        Target parent = taskTarget((String) payload.get('relatedId'), INVALID_ACTION);
        Task task = new Task(
            Subject = required(payload, 'subject', MAX_SUBJECT),
            ActivityDate = parseDate((String) payload.get('dueDate')),
            Priority = PRIORITIES.contains((String) payload.get('priority')) ? (String) payload.get('priority') : 'Normal',
            Description = (String) payload.get('notes'),
            OwnerId = UserInfo.getUserId()
        );
        // A task about a contact or a lead points at them as its person; anything else is what it is related to.
        Boolean aboutAPerson = parent != null && model.isPerson(parent.objectName);
        if (aboutAPerson) {
            task.WhoId = parent.recordId;
        } else if (parent != null) {
            task.WhatId = parent.recordId;
        }
        if (!aboutAPerson && !String.isBlank((String) payload.get('contactId'))) {
            task.WhoId = findTarget((String) payload.get('contactId'), new Set<String>{ 'Contact' }, INVALID_ACTION).recordId;
        }
        insert as user task;

        Outcome outcome = new Outcome();
        outcome.recordId = task.Id;
        // The card above already shows the subject.
        outcome.message = 'Task created, due ' + formatDate(task.ActivityDate) + '.';
        outcome.linkLabel = 'Open task';
        if (parent != null) {
            outcome.touchedIds.add(parent.recordId);
        }
        return outcome;
    }

    /**
     * The record a task is about, read as the user. Null when the task names none and this org's model
     * lets a task stand alone; otherwise what a task may be about is the model's to say.
     */
    private static Target taskTarget(String rawId, String wrongKind) {
        AntsuranceClaudeModel model = AntsuranceClaudeModel.current();
        if (String.isBlank(rawId) && !model.taskNeedsARecord()) {
            return null;
        }
        String objectName = toId(rawId).getSObjectType().getDescribe().getName();
        if (!model.taskCanBeAbout(objectName)) {
            throw new IllegalArgumentException(wrongKind);
        }
        return findTarget(rawId, new Set<String>{ objectName }, wrongKind);
    }

    private static Id toId(String rawId) {
        Id recordId;
        try {
            recordId = String.isBlank(rawId) ? null : Id.valueOf(rawId.trim());
        } catch (Exception e) {
            recordId = null;
        }
        if (recordId == null) {
            throw new IllegalArgumentException('"' + rawId + '" is not a record Id. Query for the record and use its Id.');
        }
        return recordId;
    }

    /**
     * @description Reads the record a proposal points at as the user, or explains why it cannot be used.
     * @param rawId The Id Claude gave
     * @param allowedObjects The objects the record may be of
     * @param wrongKind What to tell Claude when it is of another object
     * @return The record, with the words a card uses for it
     * @throws IllegalArgumentException with a message for Claude when the record cannot be used
     */
    public static Target findTarget(String rawId, Set<String> allowedObjects, String wrongKind) {
        AntsuranceClaudeModel model = AntsuranceClaudeModel.current();
        Id recordId = toId(rawId);
        Target target = new Target();
        target.recordId = recordId;
        Schema.DescribeSObjectResult description = recordId.getSObjectType().getDescribe();
        target.objectName = description.getName();
        if (!allowedObjects.contains(target.objectName)) {
            throw new IllegalArgumentException(wrongKind);
        }
        Boolean isCase = target.objectName == 'Case';
        // An org with no record types on cases has no record type to read.
        Boolean hasRecordType = isCase && description.fields.getMap().containsKey('RecordTypeId');
        String nameField = isCase ? null : AntsuranceClaudeModel.nameFieldOf(description);
        String fields = isCase ? 'CaseNumber, Subject, Status' + (hasRecordType ? ', RecordType.DeveloperName, RecordType.Name' : '') : nameField == null ? 'Id' : nameField;
        List<SObject> records;
        try {
            records = Database.queryWithBinds('SELECT ' + fields + ' FROM ' + target.objectName + ' WHERE Id = :recordId LIMIT 1', new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
        } catch (QueryException e) {
            records = new List<SObject>();
        }
        if (records.isEmpty()) {
            throw new IllegalArgumentException('No record with Id ' + recordId + ' is visible to this user. Query for the record and use its Id.');
        }
        SObject record = records[0];
        if (isCase) {
            SObject recordType = hasRecordType ? record.getSObject('RecordType') : null;
            target.recordType = recordType == null ? null : (String) recordType.get('DeveloperName');
            target.kindLabel = model.caseKind(target.recordType);
            target.status = (String) record.get('Status');
            target.shortName = record.get('CaseNumber') + (record.get('Subject') == null ? '' : ': ' + record.get('Subject'));
            target.name = target.kindLabel.capitalize() + ' ' + target.shortName;
        } else {
            target.kindLabel = model.wordFor(target.objectName);
            target.name = nameField == null ? description.getLabel() : String.valueOf(record.get(nameField));
            target.shortName = target.name;
        }
        return target;
    }

    /**
     * @description A value a proposal cannot do without, trimmed.
     * @param input The tool call's input, or a proposal's payload
     * @param key The value's key
     * @param maxLength The most characters it may hold
     * @return The value
     * @throws IllegalArgumentException with a message for Claude when it is missing or too long
     */
    public static String required(Map<String, Object> input, String key, Integer maxLength) {
        String value = (String) input.get(key);
        if (String.isBlank(value)) {
            throw new IllegalArgumentException(key + ' is required.');
        }
        if (value.length() > maxLength) {
            throw new IllegalArgumentException(key + ' is too long. Keep it under ' + maxLength + ' characters.');
        }
        return value.trim();
    }

    private static Date parseDate(String value) {
        try {
            return Date.valueOf(value);
        } catch (Exception e) {
            throw new IllegalArgumentException('The due date must be written as YYYY-MM-DD.');
        }
    }

    /** A date the way the card shows it, for example Oct 5, 2026. */
    private static String formatDate(Date value) {
        return Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d, yyyy');
    }

    /**
     * @description A proposal tool's definition, with a strict input schema.
     * @param name The tool's name, starting with propose_
     * @param description What it is for, as Claude reads it
     * @param properties Its input properties, each built with text, optionalText or choice
     * @param requiredKeys The properties Claude must give
     * @return The definition
     */
    public static Map<String, Object> tool(String name, String description, Map<String, Object> properties, List<String> requiredKeys) {
        return new Map<String, Object>{
            'name' => name,
            'description' => description,
            'strict' => true,
            'input_schema' => new Map<String, Object>{ 'type' => 'object', 'properties' => properties, 'required' => requiredKeys, 'additionalProperties' => false }
        };
    }

    /**
     * @description A text property of a proposal tool.
     * @param description What to put in it, as Claude reads it
     * @return The property's schema
     */
    public static Map<String, Object> text(String description) {
        return new Map<String, Object>{ 'type' => 'string', 'description' => description };
    }

    /**
     * @description A text property Claude must give or explicitly leave null.
     * @param description What to put in it, as Claude reads it
     * @return The property's schema
     */
    public static Map<String, Object> optionalText(String description) {
        return new Map<String, Object>{ 'type' => new List<String>{ 'string', 'null' }, 'description' => description };
    }

    /**
     * @description A property that takes one of a list of values.
     * @param options The values
     * @param description How to choose, as Claude reads it
     * @return The property's schema
     */
    public static Map<String, Object> choice(List<String> options, String description) {
        return new Map<String, Object>{ 'type' => 'string', 'enum' => options, 'description' => description };
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
