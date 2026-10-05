/**
 * @description Everything the customer portal reads and writes. The portal is the one part of the org
 * on the public internet, so this class is the boundary: it reads and writes in system mode (portal
 * users are given no object access of their own; every query says WITH SYSTEM_MODE so that is plain
 * to see and does not depend on a default), works out whose records to use from the running user and
 * never from a parameter, and checks that any record Id it is handed belongs to that customer's
 * account before using it.
 *
 * A customer can read their own policies, claims and service requests, and can file a claim or send
 * a service request. Nothing else is reachable from here.
 */
public without sharing class AntsurancePortalController {
    @TestVisible
    private static final String NOT_A_CUSTOMER = 'This page is for signed-in Antsurance customers.';
    /** Said whenever a record is not on the customer's own account, whatever the record is. */
    public static final String NOT_YOURS = 'We could not find that on your account.';
    private static final String CLAIM = 'Claim';
    private static final String SERVICE = 'Policy_Service';
    private static final Set<String> IN_FORCE = new Set<String>{ 'Active', 'Pending Renewal' };
    private static final Set<String> SHOWN_POLICIES = new Set<String>{ 'Active', 'Pending Renewal', 'Lapsed', 'Cancelled', 'Expired' };
    private static final Integer MAX_TEXT = 2000;
    private static final Integer MAX_SHORT = 120;
    /** How a customer's own note is signed, so only their notes are ever shown back to them. */
    public static final String FROM_PORTAL = '(customer, via the portal)';

    /** Who is signed in, as far as the portal is concerned. */
    public class Customer {
        public Id contactId;
        public Id accountId;
        public Id ownerId;
        public String firstName;
        public String name;
        public String householdName;
    }

    /** A policy as a customer sees it. */
    public class Policy {
        @AuraEnabled public Id id;
        @AuraEnabled public String policyNumber;
        @AuraEnabled public String line;
        @AuraEnabled public String insured;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean inForce;
        @AuraEnabled public String premiumText;
        @AuraEnabled public Decimal premium;
        @AuraEnabled public String billing;
        @AuraEnabled public String payments;
        @AuraEnabled public String startsText;
        @AuraEnabled public String endsText;
        @AuraEnabled public Integer daysToRenewal;
        @AuraEnabled public String limitText;
        @AuraEnabled public String deductibleText;
        @AuraEnabled public String renewalPremiumText;
        @AuraEnabled public String renewalChangeText;
        /** The policy in the customer's words: "Auto policy for your 2022 Toyota RAV4 and 2019 Honda Accord". */
        @AuraEnabled public String plainName;
        @AuraEnabled public String monthlyText;
        @AuraEnabled public String timeLeftText;
        @AuraEnabled public List<Coverage> coverages;
        @AuraEnabled public List<Person> people;
        @AuraEnabled public List<Item> items;
        @AuraEnabled public List<Extra> extras;
        /** What is due and what has been paid, worked out from the policy. Filled for a policy's own page. */
        @AuraEnabled public Bill bill;
    }

    /**
     * What a customer owes and has paid on a policy. The org keeps a policy's yearly price, how often it is
     * billed and whether payments are up to date, and no record of each payment, so the schedule here is
     * worked out from those three and says so.
     */
    public class Bill {
        @AuraEnabled public String headline;
        @AuraEnabled public String schedule;
        @AuraEnabled public String nextDue;
        @AuraEnabled public String paidSoFar;
        @AuraEnabled public String standing;
        @AuraEnabled public Boolean isBehind;
        /** What has moved the price this term: each change to the policy that added to or took from it. */
        @AuraEnabled public List<BillLine> changes;
        @AuraEnabled public String changeNote;
        @AuraEnabled public String basis;
        /** One payment ("$198"), and how often it falls ("Each month"). Empty when the year is paid in one payment. */
        @AuraEnabled public String eachText;
        @AuraEnabled public String everyWords;
        /** When the next payment falls, when one is still to come and none is past due. */
        @AuraEnabled public String nextDateText;
        public Date nextDay;
    }

    public class BillLine {
        @AuraEnabled public String label;
        @AuraEnabled public String whenText;
        @AuraEnabled public String amountText;
    }

    public class Coverage {
        @AuraEnabled public String name;
        @AuraEnabled public String limitText;
        @AuraEnabled public String deductibleText;
        @AuraEnabled public String premiumText;
        @AuraEnabled public String plainWords;
        /** The limit and the deductible as a person would say them: "Up to $300,000 for each person", "You pay the first $500". */
        @AuraEnabled public String limitWords;
        @AuraEnabled public String deductibleWords;
    }

    public class Person {
        @AuraEnabled public String name;
        @AuraEnabled public String role;
        @AuraEnabled public String relationship;
    }

    public class Item {
        @AuraEnabled public String name;
        @AuraEnabled public String kind;
        @AuraEnabled public String detail;
    }

    /** An endorsement: something added to the standard policy. */
    public class Extra {
        @AuraEnabled public String name;
        @AuraEnabled public String plainWords;
        @AuraEnabled public String premiumChangeText;
        @AuraEnabled public String addedText;
        /** What it adds to or takes from the yearly price, and whether it came after the term began. */
        @AuraEnabled public Decimal premiumChange;
        @AuraEnabled public Boolean addedThisTerm;
    }

    /** One step of a claim's progress, in the customer's words. */
    public class Step {
        @AuraEnabled public String label;
        @AuraEnabled public String state;
    }

    /** A claim as a customer sees it: where it is, and what happened last. No reserves, no internal notes. */
    public class Claim {
        @AuraEnabled public Id id;
        @AuraEnabled public String claimNumber;
        @AuraEnabled public String title;
        @AuraEnabled public Id policyId;
        @AuraEnabled public String policyNumber;
        @AuraEnabled public String policyLine;
        @AuraEnabled public Boolean isOpen;
        @AuraEnabled public String statusWord;
        @AuraEnabled public String lastUpdate;
        @AuraEnabled public String reportedText;
        @AuraEnabled public String lossDateText;
        @AuraEnabled public String paidText;
        @AuraEnabled public String handler;
        @AuraEnabled public List<Step> steps;
    }

    public class Request {
        @AuraEnabled public Id id;
        @AuraEnabled public String requestNumber;
        @AuraEnabled public String title;
        @AuraEnabled public String topic;
        @AuraEnabled public String statusWord;
        @AuraEnabled public Boolean isOpen;
        @AuraEnabled public String openedText;
        @AuraEnabled public String policyNumber;
        // The rest is filled for a request's own page.
        @AuraEnabled public Id policyId;
        @AuraEnabled public String policyLine;
        @AuraEnabled public String lastUpdate;
        @AuraEnabled public String handler;
        @AuraEnabled public String closedText;
        @AuraEnabled public Boolean canWithdraw;
        /** What they asked, in their own words. Empty when the team took the request for them: staff wording about a customer is never shown to them. */
        @AuraEnabled public String asked;
        /** True when the team opened the request on the customer's behalf, so there are no words of theirs to show. */
        @AuraEnabled public Boolean takenForYou;
        /** The details they sent, as label and value. */
        @AuraEnabled public List<Fact> facts;
        @AuraEnabled public List<Step> steps;
        /** Notes the customer has added since. Staff notes are never shown here. */
        @AuraEnabled public List<Note> notes;
    }

    public class Fact {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    public class Note {
        @AuraEnabled public String text;
        @AuraEnabled public String whenText;
    }

    public class Home {
        @AuraEnabled public String firstName;
        @AuraEnabled public String householdName;
        @AuraEnabled public List<Policy> policies;
        @AuraEnabled public List<Claim> claims;
        @AuraEnabled public List<Request> requests;
        /** Quotes they asked for here, newest first. */
        @AuraEnabled public List<AntsurancePortalQuote.Sent> quotes;
        @AuraEnabled public List<String> suggestions;
    }

    /** What comes back after a claim or request is sent. */
    public class Receipt {
        @AuraEnabled public Id id;
        @AuraEnabled public String referenceNumber;
        @AuraEnabled public String message;
        /** When it was sent, to look the filed record up with findReceipt. */
        @AuraEnabled public Long sentAt;
    }

    // ------------------------------------------------------------------------------- reads

    /**
     * @description The signed-in customer's home: their policies, open claims and open requests.
     * @return Everything the home page draws
     */
    @AuraEnabled
    public static Home getHome() {
        Customer customer = me();
        Home home = new Home();
        home.firstName = customer.firstName;
        home.householdName = customer.householdName;
        home.policies = policiesFor(customer, null, false);
        home.claims = claimsFor(customer, null);
        home.requests = requestsFor(customer);
        home.quotes = AntsurancePortalQuote.sentFor(customer);
        home.suggestions = suggestionsFor(customer, home);
        return home;
    }

    /**
     * @description One of the customer's policies, with what it covers in plain words.
     * @param policyId The policy
     * @return The policy and its coverages, people, insured items and extras
     */
    @AuraEnabled
    public static Policy getPolicy(Id policyId) {
        Customer customer = me();
        List<Policy> found = policiesFor(customer, policyId, true);
        if (found.isEmpty()) {
            throw fail(NOT_YOURS);
        }
        return found[0];
    }

    /**
     * @description One of the customer's claims.
     * @param claimId The claim
     * @return The claim and its progress
     */
    @AuraEnabled
    public static Claim getClaim(Id claimId) {
        Customer customer = me();
        List<Claim> found = claimsFor(customer, claimId);
        if (found.isEmpty()) {
            throw fail(NOT_YOURS);
        }
        return found[0];
    }

    /**
     * @description One of the customer's service requests: what they asked, where it stands and their own notes on it.
     * @param requestId The request
     * @return The request
     */
    @AuraEnabled
    public static Request getRequest(Id requestId) {
        Customer customer = me();
        Case record = ownedRequest(customer, requestId);
        Request request = toRequest(record);
        request.policyId = record.Policy__c;
        request.policyLine = record.Policy__r?.Line_of_Business__c;
        // A request only just received names its handler in the one line below; after that the page says who has it.
        request.handler = record.Status == 'New' ? null : record.Handled_By__c;
        request.closedText = record.IsClosed ? longDate(record.Closed_On__c == null ? record.ClosedDate?.date() : record.Closed_On__c) : null;
        request.canWithdraw = record.Status == 'New';

        Integer position = record.IsClosed ? 2 : record.Status == 'New' ? 0 : 1;
        request.lastUpdate = record.IsClosed
            ? 'This request is done.'
            : record.Status == 'New'
                  ? 'We have your request. ' + (String.isBlank(record.Handled_By__c) ? 'Someone' : record.Handled_By__c) + ' on our service team will pick it up, usually within one business day.'
                  : record.Status == 'Waiting on Customer'
                        ? 'We need something from you before we can finish. Add a note here, or reply to our message.'
                        : 'Our service team is working on it.';
        request.steps = new List<Step>();
        List<String> labels = new List<String>{ 'Received', 'Being worked on', 'Done' };
        for (Integer index = 0; index < labels.size(); index++) {
            Step step = new Step();
            step.label = labels[index];
            step.state = index < position || record.IsClosed ? 'done' : index == position ? 'current' : 'todo';
            request.steps.add(step);
        }

        // What they sent: "Label: value" lines become facts, the rest is their own words. A request the team
        // opened for them holds the team's wording about the customer, which is not shown.
        Boolean fromPortal = record.Description != null && (record.Description.contains('Sent from the customer portal') || record.Description.contains('Filed from the customer portal'));
        request.takenForYou = !fromPortal;
        request.facts = new List<Fact>();
        List<String> words = new List<String>();
        for (String line : (fromPortal ? record.Description : '').split('\n')) {
            String text = line.trim();
            if (String.isBlank(text) || text.startsWith('Sent from the customer portal') || text.startsWith('Filed from the customer portal')) {
                continue;
            }
            Integer colon = text.indexOf(': ');
            if (colon > 0 && colon <= 24) {
                Fact fact = new Fact();
                fact.label = text.left(colon);
                fact.value = text.substring(colon + 2);
                request.facts.add(fact);
            } else {
                words.add(text);
            }
        }
        request.asked = String.join(words, '\n');

        request.notes = new List<Note>();
        for (File_Note__c note : [SELECT Body__c, Note_Date__c, Author_Name__c FROM File_Note__c WHERE Case__c = :record.Id WITH SYSTEM_MODE ORDER BY Note_Date__c]) {
            // Only what this customer wrote. Staff notes stay internal.
            if (note.Author_Name__c != null && note.Author_Name__c.endsWith(FROM_PORTAL)) {
                Note mine = new Note();
                mine.text = note.Body__c;
                mine.whenText = note.Note_Date__c == null ? null : longDate(note.Note_Date__c.date());
                request.notes.add(mine);
            }
        }
        return request;
    }

    /**
     * @description Adds the customer's note to one of their open requests. Staff see it in the request's file notes.
     * @param requestId The request
     * @param text What they want the team to know
     * @return What happens next
     */
    @AuraEnabled
    public static Receipt addRequestNote(Id requestId, String text) {
        Customer customer = me();
        Case record = ownedRequest(customer, requestId);
        if (record.IsClosed) {
            throw fail('This request is closed. Send a new request if you need something else.');
        }
        if (String.isBlank(text)) {
            throw fail('Write your note first.');
        }
        AntsurancePortalSubmissions.hand('note', JSON.serialize(new Map<String, String>{ 'requestId' => requestId, 'text' => clip(text.trim(), MAX_TEXT) }));
        Receipt receipt = new Receipt();
        receipt.sentAt = System.currentTimeMillis();
        receipt.message = 'Your note is on its way to the team.';
        return receipt;
    }

    /**
     * @description Withdraws one of the customer's requests, while it has only been received. The customer confirmed on screen.
     * @param requestId The request
     * @return What happens next
     */
    @AuraEnabled
    public static Receipt withdrawRequest(Id requestId) {
        Customer customer = me();
        Case record = ownedRequest(customer, requestId);
        if (record.Status != 'New') {
            throw fail('This request is already being worked on, so it cannot be withdrawn here. Add a note and the team will stop.');
        }
        AntsurancePortalSubmissions.hand('withdraw', JSON.serialize(new Map<String, String>{ 'requestId' => requestId }));
        Receipt receipt = new Receipt();
        receipt.sentAt = System.currentTimeMillis();
        receipt.message = 'Your request is being withdrawn.';
        return receipt;
    }

    /**
     * @description A service request the customer may see or act on.
     * @param customer Who is asking
     * @param requestId The request
     * @return The request
     * @throws AuraHandledException when it is not one of this customer's service requests
     */
    public static Case ownedRequest(Customer customer, Id requestId) {
        List<Case> found = [
            SELECT Id, CaseNumber, Subject, Status, IsClosed, Request_Type__c, Reported_Date__c, CreatedDate, ClosedDate, Closed_On__c, Description, Handled_By__c,
                Policy__c, Policy__r.Name, Policy__r.Line_of_Business__c
            FROM Case
            WHERE Id = :requestId AND AccountId = :customer.accountId AND RecordType.DeveloperName = :SERVICE
            WITH SYSTEM_MODE
        ];
        if (found.isEmpty()) {
            throw fail(NOT_YOURS);
        }
        return found[0];
    }

    // ------------------------------------------------------------------------------- writes

    /**
     * @description Sends a service request for the customer: adding a driver, or any other change.
     * The customer has seen and confirmed these fields on screen. The request is checked here, then
     * handed to AntsurancePortalSubmissions, which files it; see that class for why it is a hand-off.
     * @param kind "driver" for adding a driver, "request" for anything else
     * @param fieldsJson The form's fields, by name
     * @return What happens next. The reference number follows from findReceipt once the request is filed.
     */
    @AuraEnabled
    public static Receipt submitRequest(String kind, String fieldsJson) {
        return submit(kind == 'driver' ? 'driver' : 'request', fieldsJson);
    }

    /**
     * @description Files a claim for the customer. The customer has seen and confirmed these fields on screen.
     * @param fieldsJson The form's fields, by name
     * @return What happens next. The claim number follows from findReceipt once the claim is filed.
     */
    @AuraEnabled
    public static Receipt submitClaim(String fieldsJson) {
        return submit('claim', fieldsJson);
    }

    /**
     * @description The claim or request the customer just sent, once it has been filed.
     * @param kind "claim", "driver", "request" or "quote"
     * @param sinceMillis When they sent it, as returned in the receipt
     * @return The receipt with its reference number, or null while it is still being filed
     */
    @AuraEnabled
    public static Receipt findReceipt(String kind, Long sinceMillis) {
        Customer customer = me();
        String recordType = kind == 'claim' ? CLAIM : SERVICE;
        Datetime since = Datetime.newInstance(sinceMillis == null ? System.currentTimeMillis() : sinceMillis).addSeconds(-5);
        if (kind == 'quote') {
            List<Quote> quotes = [
                SELECT Id, QuoteNumber
                FROM Quote
                WHERE Opportunity.AccountId = :customer.accountId AND ContactId = :customer.contactId AND Submission_Channel__c = 'Online' AND CreatedDate >= :since
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (quotes.isEmpty()) {
                return null;
            }
            Receipt sent = new Receipt();
            sent.id = quotes[0].Id;
            sent.referenceNumber = quotes[0].QuoteNumber;
            sent.message = 'A licensed agent will confirm your price and contact you, usually within one business day. Nothing starts until you say yes.';
            return sent;
        }
        List<Case> filed = [
            SELECT Id, CaseNumber
            FROM Case
            WHERE AccountId = :customer.accountId AND ContactId = :customer.contactId AND RecordType.DeveloperName = :recordType AND Origin = 'Web' AND CreatedDate >= :since
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (filed.isEmpty()) {
            return null;
        }
        Receipt receipt = receiptFor(kind);
        receipt.id = filed[0].Id;
        receipt.referenceNumber = filed[0].CaseNumber;
        return receipt;
    }

    private static Receipt submit(String kind, String fieldsJson) {
        Customer customer = me();
        // Build it first, so anything missing or not theirs is refused while the customer is still on the form.
        build(customer, kind, fieldsJson);
        AntsurancePortalSubmissions.hand(kind, fieldsJson);
        Receipt receipt = receiptFor(kind);
        receipt.sentAt = System.currentTimeMillis();
        return receipt;
    }

    private static Receipt receiptFor(String kind) {
        Receipt receipt = new Receipt();
        receipt.message = kind == 'claim'
            ? 'An adjuster will contact you within one business day to confirm what happened and explain the next steps.'
            : 'Someone on our service team will follow up, usually within one business day.';
        return receipt;
    }

    /**
     * @description Builds the claim or service request a form describes, without saving it. Used twice: to
     * check a form before it is handed over, and to create the record when it is filed.
     * @param customer Who it is for
     * @param kind "claim", "driver" or "request"
     * @param fieldsJson The form's fields, by name
     * @return The record, ready to insert
     * @throws AuraHandledException when something needed is missing, or a policy named is not this customer's
     */
    public static Case build(Customer customer, String kind, String fieldsJson) {
        Map<String, String> fields = readFields(fieldsJson);
        Policy__c policy = ownedPolicy(customer, fields.get('policyId'));

        if (kind == 'claim') {
            if (policy == null) {
                throw fail('Choose the policy this claim is on.');
            }
            String happened = required(fields, 'whatHappened', 'Tell us what happened.');
            Date lossDate = toDate(fields.get('dateOfLoss'));
            if (lossDate == null) {
                throw fail('Tell us the date it happened.');
            }
            if (lossDate > Date.today()) {
                throw fail('The date it happened cannot be in the future.');
            }
            Case claim = newCase(customer, CLAIM, policy);
            String summary = fields.get('summary');
            claim.Subject = (String.isBlank(summary) ? happened : summary).abbreviate(80);
            claim.Description = lines(new List<String>{ 'Filed from the customer portal by ' + customer.name + '.', happened });
            claim.Date_of_Loss__c = lossDate;
            claim.Loss_Type__c = lossTypes().contains(fields.get('lossType')) ? fields.get('lossType') : 'Other';
            claim.Loss_Location__c = clip(fields.get('where'), 255);
            claim.Estimated_Loss__c = toMoney(fields.get('estimate'));
            return claim;
        }

        Case request = newCase(customer, SERVICE, policy);
        if (kind == 'driver') {
            String first = required(fields, 'firstName', 'Tell us the driver\'s first name.');
            String last = required(fields, 'lastName', 'Tell us the driver\'s last name.');
            request.Request_Type__c = 'Add Driver';
            request.Subject = ('Add ' + first + ' ' + last + ' as a driver').abbreviate(MAX_SHORT);
            request.Description = lines(
                new List<String>{
                    'Sent from the customer portal by ' + customer.name + '.',
                    'Driver: ' + first + ' ' + last,
                    labeled('Date of birth', fields.get('dateOfBirth')),
                    labeled('Relationship', fields.get('relationship')),
                    labeled('License number', fields.get('licenseNumber')),
                    labeled('License state', fields.get('licenseState')),
                    labeled('First licensed', fields.get('dateLicensed')),
                    labeled('Anything else', fields.get('details'))
                }
            );
        } else {
            String topic = fields.get('topic');
            String details = required(fields, 'details', 'Tell us what you would like changed or answered.');
            request.Request_Type__c = requestTopics().contains(topic) ? topic : null;
            request.Subject = ((String.isBlank(topic) ? 'Request from the customer portal' : topic) + ': ' + details.abbreviate(60)).abbreviate(MAX_SHORT);
            request.Description = lines(new List<String>{ 'Sent from the customer portal by ' + customer.name + '.', details });
        }
        return request;
    }

    // ------------------------------------------------------------------------------- the customer

    /**
     * @description The signed-in customer, worked out from the running user alone.
     * @return Their contact and account
     * @throws AuraHandledException when the running user is not a portal customer
     */
    public static Customer me() {
        return customerFor(UserInfo.getUserId());
    }

    /**
     * @description The customer a portal user is. Only AntsurancePortalSubmissions passes a user other than
     * the running one: the user who sent a form, taken from the platform, when it files that form.
     * @param userId The portal user
     * @return Their contact and account
     * @throws AuraHandledException when the user is not a portal customer
     */
    public static Customer customerFor(Id userId) {
        List<User> users = [
            SELECT ContactId, Contact.AccountId, Contact.FirstName, Contact.Name, Contact.Account.Name, Contact.Account.OwnerId
            FROM User
            WHERE Id = :userId
            WITH SYSTEM_MODE
        ];
        if (users.isEmpty() || users[0].ContactId == null || users[0].Contact.AccountId == null) {
            throw fail(NOT_A_CUSTOMER);
        }
        Customer customer = new Customer();
        customer.contactId = users[0].ContactId;
        customer.accountId = users[0].Contact.AccountId;
        customer.ownerId = users[0].Contact.Account.OwnerId;
        customer.firstName = users[0].Contact.FirstName;
        customer.name = users[0].Contact.Name;
        customer.householdName = users[0].Contact.Account.Name;
        return customer;
    }

    /**
     * @description The customer's policies. Every read of a policy goes through here, so the account filter cannot be skipped.
     * @param customer Who is asking
     * @param onlyId One policy, or null for all of them
     * @param withDetail Whether to load coverages, people, items and extras
     * @return The policies, in-force ones first
     */
    public static List<Policy> policiesFor(Customer customer, Id onlyId, Boolean withDetail) {
        List<Policy__c> records = [
            SELECT Id, Name, Line_of_Business__c, Insured_Item__c, Status__c, Annual_Premium__c, Billing_Frequency__c, Payment_Status__c,
                Effective_Date__c, Expiration_Date__c, Coverage_Limit__c, Deductible__c
            FROM Policy__c
            WHERE Account__c = :customer.accountId AND Status__c IN :SHOWN_POLICIES
            WITH SYSTEM_MODE
            ORDER BY Expiration_Date__c DESC NULLS LAST
        ];
        Set<Id> ids = new Set<Id>();
        Map<Id, Date> termStarts = new Map<Id, Date>();
        for (Policy__c record : records) {
            if (onlyId == null || record.Id == onlyId) {
                ids.add(record.Id);
                termStarts.put(record.Id, record.Effective_Date__c);
            }
        }

        // A renewal on offer shows what the premium will become.
        Map<Id, Decimal> renewals = new Map<Id, Decimal>();
        for (Opportunity sale : [SELECT Policy__c, Amount FROM Opportunity WHERE Policy__c IN :ids AND Type = 'Renewal' AND IsClosed = FALSE AND Amount != NULL WITH SYSTEM_MODE ORDER BY CreatedDate]) {
            renewals.put(sale.Policy__c, sale.Amount);
        }

        Map<Id, List<Coverage>> coverages = new Map<Id, List<Coverage>>();
        Map<Id, List<Person>> people = new Map<Id, List<Person>>();
        Map<Id, List<Item>> items = new Map<Id, List<Item>>();
        Map<Id, List<Extra>> extras = new Map<Id, List<Extra>>();
        Map<Id, List<BillLine>> billChanges = new Map<Id, List<BillLine>>();
        if (withDetail) {
            for (Policy_Coverage__c row : [
                SELECT Policy__c, Name, Limit_Amount__c, Limit_Type__c, Deductible_Amount__c, Premium_Amount__c, What_Is_Covered__c
                FROM Policy_Coverage__c
                WHERE Policy__c IN :ids
                WITH SYSTEM_MODE
                ORDER BY Premium_Amount__c DESC NULLS LAST
            ]) {
                Coverage coverage = new Coverage();
                coverage.name = row.Name;
                coverage.limitText = row.Limit_Amount__c == null ? row.Limit_Type__c : money(row.Limit_Amount__c) + (String.isBlank(row.Limit_Type__c) ? '' : ' ' + row.Limit_Type__c.toLowerCase());
                coverage.deductibleText = row.Deductible_Amount__c == null ? null : money(row.Deductible_Amount__c);
                coverage.premiumText = money(row.Premium_Amount__c);
                coverage.plainWords = row.What_Is_Covered__c == null ? null : row.What_Is_Covered__c.replace('**', '');
                coverage.deductibleWords = row.Deductible_Amount__c == null || row.Deductible_Amount__c == 0 ? null : 'You pay the first ' + money(row.Deductible_Amount__c);
                coverage.limitWords = limitInWords(row.Limit_Amount__c, row.Limit_Type__c, row.Deductible_Amount__c);
                add(coverages, row.Policy__c, coverage);
            }
            for (Policy_Participant__c row : [
                SELECT Policy__c, Contact__r.Name, Name, Role__c, Relationship_to_Insured__c
                FROM Policy_Participant__c
                WHERE Policy__c IN :ids AND Status__c = 'Active'
                WITH SYSTEM_MODE
                ORDER BY Is_Primary__c DESC, Name
            ]) {
                Person person = new Person();
                person.name = row.Contact__r?.Name == null ? row.Name : row.Contact__r.Name;
                person.role = row.Role__c;
                person.relationship = row.Relationship_to_Insured__c;
                add(people, row.Policy__c, person);
            }
            for (Policy_Asset__c row : [SELECT Policy__c, Name, Asset_Type__c, Use__c, Details__c FROM Policy_Asset__c WHERE Policy__c IN :ids WITH SYSTEM_MODE ORDER BY Name]) {
                Item item = new Item();
                item.name = row.Name;
                item.kind = row.Asset_Type__c;
                item.detail = String.isBlank(row.Details__c) ? row.Use__c : row.Details__c;
                add(items, row.Policy__c, item);
            }
            for (Policy_Endorsement__c row : [
                SELECT Policy__c, Name, Description__c, Premium_Change__c, Effective_Date__c
                FROM Policy_Endorsement__c
                WHERE Policy__c IN :ids AND Status__c = 'Active'
                WITH SYSTEM_MODE
                ORDER BY Name
            ]) {
                Extra extra = new Extra();
                extra.name = row.Name;
                extra.plainWords = row.Description__c == null ? null : row.Description__c.replace('**', '');
                extra.premiumChangeText = row.Premium_Change__c == null || row.Premium_Change__c == 0 ? null : signedMoney(row.Premium_Change__c) + ' a year';
                extra.addedText = longDate(row.Effective_Date__c);
                extra.premiumChange = row.Premium_Change__c == null ? 0 : row.Premium_Change__c;
                Date termStart = termStarts.get(row.Policy__c);
                extra.addedThisTerm = row.Effective_Date__c != null && termStart != null && row.Effective_Date__c > termStart;
                add(extras, row.Policy__c, extra);
                if (extra.premiumChangeText != null) {
                    BillLine change = new BillLine();
                    change.label = row.Name;
                    change.whenText = row.Effective_Date__c == null ? null : 'Since ' + longDate(row.Effective_Date__c);
                    change.amountText = extra.premiumChangeText;
                    if (!billChanges.containsKey(row.Policy__c)) {
                        billChanges.put(row.Policy__c, new List<BillLine>());
                    }
                    billChanges.get(row.Policy__c).add(change);
                }
            }
        }

        List<Policy> inForce = new List<Policy>();
        List<Policy> past = new List<Policy>();
        for (Policy__c record : records) {
            if (!ids.contains(record.Id)) {
                continue;
            }
            Policy policy = new Policy();
            policy.id = record.Id;
            policy.policyNumber = record.Name;
            policy.line = record.Line_of_Business__c;
            policy.insured = record.Insured_Item__c;
            policy.status = record.Status__c == 'Pending Renewal' ? 'Renewing soon' : record.Status__c;
            policy.inForce = IN_FORCE.contains(record.Status__c);
            policy.premium = record.Annual_Premium__c;
            policy.premiumText = money(record.Annual_Premium__c);
            policy.billing = record.Billing_Frequency__c;
            policy.payments = record.Payment_Status__c;
            policy.startsText = longDate(record.Effective_Date__c);
            policy.endsText = longDate(record.Expiration_Date__c);
            policy.daysToRenewal = record.Expiration_Date__c == null ? null : Date.today().daysBetween(record.Expiration_Date__c);
            policy.limitText = money(record.Coverage_Limit__c);
            policy.deductibleText = record.Deductible__c == null || record.Deductible__c == 0 ? null : money(record.Deductible__c);
            policy.plainName = plainName(record.Line_of_Business__c, record.Insured_Item__c);
            policy.monthlyText = record.Annual_Premium__c == null ? null : 'about ' + money(record.Annual_Premium__c / 12) + ' a month';
            policy.timeLeftText = policy.daysToRenewal == null || !policy.inForce
                ? null
                : policy.daysToRenewal < 0 ? 'Term has ended' : policy.daysToRenewal == 1 ? '1 day left in this term' : policy.daysToRenewal + ' days left in this term';
            Decimal renewal = renewals.get(record.Id);
            if (renewal != null && record.Annual_Premium__c != null) {
                Decimal change = renewal - record.Annual_Premium__c;
                policy.renewalPremiumText = money(renewal);
                policy.renewalChangeText = change == 0 ? 'no change' : (change > 0 ? 'up ' : 'down ') + money(Math.abs(change));
            }
            policy.coverages = coverages.containsKey(record.Id) ? coverages.get(record.Id) : new List<Coverage>();
            policy.people = people.containsKey(record.Id) ? people.get(record.Id) : new List<Person>();
            policy.items = items.containsKey(record.Id) ? items.get(record.Id) : new List<Item>();
            policy.extras = extras.containsKey(record.Id) ? extras.get(record.Id) : new List<Extra>();
            if (withDetail && policy.inForce) {
                policy.bill = billFor(record, billChanges.get(record.Id), policy);
            }
            (policy.inForce ? inForce : past).add(policy);
        }
        inForce.addAll(past);
        return inForce;
    }

    /**
     * @description The customer's claims, open ones first. Every read of a claim goes through here.
     * @param customer Who is asking
     * @param onlyId One claim, or null for all of them
     * @return The claims
     */
    public static List<Claim> claimsFor(Customer customer, Id onlyId) {
        List<Claim> claims = new List<Claim>();
        for (Case record : [
            SELECT Id, CaseNumber, Subject, Status, IsClosed, Policy__c, Policy__r.Name, Policy__r.Line_of_Business__c, Reported_Date__c, Date_of_Loss__c, Paid_Amount__c, Handled_By__c
            FROM Case
            WHERE AccountId = :customer.accountId AND RecordType.DeveloperName = :CLAIM
            WITH SYSTEM_MODE
            ORDER BY IsClosed, Reported_Date__c DESC NULLS LAST
            LIMIT 25
        ]) {
            if (onlyId != null && record.Id != onlyId) {
                continue;
            }
            Claim claim = new Claim();
            claim.id = record.Id;
            claim.claimNumber = record.CaseNumber;
            claim.title = record.Subject;
            claim.policyId = record.Policy__c;
            claim.policyNumber = record.Policy__r?.Name;
            claim.policyLine = record.Policy__r?.Line_of_Business__c;
            claim.isOpen = !record.IsClosed;
            claim.reportedText = longDate(record.Reported_Date__c);
            claim.lossDateText = longDate(record.Date_of_Loss__c);
            claim.paidText = record.Paid_Amount__c == null || record.Paid_Amount__c == 0 ? null : money(record.Paid_Amount__c);
            claim.handler = record.Handled_By__c;
            describeProgress(claim, record.Status);
            claims.add(claim);
        }
        return claims;
    }

    /**
     * @description The customer's service requests, open ones first.
     * @param customer Who is asking
     * @return The requests
     */
    public static List<Request> requestsFor(Customer customer) {
        List<Request> requests = new List<Request>();
        for (Case record : [
            SELECT Id, CaseNumber, Subject, Status, IsClosed, Request_Type__c, Reported_Date__c, CreatedDate, Policy__r.Name
            FROM Case
            WHERE AccountId = :customer.accountId AND RecordType.DeveloperName = :SERVICE
            WITH SYSTEM_MODE
            ORDER BY IsClosed, CreatedDate DESC
            LIMIT 25
        ]) {
            requests.add(toRequest(record));
        }
        return requests;
    }

    private static Request toRequest(Case record) {
        Map<String, String> words = new Map<String, String>{
            'New' => 'Received',
            'In Progress' => 'Being worked on',
            'Working' => 'Being worked on',
            'Waiting on Customer' => 'Waiting on you',
            'Escalated' => 'Being worked on',
            'Closed' => 'Done'
        };
        Request request = new Request();
        request.id = record.Id;
        request.requestNumber = record.CaseNumber;
        request.title = record.Subject;
        request.topic = record.Request_Type__c;
        request.statusWord = words.containsKey(record.Status) ? words.get(record.Status) : record.Status;
        request.isOpen = !record.IsClosed;
        request.openedText = longDate(record.Reported_Date__c == null ? record.CreatedDate.date() : record.Reported_Date__c);
        request.policyNumber = record.Policy__r?.Name;
        return request;
    }

    /**
     * @description A policy the customer may act on, or null when no policy was named.
     * @param customer Who is asking
     * @param policyId The policy named by the form, as text
     * @return The policy
     * @throws AuraHandledException when the Id is not one of this customer's policies
     */
    public static Policy__c ownedPolicy(Customer customer, String policyId) {
        if (String.isBlank(policyId)) {
            return null;
        }
        if (!(policyId instanceof Id)) {
            throw fail(NOT_YOURS);
        }
        List<Policy__c> found = [SELECT Id, Name, Line_of_Business__c FROM Policy__c WHERE Id = :policyId AND Account__c = :customer.accountId WITH SYSTEM_MODE];
        if (found.isEmpty()) {
            throw fail(NOT_YOURS);
        }
        return found[0];
    }

    /**
     * What is due and what has been paid on a policy in force, from its yearly price, how often it is billed
     * and whether payments are up to date. Payments fall on the day of the month the term started.
     */
    private static Bill billFor(Policy__c record, List<BillLine> changes, Policy policy) {
        Bill bill = new Bill();
        bill.changes = changes == null ? new List<BillLine>() : changes;
        bill.basis = 'Worked out from your policy\'s yearly price, how it is billed and whether your payments are up to date. For a receipt, ask our team.';
        Decimal premium = record.Annual_Premium__c;
        Date starts = record.Effective_Date__c;
        if (premium == null || starts == null) {
            bill.headline = 'We cannot show a bill for this policy here.';
            return bill;
        }
        Map<String, Integer> perYear = new Map<String, Integer>{ 'Annual' => 1, 'Semi-Annual' => 2, 'Quarterly' => 4, 'Monthly' => 12 };
        Integer payments = perYear.containsKey(record.Billing_Frequency__c) ? perYear.get(record.Billing_Frequency__c) : 1;
        Decimal each = premium / payments;
        Integer monthsApart = 12 / payments;
        Integer due = 0;
        Date next;
        for (Integer index = 0; index < payments; index++) {
            Date falls = starts.addMonths(index * monthsApart);
            if (falls <= Date.today()) {
                due++;
            } else if (next == null) {
                next = falls;
            }
        }
        Boolean paidInFull = record.Payment_Status__c == 'Paid in Full';
        bill.isBehind = record.Payment_Status__c == 'Past Due';
        Integer made = paidInFull ? payments : bill.isBehind ? Math.max(due - 1, 0) : due;

        bill.headline = money(premium) + ' for the year';
        if (payments > 1) {
            bill.eachText = money(each);
            bill.everyWords = new Map<Integer, String>{ 2 => 'Every six months', 4 => 'Each quarter', 12 => 'Each month' }.get(payments);
        }
        if (!paidInFull && !bill.isBehind && next != null) {
            bill.nextDay = next;
            bill.nextDateText = longDate(next);
        }
        bill.schedule = payments == 1
            ? 'One payment for the year'
            : payments + ' payments of about ' + money(each) + ', ' + new Map<Integer, String>{ 2 => 'six months apart', 4 => 'one each quarter', 12 => 'one each month' }.get(payments);
        if (paidInFull) {
            // One row says it: the price for the year, paid, nothing more due.
            bill.standing = 'Paid in full';
            bill.schedule = 'Paid in full. Nothing more is due this term.';
        } else {
            bill.standing = bill.isBehind ? 'A payment is past due' : 'Up to date';
            bill.paidSoFar = payments == 1
                ? (made == 1 ? money(premium) : 'Nothing yet')
                : made + ' of ' + payments + ' payments, about ' + money(each * made);
            bill.nextDue = bill.isBehind
                ? 'About ' + money(each) + ' is past due. Pay it, or ask us about it, to keep your cover in place'
                : next == null ? 'Nothing more is due this term' : 'About ' + money(each) + ' on ' + longDate(next);
        }
        bill.changeNote = policy.renewalPremiumText == null
            ? (bill.changes.isEmpty() ? 'Nothing has changed your price this term.' : null)
            : 'At renewal on ' + policy.endsText + ' your price becomes ' + policy.renewalPremiumText + ' a year, ' + policy.renewalChangeText + '.';
        return bill;
    }

    /** A policy named the way its owner would: by what it protects. */
    private static String plainName(String line, String insured) {
        String kind = line == null ? 'Policy' : line.contains('Auto') ? 'Auto policy' : line == 'Homeowners' ? 'Home policy' : line + ' policy';
        if (String.isBlank(insured)) {
            return kind;
        }
        if (line == 'Umbrella') {
            return 'Umbrella policy: extra liability cover over your other policies';
        }
        return kind + ' for ' + (line != null && line.contains('Auto') ? 'your ' : '') + insured;
    }

    /** A limit as a person would say it. Insurance shorthand such as "actual cash value" is spelled out. */
    private static String limitInWords(Decimal amount, String basis, Decimal deductible) {
        if (basis == 'Actual Cash Value') {
            return deductible == null || deductible == 0 ? 'The vehicle\'s value at the time of the loss' : 'The vehicle\'s value at the time, less your ' + money(deductible) + ' deductible';
        }
        if (basis == 'Statutory') {
            return 'As state law requires';
        }
        if (amount == null) {
            return null;
        }
        if (basis == 'Per Person') {
            return 'Up to ' + money(amount) + ' for each person';
        }
        if (basis == 'Per Occurrence') {
            return 'Up to ' + money(amount) + ' for each incident';
        }
        if (basis == 'Aggregate') {
            return 'Up to ' + money(amount) + ' in total for the term';
        }
        if (basis == 'Replacement Cost') {
            return 'Up to ' + money(amount) + ', at the cost to repair or replace';
        }
        return 'Up to ' + money(amount);
    }

    /** The request topics the service team uses. */
    public static Set<String> requestTopics() {
        return picklist(Case.Request_Type__c);
    }

    /** The kinds of loss the claims team uses. */
    public static Set<String> lossTypes() {
        return picklist(Case.Loss_Type__c);
    }

    // ------------------------------------------------------------------------------- helpers

    /** The customer's words for where a claim stands. Internal statuses and reserves stay internal. */
    private static void describeProgress(Claim claim, String status) {
        List<String> labels = new List<String>{ 'Reported', 'Being reviewed', 'Estimate', 'Payment', 'Closed' };
        Map<String, Integer> position = new Map<String, Integer>{ 'New' => 0, 'Under Investigation' => 1, 'Appraisal' => 2, 'Approved' => 3, 'Payment Issued' => 3, 'Closed' => 4, 'Denied' => 4 };
        Map<String, String> updates = new Map<String, String>{
            'New' => 'We have your claim. An adjuster will contact you within one business day.',
            'Under Investigation' => 'Your adjuster is reviewing what happened and confirming your coverage.',
            'Appraisal' => 'The damage is being valued. Your adjuster will share the estimate with you.',
            'Approved' => 'Your claim is approved and your payment is being prepared.',
            'Payment Issued' => 'Your payment has been sent. Tell us once it arrives so we can close the claim.',
            'Closed' => 'This claim is settled and closed.',
            'Denied' => 'We were not able to cover this claim. Your adjuster\'s letter explains why, and you can ask us to look again.'
        };
        Integer current = position.containsKey(status) ? position.get(status) : 1;
        claim.statusWord = status == 'Denied' ? 'Not covered' : status == 'Payment Issued' ? 'Payment sent' : labels[current];
        claim.lastUpdate = updates.containsKey(status) ? updates.get(status) : 'Your adjuster is working on your claim.';
        claim.steps = new List<Step>();
        for (Integer index = 0; index < labels.size(); index++) {
            Step step = new Step();
            step.label = index == 4 && status == 'Denied' ? 'Decision' : labels[index];
            step.state = index < current || status == 'Closed' || status == 'Denied' ? 'done' : index == current ? 'current' : 'todo';
            claim.steps.add(step);
        }
    }

    /** Six or seven things worth asking, drawn from what is on the account, the likeliest first. */
    private static List<String> suggestionsFor(Customer customer, Home home) {
        List<String> suggestions = new List<String>();
        Policy auto;
        Policy soonest;
        Boolean billRising = false;
        for (Policy policy : home.policies) {
            if (!policy.inForce) {
                continue;
            }
            if (auto == null && policy.line != null && policy.line.contains('Auto')) {
                auto = policy;
            }
            if (policy.daysToRenewal != null && policy.daysToRenewal >= 0 && (soonest == null || policy.daysToRenewal < soonest.daysToRenewal)) {
                soonest = policy;
            }
            billRising = billRising || (policy.renewalChangeText != null && policy.renewalChangeText.startsWith('up'));
        }
        // Only a question the record can answer leads: a renewal offer explains a rise; otherwise what is paid and when.
        suggestions.add(billRising ? 'Why is my bill going up?' : 'What do I pay, and when?');
        if (auto != null) {
            // Someone in the household who is not yet a driver on the auto policy is the likeliest request.
            Set<Id> drivers = new Set<Id>();
            for (Policy_Participant__c driver : [SELECT Contact__c FROM Policy_Participant__c WHERE Policy__c = :auto.id AND Role__c = 'Driver' WITH SYSTEM_MODE]) {
                drivers.add(driver.Contact__c);
            }
            String someone;
            for (Contact member : [SELECT Id, FirstName FROM Contact WHERE AccountId = :customer.accountId AND Id != :customer.contactId WITH SYSTEM_MODE ORDER BY Birthdate DESC NULLS LAST, CreatedDate DESC]) {
                if (!drivers.contains(member.Id)) {
                    someone = member.FirstName;
                    break;
                }
            }
            suggestions.add(someone == null ? 'Add a driver to my auto policy' : 'Add ' + someone + ' to my auto policy');
        } else {
            suggestions.add('What does my policy cover?');
        }
        suggestions.add('I need to file a claim');
        suggestions.add(soonest == null || soonest.line == null ? 'What am I covered for?' : 'When does my ' + soonest.line.toLowerCase() + ' policy renew?');
        // Then the questions the page's own cards raise: a claim that is open, what the main policy covers, a new quote.
        Boolean hasOpenClaim = false;
        for (Claim claim : home.claims ?? new List<Claim>()) {
            hasOpenClaim = hasOpenClaim || claim.isOpen == true;
        }
        if (hasOpenClaim) {
            suggestions.add('Where does my claim stand?');
        }
        if (auto != null) {
            suggestions.add('What does my auto policy cover?');
        } else if (soonest != null && soonest.line != null) {
            suggestions.add('What does my ' + soonest.line.toLowerCase() + ' policy cover?');
        }
        suggestions.add('Get a quote for another policy');
        return suggestions;
    }

    /** A new claim or request on the customer's account, owned by the person who looks after the account. */
    private static Case newCase(Customer customer, String recordType, Policy__c policy) {
        Case record = new Case();
        record.RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get(recordType).getRecordTypeId();
        record.AccountId = customer.accountId;
        record.ContactId = customer.contactId;
        record.OwnerId = customer.ownerId;
        record.Policy__c = policy?.Id;
        record.Origin = 'Web';
        record.Status = 'New';
        record.Reported_Date__c = Date.today();
        return record;
    }

    /** The form's fields as trimmed text, with anything oversized cut down. */
    private static Map<String, String> readFields(String fieldsJson) {
        Map<String, String> fields = new Map<String, String>();
        if (String.isBlank(fieldsJson)) {
            return fields;
        }
        Map<String, Object> raw;
        try {
            raw = (Map<String, Object>) JSON.deserializeUntyped(fieldsJson);
        } catch (Exception e) {
            throw fail('That form could not be read. Refresh the page and try again.');
        }
        for (String name : raw.keySet()) {
            Object value = raw.get(name);
            if (value != null && String.isNotBlank(String.valueOf(value))) {
                fields.put(name, clip(String.valueOf(value).trim(), MAX_TEXT));
            }
        }
        return fields;
    }

    private static String required(Map<String, String> fields, String name, String message) {
        if (String.isBlank(fields.get(name))) {
            throw fail(message);
        }
        return fields.get(name);
    }

    private static String labeled(String label, String value) {
        return String.isBlank(value) ? null : label + ': ' + value;
    }

    private static String lines(List<String> parts) {
        List<String> kept = new List<String>();
        for (String part : parts) {
            if (String.isNotBlank(part)) {
                kept.add(part);
            }
        }
        return clip(String.join(kept, '\n'), 30000);
    }

    private static String clip(String value, Integer length) {
        return value == null ? null : value.left(length);
    }

    private static Date toDate(String value) {
        try {
            return String.isBlank(value) ? null : Date.valueOf(value.left(10));
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal toMoney(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            Decimal amount = Decimal.valueOf(value.replaceAll('[^0-9.]', ''));
            return amount < 0 || amount > 100000000 ? null : amount.setScale(2);
        } catch (Exception e) {
            return null;
        }
    }

    private static Set<String> picklist(Schema.SObjectField field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    private static void add(Map<Id, List<Coverage>> grouped, Id key, Coverage value) {
        if (!grouped.containsKey(key)) {
            grouped.put(key, new List<Coverage>());
        }
        grouped.get(key).add(value);
    }

    private static void add(Map<Id, List<Person>> grouped, Id key, Person value) {
        if (!grouped.containsKey(key)) {
            grouped.put(key, new List<Person>());
        }
        grouped.get(key).add(value);
    }

    private static void add(Map<Id, List<Item>> grouped, Id key, Item value) {
        if (!grouped.containsKey(key)) {
            grouped.put(key, new List<Item>());
        }
        grouped.get(key).add(value);
    }

    private static void add(Map<Id, List<Extra>> grouped, Id key, Extra value) {
        if (!grouped.containsKey(key)) {
            grouped.put(key, new List<Extra>());
        }
        grouped.get(key).add(value);
    }

    /** Whole dollars, as "$2,380". */
    public static String money(Decimal amount) {
        return amount == null ? null : '$' + amount.setScale(0, System.RoundingMode.HALF_UP).format();
    }

    private static String signedMoney(Decimal amount) {
        return (amount < 0 ? '-' : '+') + money(Math.abs(amount));
    }

    /** A date as "May 15, 2027". */
    public static String longDate(Date value) {
        return value == null ? null : Datetime.newInstance(value, Time.newInstance(12, 0, 0, 0)).format('MMM d, yyyy');
    }

    public static AuraHandledException fail(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
