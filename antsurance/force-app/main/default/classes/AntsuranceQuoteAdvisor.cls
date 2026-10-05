/**
 * @description Claude's suggestions while a quote is being configured. Claude reads the answers so
 * far, the questions and their options, how the premium is built and what we hold on the customer,
 * and proposes up to three changes the seller could make, or choices to steer away from.
 *
 * Claude proposes; the configurator prices. A proposal names a question and one of its options.
 * Each is checked here against the real questionnaire and repriced with the configurator, so the
 * figure the seller sees is the exact change in premium and never Claude's own arithmetic.
 */
public with sharing class AntsuranceQuoteAdvisor {
    private static final Integer MOST_SUGGESTIONS = 3;
    private static final Integer CLAIM_YEARS = 3;
    private static final Integer MOST_PEOPLE = 12;
    private static final Integer MOST_POLICIES = 20;
    private static final Integer MOST_CLAIMS = 15;
    private static final Integer MOST_DRIVERS = 12;
    private static final Integer MOST_ENDORSEMENTS = 30;
    private static final Integer BRIEF_LENGTH = 900;
    private static final Integer NOTES_LENGTH = 400;
    // Three short suggestions and a sentence. A small answer keeps the call quick: a suggestion is a courtesy and must not be waited for.
    private static final Integer ANSWER_TOKENS = 900;
    private static final Integer MONTHS = 12;
    private static final String CHANGE = 'change';
    private static final String AVOID = 'avoid';
    // Sections whose answers are the customer's to choose. The rest describe the risk as it is.
    private static final Set<String> CHOICE_SECTIONS = new Set<String>{ 'coverage', 'discounts' };

    private static final String INSTRUCTIONS =
        'You advise a seller at Antsurance, an insurer, while they take a customer through the quote questions for one line of business. ' +
        'You are given the questions covered so far with the current answer and every other option, how the premium is built, any reasons the quote ' +
        'would go to an underwriter, and what Antsurance holds on this customer.\n\n' +
        'Offer at most three suggestions, the most useful first. Offer fewer, or none, when the answers already fit this customer. ' +
        'Every suggestion must rest on a fact you were given about this customer or this quote. Never offer generic advice.\n\n' +
        'A suggestion has a kind:\n' +
        '- change: one answer the seller should consider changing. Good reasons: what we hold shows the customer qualifies for a discount or credit ' +
        'that is not taken; they are missing a cover their history says they need; a deductible or limit suits their claims record or what they asked for better; ' +
        'what we hold shows a factual answer is wrong.\n' +
        '- avoid: one answer the seller may be tempted to pick and should not. Use it only when both of these hold. First, the temptation is real: ' +
        'what we hold shows this customer wants a lower price or is comparing other insurers. Second, the harm is concrete today: the answer would send ' +
        'the quote to an underwriter (options marked "refers"), would leave less liability than an umbrella policy they hold with us needs underneath, ' +
        'would remove a cover they have claimed on, or would cut liability to the lowest limit offered. Never use avoid for a question in a section ' +
        'marked "fact", and never argue from something that might happen later.\n\n' +
        'House rules you may rely on:\n' +
        '- An umbrella policy needs auto liability of at least 250/500/100 and home or general liability of at least $300,000 underneath it.\n' +
        '- Questions in sections marked "customer choice" are the customer\'s to decide. Questions in sections marked "fact" describe the risk: suggest changing ' +
        'one only when what we hold contradicts the current answer, and say what contradicts it. Never suggest misstating a fact to lower the price.\n' +
        '- Do not suggest a change to an option marked "refers" unless what we hold shows it is the true answer.\n\n' +
        'How to write each suggestion:\n' +
        '- questionKey is the question\'s key and value is the option\'s value, both exactly as listed. Never the current answer. Only questions that list options.\n' +
        '- title: at most six words, an instruction in sentence case, such as "Raise the collision deductible", "Add water backup cover" or "Keep liability at 250/500/100".\n' +
        '- why: one sentence of at most 24 words, in plain words, naming the fact about this customer it rests on.\n' +
        '- Do not state any price, saving, percentage or dollar change. The system prices each suggestion and shows the exact figure beside it.\n' +
        '- No em dashes or en dashes. No exclamation marks.\n\n' +
        'pitch: only when you are told the seller is on Review, one sentence of at most 30 words the seller could say aloud to put this option to the customer: ' +
        'what it protects and what it costs, using only figures given to you (the annual premium, the limit, the deductible). Otherwise an empty string.';

    /**
     * @description One suggestion, checked and priced.
     */
    public class Suggestion {
        /** change: an answer to consider changing. avoid: an answer to steer away from. */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String questionKey;
        /** The option proposed (change) or warned against (avoid). */
        @AuraEnabled
        public String value;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String why;
        @AuraEnabled
        public String questionLabel;
        /** The current answer, in words. */
        @AuraEnabled
        public String fromLabel;
        /** The proposed or warned-against answer, in words. */
        @AuraEnabled
        public String toLabel;
        /** What making the change does to the annual premium, from the configurator. Negative is a saving. */
        @AuraEnabled
        public Decimal premiumChange;
        @AuraEnabled
        public Decimal newPremium;
        /** Reasons the quote would go to an underwriter that it does not have now. */
        @AuraEnabled
        public List<String> referrals = new List<String>();
    }

    /**
     * @description What the strip beside the price shows.
     */
    public class Advice {
        @AuraEnabled
        public List<Suggestion> suggestions = new List<Suggestion>();
        /** On Review: a sentence the seller could say to put the option to the customer. */
        @AuraEnabled
        public String pitch;
        /** True when Claude could not be asked, or was too slow. The strip then says nothing; it never shows an error. */
        @AuraEnabled
        public Boolean failed = false;
        /** True when asking again might work (a timeout, a busy service), so the strip can offer to try again. */
        @AuraEnabled
        public Boolean retryable = false;
        // For measuring: how many proposals Claude made, and how many the check dropped.
        public Integer proposed = 0;
        public Integer dropped = 0;
    }

    /**
     * @description Suggestions for a quote as its questions are being answered.
     * @param quoteId The quote
     * @param answersJson The answers so far, as a JSON object keyed by question
     * @param tier The territory and tier factor the configurator is pricing with
     * @param stepIndex The step the seller is on, from zero; the number of steps or more means Review
     * @return Up to three checked and priced suggestions; empty and marked failed when Claude cannot be reached or times out.
     * One Claude call at most, and never an exception for a failed call: the seller is not held up by a suggestion
     */
    public static Advice advise(Id quoteId, String answersJson, Decimal tier, Integer stepIndex) {
        List<Quote> quotes = [
            SELECT Id, OpportunityId, Opportunity.Line_of_Business__c, Opportunity.AccountId, Opportunity.Type, Opportunity.Policy__r.Name
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        Advice nothing = new Advice();
        if (quotes.isEmpty() || quotes[0].Opportunity == null) {
            nothing.failed = true;
            return nothing;
        }
        Opportunity sale = quotes[0].Opportunity;
        try {
            return suggest(sale.Line_of_Business__c, answersJson, tier, stepIndex, customerFacts(sale.AccountId, sale));
        } catch (AntsuranceAiClient.AiException e) {
            // Slow, busy or unreachable: the questions, the price and Next carry on without suggestions.
            nothing.failed = true;
            nothing.retryable = e.retryable == true;
        } catch (CalloutException e) {
            nothing.failed = true;
            nothing.retryable = true;
        }
        return nothing;
    }

    /**
     * @description Asks Claude for suggestions about a set of answers, then checks and prices them.
     * @param lineOfBusiness The line being quoted
     * @param answersJson The answers so far, as a JSON object keyed by question
     * @param tier The territory and tier factor to price with; null means 1
     * @param stepIndex The step the seller is on, from zero; the number of steps or more means Review
     * @param customerFacts What we hold on the customer, in plain text
     * @return The checked and priced suggestions, and the pitch on Review
     * @throws AntsuranceAiClient.AiException when Claude cannot be asked or its answer cannot be used
     */
    public static Advice suggest(String lineOfBusiness, String answersJson, Decimal tier, Integer stepIndex, String customerFacts) {
        List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire(lineOfBusiness);
        Advice advice = new Advice();
        if (sections.isEmpty()) {
            return advice;
        }
        Map<String, Object> answers = parse(answersJson);
        List<AntsuranceQuoteConfigurator.Section> covered = coveredSections(sections, stepIndex);
        Boolean isReview = stepIndex != null && stepIndex >= sections.size();
        AntsuranceQuoteConfigurator.Pricing pricing = AntsuranceQuoteConfigurator.price(lineOfBusiness, JSON.serialize(answers), tier);

        List<String> keys = new List<String>();
        for (AntsuranceQuoteConfigurator.Section section : covered) {
            for (AntsuranceQuoteConfigurator.Question question : section.questions) {
                if (!question.options.isEmpty() && AntsuranceQuoteConfigurator.isAsked(question, answers)) {
                    keys.add(question.key);
                }
            }
        }
        if (keys.isEmpty()) {
            return advice;
        }

        AntsuranceAiClient.Question request = new AntsuranceAiClient.Question(
            INSTRUCTIONS,
            describe(lineOfBusiness, covered, answers, pricing, isReview, isReview ? 'Review' : covered[covered.size() - 1].title, customerFacts)
        );
        request.maxTokens = ANSWER_TOKENS;
        request.returning(shape(keys));
        AntsuranceAiClient.Answer answer = AntsuranceAiClient.ask(request);

        List<Object> proposals = answer.data.get('suggestions') instanceof List<Object> ? (List<Object>) answer.data.get('suggestions') : new List<Object>();
        advice.proposed = proposals.size();
        advice.suggestions = check(lineOfBusiness, answers, tier, stepIndex, proposals);
        advice.dropped = advice.proposed - advice.suggestions.size();
        if (isReview) {
            advice.pitch = soundPitch((String) answer.data.get('pitch'), pricing);
        }
        return advice;
    }

    /**
     * @description Checks and prices suggestions again after the answers have changed, without asking Claude.
     * A suggestion that no longer applies (its question is hidden, or the answer now matches) is dropped.
     * @param lineOfBusiness The line being quoted
     * @param answersJson The answers now, as a JSON object keyed by question
     * @param tier The territory and tier factor to price with
     * @param stepIndex The step the seller is on
     * @param proposalsJson The suggestions on screen, as a JSON list
     * @return Those that still apply, priced against the answers as they are now
     */
    public static List<Suggestion> recheck(String lineOfBusiness, String answersJson, Decimal tier, Integer stepIndex, String proposalsJson) {
        List<Object> proposals = String.isBlank(proposalsJson) ? new List<Object>() : (List<Object>) JSON.deserializeUntyped(proposalsJson);
        return check(lineOfBusiness, parse(answersJson), tier, stepIndex, proposals);
    }

    // ---------------------------------------------------------------- checking and pricing

    /**
     * Keeps a proposal only when it names a question the seller has reached, that is asked under the current
     * answers and offers choices, with one of those choices that is not already the answer. One per question,
     * three at most. Each is priced by making the change and running the configurator.
     */
    @TestVisible
    private static List<Suggestion> check(String lineOfBusiness, Map<String, Object> answers, Decimal tier, Integer stepIndex, List<Object> proposals) {
        List<Suggestion> kept = new List<Suggestion>();
        List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire(lineOfBusiness);
        if (sections.isEmpty() || proposals == null || proposals.isEmpty()) {
            return kept;
        }
        Map<String, AntsuranceQuoteConfigurator.Question> reachable = new Map<String, AntsuranceQuoteConfigurator.Question>();
        for (AntsuranceQuoteConfigurator.Section section : coveredSections(sections, stepIndex)) {
            for (AntsuranceQuoteConfigurator.Question question : section.questions) {
                if (!question.options.isEmpty() && AntsuranceQuoteConfigurator.isAsked(question, answers)) {
                    reachable.put(question.key, question);
                }
            }
        }
        AntsuranceQuoteConfigurator.Pricing current;
        Set<String> seen = new Set<String>();
        for (Object item : proposals) {
            if (kept.size() == MOST_SUGGESTIONS) {
                break;
            }
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> proposal = (Map<String, Object>) item;
            String key = text(proposal.get('questionKey'));
            String value = text(proposal.get('value'));
            AntsuranceQuoteConfigurator.Question question = reachable.get(key);
            if (question == null || seen.contains(key)) {
                continue;
            }
            AntsuranceQuoteConfigurator.Option proposed = optionOf(question, value);
            String now = answerTo(question, answers);
            if (proposed == null || value == now) {
                continue;
            }
            seen.add(key);
            if (current == null) {
                current = AntsuranceQuoteConfigurator.price(lineOfBusiness, JSON.serialize(answers), tier);
            }
            Map<String, Object> changed = new Map<String, Object>(answers);
            changed.put(key, value);
            AntsuranceQuoteConfigurator.Pricing after = AntsuranceQuoteConfigurator.price(lineOfBusiness, JSON.serialize(changed), tier);

            Suggestion suggestion = new Suggestion();
            suggestion.kind = text(proposal.get('kind')) == AVOID ? AVOID : CHANGE;
            suggestion.questionKey = key;
            suggestion.value = value;
            suggestion.title = plain(text(proposal.get('title')));
            suggestion.why = plain(text(proposal.get('why')));
            suggestion.questionLabel = question.label;
            AntsuranceQuoteConfigurator.Option chosen = optionOf(question, now);
            suggestion.fromLabel = chosen == null ? now : chosen.label;
            suggestion.toLabel = proposed.label;
            suggestion.premiumChange = after.premium - current.premium;
            suggestion.newPremium = after.premium;
            Set<String> already = new Set<String>(current.referrals);
            for (String reason : after.referrals) {
                if (!already.contains(reason)) {
                    suggestion.referrals.add(reason);
                }
            }
            if (String.isBlank(suggestion.title) || String.isBlank(suggestion.why)) {
                continue;
            }
            kept.add(suggestion);
        }
        return kept;
    }

    /** The steps the seller has reached: up to and including the one they are on, or all of them on Review. */
    private static List<AntsuranceQuoteConfigurator.Section> coveredSections(List<AntsuranceQuoteConfigurator.Section> sections, Integer stepIndex) {
        Integer last = stepIndex == null || stepIndex >= sections.size() ? sections.size() - 1 : Math.max(stepIndex, 0);
        List<AntsuranceQuoteConfigurator.Section> covered = new List<AntsuranceQuoteConfigurator.Section>();
        for (Integer index = 0; index <= last; index++) {
            covered.add(sections[index]);
        }
        return covered;
    }

    private static AntsuranceQuoteConfigurator.Option optionOf(AntsuranceQuoteConfigurator.Question question, String value) {
        for (AntsuranceQuoteConfigurator.Option option : question.options) {
            if (option.value == value) {
                return option;
            }
        }
        return null;
    }

    /** The answer given, or the question's default. */
    private static String answerTo(AntsuranceQuoteConfigurator.Question question, Map<String, Object> answers) {
        Object given = answers.get(question.key);
        return given == null || String.isBlank(String.valueOf(given)) ? question.defaultValue : String.valueOf(given);
    }

    private static Map<String, Object> parse(String answersJson) {
        return String.isBlank(answersJson) ? new Map<String, Object>() : (Map<String, Object>) JSON.deserializeUntyped(answersJson);
    }

    private static String text(Object value) {
        return value == null ? null : String.valueOf(value).trim();
    }

    /** Claude is told not to use long dashes; this makes sure none reaches the screen. */
    private static String plain(String text) {
        return text == null ? null : text.replace(' — ', ', ').replace('—', ', ').replace('–', '-');
    }

    /**
     * The pitch is kept only when every dollar figure in it is one the quote really has: the premium, its
     * monthly equivalent, the limit or the deductible. Anything else is Claude's arithmetic and is not shown.
     */
    @TestVisible
    private static String soundPitch(String pitch, AntsuranceQuoteConfigurator.Pricing pricing) {
        if (String.isBlank(pitch)) {
            return null;
        }
        Set<String> real = new Set<String>();
        for (Decimal amount : new List<Decimal>{ pricing.premium, pricing.limitAmount, pricing.deductible, pricing.premium == null ? null : pricing.premium / MONTHS }) {
            if (amount != null) {
                real.add(String.valueOf(amount.setScale(0, RoundingMode.HALF_UP).longValue()));
            }
        }
        Matcher figures = Pattern.compile('\\$\\s?([0-9][0-9,]*)(\\.[0-9]+)?\\s?(million\\b|M\\b|[kK]\\b)?').matcher(pitch);
        while (figures.find()) {
            String digits = figures.group(1).replace(',', '');
            String unit = figures.group(3);
            if (unit != null) {
                Decimal scaled = Decimal.valueOf(digits + (figures.group(2) == null ? '' : figures.group(2))) * (unit.toLowerCase() == 'k' ? 1000 : 1000000);
                digits = String.valueOf(scaled.setScale(0, RoundingMode.HALF_UP).longValue());
            }
            if (!real.contains(digits)) {
                return null;
            }
        }
        return plain(pitch.trim());
    }

    // ---------------------------------------------------------------- what Claude is told

    private static AntsuranceAiClient.Shape shape(List<String> keys) {
        AntsuranceAiClient.Shape suggestion = new AntsuranceAiClient.Shape()
            .field('kind', AntsuranceAiClient.choice(new List<String>{ CHANGE, AVOID }, 'change: an answer to consider changing. avoid: an answer to steer away from.'))
            .field('questionKey', AntsuranceAiClient.choice(keys, 'The key of the question the suggestion is about.'))
            .field('value', AntsuranceAiClient.text('The value of the option proposed, or warned against, exactly as listed for that question.'))
            .field('title', AntsuranceAiClient.text('At most six words, an instruction in sentence case.'))
            .field('why', AntsuranceAiClient.text('One sentence of at most 24 words naming the fact about this customer it rests on. No prices or percentages.'));
        return new AntsuranceAiClient.Shape()
            .field('suggestions', AntsuranceAiClient.listOf(suggestion.toJson(), 'At most three, most useful first. Empty when the answers already fit this customer.'))
            .field('pitch', AntsuranceAiClient.text('On Review, one sentence the seller could say aloud to put this option to the customer. Otherwise an empty string.'));
    }

    /** The quote as it stands, in plain text: each question reached with its answer and options, the price, and the customer. */
    private static String describe(
        String lineOfBusiness,
        List<AntsuranceQuoteConfigurator.Section> covered,
        Map<String, Object> answers,
        AntsuranceQuoteConfigurator.Pricing pricing,
        Boolean isReview,
        String step,
        String customerFacts
    ) {
        List<String> lines = new List<String>{
            'LINE OF BUSINESS: ' + lineOfBusiness,
            isReview ? 'THE SELLER IS ON: Review, the last step, about to save the quote.' : 'THE SELLER IS ON THE STEP: ' + step,
            '',
            'QUESTIONS COVERED SO FAR (key | label | current answer | options as value = label)'
        };
        for (AntsuranceQuoteConfigurator.Section section : covered) {
            lines.add('');
            lines.add('Section: ' + section.title + (CHOICE_SECTIONS.contains(section.key) ? ' (customer choice)' : ' (fact)'));
            for (AntsuranceQuoteConfigurator.Question question : section.questions) {
                if (!AntsuranceQuoteConfigurator.isAsked(question, answers)) {
                    continue;
                }
                String now = answerTo(question, answers);
                if (question.options.isEmpty()) {
                    lines.add('- ' + question.label + ': ' + (String.isBlank(now) ? 'not answered' : now) + ' (a figure or free text, not for suggestions)');
                    continue;
                }
                List<String> choices = new List<String>();
                for (AntsuranceQuoteConfigurator.Option option : question.options) {
                    String note = option.effect == null ? '' : ' (' + option.effect + ')';
                    if (option.referral != null) {
                        note += ' (refers: ' + option.referral + ')';
                    }
                    choices.add(option.value + ' = ' + option.label + note);
                }
                lines.add('- ' + question.key + ' | ' + question.label + ' | current: ' + now + ' | options: ' + String.join(choices, '; '));
            }
        }
        lines.add('');
        lines.add('HOW THE PREMIUM IS BUILT');
        for (AntsuranceQuoteConfigurator.PriceLine priceLine : pricing.lines) {
            lines.add('- ' + priceLine.label + (String.isBlank(priceLine.effect) ? '' : ' (' + priceLine.effect + ')') + ': ' + dollars(priceLine.amount));
        }
        lines.add('Annual premium: ' + dollars(pricing.premium) + ', about ' + dollars(pricing.premium / MONTHS) + ' a month');
        lines.add('Limit: ' + (pricing.limitAmount == null ? 'not set' : dollars(pricing.limitAmount)) + '. Deductible: ' + (pricing.deductible == null || pricing.deductible == 0 ? 'none' : dollars(pricing.deductible)) + '.');
        lines.add(pricing.referrals.isEmpty() ? 'Nothing sends this quote to an underwriter as it stands.' : 'As it stands the quote goes to an underwriter because: ' + String.join(pricing.referrals, '; ') + '.');
        lines.add('');
        lines.add('WHAT WE HOLD ON THIS CUSTOMER');
        lines.add(String.isBlank(customerFacts) ? 'Nothing beyond this quote.' : customerFacts);
        return String.join(lines, '\n');
    }

    private static String dollars(Decimal amount) {
        return amount == null ? 'none' : (amount < 0 ? '-' : '') + '$' + amount.abs().setScale(0, RoundingMode.HALF_UP).format();
    }

    /**
     * What the org knows about the customer, for Claude: who they are, their other policies, their claims in
     * the past three years, and who is in the household or how big the business is. Read as the user.
     */
    @TestVisible
    private static String customerFacts(Id accountId, Opportunity sale) {
        if (accountId == null) {
            return '';
        }
        List<String> lines = new List<String>();
        for (Account customer : [
            SELECT Name, Customer_Segment__c, Customer_Since__c, Industry, NumberOfEmployees, AnnualRevenue, Description, Customer_Brief__c
            FROM Account
            WHERE Id = :accountId
            WITH USER_MODE
            LIMIT 1
        ]) {
            lines.add('Customer: ' + customer.Name + (customer.Customer_Segment__c == null ? '' : ', ' + customer.Customer_Segment__c) +
                (customer.Customer_Since__c == null ? '' : ', a customer since ' + customer.Customer_Since__c.year()) + '.');
            if (customer.Industry != null || customer.NumberOfEmployees != null || customer.AnnualRevenue != null) {
                lines.add('Business: ' + (customer.Industry == null ? 'industry not recorded' : customer.Industry) +
                    (customer.NumberOfEmployees == null ? '' : ', ' + customer.NumberOfEmployees + ' employees') +
                    (customer.AnnualRevenue == null ? '' : ', revenue ' + dollars(customer.AnnualRevenue)) + '.');
            }
            if (String.isNotBlank(customer.Description)) {
                lines.add('What they do: ' + customer.Description.left(NOTES_LENGTH));
            }
            if (String.isNotBlank(customer.Customer_Brief__c)) {
                lines.add('Notes on the customer: ' + customer.Customer_Brief__c.left(BRIEF_LENGTH).replace('\n', ' '));
            }
        }
        if (sale != null && sale.Type != null) {
            lines.add('This sale: ' + sale.Type + (sale.Policy__r == null ? '' : ' of policy ' + sale.Policy__r.Name) + '.');
        }

        List<String> people = new List<String>();
        for (Contact person : [
            SELECT Name, Household_Role__c, Licensed_Driver__c, Birthdate, Title
            FROM Contact
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY Name
            LIMIT :MOST_PEOPLE
        ]) {
            List<String> facts = new List<String>();
            if (person.Household_Role__c != null) {
                facts.add(person.Household_Role__c);
            }
            if (person.Title != null) {
                facts.add(person.Title);
            }
            if (person.Birthdate != null) {
                facts.add('age ' + age(person.Birthdate));
            }
            if (person.Licensed_Driver__c == true) {
                facts.add('licensed driver');
            }
            people.add(person.Name + (facts.isEmpty() ? '' : ' (' + String.join(facts, ', ') + ')'));
        }
        if (!people.isEmpty()) {
            lines.add('People: ' + String.join(people, '; ') + '.');
        }

        List<String> policies = new List<String>();
        for (Policy__c policy : [
            SELECT Name, Line_of_Business__c, Status__c, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Insured_Item__c, Expiration_Date__c, Underwriting_Notes__c
            FROM Policy__c
            WHERE Account__c = :accountId AND Status__c IN ('Active', 'Pending Renewal')
            WITH USER_MODE
            ORDER BY Line_of_Business__c
            LIMIT :MOST_POLICIES
        ]) {
            policies.add('- ' + policy.Line_of_Business__c + ' ' + policy.Name + ' (' + policy.Status__c + '): premium ' + dollars(policy.Annual_Premium__c) +
                ', limit ' + dollars(policy.Coverage_Limit__c) + ', deductible ' + (policy.Deductible__c == null || policy.Deductible__c == 0 ? 'none' : dollars(policy.Deductible__c)) +
                (String.isBlank(policy.Insured_Item__c) ? '' : ', insures ' + policy.Insured_Item__c) +
                (String.isBlank(policy.Underwriting_Notes__c) ? '' : '. Underwriting notes: ' + policy.Underwriting_Notes__c.left(NOTES_LENGTH).replace('\n', ' ')));
        }
        lines.add(policies.isEmpty() ? 'Policies in force with us: none.' : 'Policies in force with us:\n' + String.join(policies, '\n'));

        List<String> endorsements = new List<String>();
        for (Policy_Endorsement__c endorsement : [
            SELECT Name, Policy__r.Name
            FROM Policy_Endorsement__c
            WHERE Policy__r.Account__c = :accountId AND Policy__r.Status__c IN ('Active', 'Pending Renewal')
            WITH USER_MODE
            ORDER BY Policy__r.Name, Name
            LIMIT :MOST_ENDORSEMENTS
        ]) {
            endorsements.add(endorsement.Name + ' on ' + endorsement.Policy__r.Name);
        }
        if (!endorsements.isEmpty()) {
            lines.add('Endorsements on those policies: ' + String.join(endorsements, '; ') + '.');
        }

        List<String> drivers = new List<String>();
        for (Policy_Participant__c driver : [
            SELECT Name, Role__c, Years_Licensed__c, Good_Student_Discount__c, Violations_Past_3_Years__c, Accidents_Past_3_Years__c, Policy__r.Name
            FROM Policy_Participant__c
            WHERE Policy__r.Account__c = :accountId AND Policy__r.Status__c IN ('Active', 'Pending Renewal') AND Role__c IN ('Driver', 'Named Insured')
            WITH USER_MODE
            ORDER BY Name
            LIMIT :MOST_DRIVERS
        ]) {
            drivers.add(driver.Name + ' on ' + driver.Policy__r.Name + ': licensed ' + (driver.Years_Licensed__c == null ? 'for an unrecorded time' : driver.Years_Licensed__c.intValue() + ' years') +
                ', violations in 3 years ' + number(driver.Violations_Past_3_Years__c) + ', at-fault accidents in 3 years ' + number(driver.Accidents_Past_3_Years__c) +
                (driver.Good_Student_Discount__c == true ? ', has the good student discount' : ''));
        }
        if (!drivers.isEmpty()) {
            lines.add('Drivers on their auto policies: ' + String.join(drivers, '; ') + '.');
        }

        Date since = Date.today().addYears(-CLAIM_YEARS);
        List<String> claims = new List<String>();
        for (Case claim : [
            SELECT Subject, Loss_Type__c, Status, Reported_Date__c, Paid_Amount__c, Reserve_Amount__c, Policy__r.Line_of_Business__c
            FROM Case
            WHERE AccountId = :accountId AND RecordType.DeveloperName = 'Claim' AND Reported_Date__c >= :since
            WITH USER_MODE
            ORDER BY Reported_Date__c DESC
            LIMIT :MOST_CLAIMS
        ]) {
            claims.add('- ' + String.valueOf(claim.Reported_Date__c) + ', ' + (claim.Policy__r == null ? 'policy not recorded' : claim.Policy__r.Line_of_Business__c) + ', ' +
                (claim.Loss_Type__c == null ? 'loss' : claim.Loss_Type__c) + ': ' + claim.Subject + ' (' + claim.Status + ', paid ' + dollars(claim.Paid_Amount__c == null ? 0 : claim.Paid_Amount__c) +
                ', reserved ' + dollars(claim.Reserve_Amount__c == null ? 0 : claim.Reserve_Amount__c) + ')');
        }
        lines.add(claims.isEmpty() ? 'Claims in the past ' + CLAIM_YEARS + ' years: none.' : 'Claims in the past ' + CLAIM_YEARS + ' years:\n' + String.join(claims, '\n'));
        return String.join(lines, '\n');
    }

    private static Integer age(Date born) {
        Date today = Date.today();
        Integer years = today.year() - born.year();
        return today < born.addYears(years) ? years - 1 : years;
    }

    private static String number(Decimal value) {
        return value == null ? 'not recorded' : String.valueOf(value.intValue());
    }
}
