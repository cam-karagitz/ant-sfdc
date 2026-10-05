/**
 * @description Prepares a customer-facing quote proposal for a policy sale (AntsuranceDocumentProposal):
 * the quoted options side by side, what happens next, and for the recommended option a summary of
 * what the customer told us, read from the answers stored on the quote. The sale, its customer and
 * its quotes are read as the running user.
 */
public with sharing class AntsuranceDocumentProposalController {
    private static final Set<String> CLOSED_STATUSES = new Set<String>{ 'Declined', 'Expired' };
    // What a closed option is tagged with. A customer reads this, and "Declined" does not say who declined:
    // the customer may have turned the offer down, or the underwriter may have. Either way it is no longer on offer.
    private static final Map<String, String> CLOSED_TAGS = new Map<String, String>{ 'Declined' => 'No longer on offer', 'Expired' => 'Offer expired' };
    /** What the proposal prints for "Valid until" when every option is closed and none carries a date that has passed. */
    private static final String OFFER_CLOSED = 'Offer closed';
    /** What the proposal prints for "Valid until" when no option carries an end date. */
    private static final String NO_END_DATE = 'To be confirmed';
    private static final Set<String> TAKEN_STATUSES = new Set<String>{ 'Accepted', 'Bound' };
    // Quotes that have gone to the customer. A draft has not, so it stays out of a proposal while these exist.
    private static final Set<String> OFFERED_STATUSES = new Set<String>{ 'Issued', 'Presented', 'Accepted', 'Bound' };
    private static final Integer MOST_OPTIONS = 3;
    private static final Integer MAX_NAME = 44;
    private static final Integer INTRO_LINE_LENGTH = 126;
    private static final Integer CLOSING_LINE_LENGTH = 150;
    // Text width of an option column in characters, by how many options share the page.
    private static final Map<Integer, Integer> OPTION_LINE_LENGTHS = new Map<Integer, Integer>{ 1 => 110, 2 => 52, 3 => 32 };
    // The same for an option's name, which is set larger and in bold.
    private static final Map<Integer, Integer> OPTION_NAME_LENGTHS = new Map<Integer, Integer>{ 1 => 80, 2 => 40, 3 => 24 };
    private static final Map<Integer, String> OPTION_WIDTHS = new Map<Integer, String>{ 1 => '501pt', 2 => '228pt', 3 => '143pt' };
    private static final Map<Integer, String> OPTION_GAPS = new Map<Integer, String>{ 1 => '0pt', 2 => '21pt', 3 => '12pt' };
    // The longest answer that fits beside its question in half the page; longer ones take a full row.
    private static final Integer MAX_SHORT_ANSWER = 21;
    private static final Integer MAX_QUESTION = 33;
    private static final Integer MAX_LONG_ANSWER = 78;

    // Heights in points, measured from the printed page, for deciding where page breaks fall.
    // Everything above the opening paragraph, then the paragraph's lines.
    private static final Decimal TOP_HEIGHT = 202;
    private static final Decimal INTRO_LINE_HEIGHT = 11.5;
    // The options with one-line names and no text, then each line of text and each extra line of a name.
    private static final Decimal OPTIONS_HEIGHT = 290;
    private static final Decimal OPTION_LINE_HEIGHT = 11;
    private static final Decimal OPTION_NAME_LINE_HEIGHT = 13;
    private static final Decimal STEPS_HEIGHT = 84;
    private static final Decimal CLOSING_HEIGHT = 38;
    private static final Decimal ANSWERS_HEADING_HEIGHT = 50;
    private static final Decimal ANSWER_SECTION_HEIGHT = 30;
    private static final Decimal ANSWER_ROW_HEIGHT = 17;

    /** One quoted option, printed as a column. */
    public class Option {
        /** The option's name, on as many lines as its column needs. */
        public List<String> nameLines { get; set; }
        public String tag { get; set; }
        public Boolean isRecommended { get; set; }
        public String premium { get; set; }
        public String monthly { get; set; }
        public String limitText { get; set; }
        public String deductible { get; set; }
        public List<String> includes { get; set; }
        public List<String> differs { get; set; }
        public String reference { get; set; }
        /** The gap printed before this column: one width, or none for the first column. */
        public List<String> gaps { get; set; }
        /** Width of the column's text. */
        public String width { get; set; }
        public String cellClass { get { return isRecommended ? 'option lead-option' : 'option'; } }
    }

    /** One row of answers: two short question and answer pairs, or one long one. */
    public class AnswerRow {
        public String firstQuestion { get; set; }
        public String firstAnswer { get; set; }
        public String secondQuestion { get; set; }
        public String secondAnswer { get; set; }
        public Boolean isWide { get; set; }
        public Boolean isPair { get { return !isWide; } }
    }

    /** One group of answers, under the heading the configurator asked them under. */
    public class AnswerSection {
        public String title { get; set; }
        public List<AnswerRow> rows { get; set; }
        public String sectionClass { get; set; }
    }

    public Boolean found { get; private set; }
    /** Why there is no proposal, when there is none. */
    public String notice { get; private set; }
    public String lineOfBusiness { get; private set; }
    public String customerName { get; private set; }
    public List<String> addressLines { get; private set; }
    public String preparedBy { get; private set; }
    public String proposalDate { get; private set; }
    public String validUntil { get; private set; }
    // Sentences that end in a value are put together here, because the page drops the space before one.
    public String acceptBy { get; private set; }
    public String replyTo { get; private set; }
    public String saleType { get; private set; }
    public String underwriter { get; private set; }
    public List<String> introLines { get; private set; }
    public List<Option> options { get; private set; }
    public String recommendedName { get; private set; }
    public String answersIntro { get; private set; }
    // Wording that depends on whether there is one option or several.
    public String optionsHeading { get; private set; }
    public String firstStep { get; private set; }
    public List<String> firstStepLines { get; private set; }
    public String lastStep { get; private set; }
    public List<String> lastStepLines { get; private set; }
    /** True when every option printed is closed: the page is then a record of what was offered, not an offer. */
    public Boolean isClosed { get; private set; }
    public List<AnswerSection> answerSections { get; private set; }
    public List<String> closingLines { get; private set; }
    public String documentLabel { get; private set; }
    public String stepsClass { get; private set; }
    public String answersClass { get; private set; }
    public String closingClass { get; private set; }

    public Boolean hasAnswers { get { return answerSections != null && !answerSections.isEmpty(); } }

    /**
     * @description Loads the policy sale named by the page's id parameter. A sale that cannot be
     * found, or has no quotes yet, leaves found false and the page prints a short notice instead.
     */
    public AntsuranceDocumentProposalController() {
        found = false;
        lineOfBusiness = 'Insurance';
        documentLabel = 'Insurance proposal';
        Map<String, String> parameters = ApexPages.currentPage().getParameters();
        Opportunity sale = findSale(parameters.get('id'));
        if (sale == null) {
            notice = 'This policy sale could not be found.';
            return;
        }
        List<Quote> quotes = openQuotes(sale);
        if (quotes.isEmpty()) {
            notice = 'This policy sale has no quotes to propose yet.';
            return;
        }
        Quote recommended = recommended(quotes);
        describeSale(sale, quotes, recommended);
        describeOptions(quotes, recommended);
        describeAnswers(sale.Line_of_Business__c, recommended);
        layOut();
        found = true;

        String disposition = parameters.get('download') == '1' ? 'attachment' : 'inline';
        String fileName = 'Proposal-' + AntsuranceDocumentFormat.fileSafe(sale.Name) + '.pdf';
        ApexPages.currentPage().getHeaders().put('content-disposition', disposition + '; filename=' + fileName);
    }

    /**
     * @description Whether a policy sale has at least one quote, and so can be given a proposal.
     * @param saleId The policy sale
     * @return True when the running user can see a quote on it
     */
    public static Boolean isAvailableFor(Id saleId) {
        return saleId != null && [SELECT COUNT() FROM Quote WHERE OpportunityId = :saleId WITH USER_MODE] > 0;
    }

    private static Opportunity findSale(String recordId) {
        if (!(recordId instanceof Id) || ((Id) recordId).getSObjectType() != Opportunity.SObjectType) {
            return null;
        }
        List<Opportunity> sales = [
            SELECT
                Name, Line_of_Business__c, Type, Owner.Name, Account.Name, Account.BillingStreet, Account.BillingCity, Account.BillingState,
                Account.BillingPostalCode,
                (
                    SELECT Name, QuoteNumber, Status, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Issued_Date__c, ExpirationDate, Underwriter__c,
                        Description, Configuration__c
                    FROM Quotes
                    ORDER BY CreatedDate, QuoteNumber
                )
            FROM Opportunity
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
        return sales.isEmpty() ? null : sales[0];
    }

    /**
     * The quotes to print, up to as many as fit side by side: those that have gone to the customer;
     * failing that, those still being worked on; failing that, every quote, closed ones included.
     * So a closed option is printed only when nothing on the sale is open, and then every option is
     * closed: the page keeps what was offered, for a customer who comes back, and says it is closed.
     */
    private static List<Quote> openQuotes(Opportunity sale) {
        List<Quote> offered = new List<Quote>();
        List<Quote> inProgress = new List<Quote>();
        for (Quote quote : sale.Quotes) {
            if (OFFERED_STATUSES.contains(quote.Status)) {
                offered.add(quote);
            } else if (!CLOSED_STATUSES.contains(quote.Status)) {
                inProgress.add(quote);
            }
        }
        List<Quote> chosen = !offered.isEmpty() ? offered : (!inProgress.isEmpty() ? inProgress : sale.Quotes.clone());
        while (chosen.size() > MOST_OPTIONS) {
            chosen.remove(chosen.size() - 1);
        }
        return chosen;
    }

    /** The option the customer took, else the one written up as recommended, else the first. */
    private static Quote recommended(List<Quote> quotes) {
        for (Quote quote : quotes) {
            if (TAKEN_STATUSES.contains(quote.Status)) {
                return quote;
            }
        }
        for (Quote quote : quotes) {
            if (quote.Description != null && quote.Description.containsIgnoreCase('recommended')) {
                return quote;
            }
        }
        return quotes[0];
    }

    private void describeSale(Opportunity sale, List<Quote> quotes, Quote recommended) {
        lineOfBusiness = String.isBlank(sale.Line_of_Business__c) ? 'Insurance' : sale.Line_of_Business__c;
        documentLabel = 'Proposal, quote ' + recommended.QuoteNumber;
        Boolean isSingle = quotes.size() == 1;
        isClosed = true;
        for (Quote quote : quotes) {
            isClosed = isClosed && CLOSED_STATUSES.contains(quote.Status);
        }
        optionsHeading = isSingle ? 'Your quote' : 'Your options';
        if (isClosed) {
            // Nothing here can be accepted any more, so the steps are how to get a quote that can.
            firstStep = 'Ask for a fresh quote';
            firstStepLines = isSingle
                ? new List<String>{ 'This offer has closed.', 'We can price it again.' }
                : new List<String>{ 'These offers have closed.', 'We can price them again.' };
            lastStep = 'We send you new options';
            lastStepLines = new List<String>{ 'Priced at today\'s rates,', 'with a date to answer by.' };
        } else {
            firstStep = isSingle ? 'Check the details' : 'Choose an option';
            firstStepLines = isSingle
                ? new List<String>{ 'Make sure the cover suits you,', 'or ask us to adjust it.' }
                : new List<String>{ 'Tell us which one suits you,', 'or ask us to adjust it.' };
            lastStep = 'We put the cover in place';
            lastStepLines = new List<String>{ 'You get your policy and', 'declarations page by email.' };
        }
        customerName = sale.Account == null ? sale.Name.abbreviate(MAX_NAME) : sale.Account.Name.abbreviate(MAX_NAME);
        addressLines = new List<String>();
        if (sale.Account != null) {
            if (String.isNotBlank(sale.Account.BillingStreet)) {
                addressLines.add(sale.Account.BillingStreet.replaceAll('\\s*[\\r\\n]+\\s*', ', ').abbreviate(54));
            }
            String cityLine = String.join(AntsuranceDocumentFormat.present(new List<String>{ sale.Account.BillingCity, AntsuranceAddress.state(sale.Account, 'Billing') }), ', ');
            cityLine = String.join(AntsuranceDocumentFormat.present(new List<String>{ cityLine, sale.Account.BillingPostalCode }), ' ');
            if (String.isNotBlank(cityLine)) {
                addressLines.add(cityLine);
            }
        }
        preparedBy = sale.Owner.Name.abbreviate(MAX_NAME);
        proposalDate = AntsuranceDocumentFormat.longDate(recommended.Issued_Date__c == null ? Date.today() : recommended.Issued_Date__c);
        Date earliest = null;
        for (Quote quote : quotes) {
            if (quote.ExpirationDate != null && (earliest == null || quote.ExpirationDate < earliest)) {
                earliest = quote.ExpirationDate;
            }
        }
        // A customer reads this. With no date on any option it says so in their words, not the system's "Not recorded".
        validUntil = earliest == null ? NO_END_DATE : AntsuranceDocumentFormat.longDate(earliest);
        acceptBy = earliest == null ? 'Say yes when you are ready' : 'Say yes by ' + validUntil;
        if (isClosed) {
            // A date that has passed says when the offer ended. One still to come, or none, would read as an open offer.
            if (earliest == null || earliest >= Date.today()) {
                validUntil = OFFER_CLOSED;
            }
            acceptBy = 'Tell us what has changed';
        }
        replyTo = 'to ' + sale.Owner.Name.abbreviate(26) + '.';
        saleType = String.isBlank(sale.Type) ? 'New Business' : sale.Type;
        underwriter = AntsuranceDocumentFormat.cell(recommended.Underwriter__c, 22);

        String count = quotes.size() == 1 ? 'the option' : 'the ' + new List<String>{ 'two', 'three' }[quotes.size() - 2] + ' options';
        // A renewing customer did not ask for a quote; their cover is coming up and these are the terms for the next year.
        String opening = saleType == 'Renewal'
            ? 'Your ' + lineOfBusiness.toLowerCase() + ' insurance with Antsurance is coming up for renewal. Below ' + (quotes.size() == 1 ? 'is ' : 'are ') + count + ' we priced for the next term'
            : 'Thank you for asking Antsurance for a quote. Below ' + (quotes.size() == 1 ? 'is ' : 'are ') + count + ' we priced for your ' + lineOfBusiness.toLowerCase() + ' insurance';
        introLines = AntsuranceDocumentFormat.wrap(
            opening + (quotes.size() == 1 ? '' : ', side by side') +
            (isClosed
                ? (isSingle ? '. This offer has closed, so its premium is' : '. These offers have closed, so their premiums are') +
                  ' shown for reference. Ask us and we will price ' + (isSingle ? 'it' : 'them') + ' again.'
                : (isSingle ? '. The premium' : '. Each premium') + ' is for a 12-month policy' + (earliest == null ? '.' : ' and holds until the date shown.')),
            INTRO_LINE_LENGTH
        );
        closingLines = AntsuranceDocumentFormat.wrap(
            'This proposal is a summary of what we quoted, and it is not a policy. Cover starts only when we confirm it in writing. ' +
            'The policy sets out the full terms, conditions and exclusions, and it is the policy that decides what is covered.',
            CLOSING_LINE_LENGTH
        );
    }

    private void describeOptions(List<Quote> quotes, Quote recommended) {
        options = new List<Option>();
        Integer lineLength = OPTION_LINE_LENGTHS.get(quotes.size());
        for (Quote quote : quotes) {
            Option option = new Option();
            option.isRecommended = quote.Id == recommended.Id;
            option.nameLines = AntsuranceDocumentFormat.wrap(quote.Name.abbreviate(64), OPTION_NAME_LENGTHS.get(quotes.size()));
            if (TAKEN_STATUSES.contains(quote.Status)) {
                option.tag = 'Accepted';
            } else if (CLOSED_STATUSES.contains(quote.Status)) {
                option.tag = CLOSED_TAGS.get(quote.Status);
            } else {
                option.tag = option.isRecommended ? 'Recommended' : 'Alternative';
            }
            Decimal premium = quote.Annual_Premium__c;
            Boolean hasCents = premium != null && premium != premium.setScale(0, RoundingMode.DOWN);
            option.premium = AntsuranceDocumentFormat.money(premium, hasCents ? 2 : 0, 'On request');
            option.monthly = premium == null ? 'Ask us for the price' : 'a year, or about ' + AntsuranceDocumentFormat.money(premium / 12, 0, '') + ' a month';
            option.limitText = AntsuranceDocumentFormat.money(quote.Coverage_Limit__c, 0, 'As described');
            Boolean hasDeductible = quote.Deductible__c != null && quote.Deductible__c != 0;
            // The same way the quote board and policy card show no deductible.
            option.deductible = hasDeductible ? AntsuranceDocumentFormat.money(quote.Deductible__c, 0, '') : '$0';

            Map<String, String> parts = describedParts(quote.Description);
            String includes = parts.containsKey('includes') ? parts.get('includes') : parts.get('');
            option.includes = AntsuranceDocumentFormat.wrap(String.isBlank(includes) ? 'As set out in the quote.' : includes, lineLength);
            String differs = parts.get('difference');
            if (String.isBlank(differs)) {
                differs = !option.isRecommended ? 'Ask us how this compares.' : (isClosed ? 'This is the option we recommended.' : 'This is the option we recommend for you.');
            }
            option.differs = AntsuranceDocumentFormat.wrap(differs, lineLength);
            // A closed option was valid until its date only when that date has passed; one closed early says no date.
            Boolean datedReference = quote.ExpirationDate != null && (!isClosed || quote.ExpirationDate < Date.today());
            option.reference = 'Quote ' + quote.QuoteNumber + (datedReference ? ', valid until ' + AntsuranceDocumentFormat.longDate(quote.ExpirationDate) : '');
            option.width = OPTION_WIDTHS.get(quotes.size());
            option.gaps = options.isEmpty() ? new List<String>() : new List<String>{ OPTION_GAPS.get(quotes.size()) };
            options.add(option);
        }
        recommendedName = recommended.Name;
        answersIntro = 'We priced the ' + recommended.Name.abbreviate(40) + ' option on the answers below. Tell us if anything has changed, because it can change the price.';
    }

    /**
     * A quote's description is short Markdown: paragraphs that open with a bold label, such as
     * "**Includes:** ..." and "**Difference:** ...". Returns each paragraph's words by its label in
     * lower case, with text that has no label under the empty label.
     */
    @TestVisible
    private static Map<String, String> describedParts(String description) {
        Map<String, String> parts = new Map<String, String>();
        if (String.isBlank(description)) {
            return parts;
        }
        for (String paragraph : description.split('\\n\\s*\\n')) {
            String text = AntsuranceDocumentFormat.plain(paragraph);
            Matcher labelled = Pattern.compile('^\\s*\\*\\*([^*:]+):\\*\\*').matcher(paragraph);
            String label = '';
            if (labelled.find()) {
                label = labelled.group(1).trim().toLowerCase();
                text = AntsuranceDocumentFormat.plain(paragraph.substring(labelled.end()));
            }
            if (String.isNotBlank(text)) {
                parts.put(label, parts.containsKey(label) ? parts.get(label) + ' ' + text : text);
            }
        }
        return parts;
    }

    private void describeAnswers(String line, Quote recommended) {
        answerSections = new List<AnswerSection>();
        Map<String, Object> answers = storedAnswers(recommended.Configuration__c);
        if (answers.isEmpty()) {
            return;
        }
        // A line the configurator does not know has no questions, so no answers are printed for it.
        for (AntsuranceQuoteConfigurator.Section section : AntsuranceQuoteConfigurator.getQuestionnaire(line)) {
            List<List<String>> pairs = new List<List<String>>();
            for (AntsuranceQuoteConfigurator.Question question : section.questions) {
                String answer = readable(question, answers);
                if (answer != null) {
                    pairs.add(new List<String>{ question.label.abbreviate(MAX_QUESTION), answer });
                }
            }
            if (pairs.isEmpty()) {
                continue;
            }
            AnswerSection answerSection = new AnswerSection();
            answerSection.title = section.title;
            answerSection.rows = rowsOf(pairs);
            answerSections.add(answerSection);
        }
    }

    private static Map<String, Object> storedAnswers(String configuration) {
        if (String.isBlank(configuration)) {
            return new Map<String, Object>();
        }
        try {
            Object stored = JSON.deserializeUntyped(configuration);
            Object answers = stored instanceof Map<String, Object> ? ((Map<String, Object>) stored).get('answers') : null;
            return answers instanceof Map<String, Object> ? (Map<String, Object>) answers : new Map<String, Object>();
        } catch (JSONException problem) {
            // Text that is not the configurator's JSON carries no answers to print.
            return new Map<String, Object>();
        }
    }

    /** The answer to a question in the customer's words, or null when it was not asked or not answered. */
    private static String readable(AntsuranceQuoteConfigurator.Question question, Map<String, Object> answers) {
        if (question.showWhenKey != null) {
            Object other = answers.get(question.showWhenKey);
            if (other == null || !question.showWhenValues.contains(String.valueOf(other))) {
                return null;
            }
        }
        Object stored = answers.get(question.key);
        String value = stored == null ? null : String.valueOf(stored).trim();
        if (String.isBlank(value)) {
            return null;
        }
        if (question.type == 'toggle') {
            return value == 'true' ? 'Yes' : 'No';
        }
        if (question.type == 'choice') {
            for (AntsuranceQuoteConfigurator.Option option : question.options) {
                if (option.value == value) {
                    return option.label;
                }
            }
            return value;
        }
        if (question.type == 'currency' || question.type == 'number') {
            try {
                Decimal amount = Decimal.valueOf(value.replaceAll('[$,]', ''));
                return question.type == 'currency' ? AntsuranceDocumentFormat.money(amount, 0, value) : amount.format();
            } catch (TypeException problem) {
                // Not a number after all: print what was typed.
                return value;
            }
        }
        return value;
    }

    /** Short answers sit two to a row; one too long for half the page takes a row of its own. */
    private static List<AnswerRow> rowsOf(List<List<String>> pairs) {
        List<AnswerRow> rows = new List<AnswerRow>();
        AnswerRow open = null;
        for (List<String> pair : pairs) {
            if (pair[1].length() > MAX_SHORT_ANSWER) {
                AnswerRow wide = new AnswerRow();
                wide.isWide = true;
                wide.firstQuestion = pair[0];
                wide.firstAnswer = pair[1].abbreviate(MAX_LONG_ANSWER);
                rows.add(wide);
            } else if (open == null) {
                open = new AnswerRow();
                open.isWide = false;
                open.firstQuestion = pair[0];
                open.firstAnswer = pair[1];
                open.secondQuestion = '';
                open.secondAnswer = '';
                rows.add(open);
            } else {
                open.secondQuestion = pair[0];
                open.secondAnswer = pair[1];
                open = null;
            }
        }
        return rows;
    }

    /**
     * Decides where the page breaks go. The first page is the offer: the options, what happens next
     * and, when there are no answers to print, the closing note. The answers start a page of their own.
     * Heights were measured from printed proposals with two and three options.
     */
    private void layOut() {
        Integer mostLines = 0;
        Integer mostNameLines = 1;
        for (Option option : options) {
            mostLines = Math.max(mostLines, option.includes.size() + option.differs.size());
            mostNameLines = Math.max(mostNameLines, option.nameLines.size());
        }
        AntsuranceDocumentLayout layout = new AntsuranceDocumentLayout(TOP_HEIGHT + introLines.size() * INTRO_LINE_HEIGHT);
        layout.place(OPTIONS_HEIGHT + mostLines * OPTION_LINE_HEIGHT + (mostNameLines - 1) * OPTION_NAME_LINE_HEIGHT);
        if (!hasAnswers) {
            // With nothing to follow, the next steps and the closing note stay together, so the note is never alone on a page.
            stepsClass = layout.place(STEPS_HEIGHT + CLOSING_HEIGHT) ? 'section new-page' : 'section';
            answersClass = 'section';
            closingClass = 'closing';
            return;
        }
        Boolean stepsMoved = layout.place(STEPS_HEIGHT);
        stepsClass = stepsMoved ? 'section new-page' : 'section';
        // The answers open the second page, unless the next steps already did and they can follow those.
        if (!stepsMoved) {
            layout.newPage();
        }
        answersClass = stepsMoved ? 'section' : 'section new-page';
        layout.place(ANSWERS_HEADING_HEIGHT);
        for (AnswerSection section : answerSections) {
            Boolean newPage = layout.place(ANSWER_SECTION_HEIGHT + section.rows.size() * ANSWER_ROW_HEIGHT);
            section.sectionClass = newPage ? 'answers new-page' : 'answers';
        }
        closingClass = layout.place(CLOSING_HEIGHT) ? 'closing new-page' : 'closing';
    }
}
