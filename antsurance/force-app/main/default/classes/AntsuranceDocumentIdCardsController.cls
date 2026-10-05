/**
 * @description Prepares the insurance ID cards for an auto policy (AntsuranceDocumentIdCards): two
 * wallet-size cards for each insured vehicle, to cut out and keep in the vehicle. Below the cards the
 * page prints what to do after an accident and the policy's coverages, when there is room for them.
 * The policy, its vehicles, insureds and coverages are read as the running user.
 */
public with sharing class AntsuranceDocumentIdCardsController {
    private static final Set<String> AUTO_LINES = new Set<String>{ 'Personal Auto', 'Commercial Auto' };
    private static final Set<String> VEHICLE_TYPES = new Set<String>{ 'Vehicle', 'Fleet' };
    private static final String REMOVED = 'Removed';
    private static final Integer VIN_LENGTH = 17;
    private static final Integer MAX_INSURED = 44;
    private static final Integer MAX_VEHICLE = 40;

    // Heights in points, measured from the printed page, for deciding where page breaks fall.
    private static final Decimal TOP_HEIGHT = 150;
    private static final Decimal CARD_ROW_HEIGHT = 170;
    private static final Decimal STEPS_HEIGHT = 112;
    private static final Decimal COVERAGE_HEADING_HEIGHT = 53;
    private static final Decimal COVERAGE_ROW_HEIGHT = 24.5;

    /** One vehicle's card. The page prints it twice, side by side. */
    public class Card {
        public String vehicle { get; set; }
        public String vin { get; set; }
        /** The two copies of the card, each with the width of the gap printed before it. */
        public List<Copy> copies { get; set; }
        /** The row's style class, which carries the page break when this row starts a new page. */
        public String rowClass { get; set; }
    }

    /** One printed copy of a card. */
    public class Copy {
        public String gapWidth { get; set; }
    }

    /** One coverage on the policy, for the summary under the cards. */
    public class CoverageLine {
        public String name { get; set; }
        public String limitText { get; set; }
        public String deductible { get; set; }
    }

    public Boolean found { get; private set; }
    /** Why there are no cards, when there are none. */
    public String notice { get; private set; }
    public String policyNumber { get; private set; }
    public String lineOfBusiness { get; private set; }
    public String insured { get; private set; }
    public String effective { get; private set; }
    public String expires { get; private set; }
    public String policyPeriod { get; private set; }
    public String state { get; private set; }
    public String agentName { get; private set; }
    public String agentPhone { get; private set; }
    public String documentLabel { get; private set; }
    public List<Card> cards { get; private set; }
    public List<CoverageLine> coverages { get; private set; }
    /** The accident steps and the coverage summary print only when the last page has room for them. */
    public Boolean showSteps { get; private set; }
    public Boolean showCoverages { get; private set; }

    /**
     * @description Loads the policy named by the page's id parameter. Anything but an auto policy
     * with at least one vehicle leaves found false, and the page prints a short notice instead.
     */
    public AntsuranceDocumentIdCardsController() {
        found = false;
        showSteps = false;
        showCoverages = false;
        lineOfBusiness = 'Auto';
        documentLabel = 'Insurance ID cards';
        Map<String, String> parameters = ApexPages.currentPage().getParameters();
        Policy__c policy = findPolicy(parameters.get('id'));
        if (policy == null) {
            notice = 'This policy could not be found.';
            return;
        }
        if (!AUTO_LINES.contains(policy.Line_of_Business__c)) {
            notice = 'ID cards are issued for auto policies only.';
            return;
        }
        describePolicy(policy);
        describeCards(policy);
        if (cards.isEmpty()) {
            notice = 'This policy has no vehicles to issue ID cards for.';
            return;
        }
        describeCoverages(policy);
        layOut();
        found = true;

        String disposition = parameters.get('download') == '1' ? 'attachment' : 'inline';
        String fileName = 'ID-Cards-' + AntsuranceDocumentFormat.fileSafe(policy.Name) + '.pdf';
        ApexPages.currentPage().getHeaders().put('content-disposition', disposition + '; filename=' + fileName);
    }

    private static Policy__c findPolicy(String recordId) {
        if (!(recordId instanceof Id) || ((Id) recordId).getSObjectType() != Policy__c.SObjectType) {
            return null;
        }
        List<Policy__c> policies = [
            SELECT
                Name, Line_of_Business__c, Effective_Date__c, Expiration_Date__c, Primary_Insured__r.Name, Producer__r.Name, Producer__r.Phone,
                Account__r.Name, Account__r.RecordType.DeveloperName, Account__r.BillingState,
                (SELECT Name, Asset_Type__c, Identifier__c FROM Assets__r ORDER BY CreatedDate, Id),
                (SELECT Contact__r.Name, Role__c, Status__c FROM Participants__r ORDER BY Is_Primary__c DESC, CreatedDate, Id),
                (
                    SELECT Name, Category__c, Status__c, Limit_Amount__c, Limit_Type__c, Deductible_Amount__c
                    FROM Coverages__r
                    ORDER BY CreatedDate, Id
                )
            FROM Policy__c
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
        return policies.isEmpty() ? null : policies[0];
    }

    private void describePolicy(Policy__c policy) {
        policyNumber = policy.Name;
        lineOfBusiness = policy.Line_of_Business__c;
        documentLabel = 'Insurance ID cards ' + policy.Name;
        effective = AntsuranceDocumentFormat.longDate(policy.Effective_Date__c);
        expires = AntsuranceDocumentFormat.longDate(policy.Expiration_Date__c);
        policyPeriod = effective + ' to ' + expires;
        state = AntsuranceDocumentFormat.stateName(AntsuranceAddress.state(policy.Account__r, 'Billing'));

        // A business is the insured in its own right; a household card names every named insured.
        Boolean isBusiness = policy.Account__r.RecordType?.DeveloperName == 'Business';
        List<String> names = new List<String>();
        if (isBusiness || policy.Primary_Insured__r == null) {
            names.add(policy.Account__r.Name);
        } else {
            names.add(policy.Primary_Insured__r.Name);
            for (Policy_Participant__c participant : policy.Participants__r) {
                Boolean isInsured = participant.Role__c == 'Named Insured' && participant.Status__c != REMOVED && participant.Contact__r != null;
                if (isInsured && !names.contains(participant.Contact__r.Name)) {
                    names.add(participant.Contact__r.Name);
                }
            }
        }
        insured = String.join(names, ' and ').abbreviate(MAX_INSURED);

        agentName = policy.Producer__r == null ? 'Antsurance Direct' : policy.Producer__r.Name;
        agentPhone = policy.Producer__r == null || String.isBlank(policy.Producer__r.Phone) ? '1-800-555-0100' : policy.Producer__r.Phone;
    }

    private void describeCards(Policy__c policy) {
        cards = new List<Card>();
        for (Policy_Asset__c asset : policy.Assets__r) {
            if (!VEHICLE_TYPES.contains(asset.Asset_Type__c)) {
                continue;
            }
            Card card = new Card();
            card.vehicle = AntsuranceDocumentFormat.cell(asset.Name, MAX_VEHICLE);
            // A fleet has no single VIN: its vehicles are on the schedule kept with the policy.
            Boolean hasVin = asset.Identifier__c != null && asset.Identifier__c.length() == VIN_LENGTH && !asset.Identifier__c.contains(' ');
            card.vin = hasVin ? asset.Identifier__c : 'Any vehicle on the schedule';
            card.copies = new List<Copy>{ new Copy(), new Copy() };
            card.copies[0].gapWidth = '9pt';
            card.copies[1].gapWidth = '18pt';
            cards.add(card);
        }
    }

    private void describeCoverages(Policy__c policy) {
        coverages = new List<CoverageLine>();
        for (Policy_Coverage__c coverage : policy.Coverages__r) {
            if (coverage.Status__c == REMOVED) {
                continue;
            }
            CoverageLine line = new CoverageLine();
            line.name = coverage.Name.abbreviate(44);
            if (coverage.Limit_Amount__c != null) {
                line.limitText = AntsuranceDocumentFormat.money(coverage.Limit_Amount__c, 0, '');
                if (coverage.Limit_Type__c != null) {
                    line.limitText += ' ' + coverage.Limit_Type__c.toLowerCase();
                }
            } else if (coverage.Category__c == 'Collision' || coverage.Category__c == 'Comprehensive' || coverage.Limit_Type__c == 'Actual Cash Value') {
                line.limitText = 'Actual cash value';
            } else {
                line.limitText = 'Included';
            }
            Boolean hasDeductible = coverage.Deductible_Amount__c != null && coverage.Deductible_Amount__c != 0;
            line.deductible = hasDeductible ? AntsuranceDocumentFormat.money(coverage.Deductible_Amount__c, 0, '') : 'None';
            coverages.add(line);
        }
    }

    /**
     * Decides where the page breaks go: card rows fill each page, and the two blocks under the cards
     * are printed only when the last page has room, never on a page of their own.
     */
    private void layOut() {
        AntsuranceDocumentLayout layout = new AntsuranceDocumentLayout(TOP_HEIGHT);
        for (Card card : cards) {
            card.rowClass = layout.place(CARD_ROW_HEIGHT) ? 'cards new-page' : 'cards';
        }
        showSteps = layout.placeIfRoom(STEPS_HEIGHT);
        showCoverages = showSteps && !coverages.isEmpty() && layout.placeIfRoom(COVERAGE_HEADING_HEIGHT + coverages.size() * COVERAGE_ROW_HEIGHT);
    }
}
