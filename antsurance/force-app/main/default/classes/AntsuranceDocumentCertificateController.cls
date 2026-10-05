/**
 * @description Prepares a certificate of insurance for a commercial customer
 * (AntsuranceDocumentCertificate): the insured, the producer, every liability policy in force for
 * that customer with its limits, and the holder the certificate is made out to. The layout and the
 * wording are Antsurance's own. The customer and its policies are read as the running user.
 */
public with sharing class AntsuranceDocumentCertificateController {
    // The lines a certificate of liability insurance covers, in the order they print, with how each is named.
    private static final Map<String, String> LIABILITY_LINES = new Map<String, String>{
        'General Liability' => 'Commercial general liability',
        'Commercial Auto' => 'Business auto liability',
        'Umbrella' => 'Umbrella liability',
        'Workers Compensation' => 'Workers compensation and employers liability'
    };
    private static final Set<String> IN_FORCE = new Set<String>{ 'Active', 'Pending Renewal' };
    // Cover for the insured's own property and vehicles, which a liability certificate leaves out.
    private static final Set<String> FIRST_PARTY = new Set<String>{ 'Collision', 'Comprehensive', 'Business Property', 'Business Income', 'Dwelling', 'Personal Property' };
    private static final String REMOVED = 'Removed';
    private static final String DEFAULT_HOLDER = 'To whom it may concern';
    private static final String DEFAULT_HOLDER_LINE = 'Issued for information only';
    private static final Integer MAX_NAME = 44;
    private static final Integer MAX_HOLDER = 46;
    private static final Integer STATEMENT_LINE_LENGTH = 126;
    private static final Integer NOTICE_LINE_LENGTH = 150;

    // Heights in points, measured from the printed page, for deciding where page breaks fall.
    private static final Decimal TOP_HEIGHT = 300;
    private static final Decimal COLUMN_HEADS_HEIGHT = 53;
    private static final Decimal POLICY_ROW_HEIGHT = 24;
    private static final Decimal LIMIT_ROW_HEIGHT = 17;
    private static final Decimal ENDING_HEIGHT = 150;

    /** One limit on a policy. */
    public class LimitLine {
        public String label { get; set; }
        /** How the limit applies: per occurrence, aggregate and so on. */
        public String basis { get; set; }
        public String amount { get; set; }
    }

    /** One policy in force, with its limits. */
    public class PolicyBlock {
        public String insuranceType { get; set; }
        public String policyNumber { get; set; }
        public String period { get; set; }
        public List<LimitLine> limits { get; set; }
        /** The block's style class, which carries the page break when it starts a new page. */
        public String blockClass { get; set; }
    }

    public Boolean found { get; private set; }
    /** Why there is no certificate, when there is none. */
    public String notice { get; private set; }
    public String certificateNumber { get; private set; }
    public String issueDate { get; private set; }
    public String insuredName { get; private set; }
    public List<String> insuredLines { get; private set; }
    public String producerName { get; private set; }
    public List<String> producerLines { get; private set; }
    public List<String> statementLines { get; private set; }
    public List<PolicyBlock> policies { get; private set; }
    public String operations { get; private set; }
    public String holderName { get; private set; }
    public List<String> holderLines { get; private set; }
    public List<String> cancellationLines { get; private set; }
    public String documentLabel { get; private set; }
    public String endingClass { get; private set; }

    /**
     * @description Builds the certificate for the customer named by the page's id parameter, which
     * is a commercial policy or the customer account itself. The holder comes from the holder and
     * holderAddress parameters. A customer with no liability policy in force leaves found false.
     */
    public AntsuranceDocumentCertificateController() {
        found = false;
        documentLabel = 'Certificate of insurance';
        Map<String, String> parameters = ApexPages.currentPage().getParameters();
        Id accountId = findAccountId(parameters.get('id'));
        Account customer = accountId == null ? null : findCustomer(accountId);
        if (customer == null) {
            notice = 'This customer could not be found.';
            return;
        }
        List<Policy__c> inForce = findPolicies(customer.Id);
        if (inForce.isEmpty()) {
            notice = 'This customer has no liability policy in force to certify.';
            return;
        }
        describeParties(customer, inForce);
        describePolicies(inForce);
        describeHolder(parameters.get('holder'), parameters.get('holderAddress'));
        layOut();
        found = true;

        String disposition = parameters.get('download') == '1' ? 'attachment' : 'inline';
        String fileName = 'Certificate-' + AntsuranceDocumentFormat.fileSafe(customer.Name) + '.pdf';
        ApexPages.currentPage().getHeaders().put('content-disposition', disposition + '; filename=' + fileName);
    }

    /**
     * @description Whether a customer has a liability policy in force, and so can be issued a certificate.
     * @param accountId The customer account
     * @return True when there is at least one such policy the running user can see
     */
    public static Boolean isAvailableFor(Id accountId) {
        return accountId != null && !findPolicies(accountId).isEmpty();
    }

    private static Id findAccountId(String recordId) {
        if (!(recordId instanceof Id)) {
            return null;
        }
        Schema.SObjectType objectType = ((Id) recordId).getSObjectType();
        if (objectType == Account.SObjectType) {
            return (Id) recordId;
        }
        if (objectType != Policy__c.SObjectType) {
            return null;
        }
        List<Policy__c> policies = [SELECT Account__c FROM Policy__c WHERE Id = :recordId WITH USER_MODE LIMIT 1];
        return policies.isEmpty() ? null : policies[0].Account__c;
    }

    private static Account findCustomer(Id accountId) {
        List<Account> customers = [
            SELECT Name, BillingStreet, BillingCity, BillingState, BillingPostalCode
            FROM Account
            WHERE Id = :accountId
            WITH USER_MODE
            LIMIT 1
        ];
        return customers.isEmpty() ? null : customers[0];
    }

    private static List<Policy__c> findPolicies(Id accountId) {
        Map<String, List<Policy__c>> byLine = new Map<String, List<Policy__c>>();
        for (Policy__c policy : [
            SELECT
                Name, Line_of_Business__c, Effective_Date__c, Expiration_Date__c, Insured_Item__c, Producer__r.Name, Producer__r.Phone,
                Producer__r.BillingCity, Producer__r.BillingState,
                (SELECT Name, Category__c, Status__c, Limit_Amount__c, Limit_Type__c FROM Coverages__r ORDER BY CreatedDate, Id)
            FROM Policy__c
            WHERE Account__c = :accountId AND Line_of_Business__c IN :LIABILITY_LINES.keySet() AND Status__c IN :IN_FORCE
            WITH USER_MODE
            ORDER BY Effective_Date__c, Name
        ]) {
            if (!byLine.containsKey(policy.Line_of_Business__c)) {
                byLine.put(policy.Line_of_Business__c, new List<Policy__c>());
            }
            byLine.get(policy.Line_of_Business__c).add(policy);
        }
        List<Policy__c> ordered = new List<Policy__c>();
        for (String line : LIABILITY_LINES.keySet()) {
            if (byLine.containsKey(line)) {
                ordered.addAll(byLine.get(line));
            }
        }
        return ordered;
    }

    private void describeParties(Account customer, List<Policy__c> inForce) {
        Date today = Date.today();
        issueDate = AntsuranceDocumentFormat.longDate(today);
        // Reads as a serial number: the first policy's digits, then the day of issue.
        certificateNumber = 'COI-' + inForce[0].Name.replaceAll('[^0-9]', '') + '-' + DateTime.newInstance(today, Time.newInstance(12, 0, 0, 0)).format('yyMMdd');
        documentLabel = 'Certificate ' + certificateNumber;

        insuredName = customer.Name.abbreviate(MAX_NAME);
        insuredLines = addressLines(customer.BillingStreet, customer.BillingCity, AntsuranceAddress.state(customer, 'Billing'), customer.BillingPostalCode);

        Account producer = inForce[0].Producer__r;
        producerName = producer == null ? 'Antsurance Direct' : producer.Name.abbreviate(MAX_NAME);
        producerLines = new List<String>();
        if (producer == null) {
            producerLines.add('Sold and serviced by Antsurance');
            producerLines.add('1-800-555-0100');
        } else {
            producerLines.addAll(addressLines(null, producer.BillingCity, AntsuranceAddress.state(producer, 'Billing'), null));
            if (String.isNotBlank(producer.Phone)) {
                producerLines.add(producer.Phone);
            }
        }

        statementLines = AntsuranceDocumentFormat.wrap(
            'Antsurance Insurance Company confirms that the policies listed below are in force for the insured on the date of issue. ' +
            'This certificate is a summary for the holder. It does not change, extend or replace any policy, and each policy\'s own ' +
            'terms, conditions and exclusions decide what is covered. Claims already paid may have reduced the limits shown.',
            STATEMENT_LINE_LENGTH
        );
        cancellationLines = AntsuranceDocumentFormat.wrap(
            'If a policy listed here is cancelled before it expires, Antsurance sends notice to the insured as that policy requires. ' +
            'The holder is sent notice only when an endorsement to the policy says so.',
            NOTICE_LINE_LENGTH
        );

        // What the business does, as the general liability policy describes it.
        operations = null;
        for (Policy__c policy : inForce) {
            if (String.isNotBlank(policy.Insured_Item__c)) {
                operations = policy.Insured_Item__c.abbreviate(110);
                break;
            }
        }
        if (operations == null) {
            operations = 'All operations of the insured';
        }
    }

    private static List<String> addressLines(String street, String city, String stateCode, String postalCode) {
        List<String> lines = new List<String>();
        if (String.isNotBlank(street)) {
            lines.add(street.replaceAll('\\s*[\\r\\n]+\\s*', ', ').abbreviate(54));
        }
        String cityLine = String.join(AntsuranceDocumentFormat.present(new List<String>{ city, stateCode }), ', ');
        cityLine = String.join(AntsuranceDocumentFormat.present(new List<String>{ cityLine, postalCode }), ' ');
        if (String.isNotBlank(cityLine)) {
            lines.add(cityLine);
        }
        return lines;
    }

    private void describePolicies(List<Policy__c> inForce) {
        policies = new List<PolicyBlock>();
        for (Policy__c policy : inForce) {
            PolicyBlock block = new PolicyBlock();
            block.insuranceType = LIABILITY_LINES.get(policy.Line_of_Business__c);
            block.policyNumber = policy.Name;
            block.period = AntsuranceDocumentFormat.longDate(policy.Effective_Date__c) + ' to ' + AntsuranceDocumentFormat.longDate(policy.Expiration_Date__c);
            block.limits = new List<LimitLine>();
            for (Policy_Coverage__c coverage : policy.Coverages__r) {
                if (coverage.Status__c == REMOVED || FIRST_PARTY.contains(coverage.Category__c)) {
                    continue;
                }
                LimitLine line = new LimitLine();
                Boolean isStatutory = coverage.Limit_Amount__c == null && (coverage.Limit_Type__c == 'Statutory' || coverage.Category__c == 'Workers Compensation');
                line.label = coverage.Name.replaceAll('(?i)\\s*\\(statutory\\)', '').abbreviate(60);
                line.amount = isStatutory ? 'Statutory' : AntsuranceDocumentFormat.money(coverage.Limit_Amount__c, 0, 'Included');
                if (isStatutory) {
                    line.basis = 'As state law requires';
                } else {
                    line.basis = coverage.Limit_Type__c == null ? '' : basis(coverage.Limit_Type__c);
                }
                block.limits.add(line);
            }
            policies.add(block);
        }
    }

    private static String basis(String limitType) {
        String text = limitType.toLowerCase();
        return text.startsWith('per ') ? 'Each ' + text.removeStart('per ') : text.capitalize();
    }

    private void describeHolder(String name, String address) {
        Boolean isNamed = String.isNotBlank(name);
        holderName = (isNamed ? name.normalizeSpace() : DEFAULT_HOLDER).abbreviate(MAX_HOLDER);
        holderLines = new List<String>();
        if (String.isNotBlank(address)) {
            // An address typed on one line breaks before the city: street, then city, state and ZIP.
            String oneLine = address.normalizeSpace();
            Integer comma = oneLine.indexOf(', ');
            if (comma > 0 && oneLine.length() > MAX_HOLDER) {
                holderLines.add(oneLine.substring(0, comma).abbreviate(MAX_HOLDER));
                holderLines.add(oneLine.substring(comma + 2).abbreviate(MAX_HOLDER));
            } else {
                holderLines.add(oneLine.abbreviate(MAX_HOLDER));
            }
        } else if (!isNamed) {
            holderLines.add(DEFAULT_HOLDER_LINE);
        }
    }

    /** Decides where the page breaks go: a policy that does not fit starts a new page with its limits. */
    private void layOut() {
        AntsuranceDocumentLayout layout = new AntsuranceDocumentLayout(TOP_HEIGHT + COLUMN_HEADS_HEIGHT);
        for (PolicyBlock block : policies) {
            Boolean newPage = layout.place(POLICY_ROW_HEIGHT + block.limits.size() * LIMIT_ROW_HEIGHT);
            block.blockClass = newPage ? 'policy new-page' : 'policy';
        }
        endingClass = layout.place(ENDING_HEIGHT) ? 'ending new-page' : 'ending';
    }
}
