/**
 * @description Files a claim from what the customer said. A handler pastes an email, a web form
 * message or call notes on a customer or policy; Claude reads it against the customer's policies
 * and returns a draft first notice of loss (policy, date and type of loss, severity, location,
 * estimate, subject, description, what is still missing). The handler reviews the draft and the
 * claim is then created as that user, so the normal claim automation runs.
 */
public with sharing class AntsuranceClaimsAssistantIntake {
    private static final Integer MAX_MESSAGE = 12000;
    private static final Integer MIN_MESSAGE = 20;
    private static final Integer MAX_POLICIES = 40;
    private static final Integer MAX_CONTACTS = 20;
    private static final Integer MAX_SAMPLES = 4;
    private static final Integer MAX_SUBJECT = 255;
    private static final Integer MAX_LOCATION = 255;
    private static final Integer MAX_DESCRIPTION = 30000;
    private static final Set<String> IN_FORCE = new Set<String>{ 'Active', 'Pending Renewal' };
    private static final String NOTE_TYPE = 'Contact';

    @TestVisible
    private static final String WRONG_RECORD = 'Open this from a customer or a policy.';
    @TestVisible
    private static final String NO_ACCESS = 'The customer\'s policies could not be read. Check your access to policies.';
    @TestVisible
    private static final String NO_POLICIES = 'This customer has no policies to file a claim under.';
    @TestVisible
    private static final String TOO_SHORT = 'Paste the customer\'s message first.';
    @TestVisible
    private static final String TOO_LONG = 'That message is too long. Keep it under 12,000 characters.';
    @TestVisible
    private static final String INVALID_CLAIM = 'The claim details could not be read. Close this window and try again.';
    @TestVisible
    private static final String NEEDS_POLICY = 'Choose the policy this claim falls under.';
    @TestVisible
    private static final String NEEDS_SUBJECT = 'Give the claim a subject.';
    @TestVisible
    private static final String WRONG_POLICY = 'That policy does not belong to this customer.';

    private static final String INSTRUCTIONS =
        'You work on the claims intake desk at Antsurance, an insurance carrier. A claims handler gives you one customer\'s policies ' +
        'and a message from or about that customer: an email, a web form submission or a handler\'s notes from a phone call. ' +
        'Turn it into a first notice of loss that the handler will review before the claim is opened.\n\n' +
        'Use only what the message and the policy list say. Never fill a gap with a guess: leave the field empty and put the question in "missing".\n\n' +
        'is_claim: true when the message reports a loss, damage, injury, theft or an incident that may lead to a payment under a policy. ' +
        'False for anything else, such as a billing question, a policy change, a document request, a quote request or a complaint. ' +
        'When false, say in not_claim_reason what the message is and what the handler should do instead, and leave the other text fields empty.\n\n' +
        'policy_number: the policy the loss falls under, chosen by matching what was damaged or who was hurt to each policy\'s line of business and insured item. ' +
        'A vehicle loss goes to the auto policy that lists that vehicle; damage to the home or its contents goes to the homeowners or renters policy; ' +
        'an employee hurt at work goes to workers compensation; a member of the public hurt or their property damaged goes to general liability; ' +
        'damage to business premises, stock or equipment goes to commercial property. ' +
        'Choose the policy that fits even when it is lapsed, cancelled or expired, and flag that under "watch". ' +
        'An umbrella policy sits above other policies, so choose it only when the message is about a liability claim that exceeds the underlying policy. ' +
        'Return an empty string only when no policy on the list could respond to this kind of loss.\n\n' +
        'date_of_loss: the day the loss happened, as YYYY-MM-DD. Work out relative dates such as "last night" or "on Saturday" from today\'s date, ' +
        'taking the most recent such day before today. If the customer only knows when they found the damage, use that day and ask in "missing" when it started. ' +
        'Empty string when the message gives no way to tell.\n\n' +
        'loss_type: Collision for a moving vehicle hitting or being hit by a vehicle or an object, even when most of the damage is to someone else\'s property. ' +
        'Animal Strike when a vehicle hit a deer or another animal: that is paid under comprehensive, not collision. ' +
        'Glass when the only damage is vehicle glass. ' +
        'Theft for stolen property or a stolen vehicle, including burglary. Vandalism for deliberate damage with nothing stolen. ' +
        'Water Damage for burst pipes, leaks and appliance or plumbing failures. Fire for fire and smoke. ' +
        'Wind or Hail for storm damage, including a tree or limb brought down by a storm onto a building or a vehicle. ' +
        'Bodily Injury when a person was hurt and that is the main loss: an employee, a guest, a customer or another third party. ' +
        'Liability when someone holds the insured responsible for damage to their property or for a loss other than an injury, and no vehicle of the insured was involved. ' +
        'Other when none fit.\n\n' +
        'loss_location: where it happened, as far as the message says: the address, or the place and town. A place with no address still counts, ' +
        'such as the customer\'s apartment garage. When the loss happened at the insured address, use that address. Empty only when the message says nothing about where.\n\n' +
        'severity: Low for minor damage, about $5,000 or less, with nobody hurt. ' +
        'Medium for about $5,000 to $25,000, a vehicle that cannot be driven, or an injury that was treated and released the same day or needs a few weeks off work. ' +
        'High for about $25,000 to $200,000, a stolen or totaled vehicle, a home or premises that cannot be used, or an injury needing surgery or a stay in hospital. ' +
        'Catastrophic for more than about $200,000, a life-threatening injury or a death, or a loss affecting several homes, units or people. ' +
        'When there is no figure, judge from the damage described.\n\n' +
        'estimated_loss: the total cost the message puts on the loss, in dollars: a repair estimate, a quote, or the value of what was lost. ' +
        'If it gives several such costs for the same loss, add them up. A small expense already paid is not an estimate when the customer says the total is not yet known: ' +
        'keep it in the description and return null. Null when the message gives no figure.\n\n' +
        'subject: what happened, in under 60 characters, sentence case, no full stop, no customer name and no policy number. For example: Burst pipe flooded finished basement.\n\n' +
        'description: three to six plain sentences for the claim file, in the third person and past tense: what happened, when and where, what was damaged, ' +
        'who was hurt, who else was involved, and what has been done since. Keep every concrete detail the message gives, such as names, report numbers, plates, insurers and costs. ' +
        'Do not add advice or anything the message does not say.\n\n' +
        'reported_by: the contact from the list who sent the message or made the call, exactly as listed. Empty string when it is not one of them.\n\n' +
        'origin: Email for an email, Web for a web form, Phone for call notes, Agent when an agent or broker sent it on the customer\'s behalf, Mobile App when it says it came from the app.\n\n' +
        'missing: up to five short questions to ask the customer, most important first. Only things a handler needs to open and triage this claim and that the message does not already answer, ' +
        'such as the exact date, the location, whether anyone was hurt, the other party\'s details, a police report number, photos or a repair estimate.\n\n' +
        'watch: up to four short notes on things the handler should notice straight away, such as an injury, another party at fault, a late report, ' +
        'a policy that was not active on the date of loss, a possible coverage question, or a home that cannot be lived in. Empty when there is nothing.\n\n' +
        'Write plainly, in complete sentences, with no dashes used as punctuation. In sentences, write dates month first, like Sep 28. ' +
        AntsuranceClaimRules.AMERICAN_ENGLISH;

    /**
     * @description One of the customer's policies, for the policy picker.
     */
    public class PolicyOption {
        @AuraEnabled
        public Id policyId;
        @AuraEnabled
        public String policyNumber;
        @AuraEnabled
        public String lineOfBusiness;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String insuredItem;
        @AuraEnabled
        public Date effectiveDate;
        @AuraEnabled
        public Date expirationDate;
        @AuraEnabled
        public Boolean inForce;
    }

    /**
     * @description A person on the customer's account who may have reported the loss.
     */
    public class ContactOption {
        @AuraEnabled
        public Id contactId;
        @AuraEnabled
        public String name;
    }

    /**
     * @description A ready-made customer message that fits this customer, for trying the feature.
     */
    public class Sample {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String channel;
        @AuraEnabled
        public String text;
    }

    /**
     * @description What the intake form needs before a message is read.
     */
    public class IntakeContext {
        @AuraEnabled
        public Id accountId;
        @AuraEnabled
        public String customerName;
        /** The policy the form was opened from, when it was opened from a policy. */
        @AuraEnabled
        public Id fromPolicyId;
        @AuraEnabled
        public List<PolicyOption> policies = new List<PolicyOption>();
        @AuraEnabled
        public List<ContactOption> contacts = new List<ContactOption>();
        @AuraEnabled
        public List<String> lossTypes;
        @AuraEnabled
        public List<String> severities;
        @AuraEnabled
        public List<String> origins;
        @AuraEnabled
        public List<Sample> samples = new List<Sample>();
    }

    /**
     * @description Claude's reading of a message: a claim ready to review, or the reason it is not one.
     */
    public class Draft {
        @AuraEnabled
        public Boolean isClaim;
        @AuraEnabled
        public String notClaimReason;
        @AuraEnabled
        public Id policyId;
        @AuraEnabled
        public String policyReason;
        @AuraEnabled
        public Date dateOfLoss;
        @AuraEnabled
        public String lossType;
        @AuraEnabled
        public String severity;
        @AuraEnabled
        public String lossLocation;
        @AuraEnabled
        public Decimal estimatedLoss;
        @AuraEnabled
        public String subject;
        @AuraEnabled
        public String description;
        @AuraEnabled
        public Id contactId;
        @AuraEnabled
        public String origin;
        @AuraEnabled
        public List<String> missing = new List<String>();
        @AuraEnabled
        public List<String> watch = new List<String>();
    }

    /**
     * @description The reviewed claim sent back by the form. Field names match Draft.
     */
    public class ClaimInput {
        public Id accountId;
        public Id policyId;
        public Id contactId;
        public Date dateOfLoss;
        public String lossType;
        public String severity;
        public String lossLocation;
        public Decimal estimatedLoss;
        public String subject;
        public String description;
        public String origin;
        /** The customer's message as pasted, kept on the file as the first note. */
        public String message;
        public List<String> missing;
    }

    /**
     * @description The claim that was opened.
     */
    public class CreatedClaim {
        @AuraEnabled
        public Id caseId;
        @AuraEnabled
        public String caseNumber;
        @AuraEnabled
        public String coverageCheck;
    }

    /**
     * @description Loads the customer, their policies and contacts, the picklist values the form
     * offers, and sample messages that fit this customer.
     * @param recordId The customer (Account) or policy the form was opened from
     * @return Everything the form needs before a message is read
     * @throws AuraHandledException when the record is of another kind or cannot be read
     */
    @AuraEnabled(cacheable=true)
    public static IntakeContext getContext(Id recordId) {
        IntakeContext context = new IntakeContext();
        try {
            if (recordId?.getSObjectType() == Policy__c.SObjectType) {
                context.fromPolicyId = recordId;
                context.accountId = [SELECT Account__c FROM Policy__c WHERE Id = :recordId WITH USER_MODE LIMIT 1].Account__c;
            } else if (recordId?.getSObjectType() == Account.SObjectType) {
                context.accountId = recordId;
            } else {
                throw handled(WRONG_RECORD);
            }
            context.customerName = [SELECT Name FROM Account WHERE Id = :context.accountId WITH USER_MODE LIMIT 1].Name;
            for (Policy__c policy : queryPolicies(context.accountId)) {
                context.policies.add(toOption(policy));
            }
            for (Contact person : queryContacts(context.accountId)) {
                ContactOption option = new ContactOption();
                option.contactId = person.Id;
                option.name = person.Name;
                context.contacts.add(option);
            }
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        }
        context.lossTypes = picklistValues(Case.Loss_Type__c);
        context.severities = picklistValues(Case.Severity__c);
        context.origins = picklistValues(Case.Origin);
        context.samples = samplesFor(context);
        return context;
    }

    /**
     * @description Has Claude read a customer's message and draft the claim.
     * @param recordId The customer (Account) or policy the form was opened from
     * @param message The email, web form message or call notes as pasted
     * @return The draft claim, or isClaim false with the reason when the message is not a claim
     * @throws AuraHandledException when the message is empty or too long, the customer has no
     * policies, or Claude cannot be reached
     */
    @AuraEnabled
    public static Draft readMessage(Id recordId, String message) {
        String text = message == null ? '' : message.trim();
        if (text.length() < MIN_MESSAGE) {
            throw handled(TOO_SHORT);
        }
        if (text.length() > MAX_MESSAGE) {
            throw handled(TOO_LONG);
        }
        IntakeContext context = getContext(recordId);
        if (context.policies.isEmpty()) {
            throw handled(NO_POLICIES);
        }
        List<Policy__c> policies = queryPolicies(context.accountId);

        AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(INSTRUCTIONS, buildPrompt(context, policies, text))
            .returning(draftSchema(context));
        Map<String, Object> answer;
        try {
            answer = AntsuranceAiClient.ask(question).data;
        } catch (AntsuranceAiClient.AiException e) {
            throw handled(e.getMessage());
        }
        return toDraft(answer, context);
    }

    /**
     * @description Opens the claim the handler reviewed, as that user, and keeps the customer's
     * message on the file as the first note.
     * @param claimJson The reviewed claim, as JSON matching ClaimInput
     * @return The new claim's Id and number, and whether the policy covered the date of loss
     * @throws AuraHandledException when a required value is missing or the claim cannot be saved
     */
    @AuraEnabled
    public static CreatedClaim createClaim(String claimJson) {
        ClaimInput input;
        try {
            input = (ClaimInput) JSON.deserialize(claimJson, ClaimInput.class);
        } catch (Exception e) {
            throw handled(INVALID_CLAIM);
        }
        if (input == null || input.accountId == null) {
            throw handled(INVALID_CLAIM);
        }
        if (input.policyId == null) {
            throw handled(NEEDS_POLICY);
        }
        if (String.isBlank(input.subject)) {
            throw handled(NEEDS_SUBJECT);
        }

        CreatedClaim created = new CreatedClaim();
        try {
            Policy__c policy = [SELECT Account__c FROM Policy__c WHERE Id = :input.policyId WITH USER_MODE LIMIT 1];
            if (policy.Account__c != input.accountId) {
                throw handled(WRONG_POLICY);
            }
            Case claim = new Case(
                RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId(),
                AccountId = input.accountId,
                Policy__c = input.policyId,
                ContactId = input.contactId,
                Subject = input.subject.trim().left(MAX_SUBJECT),
                Description = input.description?.trim().left(MAX_DESCRIPTION),
                Date_of_Loss__c = input.dateOfLoss,
                Reported_Date__c = Date.today(),
                Loss_Type__c = input.lossType,
                Severity__c = input.severity,
                Loss_Location__c = input.lossLocation?.trim().left(MAX_LOCATION),
                Estimated_Loss__c = input.estimatedLoss,
                Origin = input.origin,
                Status = 'New'
            );
            insert as user claim;
            created.caseId = claim.Id;

            String note = firstNotice(input);
            if (note != null) {
                AntsuranceNotesController.addNote(claim.Id, NOTE_TYPE, note);
            }
            Case saved = [SELECT CaseNumber, Coverage_Check__c FROM Case WHERE Id = :claim.Id WITH USER_MODE LIMIT 1];
            created.caseNumber = saved.CaseNumber;
            created.coverageCheck = saved.Coverage_Check__c;
        } catch (QueryException e) {
            throw handled(NO_ACCESS);
        } catch (DmlException e) {
            throw handled(e.getDmlMessage(0));
        }
        return created;
    }

    private static List<Policy__c> queryPolicies(Id accountId) {
        return [
            SELECT
                Id,
                Name,
                Line_of_Business__c,
                Status__c,
                Effective_Date__c,
                Expiration_Date__c,
                Insured_Item__c,
                Deductible__c,
                Coverage_Limit__c,
                (SELECT Name FROM Coverages__r ORDER BY Name LIMIT 12)
            FROM Policy__c
            WHERE Account__c = :accountId AND Status__c != 'Quoted'
            WITH USER_MODE
            ORDER BY Effective_Date__c DESC NULLS LAST, Name
            LIMIT :MAX_POLICIES
        ];
    }

    private static List<Contact> queryContacts(Id accountId) {
        return [
            SELECT Id, Name, FirstName, Household_Role__c, Title, Primary_Member__c
            FROM Contact
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY Primary_Member__c DESC, Name
            LIMIT :MAX_CONTACTS
        ];
    }

    private static PolicyOption toOption(Policy__c policy) {
        PolicyOption option = new PolicyOption();
        option.policyId = policy.Id;
        option.policyNumber = policy.Name;
        option.lineOfBusiness = policy.Line_of_Business__c;
        option.status = policy.Status__c;
        option.insuredItem = policy.Insured_Item__c;
        option.effectiveDate = policy.Effective_Date__c;
        option.expirationDate = policy.Expiration_Date__c;
        option.inForce = IN_FORCE.contains(policy.Status__c);
        return option;
    }

    private static List<String> picklistValues(Schema.SObjectField field) {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    /** The customer's policies and contacts, today's date and the message, laid out for Claude. */
    @TestVisible
    private static String buildPrompt(IntakeContext context, List<Policy__c> policies, String message) {
        List<String> lines = new List<String>{
            'Today is ' + Datetime.now().format('EEEE, MMM d, yyyy') + '.',
            '',
            'Customer: ' + context.customerName
        };
        List<String> names = new List<String>();
        for (ContactOption person : context.contacts) {
            names.add(person.name);
        }
        lines.add('Contacts: ' + (names.isEmpty() ? 'none on file' : String.join(names, ', ')));
        lines.add('');
        lines.add('Policies:');
        for (Policy__c policy : policies) {
            List<String> parts = new List<String>{
                policy.Name,
                policy.Line_of_Business__c,
                policy.Status__c,
                'term ' + formatDate(policy.Effective_Date__c) + ' to ' + formatDate(policy.Expiration_Date__c)
            };
            if (String.isNotBlank(policy.Insured_Item__c)) {
                parts.add('insures ' + policy.Insured_Item__c);
            }
            if (policy.Deductible__c != null) {
                parts.add('deductible $' + policy.Deductible__c.setScale(0).format());
            }
            List<String> coverages = new List<String>();
            for (Policy_Coverage__c coverage : policy.Coverages__r) {
                coverages.add(coverage.Name);
            }
            if (!coverages.isEmpty()) {
                parts.add('coverages: ' + String.join(coverages, ', '));
            }
            lines.add('- ' + String.join(parts, ' | '));
        }
        if (context.fromPolicyId != null) {
            for (PolicyOption option : context.policies) {
                if (option.policyId == context.fromPolicyId) {
                    lines.add('');
                    lines.add(
                        'The handler opened this from policy ' +
                            option.policyNumber +
                            '. Choose it unless the loss clearly belongs under another policy on the list.'
                    );
                }
            }
        }
        lines.add('');
        lines.add('Message:');
        lines.add('<message>');
        lines.add(message);
        lines.add('</message>');
        return String.join(lines, '\n');
    }

    private static String formatDate(Date value) {
        return value == null ? 'unknown' : Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d, yyyy');
    }

    /** The answer's shape. Policy numbers, contacts and picklists are limited to this org's real values. */
    @TestVisible
    private static AntsuranceAiClient.Shape draftSchema(IntakeContext context) {
        List<String> policyNumbers = new List<String>{ '' };
        for (PolicyOption option : context.policies) {
            policyNumbers.add(option.policyNumber);
        }
        List<String> contactNames = new List<String>{ '' };
        for (ContactOption person : context.contacts) {
            contactNames.add(person.name);
        }
        return new AntsuranceAiClient.Shape()
            .field('is_claim', AntsuranceAiClient.flag('True when the message reports a loss or incident that may lead to a claim.'))
            .field('not_claim_reason', AntsuranceAiClient.text('When is_claim is false: what the message is and what to do instead. Otherwise empty.'))
            .field('policy_reason', AntsuranceAiClient.text('One sentence on why this policy, or why none fits.'))
            .field('policy_number', AntsuranceAiClient.choice(policyNumbers, 'The policy the loss falls under, or empty when none could respond.'))
            .field('date_of_loss', AntsuranceAiClient.text('YYYY-MM-DD, or empty when unknown.'))
            .field('loss_type', AntsuranceAiClient.choice(context.lossTypes, 'The kind of loss.'))
            .field('loss_location', AntsuranceAiClient.text('Where it happened, as an address or place and town. Empty when unknown.'))
            .field('estimated_loss', AntsuranceAiClient.optionalNumber('The total cost the message puts on the loss, in dollars, or null.'))
            .field('severity', AntsuranceAiClient.choice(context.severities, 'How serious the loss is.'))
            .field('subject', AntsuranceAiClient.text('What happened, under 60 characters.'))
            .field('description', AntsuranceAiClient.text('Three to six sentences for the claim file.'))
            .field('reported_by', AntsuranceAiClient.choice(contactNames, 'The contact who reported it, or empty.'))
            .field('origin', AntsuranceAiClient.choice(context.origins, 'How the message arrived.'))
            .field('missing', AntsuranceAiClient.listOf(AntsuranceAiClient.text('A question for the customer.'), 'Up to five questions still to ask.'))
            .field('watch', AntsuranceAiClient.listOf(AntsuranceAiClient.text('A short note for the handler.'), 'Up to four things to notice.'));
    }

    @TestVisible
    private static Draft toDraft(Map<String, Object> answer, IntakeContext context) {
        Draft draft = new Draft();
        draft.isClaim = answer.get('is_claim') == true;
        draft.notClaimReason = clean(answer.get('not_claim_reason'));
        draft.policyReason = clean(answer.get('policy_reason'));
        draft.lossType = clean(answer.get('loss_type'));
        draft.severity = clean(answer.get('severity'));
        draft.lossLocation = clean(answer.get('loss_location'));
        draft.subject = clean(answer.get('subject'));
        draft.description = clean(answer.get('description'));
        draft.origin = clean(answer.get('origin'));
        draft.missing = AntsuranceAiClient.toStrings(answer.get('missing'));
        draft.watch = AntsuranceAiClient.toStrings(answer.get('watch'));

        Decimal estimate = AntsuranceAiClient.toDecimal(answer.get('estimated_loss'));
        draft.estimatedLoss = estimate == null || estimate <= 0 ? null : estimate.setScale(2, RoundingMode.HALF_UP);

        String dateText = clean(answer.get('date_of_loss'));
        if (dateText != null) {
            try {
                draft.dateOfLoss = Date.valueOf(dateText);
            } catch (Exception e) {
                draft.dateOfLoss = null;
            }
        }
        String policyNumber = clean(answer.get('policy_number'));
        for (PolicyOption option : context.policies) {
            if (option.policyNumber == policyNumber) {
                draft.policyId = option.policyId;
            }
        }
        String reportedBy = clean(answer.get('reported_by'));
        for (ContactOption person : context.contacts) {
            if (person.name == reportedBy) {
                draft.contactId = person.contactId;
            }
        }
        return draft;
    }

    private static String clean(Object value) {
        String text = value == null ? null : String.valueOf(value).trim();
        return String.isBlank(text) ? null : text;
    }

    /** The first file note: the customer's own words, quoted, and what is still to ask. */
    private static String firstNotice(ClaimInput input) {
        if (String.isBlank(input.message)) {
            return null;
        }
        String channel = String.isBlank(input.origin) ? 'message' : input.origin.toLowerCase();
        List<String> lines = new List<String>{ '**First notice:** Filed from the customer\'s ' + noticeSource(channel) + ', read with Claude.', '' };
        for (String line : input.message.trim().split('\n')) {
            lines.add('> ' + line.trim());
        }
        List<String> questions = AntsuranceAiClient.toStrings(input.missing);
        if (!questions.isEmpty()) {
            lines.add('');
            lines.add('**Still to ask:**');
            for (String question : questions) {
                lines.add('- ' + question);
            }
        }
        return String.join(lines, '\n').left(MAX_DESCRIPTION);
    }

    private static String noticeSource(String channel) {
        if (channel == 'email') {
            return 'email';
        }
        if (channel == 'web') {
            return 'web form';
        }
        if (channel == 'phone') {
            return 'phone call';
        }
        if (channel == 'mobile app') {
            return 'app report';
        }
        return channel == 'agent' ? 'agent\'s report' : 'message';
    }

    /**
     * Sample messages written for the lines of business this customer holds, with the customer's
     * own names, vehicle and address dropped in, plus one message that is not a claim.
     */
    private static List<Sample> samplesFor(IntakeContext context) {
        String fullName = context.contacts.isEmpty() ? context.customerName : context.contacts[0].name;
        String firstName = fullName.substringBefore(' ');
        List<Sample> samples = new List<Sample>();
        Set<String> used = new Set<String>();
        // The policy the form was opened from comes first, then policies in force.
        List<PolicyOption> ordered = new List<PolicyOption>();
        for (PolicyOption option : context.policies) {
            if (option.policyId == context.fromPolicyId) {
                ordered.add(option);
            }
        }
        for (PolicyOption option : context.policies) {
            if (option.policyId != context.fromPolicyId && option.inForce) {
                ordered.add(option);
            }
        }
        for (PolicyOption option : context.policies) {
            if (option.policyId != context.fromPolicyId && !option.inForce) {
                ordered.add(option);
            }
        }
        for (PolicyOption option : ordered) {
            if (samples.size() >= MAX_SAMPLES - 1 || used.contains(option.lineOfBusiness)) {
                continue;
            }
            Sample entry = sampleForLine(option, context.customerName, fullName, firstName);
            if (entry != null) {
                used.add(option.lineOfBusiness);
                samples.add(entry);
            }
        }
        // A second auto message in a handler's shorthand shows that call notes work too.
        for (PolicyOption option : ordered) {
            if (samples.size() < MAX_SAMPLES - 1 && option.lineOfBusiness == 'Personal Auto') {
                samples.add(
                    newSample(
                        'auto-call',
                        'Cracked windshield',
                        'Phone',
                        'Inbound call 9:12am, insd ' +
                            fullName +
                            '. Rock came off a gravel truck on I-88 nr Aurora yesterday morning and cracked the windshield on the ' +
                            firstVehicle(option.insuredItem) +
                            '. Crack is spreading across the driver side. No other damage, nobody hurt, did not get the truck plate. ' +
                            'Wants to know if glass is covered and if the deductible applies. No estimate yet. Call back on cell after 3pm.'
                    )
                );
                break;
            }
        }
        samples.add(
            newSample(
                'not-a-claim',
                'A billing question',
                'Email',
                'Subject: Question about my bill\n\nHi,\n\nMy payment went up by $14 this month and I do not know why. Nothing has changed on our side. ' +
                    'Can you tell me what happened, and also send me a new copy of the ID cards?\n\nThanks,\n' +
                    fullName
            )
        );
        return samples;
    }

    private static Sample sampleForLine(PolicyOption option, String customerName, String fullName, String firstName) {
        String item = String.isBlank(option.insuredItem) ? 'our property' : option.insuredItem;
        switch on option.lineOfBusiness {
            when 'Personal Auto' {
                return newSample(
                    'auto-email',
                    'Rear-ended at a light',
                    'Email',
                    'Subject: Car accident on Saturday\n\nHi, this is ' +
                        firstName +
                        '. I was rear-ended at a red light on Saturday afternoon around 4:30, at Ogden Ave and Washington St in Naperville. ' +
                        'I was driving the ' +
                        firstVehicle(option.insuredItem) +
                        '. The other driver said it was her fault and I have her insurance details (State Farm) and her plate, K47 2291. ' +
                        'The police came and gave me report number NPD-26-118204. Nobody was hurt, but the bumper and trunk lid are pushed in and the trunk will not close. ' +
                        'The body shop thinks it will be around $4,200.\n\nWhat do I need to do next? I need the car for work.\n\nThanks,\n' +
                        fullName
                );
            }
            when 'Homeowners' {
                return newSample(
                    'home-web',
                    'Dishwasher line split',
                    'Web',
                    'Online claim form\n\nName: ' +
                        fullName +
                        '\nAddress of loss: ' +
                        item +
                        '\nWhat happened: We got home from a weekend away last night and found water all over the kitchen floor. ' +
                        'The supply line to the dishwasher had split. Water ran under the cabinets and into the dining room, and the hardwood is already cupping. ' +
                        'The basement ceiling underneath is stained and dripping.\nWhen: found it last night around 9pm, not sure when it started\n' +
                        'Anything else: We shut off the water and a plumber replaced the line this morning for $380. ' +
                        'A restoration company is coming tomorrow to dry it out. We have no idea what the total will be.'
                );
            }
            when 'Renters' {
                return newSample(
                    'renters-email',
                    'Apartment break-in',
                    'Email',
                    'Subject: Break-in at my apartment\n\nHello,\n\nSomeone broke into my apartment yesterday while I was at work. ' +
                        'They forced the back door and took my laptop (MacBook Pro, about $2,400 new last year), a gaming console ($500) and my road bike from the hallway ($1,150). ' +
                        'The door frame is cracked and the landlord is fixing it. I filed a police report last night, number 26-0093317.\n\n' +
                        'I have receipts for the laptop and the bike. What else do you need from me?\n\n' +
                        fullName
                );
            }
            when 'Commercial Property' {
                return newSample(
                    'property-email',
                    'Storm tore the roof',
                    'Email',
                    'Subject: Storm damage at our building\n\nHi,\n\nThursday night\'s storm peeled back a section of the membrane roof over our stockroom at ' +
                        item +
                        '. Rain got in overnight and soaked the stock on the top two shelving runs. ' +
                        'We have tarped the roof and moved what we could. Our roofer quoted $26,500 to repair the section and we think about $18,000 of stock is ruined. ' +
                        'We are open but the stockroom is out of use.\n\nPlease let me know what you need to get this moving.\n\n' +
                        fullName +
                        '\n' +
                        customerName
                );
            }
            when 'General Liability' {
                return newSample(
                    'liability-call',
                    'Customer slipped',
                    'Phone',
                    'Call from ' +
                        fullName +
                        ' at ' +
                        customerName +
                        ', 2:40pm. A customer, Margaret Doyle, slipped on ice by the front entrance on Friday morning about 8:15 and went down hard on her wrist. ' +
                        'Staff called an ambulance and she was taken to the ER, they think it is broken. Entrance had been salted at 7am per the log. ' +
                        'There is camera footage and two staff saw it. Her daughter phoned today saying they expect the medical bills to be covered. No figure mentioned.'
                );
            }
            when 'Workers Compensation' {
                return newSample(
                    'workcomp-email',
                    'Employee hurt on site',
                    'Email',
                    'Subject: Employee injury this morning\n\nHi,\n\nReporting an injury. One of our crew, Tomas Vega, cut his left hand badly on a circular saw at about 7:50 this morning on a job site in Wheaton. ' +
                        'His supervisor drove him to the ER at Northwestern Medicine Central DuPage. He needed stitches and they are checking for tendon damage. ' +
                        'He will be off work for at least two weeks. The saw guard was in place and we have photos and the supervisor\'s statement.\n\n' +
                        'What forms do you need from us?\n\n' +
                        fullName +
                        '\n' +
                        customerName
                );
            }
            when 'Commercial Auto' {
                return newSample(
                    'fleet-email',
                    'Truck hit a canopy',
                    'Email',
                    'Subject: Truck damage at a customer site\n\nHello,\n\nYesterday afternoon one of our drivers backed a box truck into the loading dock canopy at a customer\'s warehouse, 4100 W 42nd Pl in Chicago. ' +
                        'The canopy is bent and one support post is cracked. Their facilities manager says the repair will be about $7,500 and wants our insurance details. ' +
                        'Our truck has a crushed corner on the box and a broken tail light. The driver was not hurt and no one else was nearby.\n\n' +
                        'Please open a claim and tell me who their manager should talk to.\n\n' +
                        fullName +
                        '\n' +
                        customerName
                );
            }
            when else {
                return null;
            }
        }
    }

    /** "2023 Honda CR-V and 2020 Tesla Model 3" becomes "2023 Honda CR-V". */
    private static String firstVehicle(String insuredItem) {
        if (String.isBlank(insuredItem)) {
            return 'car';
        }
        return insuredItem.substringBefore(' and ').substringBefore(',').trim();
    }

    private static Sample newSample(String key, String label, String channel, String text) {
        Sample entry = new Sample();
        entry.key = key;
        entry.label = label;
        entry.channel = channel;
        entry.text = text;
        return entry;
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
