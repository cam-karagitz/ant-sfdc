/**
 * @description The underwriter's review of a quote that was referred: why it was referred, a memo
 * Claude drafts from the quote, its answers and the customer's history, and the decision.
 * The memo is stored on the quote as JSON, so it is drafted once and read many times.
 */
public with sharing class AntsuranceUnderwritingController {
    private static final Set<String> DECISIONS = new Set<String>{ 'Approved', 'Approved with Conditions', 'Declined' };
    private static final List<String> RECOMMENDATIONS = new List<String>{ 'Approve', 'Approve with conditions', 'Decline', 'Need more information' };
    private static final Integer QUOTE_VALID_DAYS = 30;
    private static final Integer CLAIMS_TO_SHOW = 12;
    private static final Integer MEMO_TOKENS = 1500;

    private static final String INSTRUCTIONS = String.join(
        new List<String>{
            'You help underwriters at Antsurance, a property and casualty insurer. A quote has been referred for underwriting review.',
            'Write a short memo for the underwriter who will decide. They know insurance; do not explain basics.',
            'Use only the facts in the request. Quote figures exactly. If something an underwriter would need is not there, put it under questions rather than guessing.',
            'Weigh the referral reasons against the rest of the risk: the exposure, the answers, the customer\'s loss history with us, how long they have been a customer and what else they insure with us.',
            'When you recommend approving with conditions, each condition must be something a person can do or check, such as a roof inspection, a higher deductible or a signed driver exclusion.',
            'Write plainly. Dates as Oct 2, 2026. Whole dollars. No dashes used as punctuation.'
        },
        '\n'
    );

    /**
     * @description What the review card shows.
     */
    public class Review {
        @AuraEnabled
        public Boolean needsReview;
        @AuraEnabled
        public String decision;
        @AuraEnabled
        public List<String> reasons = new List<String>();
        @AuraEnabled
        public Memo memo;
        // True while the quote can still be decided: referred, and neither bound nor closed.
        @AuraEnabled
        public Boolean canDecide;
    }

    /**
     * @description Claude's memo, as stored on the quote.
     */
    public class Memo {
        @AuraEnabled
        public String recommendation;
        @AuraEnabled
        public String headline;
        @AuraEnabled
        public List<Point> points = new List<Point>();
        @AuraEnabled
        public List<String> conditions = new List<String>();
        @AuraEnabled
        public List<String> questions = new List<String>();
        @AuraEnabled
        public Datetime writtenAt;
    }

    /**
     * @description One labelled point in the memo.
     */
    public class Point {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String detail;
    }

    /**
     * @description Reads the review for a quote.
     * @param quoteId The quote
     * @return Why it was referred, the stored memo if there is one, and the decision
     */
    @AuraEnabled(cacheable=true)
    public static Review getReview(Id quoteId) {
        try {
            return reviewOf(find(quoteId));
        } catch (QueryException e) {
            throw error('That quote could not be found.');
        }
    }

    /**
     * @description Has Claude draft the memo and stores it on the quote.
     * @param quoteId The quote
     * @return The review with the new memo
     */
    @AuraEnabled
    public static Review draftMemo(Id quoteId) {
        Quote quote;
        try {
            quote = find(quoteId);
        } catch (QueryException e) {
            throw error('That quote could not be found.');
        }
        Memo memo;
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(INSTRUCTIONS, describe(quote)).returning(memoShape());
            question.maxTokens = MEMO_TOKENS;
            memo = (Memo) JSON.deserialize(JSON.serialize(AntsuranceAiClient.ask(question).data), Memo.class);
        } catch (AntsuranceAiClient.AiException e) {
            throw error(e.getMessage());
        }
        memo.writtenAt = Datetime.now();
        try {
            update as user new Quote(Id = quote.Id, Underwriting_Memo__c = JSON.serialize(memo));
        } catch (DmlException e) {
            throw error('The memo could not be saved: ' + e.getDmlMessage(0));
        }
        return reviewOf(find(quoteId));
    }

    /**
     * @description Records the underwriter's decision. Approving a draft issues it, valid for 30 days,
     * and moves a sale waiting on underwriting to Quote Issued. Declining closes the quote.
     * @param quoteId The quote
     * @param decision Approved, Approved with Conditions or Declined
     * @return The review after the decision
     */
    @AuraEnabled
    public static Review decide(Id quoteId, String decision) {
        if (!DECISIONS.contains(decision)) {
            throw error('Choose Approved, Approved with Conditions or Declined.');
        }
        Quote quote;
        try {
            quote = find(quoteId);
        } catch (QueryException e) {
            throw error('That quote could not be found.');
        }
        Quote change = new Quote(Id = quote.Id, Underwriting_Decision__c = decision, Needs_Underwriting_Review__c = false);
        if (decision == 'Declined') {
            change.Status = 'Declined';
        } else if (quote.Status == 'Draft') {
            change.Status = 'Issued';
            change.Issued_Date__c = Date.today();
            change.ExpirationDate = Date.today().addDays(QUOTE_VALID_DAYS);
        }
        try {
            update as user change;
            if (decision != 'Declined' && quote.Opportunity.StageName == 'Underwriting Review') {
                update as user new Opportunity(Id = quote.OpportunityId, StageName = 'Quote Issued');
            }
        } catch (DmlException e) {
            throw error('The decision could not be saved: ' + e.getDmlMessage(0));
        }
        return reviewOf(find(quoteId));
    }

    private static Quote find(Id quoteId) {
        return [
            SELECT
                Id, Name, QuoteNumber, Status, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Submission_Channel__c, Configuration__c,
                Needs_Underwriting_Review__c, Underwriting_Memo__c, Underwriting_Decision__c, OpportunityId, Opportunity.Name, Opportunity.Type,
                Opportunity.StageName, Opportunity.IsClosed, Opportunity.Line_of_Business__c, Opportunity.AccountId, Opportunity.Account.Name,
                Opportunity.Account.Customer_Segment__c, Opportunity.Account.Industry, Opportunity.Account.NumberOfEmployees,
                Opportunity.Account.AnnualRevenue, Opportunity.Account.Customer_Since__c, Opportunity.Account.BillingCity,
                Opportunity.Account.BillingState
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
        ];
    }

    private static Review reviewOf(Quote quote) {
        Review review = new Review();
        review.needsReview = quote.Needs_Underwriting_Review__c;
        review.decision = quote.Underwriting_Decision__c;
        review.reasons = referralReasons(quote);
        review.canDecide = quote.Needs_Underwriting_Review__c && !quote.Opportunity.IsClosed && quote.Status != 'Bound';
        if (String.isNotBlank(quote.Underwriting_Memo__c)) {
            try {
                review.memo = (Memo) JSON.deserialize(quote.Underwriting_Memo__c, Memo.class);
            } catch (JSONException e) {
                // A memo edited by hand into something unreadable is treated as no memo; it can be redrafted.
                review.memo = null;
            }
        }
        return review;
    }

    /** The reasons the configurator recorded when it priced the quote. */
    private static List<String> referralReasons(Quote quote) {
        List<String> reasons = new List<String>();
        if (String.isBlank(quote.Configuration__c)) {
            return reasons;
        }
        Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(quote.Configuration__c);
        Map<String, Object> pricing = (Map<String, Object>) stored.get('pricing');
        if (pricing != null && pricing.get('referrals') != null) {
            for (Object reason : (List<Object>) pricing.get('referrals')) {
                reasons.add(String.valueOf(reason));
            }
        }
        return reasons;
    }

    /** Everything Claude gets: the quote, the answers in words, how the price was built, and the customer's history with us. */
    private static String describe(Quote quote) {
        Account customer = quote.Opportunity.Account;
        List<String> lines = new List<String>{
            'QUOTE',
            'Line of business: ' + quote.Opportunity.Line_of_Business__c,
            'Option: ' + quote.Name + ' (quote ' + quote.QuoteNumber + ', status ' + quote.Status + ')',
            'Sale: ' + quote.Opportunity.Name + ' (' + quote.Opportunity.Type + ')',
            'Annual premium: ' + money(quote.Annual_Premium__c) + '. Limit: ' + money(quote.Coverage_Limit__c) + '. Deductible: ' +
            (quote.Deductible__c == null || quote.Deductible__c == 0 ? 'none on this plan' : money(quote.Deductible__c)) + '.',
            'Came in by: ' + (quote.Submission_Channel__c == null ? 'not recorded' : quote.Submission_Channel__c),
            '',
            'WHY IT WAS REFERRED'
        };
        for (String reason : referralReasons(quote)) {
            lines.add('- ' + reason);
        }
        lines.add('');
        lines.add('WHAT THE CUSTOMER TOLD US');
        lines.addAll(answersInWords(quote));
        lines.add('');
        lines.add('CUSTOMER');
        lines.add(
            customer.Name + ', ' + customer.Customer_Segment__c + ', ' + customer.BillingCity + ' ' + AntsuranceAddress.state(customer, 'Billing') +
            (customer.Customer_Since__c == null ? '' : ', customer since ' + customer.Customer_Since__c.year())
        );
        if (customer.Industry != null) {
            lines.add(
                'Industry: ' + customer.Industry + (customer.NumberOfEmployees == null ? '' : ', ' + customer.NumberOfEmployees + ' employees') +
                (customer.AnnualRevenue == null ? '' : ', annual revenue ' + money(customer.AnnualRevenue))
            );
        }
        lines.add('');
        lines.add('POLICIES WITH US');
        List<Policy__c> policies = [
            SELECT Name, Line_of_Business__c, Status__c, Annual_Premium__c, Incurred_Losses__c, Payment_Status__c, Effective_Date__c
            FROM Policy__c
            WHERE Account__c = :customer.Id
            WITH USER_MODE
            ORDER BY Effective_Date__c DESC
        ];
        if (policies.isEmpty()) {
            lines.add('None. This would be their first policy with us.');
        }
        for (Policy__c policy : policies) {
            lines.add(
                '- ' + policy.Name + ', ' + policy.Line_of_Business__c + ', ' + policy.Status__c + ', premium ' + money(policy.Annual_Premium__c) +
                ', incurred losses ' + money(policy.Incurred_Losses__c) + (policy.Payment_Status__c == null ? '' : ', payments ' + policy.Payment_Status__c)
            );
        }
        lines.add('');
        lines.add('CLAIMS WITH US');
        List<Case> claims = [
            SELECT Subject, Loss_Type__c, Severity__c, Date_of_Loss__c, Status, Reserve_Amount__c, Paid_Amount__c, SIU_Referral__c, Policy__r.Line_of_Business__c
            FROM Case
            WHERE AccountId = :customer.Id AND RecordType.DeveloperName = 'Claim'
            WITH USER_MODE
            ORDER BY Date_of_Loss__c DESC
            LIMIT :CLAIMS_TO_SHOW
        ];
        if (claims.isEmpty()) {
            lines.add('None on record.');
        }
        for (Case claim : claims) {
            lines.add(
                '- ' + (claim.Date_of_Loss__c == null ? 'undated' : day(claim.Date_of_Loss__c)) + ', ' + claim.Policy__r.Line_of_Business__c + ', ' +
                claim.Subject + ' (' + claim.Loss_Type__c + ', ' + claim.Severity__c + ' severity, ' + claim.Status + '), reserve ' +
                money(claim.Reserve_Amount__c) + ', paid ' + money(claim.Paid_Amount__c) + (claim.SIU_Referral__c ? ', referred to SIU' : '')
            );
        }
        return String.join(lines, '\n');
    }

    /** Each answer as "Question: answer", with what it did to the price where it did anything. */
    private static List<String> answersInWords(Quote quote) {
        List<String> lines = new List<String>();
        if (String.isBlank(quote.Configuration__c)) {
            lines.add('No answers were recorded.');
            return lines;
        }
        Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(quote.Configuration__c);
        Map<String, Object> answers = (Map<String, Object>) stored.get('answers');
        for (AntsuranceQuoteConfigurator.Section section : AntsuranceQuoteConfigurator.getQuestionnaire(quote.Opportunity.Line_of_Business__c)) {
            for (AntsuranceQuoteConfigurator.Question question : section.questions) {
                Object answer = answers.get(question.key);
                // An answer to a question the other answers hide is left over from an earlier choice and is not part of the quote.
                if (answer == null || String.isBlank(String.valueOf(answer)) || !AntsuranceQuoteConfigurator.isAsked(question, answers)) {
                    continue;
                }
                String shown = String.valueOf(answer);
                for (AntsuranceQuoteConfigurator.Option option : question.options) {
                    if (option.value == shown) {
                        shown = option.label + (String.isBlank(option.effect) ? '' : ' (' + option.effect + ')');
                    }
                }
                lines.add('- ' + question.label + ': ' + shown);
            }
        }
        return lines;
    }

    private static AntsuranceAiClient.Shape memoShape() {
        AntsuranceAiClient.Shape point = new AntsuranceAiClient.Shape()
            .field('label', AntsuranceAiClient.text('Two to four words naming the point, such as Loss history or Roof condition.'))
            .field('detail', AntsuranceAiClient.text('One or two sentences with the facts and what they mean for this risk.'));
        return new AntsuranceAiClient.Shape()
            .field('recommendation', AntsuranceAiClient.choice(RECOMMENDATIONS, 'What you would do with this quote.'))
            .field('headline', AntsuranceAiClient.text('One sentence, at most 22 words, giving the reason for the recommendation.'))
            .field('points', AntsuranceAiClient.listOf(point.toJson(), 'Three to five points the decision turns on, most important first.'))
            .field('conditions', AntsuranceAiClient.listOf(AntsuranceAiClient.text('One condition, at most fourteen words.'), 'Conditions to attach if approving. Empty when there are none.'))
            .field('questions', AntsuranceAiClient.listOf(AntsuranceAiClient.text('One question, at most sixteen words.'), 'What is still unknown and worth asking. Empty when nothing is.'));
    }

    /** A date the way the cards show one, Oct 2, 2026, so Claude repeats it in that form. */
    private static String day(Date value) {
        return Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d, yyyy');
    }

    private static String money(Decimal amount) {
        return amount == null ? 'none' : '$' + amount.setScale(0, RoundingMode.HALF_UP).format();
    }

    private static AuraHandledException error(String message) {
        AuraHandledException problem = new AuraHandledException(message);
        problem.setMessage(message);
        return problem;
    }
}
