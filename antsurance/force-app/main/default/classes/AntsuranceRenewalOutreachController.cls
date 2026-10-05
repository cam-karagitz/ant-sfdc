/**
 * @description Renewal outreach for a policy that is waiting on its renewal: the facts of the renewal,
 * and a draft Claude writes for the person who will contact the customer (how likely the customer is
 * to stay, what to know first, an email and a call opening). Nothing is sent or stored from here;
 * the draft opens in the email composer or is copied.
 */
public with sharing class AntsuranceRenewalOutreachController {
    private static final String PENDING = 'Pending Renewal';
    private static final List<String> RISKS = new List<String>{ 'Low', 'Medium', 'High' };
    private static final Integer DRAFT_TOKENS = 1500;
    private static final Integer CLAIMS_TO_SHOW = 8;
    private static final Integer BRIEF_LENGTH = 1500;

    private static final String INSTRUCTIONS = String.join(
        new List<String>{
            'You help the service team at Antsurance, a property and casualty insurer, keep customers at renewal.',
            'A policy is coming up for renewal. Write what the person contacting the customer needs: how likely the customer is to leave and why, what to know before reaching out, an email to the named insured, and a sentence or two to open a phone call.',
            'Use only the facts in the request. State the renewal premium and the change in dollars honestly; never hide an increase. Give one or two real reasons to stay that the facts support, such as a claim we handled, a discount they have, or policies they bundle with us. If cheaper or richer options were quoted, mention the most relevant one with its premium.',
            'Do not promise anything the facts do not support: no rate guarantees, no coverage that is not on the policy.',
            'The email is plain and warm, at most 140 words, in short paragraphs separated by blank lines, with one clear thing to do and a date to do it by, which is a few days before the policy expires. Greet the named insured by first name. Sign off with the sender\'s first name and Antsurance.',
            'Judge retention risk from the size of the increase, claims and how they went, payment trouble, how long they have been a customer and how much else they insure with us.',
            'Write plainly. Dates as Oct 2, 2026. Whole dollars. No dashes used as punctuation.'
        },
        '\n'
    );

    /**
     * @description The facts of a renewal, for the card's header.
     */
    public class Renewal {
        @AuraEnabled
        public Boolean isRenewing;
        @AuraEnabled
        public Date expires;
        @AuraEnabled
        public Decimal currentPremium;
        @AuraEnabled
        public Decimal renewalPremium;
        @AuraEnabled
        public String insuredName;
        @AuraEnabled
        public String insuredEmail;
        @AuraEnabled
        public String preferredContact;
        @AuraEnabled
        public Id saleId;
        @AuraEnabled
        public String saleStage;
    }

    /**
     * @description Claude's draft.
     */
    public class Outreach {
        @AuraEnabled
        public String risk;
        @AuraEnabled
        public String riskReason;
        @AuraEnabled
        public List<Point> points = new List<Point>();
        @AuraEnabled
        public String subject;
        @AuraEnabled
        public String body;
        @AuraEnabled
        public String callOpening;
    }

    /**
     * @description One thing to know before reaching out.
     */
    public class Point {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String detail;
    }

    /**
     * @description Reads the renewal for a policy.
     * @param policyId The policy
     * @return Whether it is waiting on renewal, its dates and premiums, and who to contact
     */
    @AuraEnabled(cacheable=true)
    public static Renewal getRenewal(Id policyId) {
        Policy__c policy;
        try {
            policy = find(policyId);
        } catch (QueryException e) {
            throw error('That policy could not be found.');
        }
        Renewal renewal = new Renewal();
        renewal.isRenewing = policy.Status__c == PENDING;
        renewal.expires = policy.Expiration_Date__c;
        renewal.currentPremium = policy.Annual_Premium__c;
        renewal.insuredName = policy.Primary_Insured__r?.Name;
        renewal.insuredEmail = policy.Primary_Insured__r?.Email;
        renewal.preferredContact = policy.Primary_Insured__r?.Preferred_Contact_Method__c;
        Opportunity sale = renewalSale(policyId);
        if (sale != null) {
            renewal.saleId = sale.Id;
            renewal.saleStage = sale.StageName;
            renewal.renewalPremium = sale.Amount;
        }
        return renewal;
    }

    /**
     * @description Has Claude draft the outreach for a policy waiting on renewal.
     * @param policyId The policy
     * @return The draft
     */
    @AuraEnabled
    public static Outreach draft(Id policyId) {
        Policy__c policy;
        try {
            policy = find(policyId);
        } catch (QueryException e) {
            throw error('That policy could not be found.');
        }
        if (policy.Status__c != PENDING) {
            throw error('This policy is not waiting on a renewal.');
        }
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(INSTRUCTIONS, describe(policy)).returning(outreachShape());
            question.maxTokens = DRAFT_TOKENS;
            return (Outreach) JSON.deserialize(JSON.serialize(AntsuranceAiClient.ask(question).data), Outreach.class);
        } catch (AntsuranceAiClient.AiException e) {
            throw error(e.getMessage());
        }
    }

    private static Policy__c find(Id policyId) {
        return [
            SELECT
                Id, Name, Line_of_Business__c, Status__c, Annual_Premium__c, Coverage_Limit__c, Deductible__c, Effective_Date__c, Expiration_Date__c,
                Insured_Item__c, Payment_Status__c, Billing_Frequency__c, Incurred_Losses__c, Account__c, Account__r.Name, Account__r.Customer_Segment__c,
                Account__r.Customer_Since__c, Account__r.Customer_Brief__c, Producer__r.Name, Primary_Insured__r.Name, Primary_Insured__r.FirstName,
                Primary_Insured__r.Email, Primary_Insured__r.Preferred_Contact_Method__c,
                (SELECT Name, Limit_Amount__c, Deductible_Amount__c FROM Coverages__r ORDER BY Name),
                (SELECT Name, Type__c FROM Endorsements__r WHERE Status__c = 'Active' ORDER BY Name)
            FROM Policy__c
            WHERE Id = :policyId
            WITH USER_MODE
        ];
    }

    /** The open renewal sale on the policy, or the most recent one. */
    private static Opportunity renewalSale(Id policyId) {
        List<Opportunity> sales = [
            SELECT Id, Name, StageName, Amount, (SELECT Name, Status, Annual_Premium__c, Deductible__c, Coverage_Limit__c FROM Quotes ORDER BY Annual_Premium__c)
            FROM Opportunity
            WHERE Policy__c = :policyId AND Type = 'Renewal'
            WITH USER_MODE
            ORDER BY IsClosed, CreatedDate DESC
            LIMIT 1
        ];
        return sales.isEmpty() ? null : sales[0];
    }

    /** Everything Claude gets: the policy, the renewal on offer, the claims on it, and the customer's wider relationship. */
    private static String describe(Policy__c policy) {
        Account customer = policy.Account__r;
        List<String> lines = new List<String>{
            'TODAY: ' + day(Date.today()),
            'SENDER: ' + UserInfo.getFirstName() + ' ' + UserInfo.getLastName() + ', Antsurance',
            '',
            'POLICY UP FOR RENEWAL',
            policy.Name + ', ' + policy.Line_of_Business__c + ', insuring ' + policy.Insured_Item__c,
            'Current term: ' + day(policy.Effective_Date__c) + ' to ' + day(policy.Expiration_Date__c) + '. Current premium: ' + money(policy.Annual_Premium__c) + ' a year.',
            'Limit ' + money(policy.Coverage_Limit__c) + ', deductible ' + money(policy.Deductible__c) + '. Billing: ' + policy.Billing_Frequency__c + ', payments ' + policy.Payment_Status__c + '.',
            'Named insured: ' + policy.Primary_Insured__r.Name + (policy.Primary_Insured__r.Preferred_Contact_Method__c == null ? '' : ', prefers ' + policy.Primary_Insured__r.Preferred_Contact_Method__c),
            'Sold through: ' + (policy.Producer__r == null ? 'Antsurance direct' : policy.Producer__r.Name)
        };
        List<String> coverages = new List<String>();
        for (Policy_Coverage__c coverage : policy.Coverages__r) {
            coverages.add(coverage.Name);
        }
        lines.add('Coverages: ' + String.join(coverages, ', '));
        List<String> forms = new List<String>();
        for (Policy_Endorsement__c form : policy.Endorsements__r) {
            forms.add(form.Name + ' (' + form.Type__c + ')');
        }
        if (!forms.isEmpty()) {
            lines.add('Endorsements and discounts: ' + String.join(forms, ', '));
        }

        lines.add('');
        lines.add('THE RENEWAL ON OFFER');
        Opportunity sale = renewalSale(policy.Id);
        if (sale == null) {
            lines.add('No renewal has been priced yet.');
        } else {
            lines.add('Renewal premium: ' + money(sale.Amount) + ' a year. Stage: ' + sale.StageName + '.');
            for (Quote option : sale.Quotes) {
                lines.add(
                    '- Option "' + option.Name + '": ' + money(option.Annual_Premium__c) + ' a year, deductible ' + money(option.Deductible__c) + ', limit ' +
                    money(option.Coverage_Limit__c) + ' (' + option.Status + ')'
                );
            }
        }

        lines.add('');
        lines.add('CLAIMS ON THIS POLICY');
        List<Case> claims = [
            SELECT Subject, Status, Date_of_Loss__c, Paid_Amount__c, Reserve_Amount__c
            FROM Case
            WHERE Policy__c = :policy.Id AND RecordType.DeveloperName = 'Claim'
            WITH USER_MODE
            ORDER BY Date_of_Loss__c DESC
            LIMIT :CLAIMS_TO_SHOW
        ];
        if (claims.isEmpty()) {
            lines.add('None.');
        }
        for (Case claim : claims) {
            lines.add(
                '- ' + (claim.Date_of_Loss__c == null ? 'undated' : day(claim.Date_of_Loss__c)) + ': ' + claim.Subject + ' (' + claim.Status + '), paid ' +
                money(claim.Paid_Amount__c) + ', reserve ' + money(claim.Reserve_Amount__c)
            );
        }

        lines.add('');
        lines.add('THE CUSTOMER');
        lines.add(customer.Name + ', ' + customer.Customer_Segment__c + (customer.Customer_Since__c == null ? '' : ', customer since ' + customer.Customer_Since__c.year()));
        for (Policy__c other : [
            SELECT Name, Line_of_Business__c, Annual_Premium__c
            FROM Policy__c
            WHERE Account__c = :customer.Id AND Id != :policy.Id AND Status__c IN ('Active', :PENDING)
            WITH USER_MODE
            ORDER BY Line_of_Business__c
        ]) {
            lines.add('- Also insures with us: ' + other.Line_of_Business__c + ', ' + other.Name + ', ' + money(other.Annual_Premium__c) + ' a year');
        }
        if (String.isNotBlank(customer.Customer_Brief__c)) {
            lines.add('What we know about them: ' + customer.Customer_Brief__c.stripHtmlTags().left(BRIEF_LENGTH));
        }
        return String.join(lines, '\n');
    }

    private static AntsuranceAiClient.Shape outreachShape() {
        AntsuranceAiClient.Shape point = new AntsuranceAiClient.Shape()
            .field('label', AntsuranceAiClient.text('Two to four words naming the point, such as Premium change or Claim this term.'))
            .field('detail', AntsuranceAiClient.text('One sentence with the fact and why it matters for this conversation.'));
        return new AntsuranceAiClient.Shape()
            .field('risk', AntsuranceAiClient.choice(RISKS, 'How likely the customer is to leave at this renewal.'))
            .field('riskReason', AntsuranceAiClient.text('One sentence, at most 20 words, saying why.'))
            .field('points', AntsuranceAiClient.listOf(point.toJson(), 'Two or three things to know before reaching out, most important first.'))
            .field('subject', AntsuranceAiClient.text('The email subject, at most 60 characters.'))
            .field('body', AntsuranceAiClient.text('The email body as plain text, with paragraphs separated by a blank line.'))
            .field('callOpening', AntsuranceAiClient.text('One or two sentences to open a phone call instead.'));
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
