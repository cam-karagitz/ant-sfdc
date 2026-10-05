/**
 * @description Reads a broker's submission for a policy sale or a lead. Each document is read by Claude
 * in a request of its own, so one slow document never costs the others. What the documents say is then
 * laid against the quote configurator's questions here in Apex: where two documents disagree, each
 * document's own figure is kept and none is chosen. A last request has Claude list what is missing or
 * inconsistent and draft the reply to the broker. Nothing is saved and nothing is sent.
 */
public with sharing class AntsuranceSubmissionIntake {
    @TestVisible
    private static final Integer MAX_FILES = 4;
    // A PDF travels as base64 into the request and again into Claude's request, so it is held three times over.
    @TestVisible
    private static final Integer MAX_PDF_BYTES = 900000;
    @TestVisible
    private static final Integer MAX_IMAGE_BYTES = 600000;
    private static final Integer READING_TOKENS = 3000;
    private static final Integer ADVICE_TOKENS = 2200;
    private static final Integer WORDS_LENGTH = 220;
    private static final Integer TEXT_ANSWER_LENGTH = 255;
    private static final String SAMPLE_PREFIX = 'antsuranceSubmission';
    // The sample documents are about this seeded customer and line, so the link is offered only there.
    @TestVisible
    private static final String SAMPLE_CUSTOMER = 'Lakeshore Dental Group';
    @TestVisible
    private static final String SAMPLE_LINE = 'Workers Compensation';
    private static final Map<String, String> SAMPLE_TITLES = new Map<String, String>{
        'antsuranceSubmissionCoverNote' => 'Broker\'s email',
        'antsuranceSubmissionApplication' => 'Application',
        'antsuranceSubmissionLossRun' => 'Loss run'
    };
    private static final List<String> SAMPLE_ORDER = new List<String>{ 'antsuranceSubmissionCoverNote', 'antsuranceSubmissionApplication', 'antsuranceSubmissionLossRun' };

    private static final Map<String, String> MEDIA_TYPES = new Map<String, String>{
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        'jpg' => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp'
    };
    private static final Map<String, String> KIND_LABELS = new Map<String, String>{
        'application' => 'Application',
        'loss_run' => 'Loss run',
        'cover_note' => 'Cover note',
        'schedule' => 'Schedule',
        'other' => 'Other document'
    };
    private static final List<String> KINDS = new List<String>{ 'application', 'loss_run', 'cover_note', 'schedule', 'other' };
    private static final Set<String> NOTHING_WORDS = new Set<String>{ 'none', 'nothing', 'n/a', 'na', 'no', 'not applicable' };
    // Whose word is shown first for an answer: the document that is meant to state it.
    private static final Map<String, Integer> KIND_RANK = new Map<String, Integer>{ 'application' => 0, 'schedule' => 1, 'loss_run' => 2, 'cover_note' => 3, 'other' => 4 };
    private static final List<String> ISSUE_KINDS = new List<String>{ 'missing', 'inconsistent', 'differs_from_record', 'unreadable', 'appetite' };

    @TestVisible
    private static final String NO_ACCESS = 'This record could not be read. Ask an administrator to check your access.';
    @TestVisible
    private static final String NO_QUESTIONS = 'There are no quote questions for this line of business yet, so there is nothing to read a submission into.';
    @TestVisible
    private static final String NOT_ON_RECORD = 'That file is not on this record.';
    @TestVisible
    private static final String WRONG_KIND = 'Claude reads PDFs and photos here (PDF, PNG, JPEG, GIF or WebP).';
    @TestVisible
    private static final String PDF_TOO_LARGE = 'That PDF is over 900 KB. Send the pages that matter, or a smaller scan.';
    @TestVisible
    private static final String IMAGE_TOO_LARGE = 'That photo is over 600 KB. Take it again at a lower size.';
    @TestVisible
    private static final String NO_SAMPLE = 'The sample submission is not installed in this org.';
    @TestVisible
    private static final String NOTHING_READ = 'Read at least one document first.';

    private static final String READER = String.join(
        new List<String>{
            'You are an underwriting assistant at Antsurance, a property and casualty insurer. A broker has sent a submission, and you are reading ONE document from it for the underwriter.',
            'Report only what this document says. Never guess, estimate or fill in a figure. If the document does not answer a question, leave that question out.',
            'For every quote question this document answers, return the question key, the value, the page it is on, and the exact words from the document that support it, copied as written and no more than 25 words.',
            'For a choice question the value must be one of the option values listed for it, never the label. When the document gives a figure that falls inside one option\'s range, give that option, set basis to worked_out and say how in the note, for example "0.94 falls in 0.90 to 1.10". When the document states the answer outright, set basis to read and leave the note empty.',
            'For a yes or no question the value is true or false. A checkbox left empty is not an answer: leave the question out and list it under problems.',
            'For a number or an amount, give digits only, with no commas, signs or units.',
            'A count such as claims is whatever THIS document shows. On a loss run, count the claims listed. Do not correct one document from what another might say.',
            'Under facts, list what an underwriter would still want from this document and the questions do not cover: who sent it, the dates asked for, the current carrier and premium, a deadline, anything about growth or change.',
            'Under losses, give one row per period the document reports claims for.',
            'Under problems, list what is blank, unsigned, missing or does not add up inside this document, each as one plain sentence.',
            'If part of the document cannot be read, say which part under unreadable. Otherwise leave it empty.',
            'Write plainly. Dates as Oct 2, 2026. Whole dollars. No dashes used as punctuation.'
        },
        '\n'
    );

    private static final String ADVISER = String.join(
        new List<String>{
            'You are an underwriting assistant at Antsurance, a property and casualty insurer. A broker\'s submission has been read document by document, and its answers have been laid against the quote questions. You are writing for the underwriter who will check it, and drafting the reply to the broker.',
            'Use only what is in the request. Quote figures exactly and name the document each came from. Never choose between two documents that disagree: say what each one says.',
            'headline: one short sentence, 20 words at most, saying what this submission is and whether it is ready to quote. Leave the list of what is open to the issues.',
            'issues: what is missing, inconsistent, different from what Antsurance already holds on the customer, unreadable, or worth an underwriter\'s look before quoting. One entry per issue, most important first, eight at most. Each has a short title of a few words, one or two sentences of detail with the figures and the documents named, and what to ask the broker for, or an empty ask when nothing needs asking.',
            'Kinds: missing (an answer or a document that is not there), inconsistent (two documents disagree), differs_from_record (a document disagrees with what Antsurance holds), unreadable, appetite (something in the documents an underwriter should weigh, such as growth, an open claim or a change in operations).',
            'replySubject and replyBody: a short, friendly email to the broker, addressed by first name when the documents give one, thanking them, saying what is needed before a quote can go out, as a short numbered list, and by when if the broker gave a deadline. Plain text. Sign it with the name given in the request. Promise no price and no decision.',
            'You advise and the underwriter decides. Do not say the risk is accepted or declined.',
            'Write plainly. Dates as Oct 2, 2026. Whole dollars. No dashes used as punctuation.'
        },
        '\n'
    );

    // ---------------------------------------------------------------- what the page works with

    /**
     * @description A file that could be read: one already on the record, or one of the sample documents.
     */
    public class FileItem {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String extension;
        @AuraEnabled
        public String sizeLabel;
        /** record or sample. */
        @AuraEnabled
        public String source;
        @AuraEnabled
        public Boolean readable;
        @AuraEnabled
        public String whyNot;
    }

    /**
     * @description What the card needs before anything is read.
     */
    public class Context {
        /** sale or lead. */
        @AuraEnabled
        public String recordKind;
        @AuraEnabled
        public String lineOfBusiness;
        @AuraEnabled
        public String customerName;
        /** False when the line has no quote questions; whyNot says so. */
        @AuraEnabled
        public Boolean canRead;
        @AuraEnabled
        public String whyNot;
        /** True on an open policy sale: the answers can be carried into a new quote. */
        @AuraEnabled
        public Boolean canQuote;
        @AuraEnabled
        public List<FileItem> files = new List<FileItem>();
        @AuraEnabled
        public List<FileItem> samples = new List<FileItem>();
        @AuraEnabled
        public Integer maxFiles = MAX_FILES;
        @AuraEnabled
        public Integer maxPdfBytes = MAX_PDF_BYTES;
        @AuraEnabled
        public Integer maxImageBytes = MAX_IMAGE_BYTES;
    }

    /**
     * @description One quote answer a document gives.
     */
    public class Found {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String value;
        @AuraEnabled
        public Integer page;
        @AuraEnabled
        public String words;
        /** read or worked_out. */
        @AuraEnabled
        public String basis;
        @AuraEnabled
        public String note;
    }

    /**
     * @description Something else a document says that an underwriter would want.
     */
    public class Fact {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String value;
        @AuraEnabled
        public Integer page;
    }

    /**
     * @description One period of a loss history.
     */
    public class LossRow {
        @AuraEnabled
        public String period;
        @AuraEnabled
        public Integer claims;
        @AuraEnabled
        public Decimal paid;
        @AuraEnabled
        public Decimal reserved;
        @AuraEnabled
        public String note;
    }

    /**
     * @description What Claude read in one document. The page keeps these and sends them back to assemble and advise.
     */
    public class Reading {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String kindLabel;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public Integer pages;
        @AuraEnabled
        public String summary;
        @AuraEnabled
        public List<Found> answers = new List<Found>();
        @AuraEnabled
        public List<Fact> facts = new List<Fact>();
        @AuraEnabled
        public List<LossRow> losses = new List<LossRow>();
        @AuraEnabled
        public List<String> problems = new List<String>();
        @AuraEnabled
        public String unreadable;
    }

    /**
     * @description Where one answer came from.
     */
    public class Source {
        @AuraEnabled
        public String document;
        @AuraEnabled
        public Integer page;
        @AuraEnabled
        public String words;
        @AuraEnabled
        public String value;
        @AuraEnabled
        public String valueLabel;
        @AuraEnabled
        public String basis;
        @AuraEnabled
        public String note;
    }

    /**
     * @description A choice a question offers, for the person to correct an answer.
     */
    public class Choice {
        @AuraEnabled
        public String value;
        @AuraEnabled
        public String label;
    }

    /**
     * @description One quote question and what the documents say to it.
     */
    public class Row {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String section;
        /** choice, toggle, number, currency or text. */
        @AuraEnabled
        public String type;
        /** read, worked_out, conflict, not_found or changed (by the person). */
        @AuraEnabled
        public String status;
        /** The settled answer, or null while the documents disagree or say nothing. */
        @AuraEnabled
        public String value;
        @AuraEnabled
        public String valueLabel;
        @AuraEnabled
        public List<Source> sources = new List<Source>();
        @AuraEnabled
        public List<Choice> options = new List<Choice>();
    }

    /**
     * @description A referral that depends on which document is right.
     */
    public class Conditional {
        @AuraEnabled
        public String question;
        @AuraEnabled
        public String document;
        @AuraEnabled
        public String valueLabel;
        @AuraEnabled
        public List<String> reasons = new List<String>();
    }

    /**
     * @description The documents laid against the quote questions.
     */
    public class Assembly {
        @AuraEnabled
        public List<Row> rows = new List<Row>();
        /** Reasons the answers as they stand would send the quote to an underwriter. */
        @AuraEnabled
        public List<String> referrals = new List<String>();
        @AuraEnabled
        public List<Conditional> conditionals = new List<Conditional>();
        /** The settled answers, keyed by question, in the form the configurator keeps them. */
        @AuraEnabled
        public String answersJson;
        @AuraEnabled
        public Integer settled = 0;
        @AuraEnabled
        public Integer conflicts = 0;
        @AuraEnabled
        public Integer notFound = 0;
    }

    /**
     * @description One thing for the underwriter to deal with before quoting.
     */
    public class Issue {
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String detail;
        @AuraEnabled
        public String ask;
    }

    /**
     * @description Claude's read of the whole submission and the reply it drafted.
     */
    public class Advice {
        @AuraEnabled
        public String headline;
        @AuraEnabled
        public List<Issue> issues = new List<Issue>();
        @AuraEnabled
        public String replySubject;
        @AuraEnabled
        public String replyBody;
    }

    // ---------------------------------------------------------------- the record

    /** What a sale or a lead tells the reader about the customer. */
    private class Subject {
        String recordKind;
        String lineOfBusiness;
        String customerName;
        Boolean isOpen = true;
        List<String> held = new List<String>();
    }

    private static Subject subjectOf(Id recordId) {
        Subject subject = new Subject();
        try {
            if (recordId != null && recordId.getSobjectType() == Opportunity.SObjectType) {
                List<Opportunity> sales = [
                    SELECT IsClosed, Line_of_Business__c, Type, Account.Name, Account.Industry, Account.NumberOfEmployees, Account.Description, Account.BillingCity, Account.Customer_Since__c
                    FROM Opportunity
                    WHERE Id = :recordId
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (sales.isEmpty()) {
                    throw handled(NO_ACCESS);
                }
                Opportunity sale = sales[0];
                subject.recordKind = 'sale';
                subject.lineOfBusiness = sale.Line_of_Business__c;
                subject.customerName = sale.Account?.Name;
                subject.isOpen = !sale.IsClosed;
                hold(subject.held, 'Kind of sale', sale.Type);
                hold(subject.held, 'Industry', sale.Account?.Industry);
                hold(subject.held, 'Employees', sale.Account?.NumberOfEmployees);
                hold(subject.held, 'What the business does', sale.Account?.Description);
                hold(subject.held, 'City', sale.Account?.BillingCity);
                hold(subject.held, 'Customer since', sale.Account?.Customer_Since__c);
            } else if (recordId != null && recordId.getSobjectType() == Lead.SObjectType) {
                List<Lead> leads = [SELECT Company, Product_Interest__c, Industry, NumberOfEmployees, City, Description FROM Lead WHERE Id = :recordId WITH USER_MODE LIMIT 1];
                if (leads.isEmpty()) {
                    throw handled(NO_ACCESS);
                }
                Lead lead = leads[0];
                subject.recordKind = 'lead';
                subject.lineOfBusiness = lead.Product_Interest__c;
                subject.customerName = lead.Company;
                hold(subject.held, 'Industry', lead.Industry);
                hold(subject.held, 'Employees', lead.NumberOfEmployees);
                hold(subject.held, 'City', lead.City);
                hold(subject.held, 'What we know', lead.Description);
            } else {
                throw handled(NO_ACCESS);
            }
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        return subject;
    }

    private static void hold(List<String> held, String label, Object value) {
        if (value != null && String.isNotBlank(String.valueOf(value))) {
            held.add(label + ': ' + (value instanceof Date ? ((Datetime) Datetime.newInstance((Date) value, Time.newInstance(0, 0, 0, 0))).format('MMM d, yyyy') : String.valueOf(value)));
        }
    }

    private static List<AntsuranceQuoteConfigurator.Question> questionsFor(String lineOfBusiness) {
        List<AntsuranceQuoteConfigurator.Question> questions = new List<AntsuranceQuoteConfigurator.Question>();
        if (String.isBlank(lineOfBusiness)) {
            return questions;
        }
        for (AntsuranceQuoteConfigurator.Section section : AntsuranceQuoteConfigurator.getQuestionnaire(lineOfBusiness)) {
            questions.addAll(section.questions);
        }
        return questions;
    }

    /**
     * @description What the card shows before anything is read: the line being quoted, the files already
     * on the record, and the sample submission where it fits.
     * @param recordId A policy sale or a lead
     * @return The context
     * @throws AuraHandledException when the record cannot be read
     */
    @AuraEnabled
    public static Context getContext(Id recordId) {
        Subject subject = subjectOf(recordId);
        Context context = new Context();
        context.recordKind = subject.recordKind;
        context.lineOfBusiness = subject.lineOfBusiness;
        context.customerName = subject.customerName;
        context.canRead = !questionsFor(subject.lineOfBusiness).isEmpty();
        context.whyNot = context.canRead ? null : NO_QUESTIONS;
        context.canQuote = context.canRead && subject.recordKind == 'sale' && subject.isOpen;

        try {
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension, ContentDocument.ContentSize
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :recordId AND ContentDocument.FileType != :AntsuranceSalesforceNotes.FILE_TYPE
                WITH USER_MODE
                ORDER BY ContentDocument.CreatedDate DESC
                LIMIT 20
            ]) {
                FileItem item = new FileItem();
                item.id = link.ContentDocumentId;
                item.title = link.ContentDocument.Title;
                item.extension = link.ContentDocument.FileExtension?.toLowerCase();
                item.sizeLabel = sizeLabel(link.ContentDocument.ContentSize);
                item.source = 'record';
                item.whyNot = whyNotReadable(item.extension, link.ContentDocument.ContentSize);
                item.readable = item.whyNot == null;
                context.files.add(item);
            }
        } catch (QueryException e) {
            // No access to files: the card still takes uploads.
            context.files.clear();
        }

        if (subject.customerName == SAMPLE_CUSTOMER && subject.lineOfBusiness == SAMPLE_LINE) {
            Map<String, StaticResource> found = new Map<String, StaticResource>();
            for (StaticResource resource : [SELECT Name, BodyLength FROM StaticResource WHERE Name IN :SAMPLE_ORDER]) {
                found.put(resource.Name, resource);
            }
            for (String name : SAMPLE_ORDER) {
                if (!found.containsKey(name)) {
                    continue;
                }
                FileItem item = new FileItem();
                item.id = name;
                item.title = SAMPLE_TITLES.get(name);
                item.extension = 'pdf';
                item.sizeLabel = sizeLabel(found.get(name).BodyLength);
                item.source = 'sample';
                item.readable = true;
                context.samples.add(item);
            }
        }
        return context;
    }

    private static String whyNotReadable(String extension, Integer size) {
        if (extension == null || !MEDIA_TYPES.containsKey(extension)) {
            return WRONG_KIND;
        }
        if (extension == 'pdf' && size > MAX_PDF_BYTES) {
            return PDF_TOO_LARGE;
        }
        if (extension != 'pdf' && size > MAX_IMAGE_BYTES) {
            return IMAGE_TOO_LARGE;
        }
        return null;
    }

    private static String sizeLabel(Integer bytes) {
        if (bytes == null) {
            return '';
        }
        return bytes >= 1000000 ? (Decimal.valueOf(bytes) / 1000000).setScale(1, RoundingMode.HALF_UP).toPlainString() + ' MB' : Math.max(1, (Integer) Math.round(bytes / 1000.0)) + ' KB';
    }

    // ---------------------------------------------------------------- reading one document

    /**
     * @description Has Claude read a document the person just chose. It is read and let go: nothing is stored.
     * @param recordId The policy sale or lead
     * @param name The file's name, shown back on the card
     * @param mediaType The file's type, such as application/pdf
     * @param base64 The file, base64 encoded
     * @return What the document says
     * @throws AuraHandledException when the file is of a kind or size Claude cannot read here, or Claude cannot be reached
     */
    @AuraEnabled
    public static Reading readUpload(Id recordId, String name, String mediaType, String base64) {
        Subject subject = subjectOf(recordId);
        String type = mediaType == null ? '' : mediaType.toLowerCase();
        if (!new Set<String>(MEDIA_TYPES.values()).contains(type) || String.isBlank(base64)) {
            throw handled(WRONG_KIND);
        }
        Blob body = EncodingUtil.base64Decode(base64);
        if (type == 'application/pdf' && body.size() > MAX_PDF_BYTES) {
            throw handled(PDF_TOO_LARGE);
        }
        if (type != 'application/pdf' && body.size() > MAX_IMAGE_BYTES) {
            throw handled(IMAGE_TOO_LARGE);
        }
        return read(subject, String.isBlank(name) ? 'Document' : name, type, body);
    }

    /**
     * @description Has Claude read a file that is already on the record.
     * @param recordId The policy sale or lead
     * @param documentId The file (ContentDocument)
     * @return What the document says
     * @throws AuraHandledException when the file is not on this record, cannot be read here, or Claude cannot be reached
     */
    @AuraEnabled
    public static Reading readRecordFile(Id recordId, Id documentId) {
        Subject subject = subjectOf(recordId);
        ContentVersion version;
        try {
            List<ContentDocumentLink> links = [
                SELECT ContentDocument.LatestPublishedVersionId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :recordId AND ContentDocumentId = :documentId
                WITH USER_MODE
                LIMIT 1
            ];
            if (links.isEmpty()) {
                throw handled(NOT_ON_RECORD);
            }
            Id versionId = links[0].ContentDocument.LatestPublishedVersionId;
            version = [SELECT Title, FileExtension, ContentSize FROM ContentVersion WHERE Id = :versionId WITH USER_MODE LIMIT 1];
            String problem = whyNotReadable(version.FileExtension?.toLowerCase(), version.ContentSize);
            if (problem != null) {
                throw handled(problem);
            }
            // The body is loaded only once the kind and size are known to be acceptable.
            version.VersionData = [SELECT VersionData FROM ContentVersion WHERE Id = :versionId WITH USER_MODE LIMIT 1].VersionData;
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        return read(subject, version.Title, MEDIA_TYPES.get(version.FileExtension.toLowerCase()), version.VersionData);
    }

    /**
     * @description Has Claude read one of the sample documents that ship with the app, so a demo needs no files.
     * @param recordId The policy sale or lead
     * @param name The sample's static resource name
     * @return What the document says
     * @throws AuraHandledException when the sample is not installed or Claude cannot be reached
     */
    @AuraEnabled
    public static Reading readSample(Id recordId, String name) {
        Subject subject = subjectOf(recordId);
        if (name == null || !SAMPLE_TITLES.containsKey(name)) {
            throw handled(NO_SAMPLE);
        }
        List<StaticResource> resources = [SELECT Body FROM StaticResource WHERE Name = :name LIMIT 1];
        if (resources.isEmpty()) {
            throw handled(NO_SAMPLE);
        }
        return read(subject, SAMPLE_TITLES.get(name), 'application/pdf', resources[0].Body);
    }

    private static Reading read(Subject subject, String name, String mediaType, Blob body) {
        List<AntsuranceQuoteConfigurator.Question> questions = questionsFor(subject.lineOfBusiness);
        if (questions.isEmpty()) {
            throw handled(NO_QUESTIONS);
        }
        String prompt =
            'The submission is for ' +
            subject.lineOfBusiness +
            ' for ' +
            (String.isBlank(subject.customerName) ? 'a new customer' : subject.customerName) +
            '. Today is ' +
            Datetime.now().format('MMM d, yyyy') +
            '.\n\nThe quote questions, one per line, as key | question | kind | option values with their labels:\n' +
            describeQuestions(questions) +
            '\n\nThe attached document was sent as "' +
            name +
            '". Read it and report what it says.';
        Map<String, Object> answer;
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(READER, prompt).returning(readingShape(questions)).attach(mediaType, body);
            question.maxTokens = READING_TOKENS;
            answer = AntsuranceAiClient.ask(question).data;
        } catch (AntsuranceAiClient.AiException e) {
            throw handled(e.getMessage());
        }
        return toReading(name, answer, questions);
    }

    private static String describeQuestions(List<AntsuranceQuoteConfigurator.Question> questions) {
        List<String> lines = new List<String>();
        for (AntsuranceQuoteConfigurator.Question question : questions) {
            List<String> options = new List<String>();
            for (AntsuranceQuoteConfigurator.Option option : question.options) {
                options.add(option.value + ' = ' + option.label);
            }
            String kind = question.type == 'toggle' ? 'yes or no' : question.type == 'currency' ? 'amount in dollars' : question.type;
            lines.add(question.key + ' | ' + question.label + ' | ' + kind + (question.type == 'choice' ? ' | ' + String.join(options, '; ') : ''));
        }
        return String.join(lines, '\n');
    }

    private static AntsuranceAiClient.Shape readingShape(List<AntsuranceQuoteConfigurator.Question> questions) {
        List<String> keys = new List<String>();
        for (AntsuranceQuoteConfigurator.Question question : questions) {
            keys.add(question.key);
        }
        AntsuranceAiClient.Shape found = new AntsuranceAiClient.Shape()
            .field('key', AntsuranceAiClient.choice(keys, 'The key of the quote question this answers.'))
            .field('value', AntsuranceAiClient.text('The answer: an option value for a choice question, true or false for a yes or no question, digits for a number or an amount, or the words for a text question.'))
            .field('page', AntsuranceAiClient.optionalNumber('The page the answer is on, from 1.'))
            .field('words', AntsuranceAiClient.text('The exact words from the document that support the answer, no more than 25 words.'))
            .field('basis', AntsuranceAiClient.choice(new List<String>{ 'read', 'worked_out' }, 'read when the document states it outright; worked_out when you placed a stated figure into an option.'))
            .field('note', AntsuranceAiClient.text('For worked_out, how in a few words. Otherwise empty.'));
        AntsuranceAiClient.Shape fact = new AntsuranceAiClient.Shape()
            .field('label', AntsuranceAiClient.text('What the fact is, in a few words.'))
            .field('value', AntsuranceAiClient.text('The fact as the document gives it.'))
            .field('page', AntsuranceAiClient.optionalNumber('The page it is on, from 1.'));
        AntsuranceAiClient.Shape loss = new AntsuranceAiClient.Shape()
            .field('period', AntsuranceAiClient.text('The period, for example Dec 1, 2024 to Dec 1, 2025.'))
            .field('claims', AntsuranceAiClient.optionalNumber('How many claims the document lists for the period.'))
            .field('paid', AntsuranceAiClient.optionalNumber('Total paid for the period, in dollars.'))
            .field('reserved', AntsuranceAiClient.optionalNumber('Total still reserved for the period, in dollars.'))
            .field('note', AntsuranceAiClient.text('Anything notable, such as a claim still open. Otherwise empty.'));
        return new AntsuranceAiClient.Shape()
            .field('kind', AntsuranceAiClient.choice(KINDS, 'What kind of document this is. cover_note is the broker\'s email or letter that comes with the documents; schedule is a list of vehicles, locations or people.'))
            .field('title', AntsuranceAiClient.text('What the document calls itself, in a few words.'))
            .field('pages', AntsuranceAiClient.optionalNumber('How many pages it has.'))
            .field('summary', AntsuranceAiClient.text('One or two sentences on what the document is and what it says.'))
            .field('answers', AntsuranceAiClient.listOf(found.toJson(), 'One entry for each quote question this document answers.'))
            .field('facts', AntsuranceAiClient.listOf(fact.toJson(), 'Other facts an underwriter would want from this document.'))
            .field('losses', AntsuranceAiClient.listOf(loss.toJson(), 'One row per period of loss history. Empty when the document has none.'))
            .field('problems', AntsuranceAiClient.listOf(AntsuranceAiClient.text('One plain sentence.'), 'What is blank, unsigned, missing or does not add up inside this document.'))
            .field('unreadable', AntsuranceAiClient.text('Which part could not be read. An empty string when all of it could be read.'));
    }

    @TestVisible
    private static Reading toReading(String name, Map<String, Object> answer, List<AntsuranceQuoteConfigurator.Question> questions) {
        Map<String, AntsuranceQuoteConfigurator.Question> byKey = new Map<String, AntsuranceQuoteConfigurator.Question>();
        for (AntsuranceQuoteConfigurator.Question question : questions) {
            byKey.put(question.key, question);
        }
        Reading reading = new Reading();
        reading.name = name;
        reading.kind = KIND_LABELS.containsKey((String) answer.get('kind')) ? (String) answer.get('kind') : 'other';
        reading.kindLabel = KIND_LABELS.get(reading.kind);
        reading.title = clean(answer.get('title'), 120);
        reading.pages = toInteger(answer.get('pages'));
        reading.summary = clean(answer.get('summary'), 600);
        reading.unreadable = clean(answer.get('unreadable'), 400);
        // "None" and the like mean it could all be read.
        if (reading.unreadable != null && NOTHING_WORDS.contains(reading.unreadable.toLowerCase().removeEnd('.'))) {
            reading.unreadable = null;
        }
        reading.problems = AntsuranceAiClient.toStrings(answer.get('problems'));

        Set<String> taken = new Set<String>();
        for (Object item : listOf(answer.get('answers'))) {
            Map<String, Object> given = (Map<String, Object>) item;
            AntsuranceQuoteConfigurator.Question question = byKey.get((String) given.get('key'));
            String raw = clean(given.get('value'), TEXT_ANSWER_LENGTH);
            if (question == null || String.isBlank(raw) || taken.contains(question.key)) {
                continue;
            }
            String value = usable(question, raw);
            if (value == null) {
                // The document says something the question cannot take as an answer. It is kept as a fact so nothing is lost.
                Fact kept = new Fact();
                kept.label = question.label;
                kept.value = raw;
                kept.page = toInteger(given.get('page'));
                reading.facts.add(kept);
                continue;
            }
            taken.add(question.key);
            Found found = new Found();
            found.key = question.key;
            found.value = value;
            found.page = toInteger(given.get('page'));
            found.words = clean(given.get('words'), WORDS_LENGTH);
            found.basis = (String) given.get('basis') == 'worked_out' ? 'worked_out' : 'read';
            found.note = clean(given.get('note'), 200);
            reading.answers.add(found);
        }
        for (Object item : listOf(answer.get('facts'))) {
            Map<String, Object> given = (Map<String, Object>) item;
            Fact fact = new Fact();
            fact.label = clean(given.get('label'), 80);
            fact.value = clean(given.get('value'), 300);
            fact.page = toInteger(given.get('page'));
            if (String.isNotBlank(fact.label) && String.isNotBlank(fact.value)) {
                reading.facts.add(fact);
            }
        }
        for (Object item : listOf(answer.get('losses'))) {
            Map<String, Object> given = (Map<String, Object>) item;
            LossRow row = new LossRow();
            row.period = clean(given.get('period'), 80);
            row.claims = toInteger(given.get('claims'));
            row.paid = AntsuranceAiClient.toDecimal(given.get('paid'));
            row.reserved = AntsuranceAiClient.toDecimal(given.get('reserved'));
            row.note = clean(given.get('note'), 200);
            if (String.isNotBlank(row.period)) {
                reading.losses.add(row);
            }
        }
        return reading;
    }

    /** The value in the form the configurator keeps it, or null when the question cannot take it. */
    @TestVisible
    private static String usable(AntsuranceQuoteConfigurator.Question question, String raw) {
        String text = raw.trim();
        if (question.type == 'choice' || question.type == 'toggle') {
            String wanted = text.toLowerCase();
            if (question.type == 'toggle') {
                wanted = wanted == 'yes' ? 'true' : wanted == 'no' ? 'false' : wanted;
            }
            for (AntsuranceQuoteConfigurator.Option option : question.options) {
                if (option.value.toLowerCase() == wanted || option.label.toLowerCase() == wanted) {
                    return option.value;
                }
            }
            return null;
        }
        if (question.type == 'number' || question.type == 'currency') {
            try {
                Decimal amount = Decimal.valueOf(text.replaceAll('[,$\\s]', ''));
                return amount < 0 ? null : amount.setScale(0, RoundingMode.HALF_UP).toPlainString();
            } catch (TypeException e) {
                return null;
            }
        }
        return text.left(TEXT_ANSWER_LENGTH);
    }

    // ---------------------------------------------------------------- laying the documents against the questions

    /**
     * @description Lays what the documents say against the quote questions. An answer is settled when
     * every document that gives one agrees, or when the person has chosen. Where documents disagree
     * each one's figure is shown and none is chosen. No call to Claude is made.
     * @param recordId The policy sale or lead
     * @param readingsJson The readings, as returned by the read methods
     * @param choicesJson The person's own answers, keyed by question, or blank
     * @return The questions with their answers and sources, and what would refer the quote
     * @throws AuraHandledException when nothing has been read or the record cannot be read
     */
    @AuraEnabled
    public static Assembly assemble(Id recordId, String readingsJson, String choicesJson) {
        Subject subject = subjectOf(recordId);
        return assemble(subject, parseReadings(readingsJson), parseChoices(choicesJson));
    }

    private static List<Reading> parseReadings(String readingsJson) {
        List<Reading> readings = String.isBlank(readingsJson) ? new List<Reading>() : (List<Reading>) JSON.deserialize(readingsJson, List<Reading>.class);
        if (readings.isEmpty()) {
            throw handled(NOTHING_READ);
        }
        return readings;
    }

    private static Map<String, Object> parseChoices(String choicesJson) {
        return String.isBlank(choicesJson) ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(choicesJson);
    }

    private static Assembly assemble(Subject subject, List<Reading> readings, Map<String, Object> choices) {
        List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire(subject.lineOfBusiness);
        if (sections.isEmpty()) {
            throw handled(NO_QUESTIONS);
        }
        Assembly assembly = new Assembly();
        Map<String, Object> settled = new Map<String, Object>();
        List<Row> disputed = new List<Row>();
        Map<String, AntsuranceQuoteConfigurator.Question> byKey = new Map<String, AntsuranceQuoteConfigurator.Question>();

        for (AntsuranceQuoteConfigurator.Section section : sections) {
            for (AntsuranceQuoteConfigurator.Question question : section.questions) {
                byKey.put(question.key, question);
                Row row = new Row();
                row.key = question.key;
                row.label = question.label;
                row.section = section.title;
                row.type = question.type;
                for (AntsuranceQuoteConfigurator.Option option : question.options) {
                    Choice choice = new Choice();
                    choice.value = option.value;
                    choice.label = option.label;
                    row.options.add(choice);
                }
                Set<String> distinct = new Set<String>();
                List<Integer> ranks = new List<Integer>();
                for (Reading reading : readings) {
                    for (Found found : reading.answers) {
                        if (found.key != question.key) {
                            continue;
                        }
                        // What came back from the page is checked again: it is only ever an answer the question can take.
                        String value = usable(question, found.value);
                        if (value == null) {
                            continue;
                        }
                        Source source = new Source();
                        source.document = String.isBlank(reading.name) ? reading.kindLabel : reading.name;
                        source.page = found.page;
                        source.words = found.words;
                        source.value = value;
                        source.valueLabel = labelOf(question, value);
                        source.basis = found.basis;
                        source.note = found.note;
                        // An answer stated outright comes before one that was worked out, and an application before a cover note.
                        Integer rank = (found.basis == 'worked_out' ? 10 : 0) + (KIND_RANK.containsKey(reading.kind) ? KIND_RANK.get(reading.kind) : 4);
                        Integer position = 0;
                        while (position < ranks.size() && ranks[position] <= rank) {
                            position++;
                        }
                        if (position == ranks.size()) {
                            ranks.add(rank);
                            row.sources.add(source);
                        } else {
                            ranks.add(position, rank);
                            row.sources.add(position, source);
                        }
                        distinct.add(question.type == 'text' ? 'text' : value);
                    }
                }
                String chosen = choices.containsKey(question.key) && choices.get(question.key) != null ? usable(question, String.valueOf(choices.get(question.key))) : null;
                if (chosen != null) {
                    row.status = 'changed';
                    row.value = chosen;
                } else if (row.sources.isEmpty()) {
                    row.status = 'not_found';
                } else if (distinct.size() > 1) {
                    row.status = 'conflict';
                    disputed.add(row);
                } else {
                    row.status = row.sources[0].basis == 'worked_out' ? 'worked_out' : 'read';
                    row.value = row.sources[0].value;
                }
                if (row.value != null) {
                    row.valueLabel = labelOf(question, row.value);
                    settled.put(question.key, question.type == 'number' || question.type == 'currency' ? (Object) Decimal.valueOf(row.value) : (Object) row.value);
                }
                assembly.rows.add(row);
            }
        }

        // A question the answers so far do not ask (a deductible on a plan that has none) is left out.
        List<Row> asked = new List<Row>();
        for (Row row : assembly.rows) {
            if (AntsuranceQuoteConfigurator.isAsked(byKey.get(row.key), settled)) {
                asked.add(row);
                assembly.settled += row.value != null ? 1 : 0;
                assembly.conflicts += row.status == 'conflict' ? 1 : 0;
                assembly.notFound += row.status == 'not_found' ? 1 : 0;
            } else {
                settled.remove(row.key);
            }
        }
        assembly.rows = asked;
        assembly.answersJson = JSON.serialize(settled);

        // What the org's own rules would refer: the configurator's referral reasons, for the answers as they stand.
        Set<String> standing = new Set<String>(AntsuranceQuoteConfigurator.price(subject.lineOfBusiness, assembly.answersJson, null).referrals);
        assembly.referrals = new List<String>(standing);
        // And for each answer the documents disagree on: what each document's figure would do.
        for (Row row : disputed) {
            Set<String> seen = new Set<String>();
            for (Source source : row.sources) {
                if (seen.contains(source.value)) {
                    continue;
                }
                seen.add(source.value);
                Map<String, Object> trial = new Map<String, Object>(settled);
                trial.put(row.key, source.value);
                Conditional conditional = new Conditional();
                conditional.question = row.label;
                conditional.document = source.document;
                conditional.valueLabel = source.valueLabel;
                for (String reason : AntsuranceQuoteConfigurator.price(subject.lineOfBusiness, JSON.serialize(trial), null).referrals) {
                    if (!standing.contains(reason)) {
                        conditional.reasons.add(reason);
                    }
                }
                if (!conditional.reasons.isEmpty()) {
                    assembly.conditionals.add(conditional);
                }
            }
        }
        return assembly;
    }

    private static String labelOf(AntsuranceQuoteConfigurator.Question question, String value) {
        for (AntsuranceQuoteConfigurator.Option option : question.options) {
            if (option.value == value) {
                return option.label;
            }
        }
        if (question.type == 'currency') {
            return '$' + Decimal.valueOf(value).setScale(0, RoundingMode.HALF_UP).format();
        }
        if (question.type == 'number') {
            return Decimal.valueOf(value).format();
        }
        return value;
    }

    // ---------------------------------------------------------------- what is missing, and the reply

    /**
     * @description Has Claude say what is missing or inconsistent across the submission and draft the reply
     * to the broker. The reply is a draft for the person: nothing is sent.
     * @param recordId The policy sale or lead
     * @param readingsJson The readings, as returned by the read methods
     * @param choicesJson The person's own answers, keyed by question, or blank
     * @return A one-line read, the issues, and the reply
     * @throws AuraHandledException when nothing has been read or Claude cannot be reached
     */
    @AuraEnabled
    public static Advice advise(Id recordId, String readingsJson, String choicesJson) {
        Subject subject = subjectOf(recordId);
        List<Reading> readings = parseReadings(readingsJson);
        Assembly assembly = assemble(subject, readings, parseChoices(choicesJson));
        Map<String, Object> answer;
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(ADVISER, describe(subject, readings, assembly)).returning(adviceShape());
            question.maxTokens = ADVICE_TOKENS;
            answer = AntsuranceAiClient.ask(question).data;
        } catch (AntsuranceAiClient.AiException e) {
            throw handled(e.getMessage());
        }
        Advice advice = new Advice();
        advice.headline = clean(answer.get('headline'), 300);
        advice.replySubject = clean(answer.get('replySubject'), 200);
        advice.replyBody = answer.get('replyBody') == null ? null : String.valueOf(answer.get('replyBody')).trim();
        for (Object item : listOf(answer.get('issues'))) {
            Map<String, Object> given = (Map<String, Object>) item;
            Issue issue = new Issue();
            issue.kind = ISSUE_KINDS.contains((String) given.get('kind')) ? (String) given.get('kind') : 'missing';
            issue.title = clean(given.get('title'), 120);
            issue.detail = clean(given.get('detail'), 600);
            issue.ask = clean(given.get('ask'), 300);
            if (String.isNotBlank(issue.title)) {
                advice.issues.add(issue);
            }
        }
        return advice;
    }

    private static AntsuranceAiClient.Shape adviceShape() {
        AntsuranceAiClient.Shape issue = new AntsuranceAiClient.Shape()
            .field('kind', AntsuranceAiClient.choice(ISSUE_KINDS, 'What kind of issue this is.'))
            .field('title', AntsuranceAiClient.text('The issue in a few words.'))
            .field('detail', AntsuranceAiClient.text('One or two sentences, with the figures and the documents named.'))
            .field('ask', AntsuranceAiClient.text('What to ask the broker for, or empty.'));
        return new AntsuranceAiClient.Shape()
            .field('headline', AntsuranceAiClient.text('One short sentence, 20 words at most: what this submission is and whether it is ready to quote.'))
            .field('issues', AntsuranceAiClient.listOf(issue.toJson(), 'What to deal with before quoting, most important first, eight at most.'))
            .field('replySubject', AntsuranceAiClient.text('The subject line of the reply to the broker.'))
            .field('replyBody', AntsuranceAiClient.text('The reply to the broker, as plain text with line breaks.'));
    }

    /** Everything the adviser needs, as plain text. */
    private static String describe(Subject subject, List<Reading> readings, Assembly assembly) {
        List<String> lines = new List<String>{
            'Submission for ' + subject.lineOfBusiness + ' for ' + (String.isBlank(subject.customerName) ? 'a new customer' : subject.customerName) + '. Today is ' + Datetime.now().format('MMM d, yyyy') + '.',
            'Sign the reply as ' + UserInfo.getName() + ', Antsurance.',
            ''
        };
        lines.add('WHAT ANTSURANCE HOLDS ON THE CUSTOMER');
        lines.addAll(subject.held.isEmpty() ? new List<String>{ 'Nothing yet: this is a new customer.' } : subject.held);
        lines.add('');
        lines.add('THE QUOTE QUESTIONS AND WHAT THE DOCUMENTS SAY');
        for (Row row : assembly.rows) {
            if (row.status == 'not_found') {
                lines.add('- ' + row.label + ': NOT IN ANY DOCUMENT.');
            } else if (row.status == 'conflict') {
                List<String> sides = new List<String>();
                for (Source source : row.sources) {
                    sides.add(source.document + ' says ' + source.valueLabel + ' ("' + source.words + '")');
                }
                lines.add('- ' + row.label + ': THE DOCUMENTS DISAGREE. ' + String.join(sides, '; ') + '.');
            } else if (row.status == 'changed') {
                lines.add('- ' + row.label + ': ' + row.valueLabel + ' (set by the underwriter).');
            } else {
                Source source = row.sources[0];
                lines.add('- ' + row.label + ': ' + row.valueLabel + ' (' + source.document + (source.page == null ? '' : ', page ' + source.page) + ': "' + source.words + '")');
            }
        }
        lines.add('');
        lines.add('WHAT WOULD REFER THE QUOTE TO AN UNDERWRITER, BY ANTSURANCE\'S RULES');
        lines.addAll(assembly.referrals.isEmpty() ? new List<String>{ 'Nothing, on the answers as they stand.' } : assembly.referrals);
        for (Conditional conditional : assembly.conditionals) {
            lines.add('If ' + conditional.document + ' is right about ' + conditional.question + ' (' + conditional.valueLabel + '): ' + String.join(conditional.reasons, '; ') + '.');
        }
        for (Reading reading : readings) {
            lines.add('');
            lines.add('DOCUMENT: ' + reading.name + ' (' + reading.kindLabel + (reading.pages == null ? '' : ', ' + reading.pages + (reading.pages == 1 ? ' page' : ' pages')) + ')');
            lines.add(reading.summary);
            for (Fact fact : reading.facts) {
                lines.add('Fact: ' + fact.label + ': ' + fact.value);
            }
            for (LossRow loss : reading.losses) {
                lines.add(
                    'Losses, ' +
                        loss.period +
                        ': ' +
                        (loss.claims == null ? 'claims not stated' : loss.claims + (loss.claims == 1 ? ' claim' : ' claims')) +
                        (loss.paid == null ? '' : ', $' + loss.paid.setScale(0, RoundingMode.HALF_UP).format() + ' paid') +
                        (loss.reserved == null ? '' : ', $' + loss.reserved.setScale(0, RoundingMode.HALF_UP).format() + ' reserved') +
                        (String.isBlank(loss.note) ? '' : '. ' + loss.note)
                );
            }
            for (String problem : reading.problems) {
                lines.add('Problem in this document: ' + problem);
            }
            if (String.isNotBlank(reading.unreadable)) {
                lines.add('Could not be read: ' + reading.unreadable);
            }
        }
        return String.join(lines, '\n');
    }

    // ---------------------------------------------------------------- small helpers

    private static List<Object> listOf(Object value) {
        return value instanceof List<Object> ? (List<Object>) value : new List<Object>();
    }

    private static String clean(Object value, Integer length) {
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value).trim();
        return String.isBlank(text) ? null : text.left(length);
    }

    private static Integer toInteger(Object value) {
        Decimal amount = AntsuranceAiClient.toDecimal(value);
        return amount == null ? null : amount.intValue();
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
