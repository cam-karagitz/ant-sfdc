/**
 * @description The things Claude can draw in the chat instead of writing them out: a record's
 * summary card, headline figures, a chart, a work list, a Salesforce form, a draft to send, a
 * comparison and a timeline. Each is a tool Claude calls with the content and with the words to
 * show above it; the call is checked here and handed to the chat panel as a block to render.
 * Follow-up questions are lines at the end of Claude's words, read here into a block of buttons.
 * Nothing here writes a record. A form is saved by the user pressing its button in the chat, as them.
 *
 * How the tools are worded, what a record's card holds and which objects a form may touch depend on
 * the org's data model, so those come from AntsuranceClaudeModel; the checks and the shapes are here.
 */
public with sharing class AntsuranceClaudeDisplay {
    public static final String RECORD_TOOL = 'show_record';
    public static final String METRICS_TOOL = 'show_metrics';
    public static final String CHART_TOOL = 'show_chart';
    public static final String LIST_TOOL = 'show_work_list';
    public static final String FORM_TOOL = 'show_form';
    public static final String DRAFT_TOOL = 'show_draft';
    public static final String COMPARISON_TOOL = 'show_comparison';
    public static final String TIMELINE_TOOL = 'show_timeline';
    /** The block of follow-up buttons, which is read from Claude's words rather than drawn by a tool. */
    public static final String NEXT_KIND = 'next_questions';

    /** Where the chat is running: the Ask Claude tab, or the panel docked under another page. */
    public static final String SURFACE_PANEL = 'panel';

    private static final Map<String, String> KINDS = new Map<String, String>{
        RECORD_TOOL => 'record',
        METRICS_TOOL => 'metrics',
        CHART_TOOL => 'chart',
        LIST_TOOL => 'work_list',
        FORM_TOOL => 'form',
        DRAFT_TOOL => 'draft',
        COMPARISON_TOOL => 'comparison',
        TIMELINE_TOOL => 'timeline'
    };
    // A follow-up question is a line of its own at the end of Claude's words, starting with this.
    private static final Pattern NEXT_LINE = Pattern.compile('^\\s*\\?>\\s*(.+?)\\s*$');
    public static final String SAY =
        'The words shown above this block: one or two sentences that answer the question or give the insight, in Markdown, naming in full the record or figure that was asked for. ' +
        'Write them here and nothing outside the tool. When you draw a second block in the same answer, give it an empty string.';
    public static final List<String> TONES = new List<String>{ 'neutral', 'good', 'watch', 'alert' };
    public static final List<String> CHART_TYPES = new List<String>{ 'bar', 'column', 'line', 'donut' };
    public static final List<String> UNITS = new List<String>{ 'dollars', 'count', 'percent' };
    private static final Integer MAX_TILES = 4;
    private static final Integer MAX_POINTS = 12;
    private static final Integer MAX_SLICES = 6;
    private static final Integer MAX_ITEMS = 8;
    private static final Integer MAX_CHIPS = 3;
    private static final Integer MAX_COLUMNS = 4;
    private static final Integer MAX_ROWS = 10;
    private static final Integer MAX_EVENTS = 12;
    private static final Integer MAX_QUESTIONS = 3;
    private static final Integer MAX_FORM_FIELDS = 12;
    private static final Integer MAX_CURRENT = 80;
    private static final Integer MAX_HALF_WIDTH = 32;

    private static final String SHOWN = 'Shown to the user under your words.';
    private static final String FORM_SHOWN =
        'Shown as a form with Save and Cancel buttons, filled in with your values. Nothing has been written. ' +
        'The record is saved only if the user presses Save, and they may change any value first. This result is updated to say what they did.';

    /**
     * @description Something for the chat panel to draw. specJson holds the checked content for the
     * component that draws this kind of block.
     */
    public class Block {
        /** The tool call this answers; the chat uses it as the block's key. */
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String specJson;
        /** What Claude is told happened to its call. */
        public String result;
        /** Claude's words for above the block, taken from the call. */
        public String say;
    }

    /**
     * @description Claude's words with the follow-up questions taken off the end.
     */
    public class Words {
        public String text;
        public List<String> questions = new List<String>();
    }

    /**
     * @description A property in a tool's input schema, kept as text so the order Claude writes them in is the order given.
     */
    public class Prop {
        public String name;
        public String schema;

        public Prop(String name, String schema) {
            this.name = name;
            this.schema = schema;
        }
    }

    /**
     * @description Whether a tool call is one of the display tools.
     * @param toolName The tool Claude called
     * @return True for the eight display tools
     */
    public static Boolean isDisplayTool(String toolName) {
        return KINDS.containsKey(toolName);
    }

    /**
     * @description The display tool definitions as JSON text, comma separated, to splice into the
     * request's tools array. They are text rather than maps because Apex does not keep a map's key
     * order, and Claude writes a tool's properties in the order its schema lists them (a title before
     * its points, a caption after them), and each tool starts with the words to show above the block,
     * so Claude says what it found before it draws. They are not strict tools: eight more strict
     * schemas make the request's grammar too large for the API, so build() checks every call instead.
     * @return Eight tool definitions, in the words of this org's model
     */
    public static String toolDefinitionsJson() {
        return AntsuranceClaudeModel.current().displayTools();
    }

    /**
     * @description Checks a display call and builds the block for it. Writes nothing.
     * @param toolName The display tool Claude called
     * @param toolUseId The tool call's id
     * @param input The tool call's input
     * @param openRecordId The record the user has open, or null
     * @return The block to draw, with what to tell Claude
     * @throws IllegalArgumentException with a message for Claude when the call cannot be drawn as given
     */
    public static Block build(String toolName, String toolUseId, Map<String, Object> input, Id openRecordId) {
        Map<String, Object> spec;
        String result = SHOWN;
        if (toolName == RECORD_TOOL) {
            spec = recordCard(input, openRecordId);
            result = 'Shown: the summary card for ' + spec.get('name') + '.';
        } else if (toolName == METRICS_TOOL) {
            spec = metrics(input);
        } else if (toolName == CHART_TOOL) {
            spec = chart(input);
        } else if (toolName == LIST_TOOL) {
            spec = workList(input);
        } else if (toolName == FORM_TOOL) {
            spec = form(input);
            result = FORM_SHOWN + (String) spec.remove('note');
        } else if (toolName == DRAFT_TOOL) {
            spec = draft(input);
        } else if (toolName == COMPARISON_TOOL) {
            spec = comparison(input);
        } else if (toolName == TIMELINE_TOOL) {
            spec = timeline(input);
        } else {
            throw new IllegalArgumentException('There is no such tool.');
        }
        Block block = new Block();
        block.id = toolUseId;
        block.kind = KINDS.get(toolName);
        block.specJson = JSON.serialize(spec);
        block.result = result;
        block.say = optional(input, 'say');
        return block;
    }

    /**
     * @description Takes the follow-up questions off the end of Claude's words. Each is a line of its
     * own starting with ?> after the answer.
     * @param text Claude's words
     * @return The words without those lines, and the questions (three at most)
     */
    public static Words readNextQuestions(String text) {
        Words words = new Words();
        List<String> lines = text == null ? new List<String>() : text.split('\n');
        Integer last = lines.size() - 1;
        while (last >= 0) {
            if (String.isBlank(lines[last])) {
                last--;
                continue;
            }
            Matcher question = NEXT_LINE.matcher(lines[last]);
            if (!question.matches()) {
                break;
            }
            if (words.questions.isEmpty()) {
                words.questions.add(question.group(1));
            } else {
                words.questions.add(0, question.group(1));
            }
            last--;
        }
        List<String> kept = new List<String>();
        for (Integer index = 0; index <= last; index++) {
            kept.add(lines[index]);
        }
        words.text = String.join(kept, '\n').trim();
        while (words.questions.size() > MAX_QUESTIONS) {
            words.questions.remove(words.questions.size() - 1);
        }
        return words;
    }

    /**
     * @description The follow-up questions as a block of buttons for under the answer.
     * @param questions The questions read from Claude's words
     * @return The block
     */
    public static Block nextQuestions(List<String> questions) {
        Block block = new Block();
        block.id = NEXT_KIND;
        block.kind = NEXT_KIND;
        block.specJson = JSON.serialize(new Map<String, Object>{ 'questions' => questions });
        return block;
    }

    // ---------- Record card ----------

    /** What a record's card holds depends on what kind of record it is, so the content comes from the org's model. */
    private static Map<String, Object> recordCard(Map<String, Object> input, Id openRecordId) {
        AntsuranceClaudeModel model = AntsuranceClaudeModel.current();
        Id recordId = toId(input.get('record_id'), 'record_id');
        if (recordId == openRecordId) {
            throw new IllegalArgumentException(model.alreadyOpen());
        }
        return model.recordCard(recordId, recordId.getSObjectType().getDescribe().getName());
    }

    /**
     * @description Reads one record as the user.
     * @param soql The SELECT statement, without its WHERE clause
     * @param recordId The record to read
     * @return The record
     * @throws IllegalArgumentException with a message for Claude when the user cannot read it
     */
    public static SObject readOne(String soql, Id recordId) {
        List<SObject> records;
        try {
            records = Database.queryWithBinds(soql + ' WHERE Id = :recordId LIMIT 1', new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
        } catch (QueryException e) {
            records = new List<SObject>();
        }
        if (records.isEmpty()) {
            throw new IllegalArgumentException('No record with Id ' + recordId + ' is visible to this user. Query for the record and use its Id.');
        }
        return records[0];
    }

    /**
     * @description The name of the record a lookup points at.
     * @param record A record read with that parent's Name
     * @param relationship The lookup's relationship name
     * @param fallback What to return when the lookup is empty
     * @return The parent's name, or the fallback
     */
    public static String relatedName(SObject record, String relationship, String fallback) {
        String name = relatedField(record, relationship, 'Name');
        return name == null ? fallback : name;
    }

    /**
     * @description A text field of the record a lookup points at.
     * @param record A record read with that field of its parent
     * @param relationship The lookup's relationship name
     * @param field The parent's field
     * @return The value, or null when the lookup is empty
     */
    public static String relatedField(SObject record, String relationship, String field) {
        SObject parent = record.getSObject(relationship);
        return parent == null ? null : (String) parent.get(field);
    }

    /**
     * @description The values that are not blank, in order.
     * @param values Text values, some of which may be empty
     * @return Those with something in them
     */
    public static List<String> nonBlank(List<String> values) {
        List<String> kept = new List<String>();
        for (String value : values) {
            if (!String.isBlank(value)) {
                kept.add(value);
            }
        }
        return kept;
    }

    /**
     * @description Adds a labeled fact to a card, unless it has no value.
     * @param facts The card's facts so far
     * @param label What the fact is
     * @param value Its value as the card shows it
     */
    public static void addFact(List<Object> facts, String label, String value) {
        if (!String.isBlank(value)) {
            facts.add(new Map<String, Object>{ 'label' => label, 'value' => value });
        }
    }

    // ---------- Figures, chart, list ----------

    private static Map<String, Object> metrics(Map<String, Object> input) {
        List<Object> tiles = new List<Object>();
        for (Object item : listIn(input, 'tiles', 1, MAX_TILES, 'tiles')) {
            Map<String, Object> tile = (Map<String, Object>) item;
            tiles.add(
                new Map<String, Object>{
                    'label' => required(tile, 'label', 'Each tile needs a label.'),
                    'value' => required(tile, 'value', 'Each tile needs a value.'),
                    'note' => optional(tile, 'note'),
                    'tone' => tone(tile)
                }
            );
        }
        return new Map<String, Object>{ 'tiles' => tiles };
    }

    private static Map<String, Object> chart(Map<String, Object> input) {
        String chartType = (String) input.get('chart_type');
        String unit = (String) input.get('unit');
        if (!CHART_TYPES.contains(chartType)) {
            throw new IllegalArgumentException('chart_type must be one of: ' + String.join(CHART_TYPES, ', ') + '.');
        }
        if (!UNITS.contains(unit)) {
            throw new IllegalArgumentException('unit must be one of: ' + String.join(UNITS, ', ') + '.');
        }
        Boolean donut = chartType == 'donut';
        List<Object> points = new List<Object>();
        Set<String> labels = new Set<String>();
        Decimal total = 0;
        for (Object item : listIn(input, 'points', 2, donut ? MAX_SLICES : MAX_POINTS, donut ? 'slices in a donut; group the smallest as Other' : 'points')) {
            Map<String, Object> point = (Map<String, Object>) item;
            String label = required(point, 'label', 'Each point needs a label.');
            Decimal value;
            try {
                // A number, or a number written as text.
                value = Decimal.valueOf(String.valueOf(point.get('value')).replaceAll('[,$%\\s]', ''));
            } catch (Exception e) {
                throw new IllegalArgumentException('The value for ' + label + ' must be a number.');
            }
            if (value < 0 && chartType != 'line') {
                throw new IllegalArgumentException('A ' + chartType + ' chart cannot draw the negative value for ' + label + '. Use a line chart or leave it out.');
            }
            total += value;
            labels.add(label);
            points.add(new Map<String, Object>{ 'label' => label, 'value' => value });
        }
        if (donut && total <= 0) {
            throw new IllegalArgumentException('A donut needs values that add up to more than zero.');
        }
        String highlight = optional(input, 'highlight_label');
        return new Map<String, Object>{
            'title' => required(input, 'title', 'The chart needs a title.'),
            'caption' => optional(input, 'caption'),
            'chartType' => chartType,
            'unit' => unit,
            'points' => points,
            // A highlight that names no point is dropped rather than refused: the chart is still right.
            'highlight' => labels.contains(highlight) ? highlight : null
        };
    }

    private static Map<String, Object> workList(Map<String, Object> input) {
        List<Object> items = new List<Object>();
        for (Object entry : listIn(input, 'items', 1, MAX_ITEMS, 'rows; show the most urgent and say in your sentence how many there are in all')) {
            Map<String, Object> item = (Map<String, Object>) entry;
            List<Object> chips = new List<Object>();
            Object rawChips = item.get('chips');
            if (rawChips instanceof List<Object>) {
                for (Object rawChip : (List<Object>) rawChips) {
                    Map<String, Object> chip = (Map<String, Object>) rawChip;
                    if (chips.size() < MAX_CHIPS && !String.isBlank((String) chip.get('label'))) {
                        chips.add(new Map<String, Object>{ 'label' => ((String) chip.get('label')).trim(), 'tone' => tone(chip) });
                    }
                }
            }
            items.add(
                new Map<String, Object>{
                    'title' => required(item, 'title', 'Each row needs a title.'),
                    'subtitle' => optional(item, 'subtitle'),
                    'recordId' => optionalId(item.get('record_id')),
                    'amount' => optional(item, 'amount'),
                    'chips' => chips
                }
            );
        }
        return new Map<String, Object>{ 'title' => required(input, 'title', 'The list needs a title.'), 'items' => items };
    }

    // ---------- Draft, comparison, timeline ----------

    private static Map<String, Object> draft(Map<String, Object> input) {
        Id related = optionalId(input.get('related_record_id'));
        return new Map<String, Object>{
            'format' => input.get('format') == 'letter' ? 'letter' : 'email',
            'toName' => optional(input, 'to_name'),
            'toEmail' => optional(input, 'to_email'),
            'subject' => required(input, 'subject', 'The draft needs a subject line.'),
            'body' => required(input, 'body', 'The draft needs a body.'),
            'relatedRecordId' => related,
            'emailRecordId' => composerRecord(related)
        };
    }

    /**
     * The record Salesforce's email composer opens against. It does not open on a case or a quote,
     * so an email about one of those is logged on its account or its opportunity instead.
     */
    private static Id composerRecord(Id related) {
        if (related == null) {
            return null;
        }
        String objectName = related.getSObjectType().getDescribe().getName();
        if (AntsuranceClaudeModel.current().emailObjects().contains(objectName)) {
            return related;
        }
        String parentField = objectName == 'Case' ? 'AccountId' : objectName == 'Quote' ? 'OpportunityId' : null;
        if (parentField == null) {
            return null;
        }
        try {
            List<SObject> records = Database.queryWithBinds(
                'SELECT ' + parentField + ' FROM ' + objectName + ' WHERE Id = :recordId LIMIT 1',
                new Map<String, Object>{ 'recordId' => related },
                AccessLevel.USER_MODE
            );
            return records.isEmpty() ? null : (Id) records[0].get(parentField);
        } catch (QueryException e) {
            return null;
        }
    }

    private static Map<String, Object> comparison(Map<String, Object> input) {
        List<Object> columns = new List<Object>();
        Boolean hasRecommended = false;
        for (Object item : listIn(input, 'columns', 2, MAX_COLUMNS, 'options side by side')) {
            Map<String, Object> column = (Map<String, Object>) item;
            // Only the first option flagged is marked.
            Boolean recommended = column.get('recommended') == true && !hasRecommended;
            hasRecommended = hasRecommended || recommended;
            columns.add(
                new Map<String, Object>{
                    'name' => required(column, 'name', 'Each option needs a name.'),
                    'recordId' => optionalId(column.get('record_id')),
                    'recommended' => recommended
                }
            );
        }
        List<Object> rows = new List<Object>();
        for (Object item : listIn(input, 'rows', 1, MAX_ROWS, 'rows')) {
            Map<String, Object> row = (Map<String, Object>) item;
            String label = required(row, 'label', 'Each row needs a label.');
            List<Object> values = row.get('values') instanceof List<Object> ? (List<Object>) row.get('values') : new List<Object>();
            if (values.size() != columns.size()) {
                throw new IllegalArgumentException('The row ' + label + ' has ' + values.size() + ' values for ' + columns.size() + ' options. Give one value per option, in the same order.');
            }
            List<String> cells = new List<String>();
            for (Object value : values) {
                String cell = value == null ? '' : String.valueOf(value).trim();
                cells.add(cell == '' ? 'None' : cell);
            }
            rows.add(new Map<String, Object>{ 'label' => label, 'values' => cells });
        }
        return new Map<String, Object>{
            'title' => required(input, 'title', 'The comparison needs a title.'),
            'columns' => columns,
            'rows' => rows,
            'reason' => hasRecommended ? optional(input, 'reason') : null
        };
    }

    private static Map<String, Object> timeline(Map<String, Object> input) {
        List<Object> events = new List<Object>();
        for (Object item : listIn(input, 'events', 2, MAX_EVENTS, 'events; keep the ones that changed something')) {
            Map<String, Object> event = (Map<String, Object>) item;
            String title = required(event, 'title', 'Each event needs a title.');
            Date happened;
            try {
                happened = Date.valueOf(((String) event.get('date')).left(10));
            } catch (Exception e) {
                throw new IllegalArgumentException('The date for "' + title + '" must be written as YYYY-MM-DD.');
            }
            events.add(new Map<String, Object>{ 'date' => String.valueOf(happened), 'title' => title, 'detail' => optional(event, 'detail'), 'tone' => tone(event) });
        }
        return new Map<String, Object>{ 'title' => required(input, 'title', 'The timeline needs a title.'), 'events' => events };
    }

    // ---------- Form ----------

    /**
     * Checks a form before it is drawn: the object is one a form may touch and this user may create
     * or edit it, each field exists and they may set it, each suggested value fits its field, and
     * the record type is one they can use. A value Claude can correct refuses the form with the
     * reason; a field the user cannot set is left off the form and Claude is told.
     */
    private static Map<String, Object> form(Map<String, Object> input) {
        String objectName = (String) input.get('object');
        List<String> formObjects = AntsuranceClaudeModel.current().formObjects();
        if (!formObjects.contains(objectName)) {
            throw new IllegalArgumentException('A form can create or edit only: ' + String.join(formObjects, ', ') + '. Tell the user this one has to be done on its own page.');
        }
        Boolean editing = input.get('mode') == 'edit';
        Schema.DescribeSObjectResult describe = Schema.describeSObjects(new List<String>{ objectName })[0];
        String objectLabel = describe.getLabel();
        if (editing ? !describe.isUpdateable() : !describe.isCreateable()) {
            throw new IllegalArgumentException('This user is not allowed to ' + (editing ? 'edit' : 'create') + ' a ' + objectLabel + '. Tell them so.');
        }
        Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();
        Map<String, Object> spec = new Map<String, Object>{ 'mode' => editing ? 'edit' : 'create', 'objectApiName' => objectName, 'objectLabel' => objectLabel };
        List<String> notes = new List<String>();

        Id recordId;
        if (editing) {
            recordId = toId(input.get('record_id'), 'record_id');
            if (recordId.getSObjectType() != describe.getSObjectType()) {
                throw new IllegalArgumentException('record_id is not the Id of a ' + objectName + '. Query for the record and use its Id.');
            }
            spec.put('recordId', recordId);
        } else {
            String recordType = optional(input, 'record_type');
            Map<String, Schema.RecordTypeInfo> recordTypes = describe.getRecordTypeInfosByDeveloperName();
            if (recordType != null) {
                Schema.RecordTypeInfo info = recordTypes.get(recordType);
                if (info == null || !info.isAvailable() || info.isMaster()) {
                    List<String> available = new List<String>();
                    for (String developerName : recordTypes.keySet()) {
                        if (recordTypes.get(developerName).isAvailable() && !recordTypes.get(developerName).isMaster()) {
                            available.add(developerName);
                        }
                    }
                    throw new IllegalArgumentException(
                        available.isEmpty()
                            ? objectName + ' has no record types. Pass an empty record_type.'
                            : recordType + ' is not a record type this user can use on ' + objectName + '. Use one of: ' + String.join(available, ', ') + '.'
                    );
                }
                spec.put('recordTypeId', info.getRecordTypeId());
                objectLabel = info.getName();
            }
        }

        List<Object> requested = input.get('fields') instanceof List<Object> ? (List<Object>) input.get('fields') : new List<Object>();
        if (requested.size() > MAX_FORM_FIELDS) {
            throw new IllegalArgumentException('A form in the chat takes at most ' + MAX_FORM_FIELDS + ' fields. Keep the ones that matter.');
        }
        List<Map<String, Object>> fields = new List<Map<String, Object>>();
        Set<String> shown = new Set<String>();
        List<String> problems = new List<String>();
        List<String> leftOff = new List<String>();
        for (Object item : requested) {
            Map<String, Object> entry = (Map<String, Object>) item;
            String name = entry.get('name') == null ? '' : ((String) entry.get('name')).trim();
            String value = entry.get('value') == null ? '' : ((String) entry.get('value')).trim();
            if (name.equalsIgnoreCase('RecordTypeId') || name.equalsIgnoreCase('Id')) {
                continue;
            }
            // Where states and countries are picklists, the text fields cannot be set on their own, so the form uses the code fields.
            if ((name.endsWithIgnoreCase('State') || name.endsWithIgnoreCase('Country')) && fieldMap.get(name + 'Code') != null) {
                name += 'Code';
            }
            Schema.SObjectField token = fieldMap.get(name);
            if (token == null) {
                problems.add('There is no field ' + name + ' on ' + objectName + '.');
                continue;
            }
            Schema.DescribeFieldResult field = token.getDescribe();
            if (shown.contains(field.getName())) {
                continue;
            }
            if (editing ? !field.isUpdateable() : !field.isCreateable()) {
                if (field.getName() == 'Name' && fieldMap.containsKey('LastName')) {
                    problems.add('Use FirstName and LastName instead of Name.');
                } else {
                    leftOff.add(field.getName());
                }
                continue;
            }
            try {
                Map<String, Object> shownField = new Map<String, Object>{
                    'name' => field.getName(),
                    'label' => field.getLabel(),
                    'suggested' => value != '',
                    // The narrow panel shows required fields first, with the suggested ones.
                    'required' => !field.isNillable() && field.getType() != Schema.DisplayType.BOOLEAN,
                    // A long line of text gets the full width of the form, so it can be read without scrolling inside its box.
                    'wide' => field.getType() == Schema.DisplayType.TEXTAREA || value.length() > MAX_HALF_WIDTH
                };
                if (value != '') {
                    shownField.put('value', fitValue(field, value));
                }
                fields.add(shownField);
                shown.add(field.getName());
            } catch (IllegalArgumentException e) {
                problems.add(e.getMessage());
            }
        }
        if (!problems.isEmpty()) {
            throw new IllegalArgumentException(String.join(problems, ' ') + ' Correct this and call show_form again.');
        }
        addCountries(fields, shown, fieldMap, editing);
        if (!editing) {
            // A new record cannot be saved without these, so the form shows them even when Claude left them out.
            List<String> added = new List<String>();
            for (Schema.SObjectField token : fieldMap.values()) {
                Schema.DescribeFieldResult field = token.getDescribe();
                if (
                    !field.isNillable() &&
                    !field.isDefaultedOnCreate() &&
                    field.isCreateable() &&
                    field.getType() != Schema.DisplayType.BOOLEAN &&
                    !shown.contains(field.getName())
                ) {
                    fields.add(new Map<String, Object>{ 'name' => field.getName(), 'label' => field.getLabel(), 'suggested' => false, 'required' => true, 'wide' => false });
                    shown.add(field.getName());
                    added.add(field.getName());
                }
            }
            if (!added.isEmpty()) {
                notes.add('Required fields you left out were added for the user to fill in: ' + String.join(added, ', ') + '.');
            }
        }
        if (fields.isEmpty()) {
            throw new IllegalArgumentException(
                leftOff.isEmpty() ? 'Give at least one field to show.' : 'This user cannot set any of those fields (' + String.join(leftOff, ', ') + '). Tell them so.'
            );
        }
        if (!leftOff.isEmpty()) {
            notes.add('Left off the form because this user cannot set them: ' + String.join(leftOff, ', ') + '.');
        }

        if (editing) {
            SObject record = readForEdit(objectName, recordId, fields);
            spec.put('recordName', nameOf(record, objectName));
            for (Map<String, Object> shownField : fields) {
                if (shownField.get('suggested') == true) {
                    String current = display(fieldMap.get((String) shownField.get('name')).getDescribe(), record.get((String) shownField.get('name')));
                    if (current != null) {
                        shownField.put('current', current);
                    }
                }
            }
            spec.put('title', 'Edit ' + spec.get('recordName'));
        } else {
            spec.put('title', 'New ' + objectLabel.toLowerCase());
        }
        spec.put('objectLabel', objectLabel);
        spec.put('fields', fields);
        spec.put('note', notes.isEmpty() ? '' : ' ' + String.join(notes, ' '));
        return spec;
    }

    /**
     * A state picklist depends on its country, so a form with a state also shows the country, ahead of
     * it. On a new record the country starts as the one the org's model gives, when it gives one.
     */
    private static void addCountries(List<Map<String, Object>> fields, Set<String> shown, Map<String, Schema.SObjectField> fieldMap, Boolean editing) {
        for (Integer index = 0; index < fields.size(); index++) {
            String name = (String) fields[index].get('name');
            if (!name.endsWith('StateCode')) {
                continue;
            }
            Schema.SObjectField token = fieldMap.get(name.removeEnd('StateCode') + 'CountryCode');
            if (token == null || shown.contains(token.getDescribe().getName())) {
                continue;
            }
            Schema.DescribeFieldResult country = token.getDescribe();
            if (editing ? !country.isUpdateable() : !country.isCreateable()) {
                continue;
            }
            String startsAs = editing ? null : AntsuranceClaudeModel.current().defaultCountry();
            Map<String, Object> countryField = new Map<String, Object>{ 'name' => country.getName(), 'label' => country.getLabel(), 'suggested' => startsAs != null, 'wide' => false };
            if (startsAs != null) {
                countryField.put('value', startsAs);
            }
            fields.add(index, countryField);
            shown.add(country.getName());
            index++;
        }
    }

    /** The record being edited, with the fields on the form, read as the user. */
    private static SObject readForEdit(String objectName, Id recordId, List<Map<String, Object>> fields) {
        Set<String> selected = new Set<String>{ objectName == 'Case' ? 'CaseNumber' : objectName == 'Task' || objectName == 'Event' ? 'Subject' : 'Name' };
        if (objectName == 'Case') {
            selected.add('Subject');
        }
        for (Map<String, Object> field : fields) {
            selected.add((String) field.get('name'));
        }
        return readOne('SELECT ' + String.join(new List<String>(selected), ', ') + ' FROM ' + objectName, recordId);
    }

    private static String nameOf(SObject record, String objectName) {
        if (objectName == 'Case') {
            return 'case ' + record.get('CaseNumber') + (record.get('Subject') == null ? '' : ': ' + record.get('Subject'));
        }
        return (String) record.get(objectName == 'Task' || objectName == 'Event' ? 'Subject' : 'Name');
    }

    /** A suggested value in the form its field takes, or the reason it does not fit. */
    private static Object fitValue(Schema.DescribeFieldResult field, String value) {
        String name = field.getName();
        Object fitted;
        switch on field.getType() {
            when BOOLEAN {
                if (value.equalsIgnoreCase('true') || value.equalsIgnoreCase('yes')) {
                    fitted = true;
                } else if (value.equalsIgnoreCase('false') || value.equalsIgnoreCase('no')) {
                    fitted = false;
                } else {
                    throw new IllegalArgumentException(name + ' takes true or false.');
                }
            }
            when DATE {
                try {
                    fitted = String.valueOf(Date.valueOf(value.left(10)));
                } catch (Exception e) {
                    throw new IllegalArgumentException(name + ' takes a date written as YYYY-MM-DD.');
                }
            }
            when DATETIME {
                try {
                    Datetime moment = value.length() <= 10
                        ? Datetime.newInstance(Date.valueOf(value), Time.newInstance(12, 0, 0, 0))
                        : (Datetime) JSON.deserialize(JSON.serialize(value), Datetime.class);
                    fitted = moment.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');
                } catch (Exception e) {
                    throw new IllegalArgumentException(name + ' takes a date as YYYY-MM-DD or a date and time as 2026-10-05T15:00:00Z.');
                }
            }
            when CURRENCY, DOUBLE, PERCENT, INTEGER, LONG {
                try {
                    fitted = Decimal.valueOf(value.replaceAll('[,$%\\s]', ''));
                } catch (Exception e) {
                    throw new IllegalArgumentException(name + ' takes a number without symbols.');
                }
            }
            when PICKLIST {
                fitted = fitPicklist(field, value);
            }
            when MULTIPICKLIST {
                List<String> chosen = new List<String>();
                for (String part : value.split(';')) {
                    chosen.add(fitPicklist(field, part.trim()));
                }
                fitted = String.join(chosen, ';');
            }
            when REFERENCE {
                Id target;
                try {
                    target = Id.valueOf(value);
                } catch (Exception e) {
                    throw new IllegalArgumentException(name + ' is a lookup and takes an 18-character record Id, not "' + value + '". Query for the record first.');
                }
                if (!field.getReferenceTo().contains(target.getSObjectType())) {
                    throw new IllegalArgumentException(name + ' cannot point at a ' + target.getSObjectType() + '.');
                }
                fitted = target;
            }
            when STRING, TEXTAREA, EMAIL, PHONE, URL, COMBOBOX {
                if (field.getLength() > 0 && value.length() > field.getLength()) {
                    throw new IllegalArgumentException(name + ' holds at most ' + field.getLength() + ' characters.');
                }
                fitted = value;
            }
            when else {
                throw new IllegalArgumentException(name + ' cannot be set from a form in the chat. Leave it out.');
            }
        }
        return fitted;
    }

    private static String fitPicklist(Schema.DescribeFieldResult field, String value) {
        List<String> active = new List<String>();
        for (Schema.PicklistEntry entry : field.getPicklistValues()) {
            if (!entry.isActive()) {
                continue;
            }
            if (entry.getValue().equalsIgnoreCase(value) || entry.getLabel().equalsIgnoreCase(value)) {
                return entry.getValue();
            }
            if (active.size() < 20) {
                active.add(entry.getValue());
            }
        }
        throw new IllegalArgumentException('"' + value + '" is not a value of ' + field.getName() + '. Its values are: ' + String.join(active, ', ') + '.');
    }

    /** A field's current value as the form shows it beside a suggested change. Lookups are left out. */
    private static String display(Schema.DescribeFieldResult field, Object value) {
        Schema.DisplayType fieldType = field.getType();
        if (fieldType == Schema.DisplayType.REFERENCE) {
            return null;
        }
        if (value == null) {
            return 'empty';
        }
        if (fieldType == Schema.DisplayType.BOOLEAN) {
            return value == true ? 'Yes' : 'No';
        }
        if (fieldType == Schema.DisplayType.DATE) {
            return shortDate((Date) value);
        }
        if (fieldType == Schema.DisplayType.DATETIME) {
            return ((Datetime) value).format('MMM d, yyyy');
        }
        if (fieldType == Schema.DisplayType.CURRENCY) {
            return money((Decimal) value);
        }
        return String.valueOf(value).abbreviate(MAX_CURRENT);
    }

    // ---------- Reading the input ----------

    private static List<Object> listIn(Map<String, Object> input, String key, Integer least, Integer most, String what) {
        List<Object> items = input.get(key) instanceof List<Object> ? (List<Object>) input.get(key) : new List<Object>();
        if (items.size() < least) {
            throw new IllegalArgumentException(key + ' needs at least ' + least + (least == 1 ? ' entry.' : ' entries.'));
        }
        if (items.size() > most) {
            throw new IllegalArgumentException('At most ' + most + ' ' + what + '.');
        }
        return items;
    }

    private static String required(Map<String, Object> input, String key, String problem) {
        String value = optional(input, key);
        if (value == null) {
            throw new IllegalArgumentException(problem);
        }
        return value;
    }

    /** A trimmed string, or null when it is missing or empty. */
    private static String optional(Map<String, Object> input, String key) {
        Object value = input.get(key);
        return value instanceof String && !String.isBlank((String) value) ? ((String) value).trim() : null;
    }

    private static String tone(Map<String, Object> input) {
        return TONES.contains((String) input.get('tone')) ? (String) input.get('tone') : 'neutral';
    }

    private static Id toId(Object raw, String key) {
        Id recordId;
        try {
            recordId = raw instanceof String && !String.isBlank((String) raw) ? Id.valueOf(((String) raw).trim()) : null;
        } catch (Exception e) {
            recordId = null;
        }
        if (recordId == null) {
            throw new IllegalArgumentException(key + ' must be a record Id, not "' + raw + '". Query for the record and use its Id.');
        }
        return recordId;
    }

    /** A link is a convenience: one that is not a record Id is dropped rather than refused. */
    private static Id optionalId(Object raw) {
        try {
            return raw instanceof String && !String.isBlank((String) raw) ? Id.valueOf(((String) raw).trim()) : null;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * @description An amount as a card shows it, in whole dollars.
     * @param value The amount
     * @return For example $18,400, or null for no amount
     */
    public static String money(Decimal value) {
        return value == null ? null : '$' + value.setScale(0, System.RoundingMode.HALF_UP).format();
    }

    /**
     * @description A date as a card shows it.
     * @param value The date
     * @return For example Oct 5, 2026, or null for no date
     */
    public static String shortDate(Date value) {
        return value == null ? null : Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d, yyyy');
    }

    // ---------- Tool schemas, as text ----------

    /**
     * @description A display tool's definition, as JSON text.
     * @param name The tool's name
     * @param description What it draws and when to use it, as Claude reads it
     * @param properties Its input properties, in the order Claude should write them
     * @return The definition
     */
    public static String tool(String name, String description, List<Prop> properties) {
        return '{"name":' + JSON.serialize(name) + ',"description":' + JSON.serialize(description) + ',"input_schema":' + objectSchema(properties) + '}';
    }

    /** Every property is required, so leaving one empty is a decision Claude writes down. */
    private static String objectSchema(List<Prop> properties) {
        List<String> parts = new List<String>();
        List<String> names = new List<String>();
        for (Prop property : properties) {
            parts.add(JSON.serialize(property.name) + ':' + property.schema);
            names.add(property.name);
        }
        return '{"type":"object","properties":{' + String.join(parts, ',') + '},"required":' + JSON.serialize(names) + ',"additionalProperties":false}';
    }

    /**
     * @description A text property.
     * @param name The property's name
     * @param description What to put in it, as Claude reads it
     * @return The property
     */
    public static Prop text(String name, String description) {
        return new Prop(name, '{"type":"string","description":' + JSON.serialize(description) + '}');
    }

    /**
     * @description A number property.
     * @param name The property's name
     * @param description What to put in it, as Claude reads it
     * @return The property
     */
    public static Prop numberOf(String name, String description) {
        return new Prop(name, '{"type":"number","description":' + JSON.serialize(description) + '}');
    }

    /**
     * @description A true or false property.
     * @param name The property's name
     * @param description What it means, as Claude reads it
     * @return The property
     */
    public static Prop flag(String name, String description) {
        return new Prop(name, '{"type":"boolean","description":' + JSON.serialize(description) + '}');
    }

    /**
     * @description A property that takes one of a list of values.
     * @param name The property's name
     * @param options The values
     * @param description How to choose, as Claude reads it
     * @return The property
     */
    public static Prop choice(String name, List<String> options, String description) {
        return new Prop(name, '{"type":"string","enum":' + JSON.serialize(options) + ',"description":' + JSON.serialize(description) + '}');
    }

    /**
     * @description A property that takes a list of objects.
     * @param name The property's name
     * @param description What the list holds, as Claude reads it
     * @param itemProperties The properties of each entry
     * @return The property
     */
    public static Prop listOf(String name, String description, List<Prop> itemProperties) {
        return new Prop(name, '{"type":"array","description":' + JSON.serialize(description) + ',"items":' + objectSchema(itemProperties) + '}');
    }

    /**
     * @description A property that takes a list of text values.
     * @param name The property's name
     * @param description What the list holds, as Claude reads it
     * @return The property
     */
    public static Prop listOfText(String name, String description) {
        return new Prop(name, '{"type":"array","description":' + JSON.serialize(description) + ',"items":{"type":"string"}}');
    }
}
