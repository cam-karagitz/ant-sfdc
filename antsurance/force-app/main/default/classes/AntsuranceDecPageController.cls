/**
 * @description Prepares one policy for the declarations page PDF (AntsuranceDecPage). Everything the
 * page prints is formatted here as text, so the PDF layout never has to wrap, round or align on its own.
 * It also decides where the page breaks go: each section is measured, a table that runs on to the next
 * page is cut where the page ends, and the cut-off part prints its heading and column heads again.
 * The policy and its assets, participants, coverages and endorsements are read as the running user.
 */
public with sharing class AntsuranceDecPageController {
    private static final Set<String> AUTO_LINES = new Set<String>{ 'Personal Auto', 'Commercial Auto' };
    private static final Set<String> PROPERTY_LINES = new Set<String>{ 'Homeowners', 'Renters', 'Commercial Property' };
    private static final Map<String, Integer> INSTALLMENT_COUNTS = new Map<String, Integer>{ 'Monthly' => 12, 'Quarterly' => 4, 'Semi-Annual' => 2, 'Annual' => 1 };
    private static final String REMOVED = 'Removed';
    private static final String NOT_RECORDED = 'Not recorded';
    // Longest text that fits its column on one line at the page's type size.
    private static final Integer MAX_NAME = 38;
    private static final Integer MAX_VEHICLE = 36;
    private static final Integer MAX_PROPERTY = 46;
    private static final Integer MAX_OPERATION = 41;
    private static final Integer MAX_LOCATION = 46;
    private static final Integer MAX_OPERATION_LOCATION = 37;
    private static final Set<String> BUILT_ASSETS = new Set<String>{ 'Dwelling', 'Rented Residence', 'Commercial Building' };
    private static final String NOT_APPLICABLE = 'Not applicable';
    private static final Integer MAX_COVERAGE = 40;
    private static final Integer MAX_FORM_TITLE = 36;
    // Detail lines are prose under a row and may run on to a second line.
    private static final Integer MAX_DETAIL = 240;
    private static final Integer MAX_ITEM = 104;
    // About how many characters of a detail line fit across the page before it runs on to a second line.
    private static final Integer DETAIL_LINE_LENGTH = 110;

    // Heights in points, measured from the printed page, for deciding where page breaks fall.
    // Everything above the first section, with two lines under the insured's name.
    private static final Decimal TOP_HEIGHT = 244;
    private static final Decimal ADDRESS_LINE_HEIGHT = 11.5;
    private static final Decimal TITLE_HEIGHT = 32;
    private static final Decimal COLUMN_HEADS_HEIGHT = 21;
    private static final Decimal ROW_HEIGHT = 24.5;
    // A row with detail lines under it: the row, the padding under the lines, then each line.
    private static final Decimal DETAILED_ROW_HEIGHT = 26.5;
    private static final Decimal DETAIL_LINE_HEIGHT = 10.2;
    // A second line of text in a table cell.
    private static final Decimal EXTRA_LINE_HEIGHT = 11.5;
    private static final Decimal TOTAL_ROW_HEIGHT = 26;
    private static final Decimal FORMS_NOTE_HEIGHT = 14;
    // The premium summary, the contacts panel and the closing note, which always share a page.
    private static final Decimal ENDING_HEIGHT = 200;
    private static final String SECTION = 'section';
    private static final String SECTION_ON_NEW_PAGE = 'section new-page';

    /** One insured vehicle, property or operation. */
    public class AssetRow {
        public String title { get; set; }
        public String second { get; set; }
        public String third { get; set; }
        public String fourth { get; set; }
        /** The fourth cell as a list of one, or of none when the table has three columns. */
        public List<String> fourthCell { get { return fourth == null ? new List<String>() : new List<String>{ fourth }; } }
        /** Longer descriptions and the lender's interest, each printed on its own line under the row. */
        public List<String> details { get; set; }
        public Boolean hasDetail { get { return !details.isEmpty(); } }
        /** Printed lines the details take up, counting any that run on. */
        public Integer detailLineCount { get; set; }
    }

    /**
     * One driver, as the customer's own document lists them: who they are and whether the policy covers them.
     * How a driver is rated and what is on their record are the insurer's working view, so they are not printed.
     */
    public class DriverRow {
        public String name { get; set; }
        public String relationship { get; set; }
        public String licensed { get; set; }
        public String standing { get; set; }
    }

    /** One coverage line. */
    public class CoverageRow {
        public String name { get; set; }
        public String limitText { get; set; }
        public String limitNote { get; set; }
        public String deductible { get; set; }
        public String premium { get; set; }
        public Boolean hasLimitNote { get { return String.isNotBlank(limitNote); } }
    }

    /** One form, endorsement, benefit or discount. */
    public class FormRow {
        public String formNumber { get; set; }
        /** The form's title, on a second line when it is too long for its column. */
        public List<String> titleLines { get; set; }
        public String type { get; set; }
        public String limitText { get; set; }
        public String premiumEffect { get; set; }
    }

    /** The part of a table that prints on one page, under the section heading and column heads. */
    public class RowGroup {
        public List<CoverageRow> coverages { get; set; }
        public List<FormRow> forms { get; set; }
        public Boolean isFirst { get; set; }
        public Boolean isLast { get; set; }
        /** True for the parts after the first, whose heading says the table is continued. */
        public Boolean isContinued { get { return !isFirst; } }
        /** The section's style class, which carries the page break when this part starts a new page. */
        public String sectionClass { get; set; }
    }

    public Boolean found { get; private set; }
    public String policyNumber { get; private set; }
    public String lineOfBusiness { get; private set; }
    public String policyPeriod { get; private set; }
    public String term { get; private set; }
    public String issueDate { get; private set; }
    /** Today, for the footer. */
    public String printedOn { get; private set; }
    /** The footer text that leads the page count, built whole because Visualforce drops the space between text and an output tag. */
    public String printedLine {
        get {
            return 'Printed ' + printedOn + ', page ';
        }
    }
    public String namedInsured { get; private set; }
    /** The line under the named insured: other named insureds, or the contact at a business. */
    public String insuredNote { get; private set; }
    public List<String> addressLines { get; private set; }
    public String agentName { get; private set; }
    public String agentDetail { get; private set; }

    public String assetHeading { get; private set; }
    public List<String> assetColumns { get; private set; }
    public List<String> assetWidths { get; private set; }
    public String assetFourthAlign { get; private set; }
    /** Vehicles print in three columns; property and operations add a fourth for the insured value. */
    public Boolean assetHasFourth { get { return assetColumns != null && assetColumns.size() > 3; } }
    public Integer assetColumnCount { get { return assetColumns == null ? 0 : assetColumns.size(); } }
    /** The fourth column's heading as a list of one, or of none, for the page to repeat over. */
    public List<String> assetFourthColumn { get { return assetHasFourth ? new List<String>{ assetColumns[3] } : new List<String>(); } }
    public String assetFourthWidth { get { return assetHasFourth ? assetWidths[3] : '0'; } }
    public List<AssetRow> assets { get; private set; }
    public String insuredItem { get; private set; }
    public List<DriverRow> drivers { get; private set; }
    public List<CoverageRow> coverages { get; private set; }
    public List<RowGroup> coverageGroups { get; private set; }
    public List<RowGroup> formGroups { get; private set; }
    public String coverageTotal { get; private set; }
    public List<FormRow> forms { get; private set; }

    public String annualPremium { get; private set; }
    public String billingPlan { get; private set; }
    public String installments { get; private set; }
    public String policyLimit { get; private set; }
    public String policyDeductible { get; private set; }
    /** What the footer calls this document. */
    public String documentLabel { get; private set; }
    // Style classes that carry a page break when the section has to start a new page.
    public String assetsClass { get; private set; }
    public String driversClass { get; private set; }
    public String endingClass { get; private set; }

    public Boolean hasInsuredNote { get { return String.isNotBlank(insuredNote); } }
    public Boolean hasAssets { get { return assets != null && !assets.isEmpty(); } }
    public Boolean hasInsuredItemOnly { get { return !hasAssets && String.isNotBlank(insuredItem); } }
    public Boolean hasDrivers { get { return drivers != null && !drivers.isEmpty(); } }
    public Boolean hasCoverages { get { return coverages != null && !coverages.isEmpty(); } }
    public Boolean hasForms { get { return forms != null && !forms.isEmpty(); } }

    /**
     * @description Loads the policy named by the page's id parameter. An unknown, malformed or
     * unreadable id leaves found false, and the page prints a short notice instead of a document.
     */
    public AntsuranceDecPageController() {
        found = false;
        Map<String, String> parameters = ApexPages.currentPage().getParameters();
        Policy__c policy = findPolicy(parameters.get('id'));
        if (policy == null) {
            return;
        }
        found = true;
        describePolicy(policy);
        describeAssets(policy);
        describeDrivers(policy);
        describeCoverages(policy);
        describeForms(policy);
        layOut();

        // Gives the file a useful name whether it is viewed in the browser or saved.
        String disposition = parameters.get('download') == '1' ? 'attachment' : 'inline';
        String fileName = 'Declarations-' + policy.Name.replaceAll('[^A-Za-z0-9-]', '') + '.pdf';
        ApexPages.currentPage().getHeaders().put('content-disposition', disposition + '; filename=' + fileName);
    }

    private static Policy__c findPolicy(String recordId) {
        if (!(recordId instanceof Id) || ((Id) recordId).getSObjectType() != Policy__c.SObjectType) {
            return null;
        }
        List<Policy__c> policies = [
            SELECT
                Name, Line_of_Business__c, Effective_Date__c, Expiration_Date__c, Annual_Premium__c, Coverage_Limit__c, Deductible__c,
                Billing_Frequency__c, Insured_Item__c, Primary_Insured__r.Name, Producer__r.Name, Producer__r.Phone,
                Account__r.Name, Account__r.RecordType.DeveloperName, Account__r.BillingStreet, Account__r.BillingCity, Account__r.BillingState,
                Account__r.BillingPostalCode,
                (
                    SELECT Name, Asset_Type__c, Identifier__c, Model_Year__c, Location__c, Use__c, Details__c, Insured_Value__c, Lienholder__c
                    FROM Assets__r
                    ORDER BY CreatedDate, Id
                ),
                (
                    SELECT Contact__r.Name, Role__c, Status__c, Relationship_to_Insured__c, License_State__c, Is_Primary__c
                    FROM Participants__r
                    ORDER BY Is_Primary__c DESC, CreatedDate, Id
                ),
                (
                    SELECT Name, Category__c, Status__c, Limit_Amount__c, Limit_Type__c, Deductible_Amount__c, Premium_Amount__c
                    FROM Coverages__r
                    ORDER BY CreatedDate, Id
                ),
                (
                    SELECT Name, Form_Number__c, Type__c, Status__c, Premium_Change__c, Limit_Amount__c
                    FROM Endorsements__r
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
        documentLabel = 'Declarations ' + policy.Name;
        lineOfBusiness = String.isBlank(policy.Line_of_Business__c) ? 'Insurance' : policy.Line_of_Business__c;
        // Issued is the day this term's cover began. The day the page was produced is printed in the footer.
        issueDate = policy.Effective_Date__c == null ? NOT_RECORDED : longDate(policy.Effective_Date__c);
        printedOn = longDate(Date.today());
        policyPeriod = policy.Effective_Date__c == null || policy.Expiration_Date__c == null
            ? NOT_RECORDED
            : longDate(policy.Effective_Date__c) + ' to ' + longDate(policy.Expiration_Date__c);
        term = policy.Effective_Date__c == null || policy.Expiration_Date__c == null
            ? NOT_RECORDED
            : policy.Effective_Date__c.monthsBetween(policy.Expiration_Date__c) + ' months';

        // A business is the named insured in its own right; a household is named for its primary insured.
        Boolean isBusiness = policy.Account__r.RecordType?.DeveloperName == 'Business';
        namedInsured = (isBusiness || policy.Primary_Insured__r == null ? policy.Account__r.Name : policy.Primary_Insured__r.Name).abbreviate(MAX_NAME);
        List<String> others = new List<String>();
        for (Policy_Participant__c participant : policy.Participants__r) {
            Boolean isInsured = participant.Role__c == 'Named Insured';
            if (isInsured && participant.Status__c != REMOVED && participant.Contact__r != null && participant.Contact__r.Name != namedInsured) {
                others.add(participant.Contact__r.Name);
            }
        }
        if (isBusiness && policy.Primary_Insured__r != null) {
            insuredNote = ('Attention: ' + policy.Primary_Insured__r.Name).abbreviate(52);
        } else if (!others.isEmpty()) {
            insuredNote = ('and ' + String.join(others, ', ')).abbreviate(52);
        }

        addressLines = new List<String>();
        if (String.isNotBlank(policy.Account__r.BillingStreet)) {
            addressLines.add(policy.Account__r.BillingStreet.replaceAll('\\s*[\\r\\n]+\\s*', ', ').abbreviate(54));
        }
        String cityLine = String.join(present(new List<String>{ policy.Account__r.BillingCity, AntsuranceAddress.state(policy.Account__r, 'Billing') }), ', ');
        cityLine = String.join(present(new List<String>{ cityLine, policy.Account__r.BillingPostalCode }), ' ');
        if (String.isNotBlank(cityLine)) {
            addressLines.add(cityLine);
        }

        agentName = policy.Producer__r == null ? 'Antsurance Direct' : policy.Producer__r.Name.abbreviate(MAX_NAME);
        agentDetail = policy.Producer__r == null ? 'Sold and serviced by Antsurance' : (String.isBlank(policy.Producer__r.Phone) ? 'Independent agency' : policy.Producer__r.Phone);

        annualPremium = money(policy.Annual_Premium__c, 2, NOT_RECORDED);
        policyLimit = money(policy.Coverage_Limit__c, 0, NOT_RECORDED);
        policyDeductible = policy.Deductible__c == null || policy.Deductible__c == 0 ? 'None' : money(policy.Deductible__c, 0, 'None');
        billingPlan = String.isBlank(policy.Billing_Frequency__c) ? NOT_RECORDED : policy.Billing_Frequency__c;
        Integer count = INSTALLMENT_COUNTS.get(policy.Billing_Frequency__c);
        if (count == null || policy.Annual_Premium__c == null) {
            installments = NOT_RECORDED;
        } else if (count == 1) {
            installments = '1 payment of ' + annualPremium;
        } else {
            installments = count + ' payments of ' + money(policy.Annual_Premium__c / count, 2, '');
        }
        insuredItem = policy.Insured_Item__c == null ? null : policy.Insured_Item__c.abbreviate(MAX_ITEM);
    }

    private void describeAssets(Policy__c policy) {
        Boolean isAuto = AUTO_LINES.contains(policy.Line_of_Business__c);
        Boolean isProperty = PROPERTY_LINES.contains(policy.Line_of_Business__c);
        if (isAuto) {
            assetHeading = 'Insured vehicles';
            // How each vehicle is used goes on its detail line, which leaves room for a full address.
            assetColumns = new List<String>{ 'Vehicle', 'VIN', 'Garaged at' };
            assetWidths = new List<String>{ '172pt', '100pt', '205pt' };
            assetFourthAlign = 'left';
        } else {
            assetHeading = isProperty ? 'Insured property' : 'Insured operations';
            assetColumns = new List<String>{ isProperty ? 'Property' : 'Description', 'Type', isProperty ? 'Year built' : 'Location', 'Insured value' };
            assetWidths = isProperty ? new List<String>{ '225pt', '95pt', '60pt', '81pt' } : new List<String>{ '180pt', '55pt', '155pt', '71pt' };
            assetFourthAlign = 'right';
        }

        assets = new List<AssetRow>();
        for (Policy_Asset__c asset : policy.Assets__r) {
            AssetRow row = new AssetRow();
            List<String> description = new List<String>();
            if (isAuto) {
                row.title = cell(asset.Name, MAX_VEHICLE);
                row.second = cell(asset.Identifier__c, 20);
                row.third = cell(asset.Location__c, MAX_LOCATION);
                if (String.isNotBlank(asset.Use__c)) {
                    description.add(asset.Use__c);
                }
            } else {
                row.title = cell(asset.Name, isProperty ? MAX_PROPERTY : MAX_OPERATION);
                row.second = cell(asset.Asset_Type__c, isProperty ? 22 : 12);
                if (isProperty) {
                    // Only buildings have a year built.
                    row.third = String.isBlank(asset.Model_Year__c) && !BUILT_ASSETS.contains(asset.Asset_Type__c) ? NOT_APPLICABLE : cell(asset.Model_Year__c, 8);
                } else {
                    row.third = cell(asset.Location__c, MAX_OPERATION_LOCATION);
                }
                // Operations are insured for liability, so most have no value of their own.
                row.fourth = money(asset.Insured_Value__c, 0, isProperty ? NOT_RECORDED : NOT_APPLICABLE);
                if (String.isNotBlank(asset.Use__c)) {
                    description.add(asset.Use__c);
                }
            }
            if (String.isNotBlank(asset.Details__c)) {
                description.add(asset.Details__c);
            }
            row.details = new List<String>();
            if (!description.isEmpty()) {
                row.details.add(String.join(description, '. ').abbreviate(MAX_DETAIL));
            }
            if (String.isNotBlank(asset.Lienholder__c)) {
                row.details.add(((isAuto ? 'Lienholder: ' : 'Mortgagee: ') + asset.Lienholder__c).abbreviate(MAX_DETAIL));
            }
            row.detailLineCount = 0;
            for (String line : row.details) {
                row.detailLineCount += (Integer) Math.ceil((Decimal) line.length() / DETAIL_LINE_LENGTH);
            }
            assets.add(row);
        }
    }

    private void describeDrivers(Policy__c policy) {
        drivers = new List<DriverRow>();
        if (!AUTO_LINES.contains(policy.Line_of_Business__c)) {
            return;
        }
        for (Policy_Participant__c participant : policy.Participants__r) {
            Boolean isDriver = participant.Role__c == 'Driver' || participant.Role__c == 'Excluded Driver';
            if (!isDriver || participant.Status__c == REMOVED || participant.Contact__r == null) {
                continue;
            }
            DriverRow row = new DriverRow();
            row.name = participant.Contact__r.Name.abbreviate(23);
            row.relationship = cell(participant.Relationship_to_Insured__c, 18);
            row.licensed = cell(participant.License_State__c, 14);
            row.standing = participant.Role__c == 'Excluded Driver' ? 'Excluded driver' : 'Covered driver';
            drivers.add(row);
        }
    }

    private void describeCoverages(Policy__c policy) {
        coverages = new List<CoverageRow>();
        Decimal total = 0;
        for (Policy_Coverage__c coverage : policy.Coverages__r) {
            if (coverage.Status__c == REMOVED) {
                continue;
            }
            CoverageRow row = new CoverageRow();
            row.name = coverage.Name.abbreviate(MAX_COVERAGE);
            if (coverage.Limit_Amount__c != null) {
                row.limitText = money(coverage.Limit_Amount__c, 0, '');
                row.limitNote = coverage.Limit_Type__c == null ? null : coverage.Limit_Type__c.toLowerCase();
            } else if (coverage.Limit_Type__c == 'Statutory' || coverage.Category__c == 'Workers Compensation') {
                row.limitText = 'Statutory';
            } else if (coverage.Limit_Type__c == 'Replacement Cost') {
                row.limitText = 'Replacement cost';
            } else if (coverage.Limit_Type__c == 'Actual Cash Value' || coverage.Category__c == 'Collision' || coverage.Category__c == 'Comprehensive') {
                row.limitText = 'Actual cash value';
            } else {
                row.limitText = 'Included';
            }
            row.deductible = coverage.Deductible_Amount__c == null || coverage.Deductible_Amount__c == 0 ? 'None' : money(coverage.Deductible_Amount__c, 0, 'None');
            row.premium = money(coverage.Premium_Amount__c, 2, 'Included');
            total += coverage.Premium_Amount__c == null ? 0 : coverage.Premium_Amount__c;
            coverages.add(row);
        }
        coverageTotal = money(total, 2, '');
    }

    private void describeForms(Policy__c policy) {
        forms = new List<FormRow>();
        for (Policy_Endorsement__c endorsement : policy.Endorsements__r) {
            if (endorsement.Status__c == REMOVED) {
                continue;
            }
            FormRow row = new FormRow();
            row.formNumber = cell(endorsement.Form_Number__c, 16);
            row.titleLines = AntsuranceDocumentFormat.wrap(endorsement.Name.abbreviate(2 * MAX_FORM_TITLE), MAX_FORM_TITLE);
            row.type = cell(endorsement.Type__c, 23);
            row.limitText = money(endorsement.Limit_Amount__c, 0, 'None');
            Decimal change = endorsement.Premium_Change__c;
            if (change == null || change == 0) {
                row.premiumEffect = 'Included';
            } else {
                row.premiumEffect = (change > 0 ? '+' : '-') + money(Math.abs(change), 2, '');
            }
            forms.add(row);
        }
    }

    /**
     * Decides where the page breaks go. Sections that fit are left to follow one another. A section
     * that does not fit starts a new page, and the two long tables are cut where the page ends, each
     * part printing the heading and column heads again.
     */
    private void layOut() {
        Integer linesUnderInsured = Math.max(addressLines.size() + (hasInsuredNote ? 1 : 0), 1);
        AntsuranceDocumentLayout layout = new AntsuranceDocumentLayout(TOP_HEIGHT + (linesUnderInsured - 2) * ADDRESS_LINE_HEIGHT);

        assetsClass = SECTION;
        if (hasAssets) {
            Decimal height = TITLE_HEIGHT + COLUMN_HEADS_HEIGHT;
            for (AssetRow asset : assets) {
                height += asset.hasDetail ? DETAILED_ROW_HEIGHT + asset.detailLineCount * DETAIL_LINE_HEIGHT : ROW_HEIGHT;
            }
            assetsClass = layout.place(height) ? SECTION_ON_NEW_PAGE : SECTION;
        } else if (hasInsuredItemOnly) {
            assetsClass = layout.place(TITLE_HEIGHT + ROW_HEIGHT) ? SECTION_ON_NEW_PAGE : SECTION;
        }
        driversClass = SECTION;
        if (hasDrivers) {
            driversClass = layout.place(TITLE_HEIGHT + COLUMN_HEADS_HEIGHT + drivers.size() * ROW_HEIGHT) ? SECTION_ON_NEW_PAGE : SECTION;
        }

        coverageGroups = new List<RowGroup>();
        for (AntsuranceDocumentLayout.Chunk chunk : split(layout, coverages.size(), TOTAL_ROW_HEIGHT)) {
            RowGroup rowGroup = newGroup(chunk);
            rowGroup.coverages = new List<CoverageRow>();
            for (Integer index = chunk.first; index < chunk.first + chunk.size; index++) {
                rowGroup.coverages.add(coverages[index]);
            }
            coverageGroups.add(rowGroup);
        }
        formGroups = new List<RowGroup>();
        List<Decimal> formHeights = new List<Decimal>();
        for (FormRow form : forms) {
            formHeights.add(ROW_HEIGHT + (form.titleLines.size() - 1) * EXTRA_LINE_HEIGHT);
        }
        for (AntsuranceDocumentLayout.Chunk chunk : layout.split(formHeights, TITLE_HEIGHT + COLUMN_HEADS_HEIGHT, FORMS_NOTE_HEIGHT)) {
            RowGroup rowGroup = newGroup(chunk);
            rowGroup.forms = new List<FormRow>();
            for (Integer index = chunk.first; index < chunk.first + chunk.size; index++) {
                rowGroup.forms.add(forms[index]);
            }
            formGroups.add(rowGroup);
        }
        endingClass = layout.place(ENDING_HEIGHT) ? 'ending new-page' : 'ending';
    }

    private static List<AntsuranceDocumentLayout.Chunk> split(AntsuranceDocumentLayout layout, Integer rowCount, Decimal tailHeight) {
        return layout.split(AntsuranceDocumentLayout.uniform(rowCount, ROW_HEIGHT), TITLE_HEIGHT + COLUMN_HEADS_HEIGHT, tailHeight);
    }

    private static RowGroup newGroup(AntsuranceDocumentLayout.Chunk chunk) {
        RowGroup rowGroup = new RowGroup();
        rowGroup.isFirst = chunk.isFirst;
        rowGroup.isLast = chunk.isLast;
        rowGroup.sectionClass = chunk.newPage ? SECTION_ON_NEW_PAGE : SECTION;
        return rowGroup;
    }

    private static String cell(String value, Integer maxLength) {
        return AntsuranceDocumentFormat.cell(value, maxLength);
    }

    private static List<String> present(List<String> values) {
        return AntsuranceDocumentFormat.present(values);
    }

    private static String longDate(Date value) {
        return AntsuranceDocumentFormat.longDate(value);
    }

    private static String money(Decimal value, Integer scale, String whenBlank) {
        return AntsuranceDocumentFormat.money(value, scale, whenBlank);
    }
}
