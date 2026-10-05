/**
 * @description Loads a realistic Antsurance book of business: agencies, households and businesses with
 * their contacts and customer briefs; policies with coverages, participants, insured assets, endorsements
 * and underwriting notes; claims and policy service requests with dated file notes; policy sales with their
 * quotes; a working task list; and leads.
 * A core set is written by hand so the demo stories stay stable, and a larger generated set gives list
 * views, rollups and Claude's answers some volume. Dates are relative to today, so the data always looks current.
 *
 * Run from Anonymous Apex. reset() first deletes every account, contact, case, file note, opportunity,
 * policy, lead and task in the org, so it only runs in Developer Edition, sandbox and scratch orgs:
 *     AntsuranceDemoData.reset();
 */
public with sharing class AntsuranceDemoData {
    private static final String NOT_A_DEMO_ORG = 'Demo data can only be cleared in a scratch org or a Developer Edition org. A sandbox may hold a copy of real records.';
    private static final Integer TERM_MONTHS = 12;
    private static final Set<String> IN_FORCE = new Set<String>{ 'Active', 'Pending Renewal' };
    private static final Set<String> PROPERTY_LINES = new Set<String>{ 'Homeowners', 'Renters', 'Commercial Property' };

    // Who writes the file notes.
    private static final String DANA = 'Dana Whitaker, Senior Claims Adjuster';
    private static final String MARCUS = 'Marcus Lindahl, Property Adjuster';
    private static final String ANJALI = 'Anjali Venkataraman, Claims Supervisor';
    private static final String TOMASZ = 'Tomasz Zielinski, SIU Investigator';
    private static final String BRIDGET = 'Bridget Castillo, Service Representative';
    private static final String HUGH = 'Hugh Mercer, Commercial Underwriter';

    private static Map<String, Account> accounts = new Map<String, Account>();
    private static Map<String, Contact> contacts = new Map<String, Contact>();
    private static Map<String, Policy__c> policies = new Map<String, Policy__c>();
    private static List<Case> cases = new List<Case>();
    private static List<Opportunity> opportunities = new List<Opportunity>();
    private static List<File_Note__c> notes = new List<File_Note__c>();
    private static Integer policySequence = 204500;

    // The hand-written claims and requests by subject, so tasks and notes can point at them.
    private static Map<String, Case> casesBySubject = new Map<String, Case>();
    // Keys of the generated policies in the order they were made, so what is generated from them is repeatable.
    private static List<String> generatedPolicyKeys = new List<String>();
    // The generated policies in the order claims are dealt out to them, with a null for each policy a
    // household insures elsewhere. See notInsuredHere().
    private static List<String> claimRotation = new List<String>();
    // How many endorsements a generated policy keeps.
    private static final Integer GENERATED_POLICY_FORMS = 1;
    private static List<Case> generatedClaims = new List<Case>();
    // Policy sales by name, and the lead quote on each, so tasks can point at them.
    private static Map<String, Opportunity> salesByName = new Map<String, Opportunity>();
    private static Map<String, Quote> leadQuotes = new Map<String, Quote>();

    /**
     * @description Deletes the org's CRM records, then loads the demo set.
     * @throws IllegalArgumentException when run in a production org or a sandbox
     */
    public static void reset() {
        clear();
        load();
    }

    /**
     * @description Deletes every task, file note, case, opportunity, policy, contact, account and lead.
     * Coverages, participants, assets and endorsements go with their policy.
     * Records that cannot be deleted (for example an account tied to an entitlement) are left in place.
     * Runs only in a scratch org or a Developer Edition org: a sandbox may hold a copy of a customer's own
     * records, and this deletes by object, not by who made the record.
     * @throws IllegalArgumentException when run in a production org or a sandbox
     */
    public static void clear() {
        Organization org = [SELECT IsSandbox, OrganizationType, TrialExpirationDate FROM Organization LIMIT 1];
        // A scratch org is a sandbox with an expiry date.
        Boolean isThrowaway = (org.IsSandbox && org.TrialExpirationDate != null) || org.OrganizationType == 'Developer Edition';
        if (!isThrowaway && !Test.isRunningTest()) {
            throw new IllegalArgumentException(NOT_A_DEMO_ORG);
        }
        // Children before parents, so nothing is blocked by a record that depends on it.
        Database.delete([SELECT Id FROM Task], false);
        Database.delete([SELECT Id FROM File_Note__c], false);
        Database.delete([SELECT Id FROM Case], false);
        Database.delete([SELECT Id FROM Opportunity], false);
        Database.delete([SELECT Id FROM Policy__c], false);
        Database.delete([SELECT Id FROM Contact], false);
        Database.delete([SELECT Id FROM Account], false);
        Database.delete([SELECT Id FROM Lead WHERE IsConverted = FALSE], false);
    }

    /**
     * @description Inserts the demo records, owned by the running user. One insert per object.
     */
    public static void load() {
        loadAccounts();
        loadContacts();
        loadPolicies();
        loadPolicyDetails();
        loadClaims();
        loadServiceRequests();
        insert cases;
        loadFollowUpTasks();
        loadFileNotes();
        loadOpportunities();
        loadQuotes();
        loadWorkTasks();
        loadLeads();
    }

    // ---------------------------------------------------------------- accounts

    // key | family name | first adult | second adult (may be blank) | street | city | state | postal code
    private static final List<String> HOUSEHOLD_ROWS = new List<String>{
        'alvarez|Alvarez|Elena|Marco|216 W Illinois St|Wheaton|IL|60187',
        'bianchi|Bianchi|Paolo|Giulia|782 S Cedar Ave|Elmhurst|IL|60126',
        'chen|Chen|Wei|Lin|2020 Grant St|Evanston|IL|60201',
        'dlamini|Dlamini|Thabo||100 Wisconsin Ave Apt 803|Madison|WI|53703',
        'eriksen|Eriksen|Astrid|Jonas|2611 E Newport Ave|Milwaukee|WI|53211',
        'fitzgerald|Fitzgerald|Maeve|Colin|218 McKinley Ave|Geneva|IL|60134',
        'goldberg|Goldberg|Ruth|Aaron|2215 Crestview Ln|Wilmette|IL|60091',
        'hosseini|Hosseini|Darius|Shirin|640 W Barry Ave Apt 302|Chicago|IL|60657',
        'ivanov|Ivanov|Nikolai||20 N Baldwin St|Madison|WI|53703',
        'jankowski|Jankowski|Marta|Piotr|4825 W Argyle St|Chicago|IL|60630',
        'kaplan|Kaplan|Naomi||2033 Sherman Ave Apt 301|Evanston|IL|60201',
        'larsen|Larsen|Henrik|Signe|444 Eugene Dr|Lake Geneva|WI|53147',
        'mbeki|Mbeki|Zola|Sipho|404 Home Ave|Oak Park|IL|60302',
        'nguyen|Nguyen|Minh|Thuy|54 Sparrow Ct|Aurora|IL|60504',
        'ortiz|Ortiz|Gabriela||1618 S Halsted St Apt 5B|Chicago|IL|60608',
        'park|Park|Jisoo|Daniel|515 Briar Ln|Lake Forest|IL|60045',
        'quinn|Quinn|Declan|Aoife|1148 E LaSalle Ave|South Bend|IN|46617',
        'rahman|Rahman|Farid|Nadia|6145 Ralston Ave|Indianapolis|IN|46220',
        'schmidt|Schmidt|Greta|Otto|607 Midway Ave|Holland|MI|49423',
        'takahashi|Takahashi|Yuki||404 E College St Apt 1107|Iowa City|IA|52240',
        'adeyemi|Adeyemi|Tunde|Folake|624 Joshua Ct|Naperville|IL|60540',
        'gupta|Gupta|Anil|Meera|320 Elmwood Dr|Naperville|IL|60540',
        'castro|Castro|Diego|Valeria|2311 Apple Hill Ln|Aurora|IL|60506',
        'delgado|Delgado|Rosa||3021 W Armitage Ave Apt 203|Chicago|IL|60647',
        'jovanovic|Jovanovic|Milan|Sara|5006 N Tripp Ave|Chicago|IL|60630',
        'engel|Engel|Marta|Tobias|3551 S Taylor Ave|Milwaukee|WI|53207',
        'novak|Novak|Petra||1300 N Prospect Ave Apt 401|Milwaukee|WI|53202',
        'farouk|Farouk|Layla|Karim|412 Redwood Ln|Schaumburg|IL|60193',
        'hoang|Hoang|Linh||31 S Broom St Apt 107|Madison|WI|53703',
        'ibrahim|Ibrahim|Yusuf|Amina|2221 Harrison St|Evanston|IL|60201',
        'kowalczyk|Kowalczyk|Ewa|Adam|1419 E Forest Ave|Wheaton|IL|60187',
        'lombardi|Lombardi|Gina|Paul|847 Fair Oaks Ave|Oak Park|IL|60302',
        'okonjo|Okonjo|Chidi|Ngozi|355 Ahwahnee Ln|Lake Forest|IL|60045',
        'quist|Quist|Erik|Ingrid|501 Elm Ave|Geneva|IL|60134',
        'cohen|Cohen|Miriam|David|101 16th St|Wilmette|IL|60091'
    };

    // key | name | industry | street | city | state | postal code | employees | contact first | contact last | title | operations
    private static final List<String> BUSINESS_ROWS = new List<String>{
        'cedarpine|Cedar & Pine Carpentry|Construction|1420 Shermer Rd|Northbrook|IL|60062|26|Owen|Brandvold|Owner|Finish carpentry and custom millwork contractor',
        'halsted|Halsted Street Bistro|Food & Beverage|2244 N Halsted St|Chicago|IL|60614|31|Simone|Achterberg|General Manager|Full-service restaurant with a bar',
        'northpoint|Northpoint Physical Therapy|Healthcare|900 Skokie Blvd Ste 210|Northbrook|IL|60062|18|Imani|Caldwell|Practice Administrator|Outpatient physical therapy, two clinics',
        'coldharbor|Cold Harbor Storage & Logistics|Transportation|5500 W 73rd St|Bedford Park|IL|60638|74|Ray|Dombrowski|Risk Manager|Refrigerated warehousing and regional delivery',
        'wolfroad|Wolf Road Auto Body|Other|310 S Wolf Rd|Des Plaines|IL|60016|12|Gus|Pappas|Owner|Collision repair and paint shop',
        'prairiewind|Prairie Wind Hotels|Hospitality|100 E Main St|Galena|IL|61036|58|Celeste|Moreau|Director of Operations|Two boutique hotels and an event barn',
        'foxriver|Fox River Plastics|Manufacturing|2750 Alft Ln|Elgin|IL|60124|95|Dev|Raghunathan|Chief Financial Officer|Injection molding for appliance parts',
        'lincolnsq|Lincoln Square Books & Paper|Retail|4736 N Lincoln Ave|Chicago|IL|60625|9|Hattie|Lindgren|Owner|Independent bookstore and stationery shop',
        'summit|Summit Climbing Gym|Recreation|1100 Regent St|Madison|WI|53715|24|Tobias|Renner|Managing Partner|Indoor climbing gym with youth programs',
        'riverbend|Riverbend Veterinary Clinic|Healthcare|660 N Riverside Dr|Milwaukee|WI|53212|16|Leila|Farouk|Practice Owner|Small animal veterinary clinic and boarding',
        'kettle|Kettle Moraine Excavating|Construction|W3120 County Rd H|Elkhorn|WI|53121|41|Cal|Vandenberg|President|Excavation, grading and site utilities',
        'pawpaw|Paw Paw Lake Craft Distillers|Food & Beverage|18 Elm St|Coloma|MI|49038|14|June|Halloran|Owner|Craft distillery with a tasting room'
    };

    private static final Map<String, String> AREA_CODES = new Map<String, String>{
        'IL' => '630', 'WI' => '608', 'IN' => '317', 'MI' => '616', 'IA' => '319', 'MN' => '612'
    };

    // A standing brief for each hand-written customer. {since} becomes the year they joined.
    private static final Map<String, String> BRIEFS = new Map<String, String>{
        'reyes' => '**Who:** Maria and Daniel Reyes with their daughter Sofia, 17. Customers since {since} through Prairie State.\n\n**Service:** Maria handles everything and prefers a phone call. Quick to bundle when it saves money.\n\n**Watch:** Sofia has just passed her road test, so the auto premium will rise. Offer the good student discount.',
        'okafor' => '**Who:** Chinedu and Amara Okafor. Customers since {since}. Both travel often for work.\n\n**Service:** Email first, then text. They read everything and ask detailed questions.\n\n**Watch:** Open water damage claim on the home. Recommend a leak sensor and water backup cover at renewal.',
        'lindqvist' => '**Who:** Erik Lindqvist, a graduate student renting near campus. Customer since {since}.\n\n**Service:** Text only. Rarely answers calls.\n\n**Watch:** Price sensitive. An umbrella quote is open, so keep it simple.',
        'nakamura' => '**Who:** Hana and Kenji Nakamura. Customers since {since}. Two cars, one of them electric.\n\n**Service:** Use the mobile app for almost everything. Placed through Lakefront.\n\n**Watch:** Homeowners renewal is due and they are refinancing, so the mortgagee will change.',
        'castellano' => '**Who:** Lucia Castellano, renting in Riverwest. Customer since {since}.\n\n**Service:** Call after 5 pm. Changing banks disrupted her automatic payments.\n\n**Watch:** Auto policy has lapsed and a claim came in after the lapse. Handle the reinstatement and the claim conversation together.',
        'abernathy' => '**Who:** Grace and Thomas Abernathy, retired. Customers since {since}, our longest-standing household in Naperville.\n\n**Service:** Prefer to deal with Hal Brennan at Prairie State. Paper documents by mail.\n\n**Watch:** Cedar shake roof is original and has an open hail claim. Expect a roof surcharge conversation at renewal.',
        'dubois' => '**Who:** Camille Dubois, a new customer in {since}.\n\n**Service:** Email. Responds fastest in the evening.\n\n**Watch:** Auto quote is out. She is comparing two other carriers.',
        'whitfield' => '**Who:** Marcus and Renee Whitfield. Customers since {since}.\n\n**Service:** Marcus by email, Renee by phone.\n\n**Watch:** Moving to Belvidere next month, so the home policy must be rewritten. Open deer strike claim on the Expedition.',
        'petrovic' => '**Who:** Ana Petrovic. Customer since {since}. Commutes on I-90 daily.\n\n**Service:** Mobile app and text.\n\n**Watch:** One glass claim this year. Good candidate for renters cover, which she does not have with us.',
        'haddad' => '**Who:** Omar and Layla Haddad. Customers since {since}.\n\n**Service:** Omar prefers a call. Placed through Lakefront.\n\n**Watch:** Theft claim on the BMW is with SIU. Keep all contact factual and route questions to the adjuster.',
        'bluestem' => '**Who:** Craft brewery and taproom with regional distribution. Priya Raman owns it and Joe Mancini runs operations.\n\n**Service:** Send certificates to Joe. Priya signs anything that changes premium.\n\n**Watch:** New canning line needs to be endorsed. Open slip and fall claim with counsel involved. A second taproom is planned.',
        'ridgeline' => '**Who:** Roofing and solar contractor, 64 employees. Dana Kowalski is CFO and Miguel Ortega is safety director.\n\n**Service:** Broker-led through Lakefront. Copy Dana on anything about cost.\n\n**Watch:** Serious fall injury is open and OSHA is involved. The fall protection program will be a renewal condition.',
        'lakeshore' => '**Who:** Dental group with three locations, opening a fourth in Lincoln Park.\n\n**Service:** Dr. Shah is brief and decisive. Email with a clear ask.\n\n**Watch:** Landlord certificate needed before the new lease starts. Workers compensation quote is open.',
        'copperfield' => '**Who:** Manages 11 apartment buildings in Chicago. Victor Lang leads risk and Nora Whitcombe manages the portfolio.\n\n**Service:** Quarterly review with Victor. Vendor certificates go to Nora.\n\n**Watch:** Kitchen fire at 1840 N Kedzie is our largest open property claim. Two more buildings are being added to the schedule.',
        'tamarack' => '**Who:** Outdoor gear shop on State Street with a rental counter. Bea Thornton owns it.\n\n**Service:** Call the shop before noon.\n\n**Watch:** Liability policy shows past due and Bea says the check is in the mail. A break-in claim was paid last month.',
        'ironwood' => '**Who:** Precision machine shop, 112 employees across two shifts. Sam Okonkwo is controller.\n\n**Service:** Placed through Prairie State. Sam wants numbers in a spreadsheet.\n\n**Watch:** Workers compensation and liability renew next month. The largest account Prairie State places with us, so start early.',
        'sagebrush' => '**Who:** Regional truckload carrier with 46 tractors. Lena Fischer runs fleet and risk.\n\n**Service:** Lena answers texts faster than email. The driver list changes monthly.\n\n**Watch:** Jackknife loss on I-80 is approved and partly paid. A cargo and umbrella quote is in underwriting.',
        'marigold' => '**Who:** Cafe and catering business in Evanston. Rosa Delgado owns it.\n\n**Service:** Email, and avoid the lunch rush.\n\n**Watch:** Spoilage claim just came in. A food poisoning claim was denied earlier this year.',
        // The three agencies. {since} is the year each was appointed.
        'prairie' => '**Who:** Independent agency in Springfield led by Hal Brennan, appointed in {since}. Writes households and main-street businesses across Illinois.\n\n**Service:** Hal likes a call for anything unusual and a book review by email each month.\n\n**Watch:** Places Ironwood Machine Works, its largest account with us, which renews next month.',
        'lakefront' => '**Who:** Commercial brokerage in Chicago, appointed in {since}. Jo Castellanos leads the middle-market team.\n\n**Service:** Copy Jo on anything that changes premium. Certificates are expected the same day.\n\n**Watch:** Places Copperfield, Ridgeline and Sagebrush, each with a large open claim this year. Hold a claims review before renewal season.',
        'driftless' => '**Who:** Family agency in La Crosse run by Wes Halvorsen, appointed in {since}. Writes households and small businesses in Wisconsin and northern Illinois.\n\n**Service:** Prefers email. Submissions arrive complete, so turn quotes round quickly.\n\n**Watch:** The smallest of the three by premium and growing in Madison and Milwaukee, where we want more personal lines.'
    };

    // What each hand-written business does, for its description.
    private static final Map<String, String> OPERATIONS = new Map<String, String>{
        'bluestem' => 'Craft brewery with a taproom and regional distribution',
        'ridgeline' => 'Roofing and solar installation contractor',
        'lakeshore' => 'Dental practice with three locations',
        'copperfield' => 'Manager of 11 apartment buildings in Chicago',
        'tamarack' => 'Outdoor gear shop with a rental counter',
        'ironwood' => 'Precision machine shop running two shifts',
        'sagebrush' => 'Regional truckload carrier with 46 tractors',
        'marigold' => 'Cafe and off-site catering'
    };
    // Revenue per employee used across the demo, so liability rating details and the customer record agree.
    private static final Integer REVENUE_PER_EMPLOYEE = 165000;

    private static final List<String> HOUSEHOLD_SERVICE = new List<String>{
        'Prefers email and reads it the same day.',
        'Call in the evening. Does not use the app.',
        'Text first. Short messages get the fastest answer.',
        'Uses the mobile app for payments and ID cards.',
        'Likes a yearly review call before renewal.',
        'Paper documents by mail, and a call for anything urgent.'
    };
    private static final List<String> HOUSEHOLD_WATCH = new List<String>{
        'No umbrella yet. Worth a conversation at renewal.',
        'A teen driver will be licensed within two years.',
        'Roof is more than 15 years old. Ask about replacement plans.',
        'Shopped the auto rate last renewal. Lead with the multi-policy discount.',
        'Works from home, so annual mileage may be lower than rated.',
        'Recently finished the basement. Check the contents limit and the water backup limit.',
        'Second car is paid off. May want to review collision cover.'
    };
    private static final List<String> BUSINESS_SERVICE = new List<String>{
        'Send certificates the same day, because contracts depend on them.',
        'Email with a clear ask. Decisions are quick.',
        'Works through the broker for anything that changes premium.',
        'Prefers a quarterly check-in call.',
        'Call before 10 am, before the floor gets busy.'
    };
    private static final List<String> BUSINESS_WATCH = new List<String>{
        'Payroll is growing, so expect an audit adjustment on workers compensation.',
        'Considering a second location next year.',
        'Asked about cyber cover, which the liability policy excludes.',
        'Equipment is getting older. Review the property values.',
        'Seasonal staffing peaks in summer.',
        'A lease renewal may change the landlord insurance requirements.'
    };

    private static void loadAccounts() {
        agency('prairie', 'Prairie State Insurance Agency', 'Springfield', 'IL', '(217) 555-0142', 4380);
        agency('lakefront', 'Lakefront Brokerage Partners', 'Chicago', 'IL', '(312) 555-0188', 2740);
        agency('driftless', 'Driftless Insurance Group', 'La Crosse', 'WI', '(608) 555-0155', 1640);

        household('reyes', 'Reyes Household', '524 W Spring Ave', 'Naperville', 'IL', '60540', '(630) 555-0117', 2190);
        household('okafor', 'Okafor Household', '2620 Central Park Ave', 'Evanston', 'IL', '60201', '(847) 555-0164', 1460);
        household('lindqvist', 'Lindqvist Household', '123 W Washington Ave Apt 603', 'Madison', 'WI', '53703', '(608) 555-0131', 410);
        household('nakamura', 'Nakamura Household', '316 N Lombard Ave', 'Oak Park', 'IL', '60302', '(708) 555-0172', 2920);
        household('castellano', 'Castellano Household', '3348 N Humboldt Blvd', 'Milwaukee', 'WI', '53212', '(414) 555-0109', 640);
        household('abernathy', 'Abernathy Household', '2246 Keim Rd', 'Naperville', 'IL', '60565', '(630) 555-0193', 4015);
        household('dubois', 'Dubois Household', '1617 N Campbell Ave Apt 3N', 'Chicago', 'IL', '60622', '(773) 555-0126', 95);
        household('whitfield', 'Whitfield Household', '2103 Guilford Rd', 'Rockford', 'IL', '61107', '(815) 555-0158', 1825);
        household('petrovic', 'Petrovic Household', '4910 N Winchester Ave', 'Chicago', 'IL', '60640', '(773) 555-0181', 780);
        household('haddad', 'Haddad Household', '1337 Princeton Ln', 'Schaumburg', 'IL', '60193', '(847) 555-0135', 1210);

        business('bluestem', 'Bluestem Brewing Company', 'Food & Beverage', '2100 W Fulton St', 'Chicago', 'IL', '60612', '(312) 555-0150', 1340, 38);
        business('ridgeline', 'Ridgeline Roofing & Solar', 'Construction', '480 Industrial Pkwy', 'Aurora', 'IL', '60506', '(630) 555-0122', 2010, 64);
        business('lakeshore', 'Lakeshore Dental Group', 'Healthcare', '15 E Superior St Ste 400', 'Chicago', 'IL', '60611', '(312) 555-0177', 905, 22);
        business('copperfield', 'Copperfield Property Management', 'Other', '300 N State St', 'Chicago', 'IL', '60654', '(312) 555-0114', 3285, 51);
        business('tamarack', 'Tamarack Outfitters', 'Retail', '212 State St', 'Madison', 'WI', '53703', '(608) 555-0169', 560, 17);
        business('ironwood', 'Ironwood Machine Works', 'Manufacturing', '9000 Harrison Ave', 'Rockford', 'IL', '61109', '(815) 555-0103', 2555, 112);
        business('sagebrush', 'Sagebrush Freight Lines', 'Transportation', '1750 Route 30', 'Joliet', 'IL', '60431', '(815) 555-0146', 1705, 86);
        business('marigold', 'Marigold Cafe & Catering', 'Food & Beverage', '628 Davis St', 'Evanston', 'IL', '60201', '(847) 555-0191', 300, 14);

        for (String key : BRIEFS.keySet()) {
            Account record = accounts.get(key);
            record.Customer_Brief__c = BRIEFS.get(key).replace('{since}', String.valueOf(record.Customer_Since__c.year()));
        }
        generateHouseholds();
        generateBusinesses();

        saveAllowingDuplicates(accounts.values());
    }

    private static void generateHouseholds() {
        for (Integer i = 0; i < HOUSEHOLD_ROWS.size(); i++) {
            List<String> row = HOUSEHOLD_ROWS[i].split('\\|');
            household(row[0], row[1] + ' Household', row[4], row[5], row[6], row[7], phone(row[6], 20 + i), 240 + Math.mod(i * 331, 3400));
            Account record = accounts.get(row[0]);
            String agencyKey = householdAgency(i);
            String who = String.isBlank(row[3]) ? row[2] + ' ' + row[1] : row[2] + ' and ' + row[3] + ' ' + row[1];
            String watch = singlePolicyWatch(row[0], row[4].contains('Apt'));
            record.Customer_Brief__c =
                '**Who:** ' + who + '. Customers since ' + record.Customer_Since__c.year() + '. ' +
                (agencyKey == null ? 'Bought direct.' : 'Placed through ' + accounts.get(agencyKey).Name + '.') +
                '\n\n**Service:** ' + HOUSEHOLD_SERVICE[Math.mod(i, HOUSEHOLD_SERVICE.size())] +
                '\n\n**Watch:** ' + (watch != null ? watch : HOUSEHOLD_WATCH[Math.mod(i, HOUSEHOLD_WATCH.size())]);
        }
    }

    private static void generateBusinesses() {
        for (Integer j = 0; j < BUSINESS_ROWS.size(); j++) {
            List<String> row = BUSINESS_ROWS[j].split('\\|');
            business(row[0], row[1], row[2], row[3], row[4], row[5], row[6], phone(row[5], 50 + j), 300 + Math.mod(j * 427, 3000), Integer.valueOf(row[7]));
            String agencyKey = businessAgency(j);
            accounts.get(row[0]).Description = row[11] + '.';
            accounts.get(row[0]).Customer_Brief__c =
                '**Who:** ' + row[11] + ', ' + row[7] + ' employees. ' + row[8] + ' ' + row[9] + ' is the ' + row[10].toLowerCase() + '. ' +
                (agencyKey == null ? 'Bought direct.' : 'Placed through ' + accounts.get(agencyKey).Name + '.') +
                '\n\n**Service:** ' + BUSINESS_SERVICE[Math.mod(j, BUSINESS_SERVICE.size())] +
                '\n\n**Watch:** ' + BUSINESS_WATCH[Math.mod(j, BUSINESS_WATCH.size())];
        }
    }

    // Households that insure one thing with us. In a real personal lines book about two customers in five
    // hold a single policy, and each of them is a cross-sell conversation.
    private static final Set<String> HOME_ONLY = new Set<String>{ 'quist', 'jovanovic', 'kowalczyk', 'cohen' };
    private static final Set<String> RENTERS_ONLY = new Set<String>{ 'hoang', 'ortiz', 'kaplan' };
    private static final Set<String> AUTO_ONLY = new Set<String>{ 'ibrahim', 'rahman', 'okonjo', 'adeyemi', 'delgado' };

    /** What to watch for at a household that holds one policy: the policy it does not have with us. */
    private static String singlePolicyWatch(String key, Boolean rents) {
        if (HOME_ONLY.contains(key)) {
            return 'Insures the home with us and the cars with another carrier. Quote the auto with the multi-policy discount.';
        }
        if (RENTERS_ONLY.contains(key)) {
            return 'Rents and does not own a car. Renters is the only policy, so keep service quick and simple.';
        }
        if (AUTO_ONLY.contains(key)) {
            return rents
                ? 'Rents the apartment and has no renters cover. Offer it at the auto renewal.'
                : 'Insures the cars with us and the home with another carrier. Ask when the home policy renews.';
        }
        return null;
    }

    /** Which agency placed a generated household: one in four is direct. */
    private static String householdAgency(Integer index) {
        return new List<String>{ 'prairie', 'lakefront', null, 'driftless' }[Math.mod(index, 4)];
    }

    private static String businessAgency(Integer index) {
        return new List<String>{ 'lakefront', 'driftless', null }[Math.mod(index, 3)];
    }

    private static String phone(String state, Integer lastDigits) {
        return '(' + AREA_CODES.get(state) + ') 555-01' + String.valueOf(lastDigits).leftPad(2, '0');
    }

    private static Account account(String key, String recordType, String name, String street, String city, String state, String postalCode, String phone) {
        Account record = new Account(
            Name = name,
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get(recordType).getRecordTypeId(),
            // Second address set: invented streets for the households when AntsuranceDemoAddresses.useSample is on.
            BillingStreet = AntsuranceDemoAddresses.street(key, street),
            BillingCity = city,
            BillingPostalCode = postalCode,
            Phone = phone
        );
        AntsuranceAddress.put(record, 'Billing', state, 'US');
        accounts.put(key, record);
        return record;
    }

    private static void agency(String key, String name, String city, String state, String phone, Integer daysAppointed) {
        Account record = account(key, 'Agency', name, null, city, state, null, phone);
        record.Customer_Segment__c = 'Agency Partner';
        // For an agency this is the day it was appointed to sell for us.
        record.Customer_Since__c = Date.today().addDays(-daysAppointed);
        record.Website = website(name);
        record.Industry = 'Insurance';
        record.Type = 'Channel Partner / Reseller';
    }

    private static void household(String key, String name, String street, String city, String state, String postalCode, String phone, Integer daysAsCustomer) {
        Account record = account(key, 'Household', name, street, city, state, postalCode, phone);
        record.Customer_Segment__c = 'Personal Lines';
        record.Customer_Since__c = Date.today().addDays(-daysAsCustomer);
        record.Type = 'Customer - Direct';
    }

    private static void business(
        String key, String name, String industry, String street, String city, String state, String postalCode, String phone, Integer daysAsCustomer, Integer employees
    ) {
        Account record = account(key, 'Business', name, street, city, state, postalCode, phone);
        record.Customer_Segment__c = 'Commercial Lines';
        record.Customer_Since__c = Date.today().addDays(-daysAsCustomer);
        record.Industry = industry;
        record.NumberOfEmployees = employees;
        record.AnnualRevenue = employees * REVENUE_PER_EMPLOYEE;
        record.Website = website(name);
        record.Description = OPERATIONS.containsKey(key) ? OPERATIONS.get(key) + '.' : null;
        record.Type = 'Customer - Direct';
    }

    /** A made-up web address under example.com, so it can never land on a real company's site. */
    private static String website(String name) {
        return 'www.' + name.toLowerCase().replaceAll('[^a-z0-9]', '') + '.example.com';
    }

    // ---------------------------------------------------------------- contacts

    private static void loadContacts() {
        member('maria', 'reyes', 'Maria', 'Reyes', 'Head of Household', true, true, 1981);
        member('daniel', 'reyes', 'Daniel', 'Reyes', 'Spouse or Partner', false, true, 1979);
        member('sofia', 'reyes', 'Sofia', 'Reyes', 'Dependent', false, true, 2009);
        member('chinedu', 'okafor', 'Chinedu', 'Okafor', 'Head of Household', true, true, 1975);
        member('amara', 'okafor', 'Amara', 'Okafor', 'Spouse or Partner', false, true, 1978);
        member('erik', 'lindqvist', 'Erik', 'Lindqvist', 'Head of Household', true, true, 1996);
        member('hana', 'nakamura', 'Hana', 'Nakamura', 'Head of Household', true, true, 1984);
        member('kenji', 'nakamura', 'Kenji', 'Nakamura', 'Spouse or Partner', false, true, 1983);
        member('lucia', 'castellano', 'Lucia', 'Castellano', 'Head of Household', true, true, 1992);
        member('grace', 'abernathy', 'Grace', 'Abernathy', 'Head of Household', true, true, 1962);
        member('thomas', 'abernathy', 'Thomas', 'Abernathy', 'Spouse or Partner', false, true, 1960);
        member('camille', 'dubois', 'Camille', 'Dubois', 'Head of Household', true, true, 1998);
        member('marcus', 'whitfield', 'Marcus', 'Whitfield', 'Head of Household', true, true, 1973);
        member('renee', 'whitfield', 'Renee', 'Whitfield', 'Spouse or Partner', false, true, 1976);
        member('ana', 'petrovic', 'Ana', 'Petrovic', 'Head of Household', true, true, 1989);
        member('omar', 'haddad', 'Omar', 'Haddad', 'Head of Household', true, true, 1980);
        member('layla', 'haddad', 'Layla', 'Haddad', 'Spouse or Partner', false, true, 1982);

        employee('priya', 'bluestem', 'Priya', 'Raman', 'Owner', true);
        employee('joe', 'bluestem', 'Joe', 'Mancini', 'Operations Manager', false);
        employee('dana', 'ridgeline', 'Dana', 'Kowalski', 'Chief Financial Officer', true);
        employee('miguel', 'ridgeline', 'Miguel', 'Ortega', 'Safety Director', false);
        employee('anita', 'lakeshore', 'Anita', 'Shah', 'Managing Partner', true);
        employee('victor', 'copperfield', 'Victor', 'Lang', 'Director of Risk', true);
        employee('nora', 'copperfield', 'Nora', 'Whitcombe', 'Portfolio Manager', false);
        employee('bea', 'tamarack', 'Bea', 'Thornton', 'Owner', true);
        employee('sam', 'ironwood', 'Sam', 'Okonkwo', 'Controller', true);
        employee('lena', 'sagebrush', 'Lena', 'Fischer', 'Fleet and Risk Manager', true);
        employee('rosa', 'marigold', 'Rosa', 'Delgado', 'Owner', true);
        employee('hal', 'prairie', 'Hal', 'Brennan', 'Principal Agent', true);
        employee('jo', 'lakefront', 'Jo', 'Castellanos', 'Commercial Lines Broker', true);
        employee('wes', 'driftless', 'Wes', 'Halvorsen', 'Agency Principal', true);

        // Generated households: the first adult is key + 'a', the second key + 'b'.
        for (Integer i = 0; i < HOUSEHOLD_ROWS.size(); i++) {
            List<String> row = HOUSEHOLD_ROWS[i].split('\\|');
            Integer birthYear = 1958 + Math.mod(i * 7, 38);
            member(row[0] + 'a', row[0], row[2], row[1], 'Head of Household', true, true, birthYear);
            if (String.isNotBlank(row[3])) {
                member(row[0] + 'b', row[0], row[3], row[1], 'Spouse or Partner', false, true, birthYear + 2);
            }
        }
        // Generated businesses: one contact, key + 'c'.
        for (String businessRow : BUSINESS_ROWS) {
            List<String> row = businessRow.split('\\|');
            employee(row[0] + 'c', row[0], row[8], row[9], row[10], true);
        }

        saveAllowingDuplicates(contacts.values());
    }

    private static Contact contact(String key, String accountKey, String firstName, String lastName, Boolean isPrimary) {
        Account parent = accounts.get(accountKey);
        Contact record = new Contact(
            AccountId = parent.Id,
            FirstName = firstName,
            LastName = lastName,
            Email = (firstName + '.' + lastName).toLowerCase() + '@example.com',
            Phone = parent.Phone,
            MailingStreet = parent.BillingStreet,
            MailingCity = parent.BillingCity,
            MailingPostalCode = parent.BillingPostalCode,
            Primary_Member__c = isPrimary,
            Preferred_Contact_Method__c = Math.mod(contacts.size(), 3) == 0 ? 'Phone' : (Math.mod(contacts.size(), 3) == 1 ? 'Email' : 'Text')
        );
        AntsuranceAddress.put(record, 'Mailing', AntsuranceAddress.state(parent, 'Billing'), 'US');
        contacts.put(key, record);
        return record;
    }

    private static void member(String key, String accountKey, String firstName, String lastName, String role, Boolean isPrimary, Boolean isDriver, Integer birthYear) {
        Contact record = contact(key, accountKey, firstName, lastName, isPrimary);
        record.Household_Role__c = role;
        record.Licensed_Driver__c = isDriver;
        record.Birthdate = Date.newInstance(birthYear, 1 + Math.mod(contacts.size() * 5, 12), 1 + Math.mod(contacts.size() * 7, 27));
    }

    private static void employee(String key, String accountKey, String firstName, String lastName, String title, Boolean isPrimary) {
        contact(key, accountKey, firstName, lastName, isPrimary).Title = title;
    }

    // ---------------------------------------------------------------- policies

    private static final List<String> VEHICLES = new List<String>{
        '2021 Honda Civic', '2019 Toyota Highlander', '2022 Subaru Forester', '2018 Ford Escape', '2023 Hyundai Tucson', '2020 Mazda CX-5',
        '2017 Chevrolet Malibu', '2024 Kia Sportage', '2021 Toyota Camry', '2019 Jeep Grand Cherokee', '2022 Volkswagen Jetta', '2020 Nissan Rogue',
        '2023 Ford Maverick', '2018 Honda Odyssey', '2021 Tesla Model Y', '2016 Toyota Corolla', '2022 Chevrolet Equinox', '2019 Subaru Crosstrek',
        '2024 Honda Accord', '2020 Audi Q5', '2015 Honda Fit', '2023 Toyota Sienna', '2021 Volvo XC60', '2018 GMC Sierra', '2022 Hyundai Elantra',
        '2020 Ford Explorer', '2019 Lexus ES 350', '2023 Mazda3', '2017 Toyota Tacoma', '2021 Nissan Leaf'
    };

    // What the underwriter recorded on the hand-written policies that have a story.
    private static final Map<String, String> UNDERWRITING = new Map<String, String>{
        'reyes-auto' => '**Risk:** Two vehicles and two licensed adults, garaged at home in Naperville.\n\n**Considered:**\n- Multi-policy discount with the home and umbrella\n- Collision and comprehensive on both vehicles\n\n**Watch at renewal:** Sofia, 17, has passed her road test. Adding her re-rates the policy for an inexperienced operator. Ask for a report card for the good student discount.',
        'reyes-home' => '**Risk:** Single-family home in Naperville insured to a replacement cost of $485,000.\n\n**Considered:**\n- No home claims in the last five years\n- Premium paid in full each year\n\n**Watch at renewal:** The replacement cost was last reviewed two years ago. Re-run the estimate and check that the $10,000 water backup limit is still enough.',
        'ridgeline-wc' => '**Risk:** Roofing and solar installation, 64 employees, heights exposure on every job.\n\n**Conditions:**\n- Written fall protection program with daily anchor inspections\n- Return to work program in place\n\n**Watch at renewal:** The open fall claim will move the experience modification. Ask for the corrective action report.',
        'copperfield-property' => '**Risk:** 11 habitational buildings, mostly ordinary masonry, built 1920 to 1975.\n\n**Considered:**\n- Wiring updated in 9 of 11 buildings\n- No smoking policy and annual unit inspections\n\n**Watch at renewal:** Kitchen fire at 1840 N Kedzie. Require stovetop fire suppression canisters in every unit.',
        'sagebrush-auto' => '**Risk:** 46 tractors and 71 trailers, regional truckload within 500 miles.\n\n**Considered:**\n- Telematics and forward-facing cameras on every unit\n- Driver files reviewed, average tenure 6 years\n\n**Watch at renewal:** Winter losses on I-80. Ask for the severe weather shutdown policy.',
        'bluestem-gl' => '**Risk:** Brewery with a taproom and self-distribution.\n\n**Considered:**\n- Liquor liability written with staff alcohol service training\n- Taproom is about 30 percent of revenue\n\n**Watch at renewal:** Slip and fall claim in the taproom. Confirm floor mats and the spill log.',
        'ironwood-wc' => '**Risk:** Precision machining, two shifts, 112 employees.\n\n**Considered:**\n- Machine guarding audit completed last year\n- Experience modification 0.94\n\n**Watch at renewal:** Payroll is up 9 percent. Confirm the class code split between machinists and clerical.',
        'abernathy-home' => '**Risk:** 1998 custom home with a cedar shake roof.\n\n**Watch at renewal:** Roof is original and has an open hail claim. Quote with a roof surcharge or a wind and hail deductible unless it is replaced.',
        'haddad-auto' => '**Note:** Theft claim on the 2023 BMW X5 is under SIU review. Hold any coverage changes until it is resolved.',
        'castellano-auto' => '**Lapse:** Cancelled for non-payment after two missed drafts. Reinstatement needs a signed no-loss statement and the past due premium. A loss was reported after the lapse date.',
        'okafor-home' => '**Risk:** 1920s brick home with a finished basement.\n\n**Watch at renewal:** Supply line failure this term. Recommend a higher water backup limit and an automatic shutoff valve.'
    };

    private static final Map<String, String> UNDERWRITING_BY_LINE = new Map<String, String>{
        'General Liability' => '**Risk:** {item}.\n\n**Considered:**\n- Five-year loss history reviewed\n- Certificates collected from subcontractors and vendors\n\n**Watch at renewal:** Revenue growth and any new operations.',
        'Commercial Property' => '**Risk:** {item}.\n\n**Considered:**\n- Construction, occupancy and protection confirmed by inspection\n- Values updated to current replacement cost\n\n**Watch at renewal:** Roof age and any vacant space.',
        'Workers Compensation' => '**Risk:** {item}.\n\n**Considered:**\n- Payroll by class code checked against the last audit\n- Return to work program in place\n\n**Watch at renewal:** The final audit may adjust the premium.',
        'Commercial Auto' => '**Risk:** {item}.\n\n**Considered:**\n- Motor vehicle records pulled for every driver\n- Vehicles garaged at the business address\n\n**Watch at renewal:** New drivers under 25 and vehicles added mid-term.',
        'Umbrella' => '**Risk:** Sits over the general liability, auto and employers liability policies.\n\n**Watch at renewal:** Confirm the underlying limits have not changed.'
    };

    private static void loadPolicies() {
        // key, account, insured, line, status, days since effective, premium, limit, deductible, item, billing, payment, agency
        policy('reyes-auto', 'reyes', 'maria', 'Personal Auto', 'Active', 142, 2380, 300000, 500, '2022 Toyota RAV4 and 2019 Honda Accord', 'Monthly', 'Current', 'prairie');
        policy('reyes-home', 'reyes', 'maria', 'Homeowners', 'Active', 201, 1890, 485000, 1500, '524 W Spring Ave, Naperville, IL', 'Annual', 'Paid in Full', 'prairie');
        policy('reyes-umbrella', 'reyes', 'maria', 'Umbrella', 'Active', 201, 410, 1000000, 0, 'Personal umbrella over auto and home', 'Annual', 'Paid in Full', 'prairie');
        policy('okafor-auto', 'okafor', 'chinedu', 'Personal Auto', 'Active', 88, 1640, 250000, 500, '2021 Subaru Outback', 'Monthly', 'Current', null);
        policy('okafor-home', 'okafor', 'chinedu', 'Homeowners', 'Active', 260, 2240, 620000, 2500, '2620 Central Park Ave, Evanston, IL', 'Semi-Annual', 'Current', null);
        policy('lindqvist-renters', 'lindqvist', 'erik', 'Renters', 'Active', 190, 312, 30000, 250, '123 W Washington Ave Apt 603, Madison, WI', 'Monthly', 'Current', null);
        policy('lindqvist-auto', 'lindqvist', 'erik', 'Personal Auto', 'Active', 190, 1310, 100000, 1000, '2017 Mazda3', 'Monthly', 'Current', null);
        policy('nakamura-auto', 'nakamura', 'hana', 'Personal Auto', 'Active', 305, 2110, 300000, 500, '2023 Honda CR-V and 2020 Tesla Model 3', 'Monthly', 'Current', 'lakefront');
        policy('nakamura-home', 'nakamura', 'hana', 'Homeowners', 'Pending Renewal', 338, 2675, 710000, 2500, '316 N Lombard Ave, Oak Park, IL', 'Annual', 'Paid in Full', 'lakefront');
        policy('castellano-auto', 'castellano', 'lucia', 'Personal Auto', 'Lapsed', 233, 1490, 100000, 1000, '2016 Ford Escape', 'Monthly', 'Past Due', null);
        policy('castellano-renters', 'castellano', 'lucia', 'Renters', 'Active', 233, 276, 25000, 500, '3348 N Humboldt Blvd, Milwaukee, WI', 'Monthly', 'Past Due', null);
        policy('abernathy-home', 'abernathy', 'grace', 'Homeowners', 'Active', 119, 3420, 890000, 5000, '2246 Keim Rd, Naperville, IL', 'Annual', 'Paid in Full', 'prairie');
        policy('abernathy-auto', 'abernathy', 'grace', 'Personal Auto', 'Active', 119, 1975, 500000, 500, '2024 Lexus RX 350 and 2018 Buick LaCrosse', 'Semi-Annual', 'Current', 'prairie');
        policy('abernathy-umbrella', 'abernathy', 'grace', 'Umbrella', 'Active', 119, 690, 2000000, 0, 'Personal umbrella over auto and home', 'Annual', 'Paid in Full', 'prairie');
        policy('dubois-renters', 'dubois', 'camille', 'Renters', 'Active', 95, 264, 20000, 250, '1617 N Campbell Ave Apt 3N, Chicago, IL', 'Monthly', 'Current', null);
        policy('dubois-auto', 'dubois', 'camille', 'Personal Auto', 'Quoted', -12, 1560, 100000, 1000, '2020 Hyundai Kona', 'Monthly', null, null);
        policy('whitfield-auto', 'whitfield', 'marcus', 'Personal Auto', 'Active', 64, 2540, 300000, 500, '2022 Ford F-150 and 2013 Ford Expedition', 'Monthly', 'Current', 'prairie');
        policy('whitfield-home', 'whitfield', 'marcus', 'Homeowners', 'Pending Renewal', 347, 1730, 390000, 1500, '2103 Guilford Rd, Rockford, IL', 'Annual', 'Paid in Full', 'prairie');
        policy('petrovic-auto', 'petrovic', 'ana', 'Personal Auto', 'Active', 172, 1280, 100000, 500, '2019 Volkswagen Golf', 'Monthly', 'Current', null);
        policy('haddad-home', 'haddad', 'omar', 'Homeowners', 'Active', 290, 2060, 540000, 2000, '1337 Princeton Ln, Schaumburg, IL', 'Semi-Annual', 'Current', 'lakefront');
        policy('haddad-auto', 'haddad', 'omar', 'Personal Auto', 'Active', 290, 2890, 300000, 500, '2023 BMW X5 and 2021 Toyota Camry', 'Monthly', 'Current', 'lakefront');
        // The policies the three bound sales became, effective the day each sale closed.
        policy('okafor-umbrella', 'okafor', 'chinedu', 'Umbrella', 'Active', 20, 480, 1000000, 0, 'Personal umbrella over auto and home', 'Annual', 'Paid in Full', null);
        policy('alvarez-umbrella', 'alvarez', 'alvareza', 'Umbrella', 'Active', 12, 420, 1000000, 0, 'Personal umbrella over auto and home', 'Annual', 'Paid in Full', null);
        policy('halsted-auto', 'halsted', 'halstedc', 'Commercial Auto', 'Active', 18, 3900, 1000000, 1000, '2025 Ford Transit catering van', 'Monthly', 'Current', null);

        policy('bluestem-gl', 'bluestem', 'priya', 'General Liability', 'Active', 156, 8400, 2000000, 2500, 'Brewery, taproom and distribution', 'Quarterly', 'Current', 'lakefront');
        policy('bluestem-property', 'bluestem', 'priya', 'Commercial Property', 'Active', 156, 14250, 3800000, 10000, '2100 W Fulton St, Chicago, IL', 'Quarterly', 'Current', 'lakefront');
        policy('bluestem-wc', 'bluestem', 'priya', 'Workers Compensation', 'Active', 156, 21600, 1000000, 0, '38 employees, brewing and hospitality classes', 'Monthly', 'Current', 'lakefront');
        policy('ridgeline-gl', 'ridgeline', 'dana', 'General Liability', 'Active', 221, 38500, 2000000, 5000, 'Roofing and solar installation contractor', 'Quarterly', 'Current', 'lakefront');
        policy('ridgeline-wc', 'ridgeline', 'dana', 'Workers Compensation', 'Active', 221, 96400, 1000000, 0, '64 employees, roofing class codes', 'Monthly', 'Current', 'lakefront');
        policy('ridgeline-auto', 'ridgeline', 'dana', 'Commercial Auto', 'Active', 221, 27800, 1000000, 2000, 'Fleet of 14 trucks and vans', 'Monthly', 'Current', 'lakefront');
        policy('lakeshore-property', 'lakeshore', 'anita', 'Commercial Property', 'Active', 75, 6900, 1500000, 5000, '15 E Superior St Ste 400, Chicago, IL', 'Annual', 'Paid in Full', null);
        policy('lakeshore-gl', 'lakeshore', 'anita', 'General Liability', 'Active', 75, 4300, 1000000, 1000, 'Dental practice, three locations', 'Annual', 'Paid in Full', null);
        policy('copperfield-property', 'copperfield', 'victor', 'Commercial Property', 'Active', 268, 164000, 42000000, 50000, 'Portfolio of 11 apartment buildings', 'Quarterly', 'Current', 'lakefront');
        policy('copperfield-gl', 'copperfield', 'victor', 'General Liability', 'Active', 268, 31200, 2000000, 10000, 'Habitational property management', 'Quarterly', 'Current', 'lakefront');
        policy('copperfield-umbrella', 'copperfield', 'victor', 'Umbrella', 'Active', 268, 12400, 10000000, 0, 'Commercial umbrella over liability', 'Annual', 'Paid in Full', 'lakefront');
        policy('tamarack-property', 'tamarack', 'bea', 'Commercial Property', 'Active', 134, 5200, 900000, 2500, '212 State St, Madison, WI', 'Quarterly', 'Current', null);
        policy('tamarack-gl', 'tamarack', 'bea', 'General Liability', 'Active', 134, 3100, 1000000, 1000, 'Outdoor gear retail and rentals', 'Quarterly', 'Past Due', null);
        policy('ironwood-wc', 'ironwood', 'sam', 'Workers Compensation', 'Pending Renewal', 331, 142000, 1000000, 0, '112 employees, machine shop classes', 'Monthly', 'Current', 'prairie');
        policy('ironwood-gl', 'ironwood', 'sam', 'General Liability', 'Pending Renewal', 331, 44800, 2000000, 10000, 'Precision machining and fabrication', 'Quarterly', 'Current', 'prairie');
        policy('ironwood-property', 'ironwood', 'sam', 'Commercial Property', 'Active', 331, 58600, 16500000, 25000, '9000 Harrison Ave, Rockford, IL', 'Quarterly', 'Current', 'prairie');
        policy('sagebrush-auto', 'sagebrush', 'lena', 'Commercial Auto', 'Active', 102, 186000, 1000000, 5000, 'Fleet of 46 tractors and 71 trailers', 'Monthly', 'Current', 'lakefront');
        policy('sagebrush-gl', 'sagebrush', 'lena', 'General Liability', 'Active', 102, 22900, 1000000, 5000, 'Regional truckload carrier', 'Quarterly', 'Current', 'lakefront');
        policy('sagebrush-wc', 'sagebrush', 'lena', 'Workers Compensation', 'Active', 102, 88300, 1000000, 0, '86 employees, trucking classes', 'Monthly', 'Current', 'lakefront');
        policy('marigold-gl', 'marigold', 'rosa', 'General Liability', 'Active', 300, 2900, 1000000, 500, 'Cafe and off-site catering', 'Monthly', 'Current', null);
        policy('marigold-property', 'marigold', 'rosa', 'Commercial Property', 'Active', 300, 3650, 450000, 2500, '628 Davis St, Evanston, IL', 'Monthly', 'Current', null);

        generateHouseholdPolicies();
        generateBusinessPolicies();

        insert policies.values();
    }

    // Premium on a generated household policy. Auto starts here for one car and one driver; a home is rated
    // per $1,000 of dwelling value, in tenths of a dollar. Both are sized so that each personal line's premium
    // carries its claims: the lines are small, and one large hand-written claim sits on each.
    private static final Integer AUTO_BASE_PREMIUM = 1680;
    private static final Integer HOME_RATE_PER_THOUSAND = 60;

    /** An auto and a home or renters policy for most generated households, one of the two for some, and an umbrella for a few. */
    private static void generateHouseholdPolicies() {
        for (Integer i = 0; i < HOUSEHOLD_ROWS.size(); i++) {
            List<String> row = HOUSEHOLD_ROWS[i].split('\\|');
            String key = row[0];
            String insured = key + 'a';
            String agencyKey = householdAgency(i);
            Boolean isCouple = String.isNotBlank(row[3]);
            Boolean rents = row[4].contains('Apt');
            Integer days = 25 + Math.mod(i * 47, 270);
            String billing = new List<String>{ 'Monthly', 'Semi-Annual', 'Annual', 'Monthly' }[Math.mod(i, 4)];
            String payment = billing == 'Annual' ? 'Paid in Full' : 'Current';
            String address = row[4] + ', ' + row[5] + ', ' + row[6];

            String insuredVehicles = VEHICLES[Math.mod(2 * i, VEHICLES.size())];
            if (isCouple) {
                insuredVehicles += ' and ' + VEHICLES[Math.mod(2 * i + 1, VEHICLES.size())];
            }
            Decimal autoPremium = AUTO_BASE_PREMIUM + Math.mod(i * 211, 980) + (isCouple ? 940 : 0);
            Decimal autoLimit = new List<Integer>{ 100000, 250000, 300000, 500000 }[Math.mod(i, 4)];
            Decimal autoDeductible = Math.mod(i, 2) == 0 ? 500 : 1000;
            if (HOME_ONLY.contains(key) || RENTERS_ONLY.contains(key)) {
                notInsuredHere();
            } else if (key == 'hosseini') {
                generatedPolicy(key + '-auto', key, insured, 'Personal Auto', 'Lapsed', days, autoPremium, autoLimit, autoDeductible, insuredVehicles, 'Monthly', 'Past Due', agencyKey);
            } else if (key == 'takahashi') {
                generatedPolicy(key + '-auto', key, insured, 'Personal Auto', 'Quoted', -7, autoPremium, autoLimit, autoDeductible, insuredVehicles, 'Monthly', null, agencyKey);
            } else if (key == 'fitzgerald') {
                generatedPolicy(key + '-auto', key, insured, 'Personal Auto', 'Pending Renewal', 330, autoPremium, autoLimit, autoDeductible, insuredVehicles, billing, payment, agencyKey);
            } else {
                generatedPolicy(key + '-auto', key, insured, 'Personal Auto', 'Active', days, autoPremium, autoLimit, autoDeductible, insuredVehicles, billing, payment, agencyKey);
            }

            // Two residence policies and one auto policy are near the end of their term and waiting on a renewal.
            String residenceStatus = (key == 'dlamini' || key == 'mbeki') ? 'Pending Renewal' : 'Active';
            Integer residenceDays = key == 'dlamini' ? 338 : (key == 'mbeki' ? 345 : days);
            if (AUTO_ONLY.contains(key)) {
                notInsuredHere();
            } else if (rents) {
                Decimal contents = new List<Integer>{ 20000, 25000, 30000, 40000 }[Math.mod(i, 4)];
                generatedPolicy(
                    key + '-renters', key, insured, 'Renters', residenceStatus, residenceDays, 264 + Math.mod(i * 13, 110), contents,
                    Math.mod(i, 2) == 0 ? 250 : 500, address, 'Monthly', key == 'ortiz' ? 'Past Due' : 'Current', agencyKey
                );
            } else {
                Integer dwelling = 260000 + Math.mod(i * 37000, 520000);
                generatedPolicy(
                    key + '-home', key, insured, 'Homeowners', residenceStatus, residenceDays, dwelling / 1000 * HOME_RATE_PER_THOUSAND / 10, dwelling,
                    new List<Integer>{ 1000, 1500, 2500 }[Math.mod(i, 3)], address, billing, payment, agencyKey
                );
                if (Math.mod(i, 5) == 1) {
                    generatedPolicy(
                        key + '-umbrella', key, insured, 'Umbrella', key == 'goldberg' ? 'Cancelled' : 'Active', key == 'goldberg' ? 150 : days,
                        380 + Math.mod(i * 29, 300), Math.mod(i, 2) == 0 ? 2000000 : 1000000, 0, 'Personal umbrella over auto and home', 'Annual', 'Paid in Full', agencyKey
                    );
                }
            }
            if (key == 'quinn') {
                // They rented before they bought, and that policy ran out.
                generatedPolicy(key + '-renters-prior', key, insured, 'Renters', 'Expired', 600, 288, 30000, 500, '905 Portage Ave Apt 3, South Bend, IN', 'Monthly', 'Paid in Full', agencyKey);
            }
        }
    }

    // Premium per employee by industry, for general liability and for workers compensation.
    private static final Map<String, Integer> LIABILITY_RATES = new Map<String, Integer>{
        'Construction' => 520, 'Manufacturing' => 380, 'Transportation' => 240, 'Food & Beverage' => 190, 'Hospitality' => 210,
        'Healthcare' => 160, 'Retail' => 130, 'Recreation' => 310, 'Other' => 260
    };
    private static final Map<String, Integer> COMPENSATION_RATES = new Map<String, Integer>{
        'Construction' => 1450, 'Manufacturing' => 1180, 'Transportation' => 1020, 'Food & Beverage' => 560, 'Hospitality' => 430,
        'Healthcare' => 310, 'Retail' => 240, 'Recreation' => 640, 'Other' => 880
    };

    /** Liability and property for every generated business, plus workers compensation, auto and umbrella where they fit. */
    private static void generateBusinessPolicies() {
        for (Integer j = 0; j < BUSINESS_ROWS.size(); j++) {
            List<String> row = BUSINESS_ROWS[j].split('\\|');
            String key = row[0];
            String industry = row[2];
            String insured = key + 'c';
            String agencyKey = businessAgency(j);
            Integer employees = Integer.valueOf(row[7]);
            // One business has every policy up for renewal together.
            Boolean renewing = key == 'northpoint';
            String status = renewing ? 'Pending Renewal' : 'Active';
            Integer days = renewing ? 336 : 30 + Math.mod(j * 61, 280);
            String billing = new List<String>{ 'Quarterly', 'Monthly', 'Annual' }[Math.mod(j, 3)];
            String payment = billing == 'Annual' ? 'Paid in Full' : 'Current';
            String address = row[3] + ', ' + row[4] + ', ' + row[5];

            generatedPolicy(
                key + '-gl', key, insured, 'General Liability', status, days, 1800 + employees * LIABILITY_RATES.get(industry),
                employees < 40 ? 1000000 : 2000000, employees < 20 ? 1000 : (employees < 60 ? 2500 : 5000), row[11], billing,
                key == 'wolfroad' ? 'Past Due' : payment, agencyKey
            );
            Integer building = 400000 + employees * 60000;
            generatedPolicy(
                key + '-property', key, insured, 'Commercial Property', status, days, building / 1000 * 3 + 900, building,
                employees < 20 ? 2500 : (employees < 60 ? 5000 : 10000), address, billing, payment, agencyKey
            );
            if (employees >= 15) {
                generatedPolicy(
                    key + '-wc', key, insured, 'Workers Compensation', status, days, employees * COMPENSATION_RATES.get(industry), 1000000, 0,
                    employees + ' employees, ' + industry.toLowerCase() + ' classes', 'Monthly', 'Current', agencyKey
                );
            }
            if (industry == 'Construction' || industry == 'Transportation') {
                Integer fleet = Math.max(3, employees / 4);
                generatedPolicy(
                    key + '-auto', key, insured, 'Commercial Auto', status, days, fleet * 1950, 1000000, 2000,
                    'Fleet of ' + fleet + ' trucks and vans', 'Monthly', 'Current', agencyKey
                );
            }
            if (employees >= 55) {
                generatedPolicy(
                    key + '-umbrella', key, insured, 'Umbrella', status, days, 4200 + employees * 40, 5000000, 0,
                    'Commercial umbrella over liability', 'Annual', 'Paid in Full', agencyKey
                );
            }
        }
    }

    private static void generatedPolicy(
        String key, String accountKey, String insuredKey, String line, String status, Integer daysSinceEffective,
        Decimal premium, Decimal coverageLimit, Decimal deductible, String insuredItem, String billing, String paymentStatus, String agencyKey
    ) {
        policy(key, accountKey, insuredKey, line, status, daysSinceEffective, premium, coverageLimit, deductible, insuredItem, billing, paymentStatus, agencyKey);
        generatedPolicyKeys.add(key);
        claimRotation.add(key);
    }

    /**
     * Marks the place of a policy a household insures with another carrier. Claims are dealt out by a
     * policy's place in the run of generated policies, so the place is kept: every other policy then carries
     * the same claim, of the same size, as it would if this household had bought both.
     */
    private static void notInsuredHere() {
        claimRotation.add(null);
    }

    private static final Map<String, String> LINE_CODES = new Map<String, String>{
        'Personal Auto' => 'PA', 'Homeowners' => 'HO', 'Renters' => 'RN', 'Umbrella' => 'UM',
        'Commercial Property' => 'CP', 'General Liability' => 'GL', 'Workers Compensation' => 'WC', 'Commercial Auto' => 'CA'
    };

    private static void policy(
        String key, String accountKey, String insuredKey, String line, String status, Integer daysSinceEffective,
        Decimal premium, Decimal coverageLimit, Decimal deductible, String insuredItem, String billing, String paymentStatus, String agencyKey
    ) {
        policySequence += 17;
        Date effective = Date.today().addDays(-daysSinceEffective);
        Account customer = accounts.get(accountKey);
        Account producer = agencyKey == null ? null : accounts.get(agencyKey);
        Boolean isCommercial = customer.Customer_Segment__c == 'Commercial Lines';
        String underwriting = UNDERWRITING.get(key);
        if (underwriting == null && isCommercial && UNDERWRITING_BY_LINE.containsKey(line)) {
            underwriting = UNDERWRITING_BY_LINE.get(line).replace('{item}', insuredItem);
        }
        policies.put(key, new Policy__c(
            Name = 'ANT-' + LINE_CODES.get(line) + '-' + policySequence,
            Account__c = customer.Id,
            Primary_Insured__c = contacts.get(insuredKey).Id,
            Line_of_Business__c = line,
            Status__c = status,
            Effective_Date__c = effective,
            Expiration_Date__c = effective.addMonths(TERM_MONTHS),
            Annual_Premium__c = premium,
            Coverage_Limit__c = coverageLimit,
            Deductible__c = deductible,
            Insured_Item__c = insuredItem,
            Billing_Frequency__c = billing,
            Payment_Status__c = paymentStatus,
            Producer__c = producer?.Id,
            Agency__c = producer?.Name,
            Underwriting_Notes__c = underwriting
        ));
    }

    // ------------------------------- coverages, participants, assets and endorsements

    private static void loadPolicyDetails() {
        Map<Id, Account> accountsById = new Map<Id, Account>(accounts.values());
        Map<Id, Contact> contactsById = new Map<Id, Contact>(contacts.values());
        Map<Id, List<Contact>> membersByAccount = new Map<Id, List<Contact>>();
        for (Contact person : contacts.values()) {
            if (!membersByAccount.containsKey(person.AccountId)) {
                membersByAccount.put(person.AccountId, new List<Contact>());
            }
            membersByAccount.get(person.AccountId).add(person);
        }
        Map<Id, Integer> inForceByAccount = new Map<Id, Integer>();
        for (Policy__c policy : policies.values()) {
            if (IN_FORCE.contains(policy.Status__c)) {
                Integer soFar = inForceByAccount.containsKey(policy.Account__c) ? inForceByAccount.get(policy.Account__c) : 0;
                inForceByAccount.put(policy.Account__c, soFar + 1);
            }
        }

        List<Policy_Coverage__c> coverages = new List<Policy_Coverage__c>();
        List<Policy_Participant__c> participants = new List<Policy_Participant__c>();
        List<Policy_Asset__c> assets = new List<Policy_Asset__c>();
        List<Policy_Endorsement__c> endorsements = new List<Policy_Endorsement__c>();
        Integer position = 0;
        Set<Id> generatedIds = new Set<Id>();
        for (String key : generatedPolicyKeys) {
            generatedIds.add(policies.get(key).Id);
        }
        for (Policy__c policy : policies.values()) {
            Account customer = accountsById.get(policy.Account__c);
            Boolean isBundled = inForceByAccount.containsKey(customer.Id) && inForceByAccount.get(customer.Id) > 1;
            coverages.addAll(coveragesFor(policy));
            participants.addAll(participantsFor(policy, contactsById.get(policy.Primary_Insured__c), membersByAccount.get(customer.Id), customer));
            assets.addAll(assetsFor(policy, customer, position));
            List<Policy_Endorsement__c> forms = endorsementsFor(policy, customer, isBundled, position);
            // A Developer Edition org holds about 2,500 records in all. The hand-written policies keep every
            // form; a generated one keeps its first, which leaves the org room to work in after a load.
            if (generatedIds.contains(policy.Id) && forms.size() > GENERATED_POLICY_FORMS) {
                while (forms.size() > GENERATED_POLICY_FORMS) {
                    forms.remove(forms.size() - 1);
                }
            }
            endorsements.addAll(forms);
            position++;
        }
        insert coverages;
        insert participants;
        insert assets;
        insert endorsements;
    }

    /** The coverages a policy of this line normally carries. Shared with the code that builds a newly bound policy. */
    private static List<Policy_Coverage__c> coveragesFor(Policy__c policy) {
        return AntsurancePolicyContents.coveragesFor(policy);
    }

    /** The named insured, a co-owning spouse on home and umbrella, and every licensed adult as a driver on a personal auto policy. */
    private static List<Policy_Participant__c> participantsFor(Policy__c policy, Contact insured, List<Contact> members, Account customer) {
        Boolean isHousehold = customer.Customer_Segment__c == 'Personal Lines';
        if (!isHousehold) {
            // A commercial policy insures the business, which the policy names through its account. The person
            // is who we deal with there, so they are its policy contact and not a named insured.
            return new List<Policy_Participant__c>{ participant(policy, insured, 'Policy Contact', 'Employee', true) };
        }
        List<Policy_Participant__c> participants = new List<Policy_Participant__c>{ participant(policy, insured, 'Named Insured', 'Self', true) };
        String line = policy.Line_of_Business__c;
        List<String> driven = line == 'Personal Auto' ? policy.Insured_Item__c.split(' and ') : new List<String>();
        Integer driverNumber = 0;
        for (Contact person : members) {
            Boolean isAdult = person.Household_Role__c != 'Dependent';
            String relationship = person.Id == insured.Id ? 'Self' : (person.Household_Role__c == 'Spouse or Partner' ? 'Spouse or Partner' : 'Other Relative');
            if (line == 'Personal Auto' && isAdult && person.Licensed_Driver__c) {
                Policy_Participant__c driver = participant(policy, person, 'Driver', relationship, person.Id == insured.Id);
                rateDriver(driver, person, customer, driven[Math.min(driverNumber, driven.size() - 1)]);
                participants.add(driver);
                driverNumber++;
            } else if ((line == 'Homeowners' || line == 'Umbrella') && person.Household_Role__c == 'Spouse or Partner') {
                participants.add(participant(policy, person, 'Additional Insured', relationship, false));
            }
        }
        return participants;
    }

    private static Policy_Participant__c participant(Policy__c policy, Contact person, String role, String relationship, Boolean isPrimary) {
        return new Policy_Participant__c(
            Name = person.FirstName + ' ' + person.LastName + ', ' + role, Policy__c = policy.Id, Contact__c = person.Id, Role__c = role,
            Status__c = 'Active', Relationship_to_Insured__c = relationship, Is_Primary__c = isPrimary, Effective_Date__c = policy.Effective_Date__c
        );
    }

    /** A license, a three-year driving record and the rating tier that follows from them. The same person always gets the same record. */
    private static void rateDriver(Policy_Participant__c driver, Contact person, Account customer, String vehicle) {
        Integer seed = Math.abs(Math.mod((person.FirstName + person.LastName).hashCode(), 1000000000));
        String digits = String.valueOf(seed).leftPad(9, '0');
        Date licensed = Date.newInstance(person.Birthdate.year() + 16 + Math.mod(seed, 3), person.Birthdate.month(), Math.min(person.Birthdate.day(), 28));
        Integer violations = Math.mod(seed, 7) == 0 ? 1 : (Math.mod(seed, 13) == 0 ? 2 : 0);
        Integer accidents = Math.mod(seed, 11) == 0 ? 1 : 0;
        String rating = 'Non-Standard';
        if (licensed.daysBetween(Date.today()) < 3 * 365) {
            rating = 'Inexperienced Operator';
        } else if (violations + accidents == 0) {
            rating = 'Preferred';
        } else if (violations + accidents <= 2) {
            rating = 'Standard';
        }
        driver.License_Number__c = person.LastName.left(1).toUpperCase() + digits.left(3) + '-' + digits.mid(3, 4) + '-' + digits.right(2);
        driver.License_State__c = AntsuranceAddress.state(customer, 'Billing');
        driver.Date_Licensed__c = licensed;
        driver.Violations_Past_3_Years__c = violations;
        driver.Accidents_Past_3_Years__c = accidents;
        driver.Driver_Rating__c = rating;
        driver.Good_Student_Discount__c = false;
        driver.Primary_Vehicle__c = vehicle;
    }

    private static final List<String> AUTO_LENDERS = new List<String>{ 'Great Plains Credit Union', 'Lakeland Auto Finance', 'Heartland Community Bank' };
    private static final List<String> HOME_LENDERS = new List<String>{ 'First Prairie Mortgage', 'Heartland Home Lending', 'North Star Home Loans' };
    private static final List<String> HOME_DETAILS = new List<String>{
        'Frame construction, 2,400 sq ft, roof replaced 2019, central station alarm',
        'Brick veneer, 1,850 sq ft, roof 11 years old, smoke and carbon monoxide detectors',
        'Frame construction, 3,100 sq ft, finished basement, sump pump with battery backup',
        'Masonry, 2,050 sq ft, updated wiring and plumbing, deadbolts on all doors',
        'Frame construction, 2,750 sq ft, detached garage, monitored alarm'
    };
    private static final String VIN_CHARACTERS = '0123456789ABCDEFGHJKLMNPRSTUVWXYZ';
    // Where a property policy written on a schedule of buildings insures, by its insured item. The kitchen
    // fire claim is at one of these, so the coverage check can see the building is on the policy.
    private static final Map<String, String> SCHEDULED_LOCATIONS = new Map<String, String>{
        'Portfolio of 11 apartment buildings' => '11 scheduled apartment buildings in Chicago, IL, one of them 1840 N Kedzie Ave'
    };

    /** What the policy insures: each vehicle, the home or rented unit, the building and its contents, the fleet or the operation. */
    private static List<Policy_Asset__c> assetsFor(Policy__c policy, Account customer, Integer position) {
        String address = customer.BillingStreet + ', ' + customer.BillingCity + ', ' + AntsuranceAddress.state(customer, 'Billing') + ' ' + customer.BillingPostalCode;
        String item = policy.Insured_Item__c;
        Decimal coverageLimit = policy.Coverage_Limit__c;
        List<Policy_Asset__c> assets = new List<Policy_Asset__c>();
        switch on policy.Line_of_Business__c {
            when 'Personal Auto' {
                Integer sequence = 0;
                for (String vehicle : item.split(' and ')) {
                    Integer modelYear = Integer.valueOf(vehicle.left(4));
                    Policy_Asset__c car = asset(policy, vehicle, 'Vehicle', vin(vehicle, policy.Name + vehicle), address, vehicleValue(vehicle));
                    car.Model_Year__c = vehicle.left(4);
                    car.Use__c = sequence == 0 ? 'Commute, about 12,000 miles a year' : 'Pleasure, about 7,500 miles a year';
                    car.Details__c = 'Anti-lock brakes, anti-theft device and passive restraints';
                    car.Lienholder__c = modelYear >= 2022 ? AUTO_LENDERS[Math.mod(position + sequence, AUTO_LENDERS.size())] : null;
                    assets.add(car);
                    sequence++;
                }
            }
            when 'Homeowners' {
                Policy_Asset__c home = asset(policy, item.left(80), 'Dwelling', 'LOC-001', address, coverageLimit);
                home.Model_Year__c = String.valueOf(1928 + Math.mod(position * 13, 88));
                home.Use__c = 'Primary residence, owner occupied';
                home.Details__c = HOME_DETAILS[Math.mod(position, HOME_DETAILS.size())];
                home.Lienholder__c = Math.mod(position, 3) == 0 ? null : HOME_LENDERS[Math.mod(position, HOME_LENDERS.size())];
                assets.add(home);
            }
            when 'Renters' {
                Policy_Asset__c unit = asset(policy, item.left(80), 'Rented Residence', 'LOC-001', item, coverageLimit);
                unit.Use__c = 'Tenant occupied';
                unit.Details__c = 'Unit in a multi-family building, contents insured at replacement cost';
                assets.add(unit);
            }
            when 'Umbrella' {
                Policy_Asset__c underlying = asset(policy, 'Underlying policies', 'Operations', 'SCHEDULE', address, null);
                underlying.Use__c = 'Excess over the underlying liability limits';
                underlying.Details__c = item;
                assets.add(underlying);
            }
            when 'Commercial Property' {
                Policy_Asset__c building = asset(policy, item.left(80), 'Commercial Building', 'LOC-001', address, coverageLimit);
                building.Model_Year__c = String.valueOf(1952 + Math.mod(position * 7, 60));
                building.Use__c = customer.Industry == 'Other' ? 'Owner occupied' : customer.Industry + ' occupancy';
                building.Details__c = 'Joisted masonry, sprinklered, central station fire alarm';
                if (SCHEDULED_LOCATIONS.containsKey(item)) {
                    // A portfolio is insured by schedule, not at the owner's office, and a claim on it happens at one of its buildings.
                    building.Identifier__c = 'SCHEDULE ON FILE';
                    building.Location__c = SCHEDULED_LOCATIONS.get(item);
                }
                assets.add(building);
                Policy_Asset__c contents = asset(policy, 'Contents and equipment', 'Business Property', 'LOC-001-BPP', address, coverageLimit * 0.25);
                contents.Use__c = 'Stock, furniture, fixtures and equipment';
                contents.Details__c = 'Valued at replacement cost';
                assets.add(contents);
            }
            when 'General Liability' {
                Policy_Asset__c operations = asset(policy, item.left(80), 'Operations', 'OPS-001', address, null);
                operations.Use__c = 'Premises and operations';
                operations.Details__c = 'Rated on annual revenue of about $' + (customer.NumberOfEmployees * REVENUE_PER_EMPLOYEE).format();
                assets.add(operations);
            }
            when 'Workers Compensation' {
                // What a workers compensation policy lists is the workplace. Payroll is how it is rated, not what is insured.
                Policy_Asset__c workplace = asset(policy, ('Workplace, ' + customer.BillingStreet).left(80), 'Workplace', 'LOC-001', address, null);
                workplace.Use__c = 'All ' + customer.NumberOfEmployees + ' employees work from this location';
                workplace.Details__c = item + '. Rated on estimated annual payroll of $' + (customer.NumberOfEmployees * 58000).format() + '.';
                assets.add(workplace);
            }
            when 'Commercial Auto' {
                Policy_Asset__c fleet = asset(policy, item.left(80), 'Fleet', 'SCHEDULE ON FILE', address, Math.max(3, customer.NumberOfEmployees / 4) * 48000);
                fleet.Use__c = 'Business use within 500 miles';
                fleet.Details__c = 'Vehicle schedule with VINs is on file and updated monthly';
                fleet.Lienholder__c = 'Great Plains Equipment Finance';
                assets.add(fleet);
            }
        }
        place(assets, customer);
        return assets;
    }

    // Town centres, so each asset can be put on a map. Latitude then longitude.
    private static final Map<String, List<Decimal>> TOWN_COORDINATES = new Map<String, List<Decimal>>{
        'Aurora' => new List<Decimal>{ 41.7606, -88.3201 }, 'Bedford Park' => new List<Decimal>{ 41.7645, -87.7773 },
        'Chicago' => new List<Decimal>{ 41.8827, -87.6500 }, 'Coloma' => new List<Decimal>{ 42.1861, -86.3084 },
        'Des Plaines' => new List<Decimal>{ 42.0334, -87.8834 }, 'Elgin' => new List<Decimal>{ 42.0354, -88.2826 },
        'Elkhorn' => new List<Decimal>{ 42.6728, -88.5443 }, 'Elmhurst' => new List<Decimal>{ 41.8995, -87.9403 },
        'Evanston' => new List<Decimal>{ 42.0451, -87.6977 }, 'Galena' => new List<Decimal>{ 42.4167, -90.4290 },
        'Geneva' => new List<Decimal>{ 41.8875, -88.3054 }, 'Holland' => new List<Decimal>{ 42.7875, -86.1089 },
        'Indianapolis' => new List<Decimal>{ 39.7684, -86.1581 }, 'Iowa City' => new List<Decimal>{ 41.6611, -91.5302 },
        'Joliet' => new List<Decimal>{ 41.5250, -88.0817 }, 'La Crosse' => new List<Decimal>{ 43.8014, -91.2296 },
        'Lake Forest' => new List<Decimal>{ 42.2586, -87.8507 }, 'Lake Geneva' => new List<Decimal>{ 42.5917, -88.4334 },
        'Madison' => new List<Decimal>{ 43.0731, -89.4012 }, 'Milwaukee' => new List<Decimal>{ 43.0389, -87.9265 },
        'Naperville' => new List<Decimal>{ 41.7508, -88.1535 }, 'Northbrook' => new List<Decimal>{ 42.1275, -87.8290 },
        'Oak Park' => new List<Decimal>{ 41.8850, -87.7845 }, 'Rockford' => new List<Decimal>{ 42.2711, -89.0940 },
        'Schaumburg' => new List<Decimal>{ 42.0334, -88.0834 }, 'South Bend' => new List<Decimal>{ 41.6764, -86.2520 },
        'Springfield' => new List<Decimal>{ 39.7817, -89.6501 }, 'Wheaton' => new List<Decimal>{ 41.8661, -88.1070 },
        'Wilmette' => new List<Decimal>{ 42.0723, -87.7328 }
    };
    // The households live at real addresses, so their map pins and property links land on the actual home.
    // Latitude then longitude, keyed by street address.
    private static final Map<String, List<Decimal>> ADDRESS_COORDINATES = new Map<String, List<Decimal>>{
        '524 W Spring Ave' => new List<Decimal>{ 41.77831, -88.15699 },
        '2246 Keim Rd' => new List<Decimal>{ 41.72380, -88.11021 },
        '2620 Central Park Ave' => new List<Decimal>{ 42.06525, -87.71809 },
        '2020 Grant St' => new List<Decimal>{ 42.05891, -87.70147 },
        '2033 Sherman Ave Apt 301' => new List<Decimal>{ 42.05489, -87.68161 },
        '123 W Washington Ave Apt 603' => new List<Decimal>{ 43.07331, -89.38577 },
        '100 Wisconsin Ave Apt 803' => new List<Decimal>{ 43.07548, -89.38588 },
        '20 N Baldwin St' => new List<Decimal>{ 43.08756, -89.36691 },
        '316 N Lombard Ave' => new List<Decimal>{ 41.89248, -87.77952 },
        '404 Home Ave' => new List<Decimal>{ 41.88121, -87.79960 },
        '3348 N Humboldt Blvd' => new List<Decimal>{ 43.07943, -87.89721 },
        '2611 E Newport Ave' => new List<Decimal>{ 43.07928, -87.87743 },
        '1617 N Campbell Ave Apt 3N' => new List<Decimal>{ 41.91085, -87.68943 },
        '4910 N Winchester Ave' => new List<Decimal>{ 41.97097, -87.67818 },
        '640 W Barry Ave Apt 302' => new List<Decimal>{ 41.93815, -87.64596 },
        '4825 W Argyle St' => new List<Decimal>{ 41.97146, -87.74894 },
        '1618 S Halsted St Apt 5B' => new List<Decimal>{ 41.85929, -87.64699 },
        '2103 Guilford Rd' => new List<Decimal>{ 42.27759, -89.06074 },
        '1337 Princeton Ln' => new List<Decimal>{ 42.01049, -88.11436 },
        '216 W Illinois St' => new List<Decimal>{ 41.86184, -88.10914 },
        '782 S Cedar Ave' => new List<Decimal>{ 41.87582, -87.92488 },
        '218 McKinley Ave' => new List<Decimal>{ 41.89136, -88.31677 },
        '2215 Crestview Ln' => new List<Decimal>{ 42.07255, -87.72998 },
        '444 Eugene Dr' => new List<Decimal>{ 42.57811, -88.43041 },
        '54 Sparrow Ct' => new List<Decimal>{ 41.75335, -88.22552 },
        '515 Briar Ln' => new List<Decimal>{ 42.23026, -87.83454 },
        '1148 E LaSalle Ave' => new List<Decimal>{ 41.67895, -86.23350 },
        '6145 Ralston Ave' => new List<Decimal>{ 39.86683, -86.13153 },
        '607 Midway Ave' => new List<Decimal>{ 42.77429, -86.16287 },
        '404 E College St Apt 1107' => new List<Decimal>{ 41.65900, -91.53006 },
        '624 Joshua Ct' => new List<Decimal>{ 41.76321, -88.17087 },
        '320 Elmwood Dr' => new List<Decimal>{ 41.75325, -88.15450 },
        '2311 Apple Hill Ln' => new List<Decimal>{ 41.76149, -88.37191 },
        '3021 W Armitage Ave Apt 203' => new List<Decimal>{ 41.91713, -87.70345 },
        '5006 N Tripp Ave' => new List<Decimal>{ 41.97211, -87.73459 },
        '3551 S Taylor Ave' => new List<Decimal>{ 42.97986, -87.90091 },
        '1300 N Prospect Ave Apt 401' => new List<Decimal>{ 43.04702, -87.89501 },
        '412 Redwood Ln' => new List<Decimal>{ 42.01815, -88.09369 },
        '31 S Broom St Apt 107' => new List<Decimal>{ 43.07113, -89.38840 },
        '2221 Harrison St' => new List<Decimal>{ 42.06359, -87.70442 },
        '1419 E Forest Ave' => new List<Decimal>{ 41.87580, -88.08598 },
        '847 Fair Oaks Ave' => new List<Decimal>{ 41.90076, -87.78845 },
        '355 Ahwahnee Ln' => new List<Decimal>{ 42.24634, -87.86029 },
        '501 Elm Ave' => new List<Decimal>{ 41.89771, -88.29408 },
        '101 16th St' => new List<Decimal>{ 42.06921, -87.71661 }
    };
    // How far from the town centre an address can land, in hundred-thousandths of a degree (about a kilometre).
    private static final Integer SPREAD = 1100;

    /**
     * Gives each asset map coordinates: the household's own for a real address, otherwise a spot near the
     * town centre that is steady for the address, because the business addresses are made up.
     */
    private static void place(List<Policy_Asset__c> assets, Account customer) {
        List<Decimal> exact = ADDRESS_COORDINATES.get(customer.BillingStreet);
        if (exact != null) {
            for (Policy_Asset__c asset : assets) {
                asset.Latitude__c = exact[0];
                asset.Longitude__c = exact[1];
            }
            return;
        }
        List<Decimal> centre = TOWN_COORDINATES.get(customer.BillingCity);
        if (centre == null) {
            return;
        }
        Decimal north = (Math.mod(Math.abs((customer.BillingStreet + 'north').hashCode()), SPREAD * 2) - SPREAD) / 100000.0;
        // Only ever west of the centre, which keeps lakefront towns out of the water.
        Decimal west = Math.mod(Math.abs((customer.BillingStreet + 'west').hashCode()), SPREAD * 2) / 100000.0;
        for (Policy_Asset__c asset : assets) {
            asset.Latitude__c = centre[0] + north;
            asset.Longitude__c = centre[1] - west;
        }
    }

    // What each make cost new, in thousands of dollars, with the models that sit well away from their make's middle.
    private static final Map<String, Integer> PRICE_NEW = new Map<String, Integer>{
        'Audi' => 50, 'BMW' => 80, 'Buick' => 36, 'Chevrolet' => 30, 'Ford' => 36, 'GMC' => 52, 'Honda' => 30, 'Hyundai' => 29, 'Jeep' => 44,
        'Kia' => 30, 'Lexus' => 50, 'Mazda' => 29, 'Mazda3' => 24, 'Nissan' => 29, 'Subaru' => 31, 'Tesla' => 46, 'Toyota' => 33, 'Volkswagen' => 27, 'Volvo' => 48,
        'Ford F-150' => 48, 'Ford Expedition' => 56, 'Ford Escape' => 29, 'Ford Maverick' => 27, 'Honda Fit' => 18, 'Honda Civic' => 26,
        'Honda Odyssey' => 38, 'Toyota Corolla' => 23, 'Toyota Highlander' => 42, 'Toyota Sienna' => 42, 'Toyota Tacoma' => 40, 'Nissan Leaf' => 31
    };
    // A vehicle whose claim turns on its value is insured for the figure the claim uses.
    private static final Map<String, Integer> VEHICLE_VALUES = new Map<String, Integer>{
        // The stolen BMW is reserved at this cash value less the deductible.
        '2023 BMW X5' => 58500,
        // The deer strike estimate of $9,400 is a repair, not a total loss, against this.
        '2013 Ford Expedition' => 14200
    };

    /**
     * @description What a vehicle is insured for: its price new, less a tenth for each year of its age,
     * to the nearest $100. The same vehicle always gets the same figure in the same year.
     * @param vehicle The vehicle as the policy names it: year, make, model
     * @return The insured value in dollars
     */
    public static Decimal vehicleValue(String vehicle) {
        if (VEHICLE_VALUES.containsKey(vehicle)) {
            return VEHICLE_VALUES.get(vehicle);
        }
        List<String> words = vehicle.split(' ');
        String make = words.size() > 1 ? words[1] : '';
        String model = words.size() > 2 ? make + ' ' + words[2] : make;
        Integer priceNew = PRICE_NEW.containsKey(model) ? PRICE_NEW.get(model) : (PRICE_NEW.containsKey(make) ? PRICE_NEW.get(make) : 32);
        Integer age = Math.max(Date.today().year() - Integer.valueOf(words[0]), 0);
        Decimal keptEachYear = 0.9;
        return (priceNew * 10 * keptEachYear.pow(age)).round() * 100;
    }

    private static Policy_Asset__c asset(Policy__c policy, String name, String assetType, String identifier, String location, Decimal insuredValue) {
        return new Policy_Asset__c(
            Policy__c = policy.Id, Name = name, Asset_Type__c = assetType, Identifier__c = identifier, Location__c = location, Insured_Value__c = insuredValue
        );
    }

    // World manufacturer identifiers, so a made-up VIN starts the way that make's real ones do.
    private static final Map<String, String> MAKE_CODES = new Map<String, String>{
        'Toyota' => '2T3', 'Honda' => '1HG', 'Ford' => '1FT', 'Kia' => '5XY', 'BMW' => '5UX', 'Tesla' => '5YJ', 'Subaru' => '4S4', 'Mazda' => 'JM1',
        'Lexus' => '2T2', 'Buick' => '1G4', 'Hyundai' => 'KM8', 'Volkswagen' => '3VW', 'Chevrolet' => '1G1', 'Nissan' => '1N4', 'Jeep' => '1C4',
        'Volvo' => 'YV4', 'Audi' => 'WA1', 'GMC' => '1GT', 'Ram' => '1C6', 'Dodge' => '2C3', 'Acura' => '19U', 'Chrysler' => '2C4'
    };
    // Model year letters from 2010 (A) to 2026 (T); I, O and Q are never used in a VIN.
    private static final String YEAR_CODES = 'ABCDEFGHJKLMNPRST';

    /**
     * A made-up 17-character VIN shaped like a real one: maker, descriptor, check digit, model year, plant
     * and serial. The same vehicle on the same policy always gets the same one.
     */
    private static String vin(String vehicle, String seed) {
        List<String> words = vehicle.split(' ');
        String maker = words.size() > 1 && MAKE_CODES.containsKey(words[1]) ? MAKE_CODES.get(words[1]) : '1AN';
        Integer yearIndex = Math.min(Math.max(Integer.valueOf(words[0]) - 2010, 0), YEAR_CODES.length() - 1);
        // An MD5 digest of the seed gives well-mixed values to draw each part from.
        String digest = EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(seed)));
        String descriptor = '';
        for (Integer position = 0; position < 6; position++) {
            Integer index = Math.mod(Math.abs(digest.substring(position * 3, position * 3 + 3).hashCode()), VIN_CHARACTERS.length());
            descriptor += VIN_CHARACTERS.substring(index, index + 1);
        }
        String checkDigit = String.valueOf(Math.mod(Math.abs(digest.substring(18, 22).hashCode()), 10));
        String serial = String.valueOf(100000 + Math.mod(Math.abs(digest.substring(22, 30).hashCode()), 900000));
        return maker + descriptor.left(5) + checkDigit + YEAR_CODES.substring(yearIndex, yearIndex + 1) + descriptor.right(1) + serial;
    }

    /**
     * The forms attached to a policy of this line. Coverage premiums already add up to the policy premium,
     * so a premium change here says what the form is worth inside that total rather than adding to it.
     */
    private static List<Policy_Endorsement__c> endorsementsFor(Policy__c policy, Account customer, Boolean isBundled, Integer position) {
        Decimal premium = policy.Annual_Premium__c;
        Decimal coverageLimit = policy.Coverage_Limit__c;
        Boolean isHousehold = customer.Customer_Segment__c == 'Personal Lines';
        List<Policy_Endorsement__c> forms = new List<Policy_Endorsement__c>();
        switch on policy.Line_of_Business__c {
            when 'Personal Auto' {
                forms.add(endorsement(policy, 'Roadside Assistance', 'ANT PA 03 12', 'Benefit', 36, null,
                    'Towing to the nearest qualified shop, jump starts, lockout and flat tire help. Up to four calls a term.'));
                forms.add(endorsement(policy, 'Rental Reimbursement', 'ANT PA 03 20', 'Benefit', 54, 1200,
                    'Pays for a rental car while an insured vehicle is being repaired after a covered loss: **$40 a day for up to 30 days**.'));
                if (isBundled) {
                    forms.add(endorsement(policy, 'Multi-Policy Discount', 'ANT PA 09 01', 'Discount', -(premium * 0.08).setScale(0), null,
                        'Eight percent off because the household also insures its home or belongings with Antsurance.'));
                }
                if (policy.Insured_Item__c.contains('2022') || policy.Insured_Item__c.contains('2023') || policy.Insured_Item__c.contains('2024')) {
                    // Named, because a household often insures two cars and the clause covers only the financed one.
                    forms.add(endorsement(policy, 'Loss Payable Clause', 'ANT PA 05 40', 'Lienholder or Mortgagee', null, null,
                        'A total loss payment on the financed vehicle, the ' + financedVehicle(policy.Insured_Item__c) + ', is made jointly to the insured and ' +
                        AUTO_LENDERS[Math.mod(position, AUTO_LENDERS.size())] + '.'));
                }
            }
            when 'Homeowners' {
                forms.add(endorsement(policy, 'Water Backup and Sump Overflow', 'ANT HO 04 95', 'Endorsement', 95, 10000,
                    'Covers water that backs up through sewers or drains or overflows from a sump. The standard policy excludes it.'));
                if (Math.mod(position, 2) == 0) {
                    forms.add(endorsement(policy, 'Scheduled Personal Property', 'ANT HO 04 61', 'Endorsement', 140, 18000,
                        'Covers listed jewelry and artwork for their appraised value with no deductible, including accidental loss.'));
                } else {
                    forms.add(endorsement(policy, 'Protective Device Discount', 'ANT HO 09 14', 'Discount', -(premium * 0.04).setScale(0), null,
                        'Four percent off for a monitored burglar and fire alarm.'));
                }
                if (Math.mod(position, 3) != 0) {
                    forms.add(endorsement(policy, 'Mortgagee Clause', 'ANT HO 05 10', 'Lienholder or Mortgagee', null, null,
                        'Names ' + HOME_LENDERS[Math.mod(position, HOME_LENDERS.size())] + ' as mortgagee. A dwelling loss is paid jointly, and the lender is told before the policy is cancelled.'));
                }
                forms.add(endorsement(policy, 'Earth Movement Exclusion', 'ANT HO 02 30', 'Exclusion', null, null,
                    'Earthquake, landslide, sinkhole and settling are not covered.'));
            }
            when 'Renters' {
                forms.add(endorsement(policy, 'Replacement Cost on Contents', 'ANT RN 04 10', 'Endorsement', 18, null,
                    'Belongings are settled at the cost to replace them new rather than their depreciated value.'));
                forms.add(endorsement(policy, 'Identity Fraud Expense', 'ANT RN 04 55', 'Benefit', 25, 15000,
                    'Pays the costs of restoring identity after fraud: lost wages, legal fees and document replacement.'));
                forms.add(endorsement(policy, 'Flood Exclusion', 'ANT RN 02 12', 'Exclusion', null, null,
                    'Surface water and flood are not covered. A separate flood policy is needed.'));
            }
            when 'Umbrella' {
                forms.add(endorsement(policy, 'Schedule of Underlying Insurance', 'ANT UM 01 05', 'Endorsement', null, null,
                    'Lists the policies this umbrella sits over and the limits they must keep.'));
                if (isHousehold) {
                    forms.add(endorsement(policy, 'Excess Uninsured Motorist', 'ANT UM 04 20', 'Endorsement', 60, 1000000,
                        'Extends the umbrella limit to the household\'s own injuries caused by an uninsured driver.'));
                    forms.add(endorsement(policy, 'Business Pursuits Exclusion', 'ANT UM 02 08', 'Exclusion', null, null,
                        'Liability from a business run by a household member is not covered.'));
                } else {
                    forms.add(endorsement(policy, 'Professional Services Exclusion', 'ANT UM 02 21', 'Exclusion', null, null,
                        'Liability from professional advice or services is not covered.'));
                }
            }
            when 'Commercial Property' {
                forms.add(endorsement(policy, 'Equipment Breakdown', 'ANT CP 04 30', 'Endorsement', (premium * 0.03).setScale(0), null,
                    'Covers sudden mechanical or electrical breakdown of boilers, refrigeration, electrical panels and production equipment, including spoilage.'));
                forms.add(endorsement(policy, 'Ordinance or Law', 'ANT CP 04 05', 'Endorsement', (premium * 0.02).setScale(0), (coverageLimit * 0.1).setScale(0),
                    'Pays the extra cost of rebuilding to current building codes after a covered loss.'));
                if (Math.mod(position, 2) == 0) {
                    forms.add(endorsement(policy, 'Sprinkler Protection Credit', 'ANT CP 09 03', 'Discount', -(premium * 0.05).setScale(0), null,
                        'Five percent off for a fully sprinklered building with a monitored alarm.'));
                }
                forms.add(endorsement(policy, 'Flood Exclusion', 'ANT CP 02 10', 'Exclusion', null, null,
                    'Flood, surface water and sewer backup are not covered unless added by endorsement.'));
            }
            when 'General Liability' {
                forms.add(endorsement(policy, 'Additional Insured: Managers or Lessors of Premises', 'ANT GL 20 11', 'Endorsement', 150, null,
                    'Extends coverage to the landlord for claims arising from the leased premises.'));
                forms.add(endorsement(policy, 'Waiver of Subrogation', 'ANT GL 24 04', 'Endorsement', 250, null,
                    'Antsurance gives up its right to recover from a party the insured has agreed in a contract not to pursue.'));
                if (customer.Industry == 'Food & Beverage' || customer.Industry == 'Hospitality') {
                    forms.add(endorsement(policy, 'Liquor Liability', 'ANT GL 04 60', 'Endorsement', (premium * 0.08).setScale(0), 1000000,
                        'Covers injury or damage caused by a guest who was served alcohol on the premises.'));
                }
                forms.add(endorsement(policy, 'Cyber Incident Exclusion', 'ANT GL 21 06', 'Exclusion', null, null,
                    'Data breaches, ransomware and loss of electronic data are not covered. A separate cyber policy is needed.'));
            }
            when 'Workers Compensation' {
                forms.add(endorsement(policy, 'Waiver of Our Right to Recover from Others', 'ANT WC 00 03 13', 'Endorsement', (premium * 0.01).setScale(0), null,
                    'Antsurance will not seek recovery from a customer or general contractor named in a written contract.'));
                forms.add(endorsement(policy, 'Voluntary Compensation', 'ANT WC 00 03 11', 'Endorsement', null, null,
                    'Extends benefits to workers the statute does not require the employer to cover, such as officers who opted out.'));
                forms.add(endorsement(policy, 'Experience Modification', 'ANT WC 04 03', 'Discount', -(premium * 0.06).setScale(0), null,
                    'A credit for a loss record better than the industry average for this class of work.'));
            }
            when 'Commercial Auto' {
                forms.add(endorsement(policy, 'Hired and Non-Owned Auto', 'ANT CA 20 54', 'Endorsement', (premium * 0.02).setScale(0), coverageLimit,
                    'Covers liability when employees drive rented vehicles or their own cars on company business.'));
                forms.add(endorsement(policy, 'Towing and Labor', 'ANT CA 03 12', 'Benefit', (premium * 0.01).setScale(0), 500,
                    'Pays for towing and roadside labor for any scheduled vehicle, up to $500 a disablement.'));
                forms.add(endorsement(policy, 'Loss Payable Clause', 'ANT CA 05 40', 'Lienholder or Mortgagee', null, null,
                    'Physical damage payments on financed units are made jointly to the insured and Great Plains Equipment Finance.'));
            }
        }
        return forms;
    }

    /** The newest vehicle on a policy's insured item ("2022 Ford F-150 and 2013 Ford Expedition"): the one still financed. */
    @TestVisible
    private static String financedVehicle(String insuredItem) {
        String newest;
        Integer newestYear = 0;
        for (String vehicle : (insuredItem ?? '').split(' and ')) {
            String first = vehicle.trim().substringBefore(' ');
            if (first.isNumeric() && Integer.valueOf(first) > newestYear) {
                newestYear = Integer.valueOf(first);
                newest = vehicle.trim();
            }
        }
        return newest ?? (insuredItem ?? 'vehicle').trim();
    }

    private static Policy_Endorsement__c endorsement(
        Policy__c policy, String title, String formNumber, String formType, Decimal premiumChange, Decimal limitAmount, String description
    ) {
        return new Policy_Endorsement__c(
            Policy__c = policy.Id, Name = title, Form_Number__c = formNumber, Type__c = formType, Status__c = 'Active',
            Effective_Date__c = policy.Effective_Date__c, Premium_Change__c = premiumChange, Limit_Amount__c = limitAmount, Description__c = description
        );
    }

    // ---------------------------------------------------------------- claims

    // Generated claims by line: subject | loss type | severity | typical estimate | location | description.
    // {city} and {address} are filled from the customer, and {vehicle} from the policy: a household often
    // insures two cars, and a claim that does not say which one cannot be read against the policy.
    private static final Map<String, List<String>> CLAIM_TEMPLATES = new Map<String, List<String>>{
        'Personal Auto' => new List<String>{
            'Rear-end collision in stop-and-go traffic|Collision|Medium|5400|Main St, {city}|The {vehicle} was struck from behind in slow traffic. Bumper, trunk lid and tail lamps damaged. No injuries reported.',
            'Hail dents across the hood and roof|Wind or Hail|Low|3200|Home driveway, {city}|Hail during an afternoon storm left dents on the hood, roof and trunk of the {vehicle}. Glass intact. Paintless dent repair quoted.',
            'Catalytic converter stolen overnight|Theft|Low|2100|Street parking, {city}|The catalytic converter was cut from the {vehicle} while it was parked on the street overnight. Police report filed.',
            'Side-swiped while parked on the street|Collision|Low|2800|Residential street, {city}|An unknown vehicle side-swiped the {vehicle} while it was parked. Driver side doors and mirror damaged. No witness.',
            'Windshield cracked by highway debris|Glass|Low|650|Interstate near {city}|Debris from a truck cracked the windshield of the {vehicle}. Replacement and camera recalibration needed.',
            'Slid on ice into a guardrail|Collision|High|14500|County highway outside {city}|The insured lost traction on black ice in the {vehicle} and struck a guardrail. Front suspension, fender and airbags. Driver sore but not treated.',
            'Backed into a light pole in a parking garage|Collision|Low|1900|Parking garage, {city}|Low speed impact with a light pole while reversing the {vehicle}. Rear bumper and liftgate scratched and dented.',
            'Vehicle broken into, window smashed|Vandalism|Low|1350|Trailhead parking lot near {city}|A side window of the {vehicle} was smashed and a bag taken from the back seat. Glass replacement and door panel repair.',
            'Flooded in a viaduct during heavy rain|Other|High|21800|Viaduct on the edge of {city}|The {vehicle} stalled in rising water under a viaduct. Water reached the seats. Likely a total loss.',
            'Struck by a driver who ran a stop sign|Collision|Medium|8700|Intersection in {city}|Another driver ran a stop sign and struck the passenger side of the {vehicle}. Other driver cited. Passenger door and quarter panel damaged.'
        },
        'Homeowners' => new List<String>{
            'Sump pump failure flooded the basement|Water Damage|High|12500|{address}|The sump pump failed during a storm and water backed up into the finished basement. Flooring, drywall and furniture damaged.',
            'Wind tore shingles from the roof|Wind or Hail|Medium|6800|{address}|High winds lifted shingles on the west slope. Water stained one bedroom ceiling. Temporary tarp in place.',
            'Tree limb fell on the detached garage|Wind or Hail|Medium|7600|{address}|A large limb came down in a storm and damaged the garage roof and door. The vehicle inside was not damaged.',
            'Kitchen grease fire with smoke damage|Fire|High|18500|{address}|A stovetop grease fire damaged the range hood and cabinets. Smoke throughout the first floor. The family stayed with relatives for a week.',
            'Packages and a bicycle stolen from the porch|Theft|Low|1400|{address}|A bicycle and two delivered packages were taken from the front porch. Doorbell camera footage given to police.',
            'Dishwasher supply line leak damaged flooring|Water Damage|Medium|5400|{address}|A slow leak behind the dishwasher damaged hardwood flooring and the subfloor in the kitchen.',
            'Lightning strike damaged electronics|Other|Low|3200|{address}|A nearby lightning strike caused a power surge. Furnace control board, two televisions and a router failed.',
            'Frozen pipe burst in an exterior wall|Water Damage|High|11500|{address}|A pipe in an exterior wall froze and burst during a cold snap. Water damage to a bedroom and the room below.'
        },
        'Renters' => new List<String>{
            'Upstairs neighbor overflow soaked furniture|Water Damage|Low|900|{address}|A bathtub overflow in the unit above soaked a sofa, rug and bookshelf.',
            'Laptop and camera stolen in a break-in|Theft|Low|1400|{address}|Entry through an unlocked window. Laptop, camera and headphones taken. Police report filed.',
            'Smoke damage from a fire in the next unit|Fire|Medium|1900|{address}|A fire next door left smoke and soot damage on clothing, bedding and furniture. The unit could not be used for nine days.',
            'Bicycle stolen from the building bike room|Theft|Low|650|{address}|A locked bicycle was taken from the shared bike room. The lock was cut.'
        },
        'Commercial Property' => new List<String>{
            'Burst sprinkler line soaked inventory|Water Damage|High|22000|{address}|A sprinkler line failed over the stock room and soaked inventory and shelving. Operations interrupted for four days.',
            'Break-in through rear door, registers taken|Theft|Medium|6500|{address}|Forced entry through the rear door overnight. Two registers, a safe and tablets taken. Door and frame damaged.',
            'Roof membrane damaged in a wind storm|Wind or Hail|High|19500|{address}|Wind peeled back a section of roof membrane and rain entered the building. Ceiling tiles, insulation and some equipment damaged.',
            'Vehicle drove into the storefront|Other|Medium|12500|{address}|A customer\'s vehicle jumped the curb and struck the front of the building. Glass, framing and a display damaged. No injuries.',
            'Power surge damaged refrigeration equipment|Other|Medium|8200|{address}|A utility power surge damaged compressors and control boards. Some stock was lost before repairs.',
            'Small electrical fire in the back office|Fire|Medium|9500|{address}|A fire started at a power strip in the back office and was put out by staff. Smoke damage to the office and hallway.'
        },
        'General Liability' => new List<String>{
            'Customer tripped on the entry mat|Bodily Injury|Medium|34000|{address}|A customer tripped on a curled entry mat and injured a knee. Incident report completed and the mat replaced.',
            'Delivery damaged a client\'s lobby floor|Liability|Low|6200|Client premises, {city}|Staff making a delivery scratched a stone lobby floor with a hand truck. The client has asked for repair costs.',
            'Visitor slipped on ice in the parking lot|Bodily Injury|Medium|41000|{address}|A visitor fell on ice near the entrance and injured a shoulder. The snow removal log shows the lot was treated that morning.',
            'Completed work alleged to have caused a leak|Liability|Medium|27500|Customer site, {city}|A customer alleges that work completed last year caused a leak and damaged finishes. Investigating the cause.',
            'Customer burned by a hot beverage|Bodily Injury|Low|3900|{address}|A customer alleges a burn from a spilled hot drink. First aid given on site. No treatment records received yet.',
            'Falling sign damaged a parked car|Liability|Low|4400|{address}|A sign bracket failed in high wind and the sign fell on a customer\'s parked car.'
        },
        'Workers Compensation' => new List<String>{
            'Employee strained back lifting stock|Bodily Injury|Medium|29000|{address}|An employee strained their lower back lifting a heavy box. Treated at an occupational clinic and placed on light duty.',
            'Laceration from equipment, stitches required|Bodily Injury|Low|4200|{address}|An employee cut a hand on equipment and needed stitches. Returned to work the next day with restrictions.',
            'Employee fell from a step ladder|Bodily Injury|High|74000|{address}|An employee fell from a step ladder and fractured an ankle. Surgery scheduled. Expected to be off work for eight weeks.',
            'Repetitive strain injury in the wrist|Bodily Injury|Medium|21500|{address}|An employee reported wrist pain that developed over several months. Treating with therapy and a workstation change.',
            'Burn from hot liquid in the kitchen|Bodily Injury|Low|5100|{address}|An employee was burned on the forearm by hot liquid. Treated and released the same day.'
        },
        'Commercial Auto' => new List<String>{
            'Box truck backed into a loading dock|Collision|Low|7800|Customer dock, {city}|A driver misjudged the distance while backing in and damaged the truck\'s rear door and frame.',
            'Van rear-ended in traffic, driver sore|Collision|Medium|26500|Highway near {city}|A company van was struck from behind in traffic. The driver reported neck soreness and was checked at urgent care.',
            'Work truck broken into, side boxes pried open|Vandalism|Medium|11800|Job site, {city}|The side boxes and cab of a work truck were pried open overnight. The boxes, two doors and the ignition lock need replacing. Police report filed. The tools taken are claimed on the contractor\'s equipment policy, not this one.',
            'Truck struck a low overhang|Collision|Medium|17500|Alley in {city}|A driver struck a low overhang and damaged the cargo box roof. No one was hurt.'
        }
    };

    // Mostly settled claims, so there is history, with a spread of open ones.
    private static final List<String> CLAIM_STATUSES = new List<String>{
        'Closed', 'Closed', 'Payment Issued', 'Closed', 'Under Investigation', 'Closed', 'Denied', 'Closed',
        'Approved', 'Closed', 'New', 'Closed', 'Appraisal', 'Payment Issued', 'Closed'
    };
    // The least time since the loss for a claim that has reached each status, and how many days longer it
    // may be. Settled claims reach back most of a year, and an investigation or an appraisal can run for weeks,
    // so claims are reported across the months and open ones are of different ages.
    private static final Map<String, Integer> CLAIM_AGE = new Map<String, Integer>{
        'New' => 1, 'Under Investigation' => 10, 'Appraisal' => 20, 'Approved' => 20, 'Payment Issued' => 40, 'Closed' => 75, 'Denied' => 50
    };
    private static final Map<String, Integer> CLAIM_AGE_SPREAD = new Map<String, Integer>{
        'New' => 6, 'Under Investigation' => 60, 'Appraisal' => 50, 'Approved' => 25, 'Payment Issued' => 80, 'Closed' => 280, 'Denied' => 150
    };
    private static final List<String> ORIGINS = new List<String>{ 'Phone', 'Mobile App', 'Web', 'Agent', 'Email' };

    private static void loadClaims() {
        // policy, contact, subject, status, severity, loss type, days since loss, days since reported, location, estimate, reserve, paid, origin
        claim('nakamura-auto', 'hana', 'Rear-ended at a red light on Harlem Ave', 'New', 'Medium', 'Collision', 2, 1, 'Harlem Ave and Lake St, Oak Park, IL', 6800, 0, 0, 'Mobile App',
            'Insured was stopped at a red light when another driver struck the rear of the 2023 Honda CR-V. Rear bumper, liftgate and sensors damaged. No injuries reported. Other driver cited at the scene.').Subrogation_Potential__c = true;
        claim('whitfield-auto', 'renee', 'Deer strike on Route 20, front-end damage', 'New', 'Medium', 'Animal Strike', 1, 1, 'US Route 20 near Cherry Valley, IL', 9400, 0, 0, 'Phone',
            'Renee Whitfield hit a deer at dusk in the 2013 Ford Expedition. Right front fender, headlamp, bumper and hood damaged, and the radiator is leaking. Vehicle towed to a body shop in Rockford.');
        claim('marigold-property', 'rosa', 'Walk-in cooler failed, food spoilage', 'New', 'Low', 'Other', 3, 2, '628 Davis St, Evanston, IL', 4200, 0, 0, 'Email',
            'Compressor on the walk-in cooler failed overnight. Perishable inventory for two catering events was lost. Insured has the repair invoice and a spoilage inventory.');
        claim('castellano-auto', 'lucia', 'Hit a parked car in a grocery store lot', 'New', 'Low', 'Collision', 4, 3, 'Outpost Natural Foods, Milwaukee, WI', 3100, 0, 0, 'Phone',
            'Lucia clipped a parked sedan while pulling into a space. Damage to her front bumper and the other car\'s rear door. The auto policy lapsed for non-payment before the loss.');
        // $47,500 is the first estimate, set before any document came in. scripts/prepare_demo.sh attaches the mitigation
        // invoice and the rebuild estimate and then raises it to their total, $48,921, which leaves the reserve $1,421 short.
        claim('okafor-home', 'chinedu', 'Burst pipe flooded finished basement', 'Under Investigation', 'High', 'Water Damage', 11, 10, '2620 Central Park Ave, Evanston, IL', 47500, 45000, 5000, 'Phone',
            'Supply line to the basement bathroom burst while the family was away for the weekend. Standing water damaged flooring, drywall, furnace and stored belongings. Mitigation vendor on site; advance paid for emergency drying.');
        claim('haddad-auto', 'omar', '2023 BMW X5 stolen from driveway', 'Under Investigation', 'High', 'Theft', 16, 15, '1337 Princeton Ln, Schaumburg, IL', 58500, 58000, 0, 'Phone',
            'Insured reports the BMW X5 was taken from the driveway overnight. Both key fobs are accounted for. Police report filed. The lender reports two missed payments before the loss.').SIU_Referral__c = true;
        claim('bluestem-gl', 'joe', 'Taproom guest slipped on wet floor', 'Under Investigation', 'Medium', 'Bodily Injury', 24, 22, 'Bluestem taproom, 2100 W Fulton St, Chicago, IL', 44500, 42000, 0, 'Agent',
            'A guest slipped near the bar after a keg line leak and fractured a wrist. Incident report and camera footage reviewed on site. Claimant has retained counsel.');
        claim('ridgeline-wc', 'miguel', 'Installer fell from second-story roof', 'Approved', 'Catastrophic', 'Bodily Injury', 8, 8, 'Residential job site, Wheaton, IL', 285000, 285000, 18500, 'Phone',
            'A roofing installer fell roughly 18 feet when an anchor point failed. Admitted with a fractured pelvis and vertebrae. OSHA has been notified. Nurse case manager assigned.');
        claim('abernathy-home', 'grace', 'Hail damage to roof and skylights', 'Appraisal', 'High', 'Wind or Hail', 19, 17, '2246 Keim Rd, Naperville, IL', 17500, 12500, 0, 'Agent',
            'Golf-ball-sized hail during the storm on the date of loss damaged the cedar shake roof, two skylights and gutters. Independent adjuster inspected; the contractor is proposing full replacement.');
        claim('copperfield-property', 'nora', 'Kitchen fire spread to three apartments', 'Appraisal', 'Catastrophic', 'Fire', 27, 27, '1840 N Kedzie Ave, Chicago, IL', 265000, 215000, 35000, 'Phone',
            'Fire started in a third-floor kitchen and spread to two neighboring units; smoke and water damage on two floors. Eleven tenants relocated. The fire investigator points to the range; building estimate in progress.').Subrogation_Potential__c = true;
        claim('lindqvist-renters', 'erik', 'Apartment burglary, laptop and bike stolen', 'Approved', 'Low', 'Theft', 21, 20, '123 W Washington Ave Apt 603, Madison, WI', 1700, 1450, 0, 'Web',
            'Break-in through a rear window while the insured was at work. Laptop, road bike and camera taken. Police report filed. Settlement agreed less the deductible.');
        claim('sagebrush-auto', 'lena', 'Tractor-trailer jackknifed on I-80, cargo loss', 'Approved', 'High', 'Collision', 34, 33, 'I-80 westbound near Morris, IL', 126000, 121000, 40000, 'Phone',
            'Unit 217 jackknifed in freezing rain and struck the median. Tractor is a total loss; trailer repairable. Driver treated and released. Cargo claim handled separately by the shipper.');
        claim('reyes-auto', 'daniel', 'Parking lot scrape, rear quarter panel', 'Payment Issued', 'Low', 'Collision', 29, 28, 'Fox Valley Mall, Aurora, IL', 2350, 1850, 1850, 'Mobile App',
            'Daniel Reyes scraped a concrete bollard while backing the 2019 Honda Accord out of a parking space. Rear quarter panel and bumper repaired at a network shop. Payment issued to the shop less the deductible.');
        claim('tamarack-property', 'bea', 'Storefront window smashed, merchandise taken', 'Payment Issued', 'Medium', 'Vandalism', 41, 40, '212 State St, Madison, WI', 14800, 12300, 12300, 'Email',
            'Front display window broken overnight and jackets and packs taken from the display. Board-up, glass replacement and stock loss paid.');
        claim('petrovic-auto', 'ana', 'Cracked windshield from road debris', 'Closed', 'Low', 'Glass', 58, 58, 'I-90 near Rosemont, IL', 780, 780, 780, 'Mobile App',
            'Rock from a gravel truck cracked the windshield. Replaced by a mobile glass vendor and recalibrated. No deductible applies to glass.');
        claim('ironwood-property', 'sam', 'Forklift struck loading dock door', 'Closed', 'Low', 'Other', 73, 71, '9000 Harrison Ave, Rockford, IL', 31700, 6700, 6700, 'Agent',
            'A forklift operator misjudged clearance and damaged an overhead dock door, its track and the dock leveler. Door and leveler replaced. Paid less the $25,000 deductible.');
        claim('marigold-gl', 'rosa', 'Guest alleges food poisoning after wedding', 'Denied', 'Low', 'Liability', 66, 60, 'Off-site event, Glencoe, IL', 5000, 0, 0, 'Email',
            'One wedding guest alleged illness after a catered event. Health department found no violations and no other guests reported symptoms. Denied for lack of evidence the food caused the illness.');

        // The day each settled claim was closed, which is the day of its last note.
        casesBySubject.get('Cracked windshield from road debris').Closed_On__c = Date.today().addDays(-55);
        casesBySubject.get('Forklift struck loading dock door').Closed_On__c = Date.today().addDays(-60);
        casesBySubject.get('Guest alleges food poisoning after wedding').Closed_On__c = Date.today().addDays(-45);

        generateClaims();
    }

    // The sample documents attached to these claims print a fixed date of loss (see
    // staticresources/antsuranceClaimDocSources). While a load falls within DOCUMENTS_CURRENT_DAYS of that
    // date the claim takes it, so Claude finds the documents and the claim in agreement. A later load goes
    // back to dates relative to today, and the documents should then be re-made.
    private static final Map<String, Date> DOCUMENT_LOSS_DATES = new Map<String, Date>{
        'Burst pipe flooded finished basement' => Date.newInstance(2026, 9, 21),
        'Rear-ended at a red light on Harlem Ave' => Date.newInstance(2026, 9, 30),
        'Installer fell from second-story roof' => Date.newInstance(2026, 9, 26)
    };
    private static final Integer DOCUMENTS_CURRENT_DAYS = 60;

    private static Case claim(
        String policyKey, String contactKey, String subject, String status, String severity, String lossType, Integer daysSinceLoss, Integer daysSinceReported,
        String location, Decimal estimate, Decimal reserve, Decimal paid, String origin, String description
    ) {
        Case record = buildClaim(
            policies.get(policyKey), contacts.get(contactKey).Id, subject, status, severity, lossType, daysSinceLoss, daysSinceReported,
            location, estimate, reserve, paid, origin, description
        );
        Date printed = DOCUMENT_LOSS_DATES.get(subject);
        Integer daysSincePrinted = printed == null ? -1 : printed.daysBetween(Date.today());
        if (daysSincePrinted >= daysSinceLoss && daysSincePrinted <= DOCUMENTS_CURRENT_DAYS) {
            record.Date_of_Loss__c = printed;
            record.Reported_Date__c = printed.addDays(daysSinceLoss - daysSinceReported);
        }
        casesBySubject.put(subject, record);
        return record;
    }

    private static Case buildClaim(
        Policy__c policy, Id contactId, String subject, String status, String severity, String lossType, Integer daysSinceLoss, Integer daysSinceReported,
        String location, Decimal estimate, Decimal reserve, Decimal paid, String origin, String description
    ) {
        Case record = new Case(
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId(),
            Policy__c = policy.Id,
            AccountId = policy.Account__c,
            ContactId = contactId,
            Subject = subject,
            Description = description,
            Status = status,
            Severity__c = severity,
            Priority = severity == 'Low' ? 'Low' : (severity == 'Medium' ? 'Medium' : 'High'),
            Loss_Type__c = lossType,
            Date_of_Loss__c = Date.today().addDays(-daysSinceLoss),
            Reported_Date__c = Date.today().addDays(-daysSinceReported),
            Loss_Location__c = location,
            Estimated_Loss__c = estimate,
            Reserve_Amount__c = reserve,
            Paid_Amount__c = paid,
            Origin = origin,
            // The supervisor takes the catastrophic losses; otherwise property and casualty claims have their own adjusters.
            Handled_By__c = (severity == 'Catastrophic' ? ANJALI : (PROPERTY_LINES.contains(policy.Line_of_Business__c) ? MARCUS : DANA)).substringBefore(',')
        );
        cases.add(record);
        return record;
    }

    // One generated household policy in this many has a claim.
    private static final Integer HOUSEHOLD_CLAIM_EVERY = 10;

    /** Claims on about three in five of the generated business policies in force and one in ten of the household ones, each inside its policy term. */
    private static void generateClaims() {
        Map<Id, Account> accountsById = new Map<Id, Account>(accounts.values());
        Map<String, Integer> usedByLine = new Map<String, Integer>();
        Integer eligible = 0;
        for (String key : claimRotation) {
            if (key == null) {
                // A policy insured elsewhere takes its turn and has no claim with us.
                eligible++;
                continue;
            }
            Policy__c policy = policies.get(key);
            String line = policy.Line_of_Business__c;
            Integer daysInForce = policy.Effective_Date__c.daysBetween(Date.today());
            if (!IN_FORCE.contains(policy.Status__c) || !CLAIM_TEMPLATES.containsKey(line) || daysInForce < 6) {
                continue;
            }
            Integer sequence = eligible++;
            Integer pick = Math.mod(sequence, 5);
            // Businesses claim often enough to fill the claims floor. Households claim far less, or the
            // personal lines would run at a loss ratio no carrier could survive.
            Boolean isHousehold = accountsById.get(policy.Account__c).Customer_Segment__c != 'Commercial Lines';
            if (isHousehold ? Math.mod(sequence, HOUSEHOLD_CLAIM_EVERY) != 0 : (pick == 2 || pick == 4)) {
                continue;
            }
            Integer used = usedByLine.containsKey(line) ? usedByLine.get(line) : 0;
            usedByLine.put(line, used + 1);
            List<String> template = CLAIM_TEMPLATES.get(line)[Math.mod(used, CLAIM_TEMPLATES.get(line).size())].split('\\|');
            Account customer = accountsById.get(policy.Account__c);
            String status = CLAIM_STATUSES[Math.mod(generatedClaims.size(), CLAIM_STATUSES.size())];

            // Older for settled claims, never before the policy started.
            Integer age = CLAIM_AGE.get(status) + Math.mod(sequence * 37, CLAIM_AGE_SPREAD.get(status));
            Integer daysSinceLoss = Math.min(age, daysInForce - 2);
            Integer daysSinceReported = Math.max(daysSinceLoss - Math.mod(sequence, 3), 0);

            Decimal estimate = (Decimal.valueOf(template[3]) * (80 + Math.mod(sequence * 17, 50)) / 100 / 50).round() * 50;
            Decimal deductible = policy.Deductible__c == null ? 0 : policy.Deductible__c;
            // Nobody claims for a loss near their deductible, so a small loss on a high deductible is scaled up to clear it.
            if (estimate < deductible * 1.5) {
                estimate = ((deductible * 1.5 + estimate / 2) / 50).round() * 50;
            }
            // What is reserved, and later paid, is the estimate less the deductible.
            Decimal settlement = estimate - deductible;
            Decimal reserve = 0;
            Decimal paid = 0;
            if (status == 'Under Investigation' || status == 'Appraisal' || status == 'Approved') {
                reserve = settlement;
            } else if (status == 'Payment Issued' || status == 'Closed') {
                reserve = settlement;
                paid = settlement;
            }
            String address = customer.BillingStreet + ', ' + customer.BillingCity + ', ' + AntsuranceAddress.state(customer, 'Billing');
            String location = template[4].replace('{address}', address).replace('{city}', customer.BillingCity + ', ' + AntsuranceAddress.state(customer, 'Billing'));
            Case generated = buildClaim(
                policy, policy.Primary_Insured__c, template[0], status, template[2], template[1], daysSinceLoss, daysSinceReported,
                location.left(120), estimate, reserve, paid, ORIGINS[Math.mod(sequence, ORIGINS.size())],
                template[5].replace('{vehicle}', line == 'Personal Auto' ? policy.Insured_Item__c.substringBefore(' and ') : 'vehicle')
            );
            if (status == 'Closed' || status == 'Denied') {
                // Closed on the day of its last note, halfway back to the day it was reported.
                generated.Closed_On__c = Date.today().addDays(-(daysSinceReported / 2));
            }
            generatedClaims.add(generated);
        }
    }

    // ---------------------------------------------------------------- service requests

    // Generated requests: request type | subject | priority | description.
    private static final List<String> AUTO_REQUESTS = new List<String>{
        'Add Vehicle|Add a newly purchased vehicle|Medium|Bought a second car this weekend and needs it added with the same coverages. The dealer needs proof of insurance.',
        'Change Coverage|Raise liability limits|Low|Asked what it would cost to raise bodily injury liability to the next limit.',
        'Policy Document Request|Needs a new proof of insurance card|Low|Lost the insurance card and needs a replacement for a registration renewal.',
        'Billing Question|Charged twice this month|Medium|The bank statement shows two drafts in the same week. Wants one refunded.',
        'Change Address|Moved across town|Low|New garaging address. Wants to know if the rate changes.'
    };
    private static final List<String> HOME_REQUESTS = new List<String>{
        'Change Coverage|Add scheduled jewelry coverage|Low|Has a new appraisal for an engagement ring and wants it scheduled.',
        'Policy Document Request|Lender needs updated declarations|Low|The mortgage company asked for a current declarations page showing the mortgagee clause.',
        'Billing Question|Escrow payment not showing|Medium|The lender says the premium was paid from escrow, but the account shows a balance due.',
        'Change Coverage|Increase the personal property limit|Low|Bought new furniture and electronics and wants a higher contents limit.'
    };
    private static final List<String> COMMERCIAL_REQUESTS = new List<String>{
        'Certificate of Insurance|Certificate for a new customer contract|High|A new customer contract requires a certificate naming them as additional insured before work starts.',
        'Change Coverage|Add a newly leased location|Medium|Signed a lease for a second location starting next month. Needs it added to the property and liability policies.',
        'Billing Question|Question about the audit premium|Medium|Received the final audit bill and does not understand the additional premium.',
        'Policy Document Request|Loss runs for a bid package|Low|Needs five years of loss runs for a contract bid due next week.'
    };
    private static final List<String> REQUEST_STATUSES = new List<String>{
        'Closed', 'In Progress', 'Closed', 'New', 'Waiting on Customer', 'Closed', 'In Progress', 'Closed', 'Waiting on Customer', 'Closed'
    };
    // The least time since a request of each status came in, and how many days longer it may be. A request
    // that is being worked or waiting on the customer can be weeks old, so the open ones do not all fall in one week.
    private static final Map<String, Integer> REQUEST_AGE = new Map<String, Integer>{ 'New' => 0, 'In Progress' => 3, 'Waiting on Customer' => 5, 'Closed' => 12 };
    private static final Map<String, Integer> REQUEST_AGE_SPREAD = new Map<String, Integer>{ 'New' => 6, 'In Progress' => 24, 'Waiting on Customer' => 36, 'Closed' => 200 };

    private static void loadServiceRequests() {
        // policy, contact, request type, subject, status, priority, days since reported, origin
        service('reyes-auto', 'maria', 'Add Driver', 'Add Sofia Reyes as a driver', 'New', 'Medium', 0, 'Phone',
            'Sofia turned 17 and passed her road test last week. Maria wants her added to the auto policy as a driver on the 2019 Honda Accord, and asked whether a good student discount applies.');
        service('whitfield-home', 'marcus', 'Change Address', 'Moving to a new home in Belvidere', 'In Progress', 'Medium', 11, 'Email',
            'The Whitfields close on a new house next month. They need the homeowners policy rewritten for the new address and want to keep the same limits.');
        service('lakeshore-gl', 'anita', 'Certificate of Insurance', 'Certificate for new landlord at the Lincoln Park office', 'New', 'High', 1, 'Email',
            'The landlord for the new Lincoln Park location needs a certificate naming them as additional insured before the lease start date.');
        service('castellano-auto', 'lucia', 'Billing Question', 'Wants to reinstate after missed payments', 'Waiting on Customer', 'High', 13, 'Phone',
            'Lucia missed two payments while changing banks. She wants to reinstate the auto policy. Waiting on the signed no-loss statement and the past due amount.');
        service('ridgeline-auto', 'dana', 'Add Vehicle', 'Add two new service vans to the fleet', 'In Progress', 'Medium', 3, 'Agent',
            'Two 2026 Ford Transit vans delivered this week. VINs and garaging address provided by the broker.');
        service('okafor-auto', 'amara', 'Change Coverage', 'Lower collision deductible to $250', 'New', 'Low', 2, 'Web',
            'Amara asked what the premium difference would be to lower the collision deductible from $500 to $250.');
        service('copperfield-gl', 'victor', 'Certificate of Insurance', 'Certificates for 14 vendors renewing this quarter', 'In Progress', 'Medium', 16, 'Email',
            'Annual vendor certificate batch. List of certificate holders attached by the insured.');
        service('bluestem-property', 'priya', 'Change Coverage', 'Add coverage for new canning line', 'Waiting on Customer', 'Medium', 19, 'Agent',
            'Bluestem installed a canning line valued at about $420,000. Need the equipment schedule and install date to endorse the policy.');
        service('nakamura-home', 'kenji', 'Policy Document Request', 'Needs declarations page for mortgage refinance', 'Closed', 'Low', 12, 'Web',
            'Sent the current declarations page and mortgagee clause to the lender.');
        service('sagebrush-auto', 'lena', 'Remove Driver', 'Remove two drivers who left the company', 'Closed', 'Low', 15, 'Email',
            'Driver list updated and confirmation sent.');
        service('dubois-renters', 'camille', 'Billing Question', 'Asked to move the payment date to the 15th', 'Closed', 'Low', 18, 'Phone',
            'Payment date changed and confirmed by email.');
        service('tamarack-gl', 'bea', 'Billing Question', 'Past due notice received, says payment was mailed', 'New', 'Medium', 1, 'Phone',
            'Bea received a past due notice for the liability policy and says a check was mailed two weeks ago.');

        generateServiceRequests();
    }

    private static void service(
        String policyKey, String contactKey, String requestType, String subject, String status, String priority, Integer daysSinceReported, String origin, String description
    ) {
        casesBySubject.put(
            subject,
            buildService(policies.get(policyKey), contacts.get(contactKey).Id, requestType, subject, status, priority, daysSinceReported, origin, description)
        );
    }

    private static Case buildService(
        Policy__c policy, Id contactId, String requestType, String subject, String status, String priority, Integer daysSinceReported, String origin, String description
    ) {
        Case record = new Case(
            RecordTypeId = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId(),
            Policy__c = policy.Id,
            AccountId = policy.Account__c,
            ContactId = contactId,
            Request_Type__c = requestType,
            Subject = subject,
            Description = description,
            Status = status,
            Priority = priority,
            Reported_Date__c = Date.today().addDays(-daysSinceReported),
            Origin = origin,
            Handled_By__c = BRIDGET.substringBefore(',')
        );
        if (status == 'Closed') {
            // Most requests are dealt with within a few days of coming in.
            record.Closed_On__c = Date.today().addDays(-Math.max(daysSinceReported - 1 - Math.mod(cases.size(), 4), 0));
        }
        cases.add(record);
        return record;
    }

    /** A service request on about every fourth generated policy, skipping umbrellas and policies that are no longer live. */
    private static void generateServiceRequests() {
        Set<String> serviceable = new Set<String>{ 'Active', 'Pending Renewal', 'Lapsed' };
        Integer made = 0;
        for (Integer sequence = 2; sequence < generatedPolicyKeys.size(); sequence += 4) {
            Integer chosen = sequence;
            Policy__c policy = policies.get(generatedPolicyKeys[chosen]);
            // Step back to the nearest policy someone would actually call about.
            while (chosen > sequence - 2 && (policy.Line_of_Business__c == 'Umbrella' || !serviceable.contains(policy.Status__c))) {
                chosen--;
                policy = policies.get(generatedPolicyKeys[chosen]);
            }
            String line = policy.Line_of_Business__c;
            List<String> templates = line == 'Personal Auto' ? AUTO_REQUESTS : ((line == 'Homeowners' || line == 'Renters') ? HOME_REQUESTS : COMMERCIAL_REQUESTS);
            List<String> template = templates[Math.mod(made, templates.size())].split('\\|');
            String status = REQUEST_STATUSES[Math.mod(made, REQUEST_STATUSES.size())];
            // Never before the policy started.
            Integer daysInForce = Math.max(policy.Effective_Date__c.daysBetween(Date.today()), 0);
            Integer age = Math.min(REQUEST_AGE.get(status) + Math.mod(made * 13, REQUEST_AGE_SPREAD.get(status)), daysInForce);
            buildService(policy, policy.Primary_Insured__c, template[0], template[1], status, template[2], age, ORIGINS[Math.mod(made, ORIGINS.size())], template[3]);
            made++;
        }
    }

    // ---------------------------------------------------------------- tasks

    private static void loadFollowUpTasks() {
        insert new List<Task>{
            task(casesBySubject.get('Burst pipe flooded finished basement'), 'Review the drying vendor invoice', 2, 'High'),
            task(casesBySubject.get('2023 BMW X5 stolen from driveway'), 'Get statement and key fob analysis', 1, 'High'),
            task(casesBySubject.get('Taproom guest slipped on wet floor'), 'Send footage to defense counsel', 3, 'Normal'),
            task(casesBySubject.get('Installer fell from second-story roof'), 'Call the nurse case manager', 2, 'High'),
            task(casesBySubject.get('Hail damage to roof and skylights'), 'Compare estimate with our scope', 2, 'Normal'),
            task(casesBySubject.get('Kitchen fire spread to three apartments'), 'Open the range subrogation file', 4, 'High'),
            task(casesBySubject.get('Wants to reinstate after missed payments'), 'Chase the no-loss statement', -1, 'High'),
            task(casesBySubject.get('Add coverage for new canning line'), 'Chase the equipment schedule', 1, 'Normal')
        };
    }

    private static Task task(Case record, String subject, Integer dueInDays, String priority) {
        return new Task(
            WhatId = record.Id, WhoId = record.ContactId, Subject = subject, ActivityDate = Date.today().addDays(dueInDays),
            Priority = priority, Status = 'Not Started', Description = handlerNote(record)
        );
    }

    /** Every task belongs to the one demo user, so a task on a claim or request says in its comments whose work it is. */
    private static String handlerNote(Case record) {
        return String.isBlank(record.Handled_By__c) ? null : 'With ' + record.Handled_By__c + ', who is handling this file.';
    }

    // ---------------------------------------------------------------- file notes

    private static void loadFileNotes() {
        claimNotesNew();
        claimNotesUnderInvestigation();
        claimNotesInAppraisalAndApproved();
        claimNotesPaidAndClosed();
        serviceRequestNotes();
        policyNotes();
        generatedClaimNotes();
        insert notes;
    }

    private static void claimNotesNew() {
        String rearEnd = 'Rear-ended at a red light on Harlem Ave';
        caseNote(rearEnd, 1, 9, 'Contact', DANA, '**First notice:** Hana reported through the app with photos. Stopped at a red light, struck from behind. No injuries.\n\n**Other party:** Driver cited at the scene. Plate and carrier details are in the police report she gave us.');
        caseNote(rearEnd, 1, 11, 'Coverage', DANA, '**Coverage:** Policy in force on the date of loss. Collision applies with a $500 deductible.\n\n**Subrogation:** Clear liability on the other driver. Flagged for recovery.');
        caseNote(rearEnd, 0, 9, 'Investigation', DANA, '**Next steps:**\n- The Oak Park crash report is on the file and names the other driver\'s carrier\n- Hana sent a phone photo of the shop\'s repair estimate\n- Put the other carrier on notice of our recovery claim');

        String deer = 'Deer strike on Route 20, front-end damage';
        caseNote(deer, 1, 16, 'Contact', DANA, '**First notice:** Renee called from the roadside. Deer strike at dusk, airbags did not deploy, nobody hurt. Vehicle towed to Rockford.');
        caseNote(deer, 1, 17, 'Coverage', DANA, '**Coverage:** An animal strike falls under comprehensive, with a $500 deductible. Towing is covered by the roadside benefit.');
        caseNote(deer, 0, 10, 'Investigation', DANA, '**Estimate:** Rockford Collision is writing the repair estimate. Until it arrives, the $9,400 taken at first notice stands. Radiator and headlamp damage may keep the Expedition off the road for two weeks. Rental reimbursement explained to Renee.');

        String cooler = 'Walk-in cooler failed, food spoilage';
        caseNote(cooler, 2, 14, 'Contact', MARCUS, '**First notice:** Rosa emailed to report the loss. The compressor failed overnight and stock for two catering events was lost. She has the repair invoice and a spoilage inventory and will send both.');
        caseNote(cooler, 1, 10, 'Coverage', MARCUS, '**Coverage question:** Spoilage from mechanical breakdown needs the equipment breakdown endorsement. Checking the policy forms before confirming.');
        caseNote(cooler, 0, 11, 'Investigation', MARCUS, '**Requested:**\n- Technician report on the cause of failure\n- Purchase invoices to support the inventory values');

        String parked = 'Hit a parked car in a grocery store lot';
        caseNote(parked, 3, 15, 'Contact', DANA, '**First notice:** Lucia called. She clipped a parked sedan while pulling into a space. Damage to her bumper and the other car\'s rear door. She left a note with her details.');
        caseNote(parked, 3, 16, 'Coverage', DANA, '**Coverage problem:** The auto policy lapsed for non-payment before the date of loss. The system check shows the policy was not in force.\n\n**Action:** Sent to Anjali for a coverage decision before anything is promised.');
        caseNote(parked, 2, 10, 'Coverage', ANJALI, '**Review:** The lapse notice was mailed and the grace period ended before the loss. No payment was received in the grace period.\n\n**Decision pending:** A reinstatement request is open with service. A reinstatement would not cover a loss that had already happened.');
        caseNote(parked, 1, 14, 'Contact', DANA, '**Call with Lucia:** Explained that coverage is unlikely and why. She was upset but understood. She asked about the reinstatement and I pointed her to Bridget.');
    }

    private static void claimNotesUnderInvestigation() {
        String pipe = 'Burst pipe flooded finished basement';
        caseNote(pipe, 10, 9, 'Contact', MARCUS, '**First notice:** Chinedu called on returning from a weekend away. The supply line to the basement bathroom burst. Standing water across the finished basement.\n\n**Emergency:** Authorized a mitigation vendor to start extraction and drying today.');
        caseNote(pipe, 9, 14, 'Investigation', MARCUS, '**Inspection:** A braided supply line failed at the fitting. Damage to flooring, drywall to four feet, the furnace and stored belongings.\n\n**Coverage:** Sudden and accidental discharge is covered. The $2,500 deductible applies.');
        caseNote(pipe, 8, 11, 'Reserve', MARCUS, '**Reserve set at $45,000:**\n- Mitigation and drying $9,500\n- Rebuild $24,000\n- Furnace $5,500\n- Contents $6,000');
        caseNote(pipe, 6, 15, 'Payment', MARCUS, '**Advance paid:** $5,000 to the Okafors for emergency drying and immediate needs.');
        caseNote(pipe, 2, 10, 'Investigation', MARCUS, '**Status:** Drying is complete and moisture readings are normal. Waiting on the mitigation invoice and the contractor\'s rebuild estimate.');

        String theft = '2023 BMW X5 stolen from driveway';
        caseNote(theft, 15, 10, 'Contact', DANA, '**First notice:** Omar reported the BMW taken from the driveway overnight. Police report filed. Both key fobs are with him.');
        caseNote(theft, 14, 11, 'Investigation', DANA, '**Red flags:**\n- No forced entry and both fobs accounted for\n- The lender confirmed by phone two missed payments before the loss\n- The vehicle was listed for sale last month\n\n**Action:** Referred to SIU.');
        caseNote(theft, 13, 9, 'Investigation', TOMASZ, '**SIU opened.** Requested the recorded statement, a key fob read, the lender payoff and phone records for the night of the loss.');
        caseNote(theft, 12, 15, 'Reserve', ANJALI, '**Reserve approved at $58,000**, actual cash value less the deductible, pending SIU.');
        caseNote(theft, 6, 13, 'Investigation', TOMASZ, '**Update:** Recorded statement taken and held in the SIU file. The timeline is consistent so far. The fob analysis is due from the dealer next week. License plate reader search requested from the police.');
        caseNote(theft, 1, 10, 'Contact', DANA, '**Call with Omar:** He asked when he will be paid. Explained that the investigation is still open and that the rental benefit runs for 30 days.');

        String slip = 'Taproom guest slipped on wet floor';
        caseNote(slip, 22, 10, 'Contact', DANA, '**First notice:** Reported by the broker. A guest slipped near the bar after a keg line leak and fractured a wrist.');
        caseNote(slip, 20, 14, 'Investigation', DANA, '**Reviewed at the taproom with Joe:** The incident report, two staff statements and the camera footage. The footage shows the leak about six minutes before the fall and no wet floor sign. Joe is sending copies.');
        caseNote(slip, 16, 11, 'Reserve', ANJALI, '**Reserve set at $42,000** for medical, lost wages and general damages. Liability looks adverse.');
        caseNote(slip, 9, 9, 'Contact', DANA, '**Counsel:** The claimant has retained an attorney, who called to say so. All contact now goes through counsel.');
        caseNote(slip, 3, 15, 'Investigation', DANA, '**Next:** The footage goes to defense counsel as soon as Joe\'s copy arrives. Medical records requested through the claimant\'s attorney.');

        String fall = 'Installer fell from second-story roof';
        caseNote(fall, 8, 13, 'Contact', DANA, '**First notice:** Miguel Ortega called from the hospital. An installer fell about 18 feet when an anchor point failed. Fractured pelvis and vertebrae. Admitted.');
        caseNote(fall, 8, 15, 'Coverage', DANA, '**Coverage:** The employee was in the course of employment, so the claim is compensable. The insured has notified OSHA.');
        caseNote(fall, 7, 10, 'Reserve', ANJALI, '**Reserve set at $285,000:**\n- Medical $190,000\n- Lost wages $75,000\n- Expense $20,000\n\nNurse case manager assigned.');
        caseNote(fall, 5, 14, 'Payment', DANA, '**Paid $18,500** on the hospital\'s interim bill for the emergency admission and first surgery.');
        caseNote(fall, 3, 11, 'Investigation', DANA, '**Anchor failure:** The anchor was a rented unit. Ridgeline has set the unit aside for our engineer, as the employer\'s first report says. Possible recovery against the rental company.');
        caseNote(fall, 1, 9, 'Contact', DANA, '**Family call:** Spoke with the installer\'s wife about wage payments and what to expect. The first wage check goes out this week.');
    }

    private static void claimNotesInAppraisalAndApproved() {
        String hail = 'Hail damage to roof and skylights';
        caseNote(hail, 17, 10, 'Contact', MARCUS, '**First notice:** Reported by Hal Brennan at Prairie State. Golf-ball hail damaged the cedar shake roof, two skylights and gutters.');
        caseNote(hail, 14, 13, 'Investigation', MARCUS, '**Inspection:** The independent adjuster found hail hits on all slopes, both skylights cracked and gutters dented. The roof is original.');
        caseNote(hail, 12, 11, 'Reserve', MARCUS, '**Reserve set at $12,500.** The roof is repairable by slope under our scope. The contractor is proposing full replacement.');
        caseNote(hail, 5, 15, 'Investigation', MARCUS, '**Difference in scope:** The contractor quoted $51,200 by phone for full replacement and is sending the written estimate. Ours is $17,500. A joint inspection may be needed.');

        String fire = 'Kitchen fire spread to three apartments';
        caseNote(fire, 27, 8, 'Contact', MARCUS, '**First notice:** Nora Whitcombe called at 6 am. A fire in a third-floor kitchen at 1840 N Kedzie spread to two neighboring units. Fire department on scene and no injuries.');
        caseNote(fire, 26, 14, 'Investigation', MARCUS, '**Site visit:** Three units burned out, with smoke and water damage on two floors. Eleven tenants relocated. Building secured and boarded.');
        caseNote(fire, 24, 10, 'Reserve', ANJALI, '**Reserve set at $215,000:**\n- Building $150,000\n- Loss of rents $40,000\n- Emergency services $25,000');
        caseNote(fire, 20, 11, 'Payment', MARCUS, '**Paid $35,000** for emergency services, board-up and tenant relocation.');
        caseNote(fire, 13, 15, 'Investigation', MARCUS, '**Cause and origin:** The fire investigator called with the finding: a range failure, not tenant misuse. The written report is to follow. The range is preserved as evidence.\n\n**Subrogation:** Opening a recovery file against the manufacturer.');
        caseNote(fire, 4, 9, 'Investigation', MARCUS, '**Building estimate:** The engineer confirmed the structure is sound. Contractor bids are due Friday.');

        String burglary = 'Apartment burglary, laptop and bike stolen';
        caseNote(burglary, 20, 12, 'Contact', MARCUS, '**First notice:** Filed online. Break-in through a rear window. Laptop, road bike and camera taken. Police report filed.');
        caseNote(burglary, 16, 10, 'Investigation', MARCUS, '**Values:** Laptop and bike prices confirmed with the retailers from Erik\'s order numbers. The camera was valued from a like model on sale today.');
        caseNote(burglary, 9, 14, 'Reserve', MARCUS, '**Settlement agreed at $1,450** after the $250 deductible. Erik accepted by text.');

        String jackknife = 'Tractor-trailer jackknifed on I-80, cargo loss';
        caseNote(jackknife, 33, 7, 'Contact', DANA, '**First notice:** Lena called from dispatch. Unit 217 jackknifed in freezing rain and hit the median. Driver treated and released.');
        caseNote(jackknife, 30, 13, 'Investigation', DANA, '**Appraisal:** The tractor is a total loss and the trailer is repairable. Telematics show 48 mph in a 65 zone, which was reasonable for the conditions.');
        caseNote(jackknife, 25, 10, 'Reserve', ANJALI, '**Reserve set at $121,000:** tractor $96,000, trailer $18,000, towing and storage $7,000.');
        caseNote(jackknife, 15, 15, 'Payment', DANA, '**Paid $40,000** toward the tractor to the lienholder. The balance follows when the title is released.');
        caseNote(jackknife, 6, 11, 'Contact', DANA, '**Update for Lena:** Trailer repair approved. The cargo claim is with the shipper\'s carrier, not this policy.');
    }

    private static void claimNotesPaidAndClosed() {
        String scrape = 'Parking lot scrape, rear quarter panel';
        caseNote(scrape, 28, 12, 'Contact', DANA, '**First notice:** Daniel reported through the app. Scraped a bollard while backing the 2019 Honda Accord out. Photos attached.');
        caseNote(scrape, 24, 10, 'Investigation', DANA, '**Estimate:** The network shop wrote $2,350. Photo estimate approved without an inspection.');
        caseNote(scrape, 12, 14, 'Payment', DANA, '**Paid $1,850** to the shop after the $500 deductible. Repairs complete and guaranteed.');

        String window = 'Storefront window smashed, merchandise taken';
        caseNote(window, 40, 9, 'Contact', MARCUS, '**First notice:** Bea called from the shop. The front window was smashed overnight and jackets and packs were taken from the display.');
        caseNote(window, 36, 13, 'Investigation', MARCUS, '**Checked:** The police report number with Madison Police, the board-up and glass costs with the two vendors, and the stock loss against the point of sale system.');
        caseNote(window, 22, 11, 'Payment', MARCUS, '**Paid $12,300:** glass and board-up $4,100, stock $10,700, less the $2,500 deductible.');

        String glass = 'Cracked windshield from road debris';
        caseNote(glass, 58, 13, 'Contact', DANA, '**First notice:** Reported in the app. A rock from a gravel truck cracked the windshield.');
        caseNote(glass, 55, 10, 'Payment', DANA, '**Paid $780** to the mobile glass vendor. Camera recalibrated. No deductible on glass. Closed.');

        String dock = 'Forklift struck loading dock door';
        caseNote(dock, 71, 10, 'Contact', MARCUS, '**First notice:** Reported by Prairie State. A forklift struck an overhead dock door and bent the track.');
        caseNote(dock, 60, 14, 'Payment', MARCUS, '**Paid $6,700** for the door and leveler after the $25,000 deductible. Suggested bollards at the dock. Closed.');

        String wedding = 'Guest alleges food poisoning after wedding';
        caseNote(wedding, 60, 11, 'Contact', DANA, '**First notice:** One wedding guest alleges illness after the catered dinner. Rosa says no other guest complained.');
        caseNote(wedding, 52, 15, 'Investigation', DANA, '**Findings:** The health department inspection found no violations. Temperature logs are complete. 140 guests, one complaint, and no medical records produced.');
        caseNote(wedding, 45, 10, 'Coverage', ANJALI, '**Denied:** No evidence the food caused the illness. Denial letter sent to the claimant with our findings.');
    }

    private static void serviceRequestNotes() {
        caseNote('Add Sofia Reyes as a driver', 0, 9, 'Service', BRIDGET, '**Call with Maria:** Sofia passed her road test and will mostly drive the 2019 Honda Accord.\n\n**Needed:** License number, date licensed and a recent report card for the good student discount.');
        caseNote('Moving to a new home in Belvidere', 4, 10, 'Service', BRIDGET, '**Request:** Closing next month on a house in Belvidere. They want the same limits.');
        caseNote('Moving to a new home in Belvidere', 2, 14, 'Service', BRIDGET, '**Quote:** The new address rates slightly lower. Waiting on the closing date and the lender\'s mortgagee clause.');
        caseNote('Certificate for new landlord at the Lincoln Park office', 1, 11, 'Service', BRIDGET, '**Request:** The landlord needs to be named as additional insured before the lease starts on the 1st.\n\n**Next:** Confirm the landlord\'s legal name from the lease.');
        caseNote('Wants to reinstate after missed payments', 6, 16, 'Contact', BRIDGET, '**Call with Lucia:** Two drafts failed when she changed banks. She wants the auto policy back.');
        caseNote('Wants to reinstate after missed payments', 4, 10, 'Service', BRIDGET, '**Sent:** The no-loss statement and the past due amount.\n\n**Problem:** A loss was reported after the lapse, so she may not be able to sign the statement. Raised with Anjali.');
        caseNote('Add two new service vans to the fleet', 3, 13, 'Service', BRIDGET, '**Received:** VINs and garaging address from the broker.');
        caseNote('Add two new service vans to the fleet', 1, 10, 'Underwriting', HUGH, '**Rated:** Two 2026 Ford Transit vans add about $3,900 a year. The endorsement is issued once Dana Kowalski approves.');
        caseNote('Lower collision deductible to $250', 1, 15, 'Service', BRIDGET, '**Quoted:** Lowering collision from $500 to $250 adds $86 a year. Emailed Amara the comparison.');
        caseNote('Certificates for 14 vendors renewing this quarter', 4, 11, 'Service', BRIDGET, '**Progress:** 9 of 14 certificates issued. Five holders need corrected addresses from Nora.');
        caseNote('Add coverage for new canning line', 9, 14, 'Service', BRIDGET, '**Request from the broker:** New canning line installed, value about $420,000. Asked for the equipment schedule.');
        caseNote('Add coverage for new canning line', 5, 10, 'Underwriting', HUGH, '**Needed to endorse:** Equipment schedule with serial numbers, the install date and whether it is financed. Asked the broker twice.');
        caseNote('Past due notice received, says payment was mailed', 1, 12, 'Service', BRIDGET, '**Call with Bea:** She says a check was mailed two weeks ago. Nothing has posted yet. Asked for the check number and offered a card payment to stop the notice.');
    }

    private static void policyNotes() {
        policyNote('ironwood-wc', 12, 10, 'Underwriting', HUGH, '**Renewal review:** Payroll is up 9 percent and the experience modification is 0.94. Quote released at $149,500 and sent to Prairie State.');
        policyNote('ironwood-gl', 8, 14, 'Underwriting', HUGH, '**Renewal:** Waiting on updated revenue figures before releasing the liability quote.');
        policyNote('copperfield-property', 18, 11, 'Underwriting', HUGH, '**Mid-term review after the Kedzie fire:** Recommending stovetop suppression canisters in all 312 units as a renewal condition.');
        policyNote('sagebrush-auto', 21, 9, 'Underwriting', HUGH, '**Fleet review:** Telematics scores are in the top quarter of the peer group. One total loss this term, in severe weather.');
        policyNote('ridgeline-wc', 5, 15, 'Underwriting', HUGH, '**After the fall claim:** Asked for the corrective action report and anchor inspection logs. The fall protection program will be a renewal condition.');
        policyNote('bluestem-property', 7, 10, 'Underwriting', HUGH, '**Canning line:** Value about $420,000. It will be added to business personal property once the equipment schedule arrives.');
        policyNote('nakamura-home', 6, 13, 'Service', BRIDGET, '**Renewal:** Offer sent at $2,810. Kenji asked for the declarations page for a refinance, so the mortgagee will change at renewal.');
        policyNote('castellano-auto', 20, 9, 'Service', BRIDGET, '**Lapse:** The second draft was returned. Cancellation notice mailed. The policy lapsed at the end of the grace period.');
        policyNote('dubois-auto', 3, 16, 'Service', BRIDGET, '**Quote follow-up:** Camille is comparing two other carriers. Reminded her of the multi-policy discount with her renters policy.');
        policyNote('abernathy-home', 9, 11, 'Underwriting', HUGH, '**Roof:** With the hail claim open, renewal will need either a roof replacement or a wind and hail deductible. Told Hal Brennan so there are no surprises.');
    }

    /** A first-contact note on every generated claim, and a second that matches where the claim has got to. */
    private static void generatedClaimNotes() {
        Map<Id, Contact> contactsById = new Map<Id, Contact>(contacts.values());
        Map<Id, Policy__c> policiesById = new Map<Id, Policy__c>(policies.values());
        for (Case record : generatedClaims) {
            Policy__c policy = policiesById.get(record.Policy__c);
            String adjuster = PROPERTY_LINES.contains(policy.Line_of_Business__c) ? MARCUS : DANA;
            Integer reportedDaysAgo = record.Reported_Date__c.daysBetween(Date.today());
            String channel = record.Origin == 'Phone' ? 'by phone' : (record.Origin == 'Agent' ? 'through the agent' : 'through the ' + record.Origin.toLowerCase());
            note(record, record.Policy__c, record.AccountId, reportedDaysAgo, 10, 'Contact', adjuster,
                '**First notice:** ' + contactsById.get(record.ContactId).FirstName + ' reported the loss ' + channel + '. Facts confirmed and next steps explained.');

            String noteType;
            String body;
            switch on record.Status {
                when 'Closed' {
                    noteType = 'Payment';
                    Boolean hasDeductible = policy.Deductible__c != null && policy.Deductible__c > 0;
                    body = '**Paid ' + money(record.Paid_Amount__c) + '** ' + (hasDeductible ? 'after the ' + money(policy.Deductible__c) + ' deductible' : 'with no deductible') + '. Receipt confirmed. Closed.';
                }
                when 'Payment Issued' {
                    noteType = 'Payment';
                    body = '**Paid ' + money(record.Paid_Amount__c) + '.** Waiting for confirmation that the work is complete before closing.';
                }
                when 'Denied' {
                    noteType = 'Coverage';
                    body = '**Denied:** The facts do not support a covered loss under the policy. Denial letter sent with the policy wording.';
                }
                when 'Under Investigation' {
                    noteType = 'Investigation';
                    body = '**Investigating:** Statements and documents requested. Reserve set at ' + money(record.Reserve_Amount__c) + '.';
                }
                when 'Appraisal' {
                    noteType = 'Investigation';
                    body = '**Appraisal:** The estimate is under review against our scope. Reserve set at ' + money(record.Reserve_Amount__c) + '.';
                }
                when 'Approved' {
                    noteType = 'Reserve';
                    body = '**Approved:** Settlement agreed at ' + money(record.Reserve_Amount__c) + '. Payment is being issued.';
                }
            }
            if (body != null) {
                note(record, record.Policy__c, record.AccountId, reportedDaysAgo / 2, 14, noteType, adjuster, body);
            }
        }
    }

    private static String money(Decimal amount) {
        return '$' + (amount == null ? 0 : amount).setScale(0).format();
    }

    private static void caseNote(String subject, Integer daysAgo, Integer hour, String noteType, String author, String body) {
        Case record = casesBySubject.get(subject);
        note(record, record.Policy__c, record.AccountId, daysAgo, hour, noteType, author, body);
    }

    private static void policyNote(String policyKey, Integer daysAgo, Integer hour, String noteType, String author, String body) {
        Policy__c policy = policies.get(policyKey);
        note(null, policy.Id, policy.Account__c, daysAgo, hour, noteType, author, body);
    }

    private static void note(Case record, Id policyId, Id accountId, Integer daysAgo, Integer hour, String noteType, String author, String body) {
        Datetime written = Datetime.newInstance(Date.today().addDays(-daysAgo), Time.newInstance(hour, Math.mod(notes.size() * 7, 60), 0, 0));
        // A note dated today cannot be later than now.
        Datetime latest = Datetime.now().addMinutes(-5);
        notes.add(new File_Note__c(
            Case__c = record?.Id, Policy__c = policyId, Account__c = accountId, Note_Type__c = noteType, Author_Name__c = author, Body__c = body,
            Note_Date__c = written > latest ? latest : written
        ));
    }

    // ---------------------------------------------------------------- sales

    private static final List<String> RENEWAL_STAGES = new List<String>{ 'Quote Issued', 'Underwriting Review', 'Bind Requested', 'Submission Received' };

    private static void loadOpportunities() {
        // account, name, line, type, stage, premium, days until close, policy being renewed
        sale('ironwood', 'Ironwood Machine Works - Workers Comp renewal', 'Workers Compensation', 'Renewal', 'Quote Issued', 149500, 28, 'ironwood-wc');
        sale('ironwood', 'Ironwood Machine Works - General Liability renewal', 'General Liability', 'Renewal', 'Underwriting Review', 46200, 28, 'ironwood-gl');
        sale('nakamura', 'Nakamura Household - Homeowners renewal', 'Homeowners', 'Renewal', 'Bind Requested', 2810, 21, 'nakamura-home');
        sale('whitfield', 'Whitfield Household - Homeowners renewal', 'Homeowners', 'Renewal', 'Quote Issued', 1820, 14, 'whitfield-home');
        sale('sagebrush', 'Sagebrush Freight Lines - Cargo and umbrella', 'Umbrella', 'Cross-Sell', 'Underwriting Review', 64000, 45, null);
        sale('lakeshore', 'Lakeshore Dental Group - Workers Comp', 'Workers Compensation', 'Cross-Sell', 'Submission Received', 18700, 60, null);
        sale('dubois', 'Dubois Household - Personal Auto', 'Personal Auto', 'Cross-Sell', 'Quote Issued', 1560, 9, 'dubois-auto');
        sale('bluestem', 'Bluestem Brewing - Second taproom property', 'Commercial Property', 'New Business', 'Submission Received', 9800, 52, null);
        sale('copperfield', 'Copperfield - Two buildings added to schedule', 'Commercial Property', 'New Business', 'Bind Requested', 27400, 12, null);
        sale('tamarack', 'Tamarack Outfitters - Commercial Auto for delivery van', 'Commercial Auto', 'Cross-Sell', 'Quote Issued', 3400, 24, null);
        sale('lindqvist', 'Lindqvist Household - Umbrella', 'Umbrella', 'Cross-Sell', 'Submission Received', 320, 38, null);
        sale('ridgeline', 'Ridgeline Roofing - Excess liability', 'Umbrella', 'New Business', 'Underwriting Review', 41000, 33, null);
        sale('okafor', 'Okafor Household - Umbrella', 'Umbrella', 'Cross-Sell', 'Bound', 480, -20, 'okafor-umbrella');
        sale('marigold', 'Marigold Cafe - Workers Comp', 'Workers Compensation', 'Cross-Sell', 'Declined', 6100, -34, null);

        // A renewal for every generated policy that is waiting on one, closing on its expiration date.
        Map<Id, Account> accountsById = new Map<Id, Account>(accounts.values());
        Integer renewals = 0;
        for (String key : generatedPolicyKeys) {
            Policy__c policy = policies.get(key);
            if (policy.Status__c != 'Pending Renewal') {
                continue;
            }
            Account customer = accountsById.get(policy.Account__c);
            opportunity(
                customer.Id, customer.Name + ' - ' + policy.Line_of_Business__c + ' renewal', policy.Line_of_Business__c, 'Renewal',
                RENEWAL_STAGES[Math.mod(renewals++, RENEWAL_STAGES.size())], (policy.Annual_Premium__c * 1.05).setScale(0),
                Date.today().daysBetween(policy.Expiration_Date__c), policy.Id
            );
        }
        sale('takahashi', 'Takahashi Household - Personal Auto', 'Personal Auto', 'Cross-Sell', 'Quote Issued', policies.get('takahashi-auto').Annual_Premium__c, 11, 'takahashi-auto');

        // Umbrella offers to households that own a home and do not have one.
        sale('alvarez', 'Alvarez Household - Umbrella', 'Umbrella', 'Cross-Sell', 'Bound', 420, -12, 'alvarez-umbrella');
        sale('chen', 'Chen Household - Umbrella', 'Umbrella', 'Cross-Sell', 'Quote Issued', 455, 18, null);
        sale('eriksen', 'Eriksen Household - Umbrella', 'Umbrella', 'Cross-Sell', 'Submission Received', 390, 41, null);
        sale('ivanov', 'Ivanov Household - Umbrella', 'Umbrella', 'Cross-Sell', 'Declined', 380, -25, null);
        sale('mbeki', 'Mbeki Household - Umbrella', 'Umbrella', 'Cross-Sell', 'Underwriting Review', 510, 30, null);
        sale('schmidt', 'Schmidt Household - Umbrella', 'Umbrella', 'Cross-Sell', 'Quote Issued', 440, 22, null);

        // New lines for businesses that already insure something with us.
        sale('wolfroad', 'Wolf Road Auto Body - Workers Comp', 'Workers Compensation', 'Cross-Sell', 'Submission Received', 10560, 47, null);
        sale('lincolnsq', 'Lincoln Square Books & Paper - Workers Comp', 'Workers Compensation', 'Cross-Sell', 'Quote Issued', 2160, 16, null);
        sale('pawpaw', 'Paw Paw Lake Craft Distillers - Workers Comp', 'Workers Compensation', 'Cross-Sell', 'Underwriting Review', 7840, 35, null);
        sale('halsted', 'Halsted Street Bistro - Commercial Auto for catering van', 'Commercial Auto', 'Cross-Sell', 'Bound', 3900, -18, 'halsted-auto');
        sale('summit', 'Summit Climbing Gym - Umbrella', 'Umbrella', 'Cross-Sell', 'Declined', 5200, -40, null);
        sale('riverbend', 'Riverbend Veterinary Clinic - Umbrella', 'Umbrella', 'Cross-Sell', 'Quote Issued', 4800, 27, null);
        sale('prairiewind', 'Prairie Wind Hotels - Commercial Auto for shuttle vans', 'Commercial Auto', 'New Business', 'Bind Requested', 7800, 8, null);

        addBoundHistory(accountsById);

        insert opportunities;
        for (Opportunity sale : opportunities) {
            salesByName.put(sale.Name, sale);
        }
    }

    private static final Set<String> CLOSED_CASE_STATUSES = new Set<String>{ 'Closed', 'Denied' };
    private static final Set<String> CLOSED_SALE_STAGES = new Set<String>{ 'Bound', 'Declined' };
    // How far back the book shows business being bound, and after how long a bound sale counts as history.
    private static final Integer HISTORY_MONTHS = 6;
    private static final Integer RECENT_BIND_DAYS = 25;

    /**
     * The sales that became policies already in the book: for each of the last six months, one household
     * policy and one business policy that took effect that month, closed as Bound three days before. No new
     * policies are made, so the bound-premium chart gets a shape for the price of a sale and a quote each.
     */
    private static void addBoundHistory(Map<Id, Account> accountsById) {
        Set<Id> alreadySold = new Set<Id>();
        Set<String> names = new Set<String>();
        for (Opportunity sale : opportunities) {
            names.add(sale.Name);
            if (sale.Policy__c != null) {
                alreadySold.add(sale.Policy__c);
            }
        }
        Set<String> filled = new Set<String>();
        for (String key : generatedPolicyKeys) {
            Policy__c policy = policies.get(key);
            Account customer = accountsById.get(policy.Account__c);
            Integer daysInForce = policy.Effective_Date__c.daysBetween(Date.today());
            Integer monthsAgo = daysInForce / 30;
            String slot = monthsAgo + (customer.Customer_Segment__c == 'Commercial Lines' ? ' business' : ' household');
            String name = customer.Name + ' - ' + policy.Line_of_Business__c;
            // General liability is left out: its quote would re-rate the business's revenue, which its policy already states.
            if (
                policy.Status__c != 'Active' || alreadySold.contains(policy.Id) || monthsAgo < 1 || monthsAgo > HISTORY_MONTHS || filled.contains(slot) ||
                names.contains(name) || policy.Line_of_Business__c == 'General Liability'
            ) {
                continue;
            }
            filled.add(slot);
            names.add(name);
            opportunity(customer.Id, name, policy.Line_of_Business__c, 'New Business', 'Bound', policy.Annual_Premium__c, -(daysInForce + 3), policy.Id);
        }
    }

    private static void sale(String accountKey, String name, String line, String type, String stage, Decimal premium, Integer daysUntilClose, String policyKey) {
        opportunity(accounts.get(accountKey).Id, name, line, type, stage, premium, daysUntilClose, policyKey == null ? null : policies.get(policyKey).Id);
    }

    private static void opportunity(Id accountId, String name, String line, String type, String stage, Decimal premium, Integer daysUntilClose, Id policyId) {
        opportunities.add(new Opportunity(
            RecordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName().get('Policy_Sale').getRecordTypeId(),
            AccountId = accountId,
            Name = name.left(120),
            Line_of_Business__c = line,
            Type = type,
            StageName = stage,
            Amount = premium,
            CloseDate = Date.today().addDays(daysUntilClose),
            Policy__c = policyId,
            LeadSource = type == 'New Business' ? 'Partner Referral' : null
        ));
    }

    // ---------------------------------------------------------------- quotes

    // By line: lead option | cheaper option | its premium as a percent of the lead | richer option | its percent | what the lead includes | what the richer option adds
    private static final Map<String, String> QUOTE_OPTIONS = new Map<String, String>{
        'Personal Auto' => 'Standard deductible|Higher deductible, lower premium|92|Adds rental and roadside|106|Liability, collision, comprehensive and uninsured motorist|rental reimbursement and roadside assistance',
        'Homeowners' => 'Standard deductible|Higher deductible, lower premium|91|Adds equipment breakdown cover|105|Dwelling, personal property, loss of use and personal liability|equipment breakdown and service line cover',
        'Renters' => 'Standard deductible|Higher deductible, lower premium|93|Adds replacement cost on contents|108|Personal property, loss of use and personal liability|replacement cost settlement on contents',
        'Umbrella' => 'Standard limit|Lower limit, lower premium|70|Double the limit|155|Excess liability over the underlying policies|twice the excess limit',
        'Commercial Property' => 'Standard deductible|Higher deductible, lower premium|92|Adds equipment breakdown|104|Building, business personal property and business income|equipment breakdown and spoilage cover',
        'General Liability' => 'Standard limits|Higher deductible, lower premium|93|Higher aggregate limit|111|Premises and operations, products and completed operations and medical expense|a higher aggregate limit',
        'Workers Compensation' => 'Guaranteed cost|Small deductible plan|93|Adds voluntary compensation|102|Statutory workers compensation and employers liability|voluntary compensation for officers who opted out',
        'Commercial Auto' => 'Standard deductible|Higher deductible, lower premium|92|Adds hired and non-owned auto|103|Liability, collision and comprehensive for the scheduled vehicles|hired and non-owned auto liability'
    };
    // Days since the options on each quoted sale went out: some have sat for weeks, some are fresh.
    private static final List<Integer> QUOTE_AGES = new List<Integer>{ 12, 5, 31, 9, 18, 3, 27, 22, 36, 7, 20 };
    // Days since the accepted option went out on each sale that is waiting to bind.
    private static final List<Integer> ACCEPTED_AGES = new List<Integer>{ 6, 19, 24, 16 };

    /**
     * Quotes follow the stage of their sale: options out with the customer on a quoted sale, one accepted
     * on a sale waiting to bind, one bound on a won sale, and a draft on some sales still in underwriting.
     * The lead option always carries the sale's amount.
     */
    // Sales whose draft quote is waiting on an underwriter, and the answers that sent it there.
    private static final Map<String, Map<String, Object>> REFERRED_ANSWERS = new Map<String, Map<String, Object>>{
        'Paw Paw Lake Craft Distillers - Workers Comp' => new Map<String, Object>{ 'experienceMod' => 'high', 'returnToWork' => 'false' },
        // Heat treating and plating go out to other shops, which is what an underwriter would want to look at.
        'Ironwood Machine Works - General Liability renewal' => new Map<String, Object>{ 'subcontractors' => 'over25' },
        'Ridgeline Roofing - Excess liability' => new Map<String, Object>{ 'violations' => '2plus', 'vehicles' => 14 }
    };

    // How quote requests arrive, in the mix a personal and small-commercial carrier sees.
    private static final List<String> QUOTE_CHANNELS = new List<String>{ 'Phone', 'Online', 'Agent', 'Phone', 'Online', 'In Person', 'Agent', 'Phone' };

    private static void loadQuotes() {
        Map<Id, Policy__c> policiesById = new Map<Id, Policy__c>(policies.values());
        Map<Id, Account> accountsById = new Map<Id, Account>(accounts.values());
        Map<String, Integer> seenByStage = new Map<String, Integer>();
        List<Quote> quotes = new List<Quote>();
        for (Opportunity sale : opportunities) {
            String stage = sale.StageName;
            Integer sequence = seenByStage.containsKey(stage) ? seenByStage.get(stage) : 0;
            seenByStage.put(stage, sequence + 1);
            Policy__c linked = policiesById.get(sale.Policy__c);
            Boolean isCommercial = accountsById.get(sale.AccountId).Customer_Segment__c == 'Commercial Lines';
            List<Quote> options = optionsFor(
                sale, linked != null ? linked.Coverage_Limit__c : defaultLimit(sale.Line_of_Business__c, sale.Amount, isCommercial),
                linked != null ? linked.Deductible__c : defaultDeductible(sale.Line_of_Business__c), isCommercial ? 'Hugh Mercer' : 'Lydia Osei'
            );
            Integer daysSinceClose = sale.CloseDate.daysBetween(Date.today());
            switch on stage {
                when 'Quote Issued' {
                    Integer age = QUOTE_AGES[Math.mod(sequence, QUOTE_AGES.size())];
                    String status = Math.mod(sequence, 2) == 0 ? 'Presented' : 'Issued';
                    // Every other sale went out as three options rather than two.
                    quotes.add(issue(options[0], status, age));
                    quotes.add(issue(options[1], status, age));
                    if (Math.mod(sequence, 2) == 1) {
                        quotes.add(issue(options[2], status, age));
                    }
                }
                when 'Bind Requested' {
                    Integer age = ACCEPTED_AGES[Math.mod(sequence, ACCEPTED_AGES.size())];
                    quotes.add(issue(options[0], 'Accepted', age));
                    quotes.add(issue(options[1], 'Declined', age));
                }
                when 'Bound' {
                    quotes.add(issue(options[0], 'Bound', daysSinceClose + 16));
                    // A sale bound long ago keeps only the option that was bound; the storage budget is tight.
                    if (daysSinceClose <= RECENT_BIND_DAYS) {
                        quotes.add(issue(options[1], 'Declined', daysSinceClose + 16));
                    }
                }
                when 'Declined' {
                    quotes.add(issue(options[0], Math.mod(sequence, 2) == 0 ? 'Declined' : 'Expired', daysSinceClose + 25));
                    if (sequence == 2) {
                        quotes.add(issue(options[2], 'Expired', daysSinceClose + 25));
                    }
                }
                when 'Underwriting Review' {
                    if (Math.mod(sequence, 2) == 0 || REFERRED_ANSWERS.containsKey(sale.Name)) {
                        options[0].Status = 'Draft';
                        quotes.add(options[0]);
                    }
                }
            }
            leadQuotes.put(sale.Name, options[0]);
        }
        // Each quote carries the configurator's answers, worked back from its terms. Options on one sale share
        // the same customer answers and came in the same way.
        Map<Id, Integer> saleNumbers = new Map<Id, Integer>();
        Map<Id, String> linesBySale = new Map<Id, String>();
        Map<Id, Map<String, Object>> knownBySale = new Map<Id, Map<String, Object>>();
        Map<Id, Id> customersBySale = new Map<Id, Id>();
        Map<Id, Account> ratedRevenue = new Map<Id, Account>();
        for (Opportunity sale : opportunities) {
            customersBySale.put(sale.Id, sale.AccountId);
            saleNumbers.put(sale.Id, saleNumbers.size());
            linesBySale.put(sale.Id, sale.Line_of_Business__c);
            Map<String, Object> known = AntsuranceQuoteConfigurator.knownAnswers(accountsById.get(sale.AccountId), policiesById.get(sale.Policy__c));
            if (REFERRED_ANSWERS.containsKey(sale.Name)) {
                known.putAll(REFERRED_ANSWERS.get(sale.Name));
            }
            knownBySale.put(sale.Id, known);
        }
        for (Quote quote : quotes) {
            Integer saleNumber = saleNumbers.get(quote.OpportunityId);
            quote.Submission_Channel__c = QUOTE_CHANNELS[Math.mod(saleNumber, QUOTE_CHANNELS.size())];
            // The answers were taken the day the quote went out, or yesterday for one still in draft.
            quote.Configuration__c = AntsuranceQuoteConfigurator.demoConfiguration(
                linesBySale.get(quote.OpportunityId), quote.Annual_Premium__c, quote.Coverage_Limit__c, quote.Deductible__c, saleNumber,
                knownBySale.get(quote.OpportunityId), quote.Issued_Date__c == null ? Date.today().addDays(-1) : quote.Issued_Date__c
            );
            quote.Needs_Underwriting_Review__c = AntsuranceQuoteConfigurator.needsReview(quote.Configuration__c);
            // A business's revenue on file should be the figure its liability quote was rated on.
            Id customerId = customersBySale.get(quote.OpportunityId);
            if (linesBySale.get(quote.OpportunityId) == 'General Liability' && quote.Configuration__c != null && !ratedRevenue.containsKey(customerId)) {
                Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(quote.Configuration__c);
                Object revenue = ((Map<String, Object>) stored.get('answers')).get('revenue');
                if (revenue != null) {
                    ratedRevenue.put(customerId, new Account(Id = customerId, AnnualRevenue = Decimal.valueOf(String.valueOf(revenue))));
                }
            }
        }
        insert quotes;
        update ratedRevenue.values();
    }

    /** The lead option at the sale's amount, a cheaper one and a richer one. The quote name is what sets the option apart. */
    private static List<Quote> optionsFor(Opportunity sale, Decimal coverageLimit, Decimal deductible, String underwriter) {
        List<String> terms = QUOTE_OPTIONS.get(sale.Line_of_Business__c).split('\\|');
        Boolean isUmbrella = sale.Line_of_Business__c == 'Umbrella';
        Integer cheaperPercent = Integer.valueOf(terms[2]);
        Integer richerPercent = Integer.valueOf(terms[4]);
        Decimal higherDeductible = deductible == null || deductible == 0 ? 2500 : deductible * 2;

        Quote lead = new Quote(
            OpportunityId = sale.Id, Name = terms[0], Annual_Premium__c = sale.Amount, Coverage_Limit__c = coverageLimit, Deductible__c = deductible,
            Underwriter__c = underwriter, Description = '**Includes:** ' + terms[5] + '.\n\n**Why this option:** The recommended option, and the one the sale amount is based on.'
        );
        Quote cheaper = new Quote(
            OpportunityId = sale.Id, Name = terms[1], Annual_Premium__c = (sale.Amount * cheaperPercent / 100).setScale(0),
            Coverage_Limit__c = isUmbrella ? coverageLimit / 2 : coverageLimit, Deductible__c = isUmbrella ? deductible : higherDeductible, Underwriter__c = underwriter,
            Description = '**Includes:** The same coverages as the lead option.\n\n**Difference:** ' +
                (isUmbrella ? 'Half the limit' : 'A ' + money(higherDeductible) + ' deductible') + ', which takes about ' + (100 - cheaperPercent) + ' percent off the premium.'
        );
        Quote richer = new Quote(
            OpportunityId = sale.Id, Name = terms[3], Annual_Premium__c = (sale.Amount * richerPercent / 100).setScale(0),
            Coverage_Limit__c = isUmbrella ? coverageLimit * 2 : coverageLimit, Deductible__c = deductible, Underwriter__c = underwriter,
            Description = '**Includes:** Everything in the lead option, plus ' + terms[6] + '.\n\n**Difference:** Adds about ' + (richerPercent - 100) + ' percent to the premium.'
        );
        return new List<Quote>{ lead, cheaper, richer };
    }

    /** Dates an option and gives it a status. A quote is good for 30 days, or 45 when it was held open for the customer. */
    private static Quote issue(Quote option, String status, Integer daysAgo) {
        option.Status = status;
        option.Issued_Date__c = Date.today().addDays(-daysAgo);
        option.ExpirationDate = option.Issued_Date__c.addDays(daysAgo > 28 && (status == 'Issued' || status == 'Presented') ? 45 : 30);
        return option;
    }

    private static Decimal defaultLimit(String line, Decimal premium, Boolean isCommercial) {
        switch on line {
            when 'Umbrella' {
                return isCommercial ? 5000000 : 1000000;
            }
            when 'Commercial Property' {
                return (premium / 300).round() * 100000;
            }
            when 'Homeowners' {
                return 400000;
            }
            when 'Renters' {
                return 30000;
            }
            when 'Personal Auto' {
                return 100000;
            }
            when else {
                return 1000000;
            }
        }
    }

    private static Decimal defaultDeductible(String line) {
        Map<String, Integer> deductibles = new Map<String, Integer>{
            'Commercial Property' => 5000, 'General Liability' => 2500, 'Commercial Auto' => 2000, 'Personal Auto' => 1000, 'Homeowners' => 1500, 'Renters' => 500
        };
        return deductibles.containsKey(line) ? deductibles.get(line) : 0;
    }

    // ---------------------------------------------------------------- the working task list

    /**
     * What is on the desk: open tasks across claims, requests, policies and sales, and a history of
     * finished ones. A quote follow-up hangs off the sale, not the quote, so the sale's Activity shows it.
     * A subject is 34 characters or fewer: the Activity panel on a record page shows one line of it at
     * laptop width and cuts the rest.
     */
    private static void loadWorkTasks() {
        List<Task> tasks = new List<Task>{
            // Claims
            workTask(claimId('Rear-ended at a red light on Harlem Ave'), 'hana', 'Put the other carrier on notice', 1, 'Normal'),
            workTask(claimId('Burst pipe flooded finished basement'), 'chinedu', 'Approve Okafor rebuild estimate', 3, 'High'),
            workTask(claimId('Hail damage to roof and skylights'), 'grace', 'Book the joint roof inspection', 5, 'Normal'),
            workTask(claimId('Tractor-trailer jackknifed on I-80, cargo loss'), 'lena', 'Pay tractor balance on clear title', 6, 'Normal'),
            workTask(claimId('Hit a parked car in a grocery store lot'), 'lucia', 'Send Lucia the coverage decision', -2, 'High'),
            workTask(claimId('Kitchen fire spread to three apartments'), 'nora', 'Review the Kedzie contractor bids', 4, 'High'),
            // Service requests
            workTask(claimId('Lower collision deductible to $250'), 'amara', 'Email Amara the deductible options', 0, 'Normal'),
            workTask(claimId('Certificate for new landlord at the Lincoln Park office'), 'anita', 'Confirm the landlord\'s legal name', 0, 'High'),
            workTask(claimId('Moving to a new home in Belvidere'), 'marcus', 'Rewrite the policy for Belvidere', 7, 'Normal'),
            workTask(claimId('Certificates for 14 vendors renewing this quarter'), 'nora', 'Issue the last five certificates', -1, 'Normal'),
            // Policies
            workTask(policies.get('whitfield-home').Id, 'marcus', 'Call the Whitfields on the renewal', 0, 'High'),
            workTask(policies.get('abernathy-home').Id, 'grace', 'Order Abernathy roof inspection', 10, 'Normal'),
            workTask(policies.get('ridgeline-wc').Id, 'miguel', 'Chase Ridgeline corrective report', -3, 'High'),
            workTask(policies.get('ironwood-wc').Id, 'sam', 'Review Ironwood payroll by class', 4, 'Normal'),
            workTask(policies.get('nakamura-home').Id, 'kenji', 'Confirm the Nakamura mortgagee', 8, 'Normal'),
            // Policy sales
            workTask(saleId('Ridgeline Roofing - Excess liability'), 'dana', 'Call Dana about the excess quote', 2, 'High'),
            workTask(saleId('Sagebrush Freight Lines - Cargo and umbrella'), 'lena', 'Chase the Sagebrush loss runs', -4, 'Normal'),
            workTask(saleId('Copperfield - Two buildings added to schedule'), 'victor', 'Bind the two added buildings', 1, 'High'),
            workTask(saleId('Dubois Household - Personal Auto'), 'camille', 'Call Camille about the auto quote', 0, 'Normal'),
            workTask(saleId('Lakeshore Dental Group - Workers Comp'), 'anita', 'Submit the Lakeshore application', 5, 'Normal'),
            workTask(saleId('Chen Household - Umbrella'), 'chena', 'Show the Chens umbrella options', 3, 'Normal'),
            workTask(saleId('Prairie Wind Hotels - Commercial Auto for shuttle vans'), 'prairiewindc', 'Collect the signed application', 2, 'High'),
            // Quotes
            workTask(saleId('Ironwood Machine Works - Workers Comp renewal'), 'sam', 'Walk Sam through the comp quote', -1, 'High'),
            workTask(saleId('Tamarack Outfitters - Commercial Auto for delivery van'), 'bea', 'Follow up on the Tamarack quote', 1, 'Normal'),
            workTask(saleId('Riverbend Veterinary Clinic - Umbrella'), 'riverbendc', 'Ask Leila for an umbrella decision', 6, 'Normal'),

            // Finished work, for history
            doneTask(claimId('Parking lot scrape, rear quarter panel'), 'daniel', 'Approved the Accord photo estimate', 24),
            doneTask(claimId('Cracked windshield from road debris'), 'ana', 'Paid the mobile glass vendor', 55),
            doneTask(claimId('Storefront window smashed, merchandise taken'), 'bea', 'Checked stock against the till', 30),
            doneTask(claimId('Apartment burglary, laptop and bike stolen'), 'erik', 'Agreed the settlement with Erik', 9),
            doneTask(claimId('Tractor-trailer jackknifed on I-80, cargo loss'), 'lena', 'Appraised tractor as a total loss', 30),
            doneTask(claimId('Kitchen fire spread to three apartments'), 'nora', 'Walked the site with investigator', 20),
            doneTask(claimId('Installer fell from second-story roof'), 'miguel', 'Assigned a nurse case manager', 7),
            doneTask(claimId('2023 BMW X5 stolen from driveway'), 'omar', 'Referred the BMW theft to SIU', 14),
            doneTask(claimId('Guest alleges food poisoning after wedding'), 'rosa', 'Sent the claimant a denial letter', 45),
            doneTask(claimId('Needs declarations page for mortgage refinance'), 'kenji', 'Sent declarations to the lender', 11),
            doneTask(claimId('Remove two drivers who left the company'), 'lena', 'Updated the Sagebrush driver list', 14),
            doneTask(claimId('Asked to move the payment date to the 15th'), 'camille', 'Changed Camille\'s payment date', 17),
            doneTask(policies.get('ironwood-wc').Id, 'sam', 'Released the renewal quote', 12),
            doneTask(policies.get('copperfield-property').Id, 'victor', 'Completed the mid-term inspection', 35),
            doneTask(policies.get('nakamura-home').Id, 'hana', 'Mailed the Nakamura renewal offer', 6),
            doneTask(policies.get('sagebrush-auto').Id, 'lena', 'Reviewed fleet telematics scores', 21),
            doneTask(saleId('Okafor Household - Umbrella'), 'chinedu', 'Bound the Okafor umbrella', 20),
            doneTask(saleId('Marigold Cafe - Workers Comp'), 'rosa', 'Told Rosa we declined to quote', 34),
            doneTask(saleId('Halsted Street Bistro - Commercial Auto for catering van'), 'halstedc', 'Issued the Halsted van policy', 18),
            doneTask(saleId('Whitfield Household - Homeowners renewal'), 'marcus', 'Quoted the Whitfield renewal', 5),
            doneTask(saleId('Tamarack Outfitters - Commercial Auto for delivery van'), 'bea', 'Sent Bea the delivery van quote', 9)
        };
        // The activity timeline dates a finished task by when it was completed, which is the day of the load,
        // whatever its due date says. On a claim, request or sale that closed some time ago that reads as work
        // done today on a closed file, so finished tasks stay only on records that are still open.
        Map<Id, Case> casesById = new Map<Id, Case>(casesBySubject.values());
        Set<Id> closedRecords = new Set<Id>();
        for (Case record : casesById.values()) {
            if (CLOSED_CASE_STATUSES.contains(record.Status)) {
                closedRecords.add(record.Id);
            }
        }
        for (Opportunity sale : opportunities) {
            if (CLOSED_SALE_STAGES.contains(sale.StageName)) {
                closedRecords.add(sale.Id);
            }
        }
        for (Integer index = tasks.size() - 1; index >= 0; index--) {
            Task item = tasks[index];
            if (item.Status == 'Completed' && closedRecords.contains(item.WhatId)) {
                tasks.remove(index);
            } else if (casesById.containsKey(item.WhatId)) {
                item.Description = handlerNote(casesById.get(item.WhatId));
            }
        }
        insert tasks;
    }

    private static Id claimId(String subject) {
        return casesBySubject.get(subject).Id;
    }

    private static Id saleId(String name) {
        return salesByName.get(name).Id;
    }

    private static Task workTask(Id whatId, String contactKey, String subject, Integer dueInDays, String priority) {
        return new Task(
            WhatId = whatId, WhoId = contacts.get(contactKey).Id, Subject = subject, ActivityDate = Date.today().addDays(dueInDays),
            Priority = priority, Status = 'Not Started'
        );
    }

    private static Task doneTask(Id whatId, String contactKey, String subject, Integer daysAgo) {
        Task finished = workTask(whatId, contactKey, subject, -daysAgo, 'Normal');
        finished.Status = 'Completed';
        return finished;
    }

    private static void loadLeads() {
        List<Lead> leads = new List<Lead>{
            lead('Priscilla', 'Vance', 'Vance Household', 'Personal Auto', 'Open - Not Contacted', 'Web', 'Wheaton', 'IL'),
            lead('Theo', 'Marchetti', 'Marchetti Household', 'Homeowners', 'Working - Contacted', 'Phone Inquiry', 'Glen Ellyn', 'IL'),
            lead('Ingrid', 'Solberg', 'Solberg Household', 'Renters', 'Open - Not Contacted', 'Web', 'Madison', 'WI'),
            lead('Devon', 'Achebe', 'Achebe Household', 'Umbrella', 'Working - Contacted', 'Partner Referral', 'Evanston', 'IL'),
            lead('Carmen', 'Villanueva', 'Villanueva Tile & Stone', 'General Liability', 'Working - Contacted', 'Partner Referral', 'Cicero', 'IL'),
            lead('Walt', 'Greer', 'Greer Family Orchards', 'Commercial Property', 'Open - Not Contacted', 'Web', 'Woodstock', 'IL'),
            lead('Mei', 'Tanaka', 'Lantern Street Pediatrics', 'Workers Compensation', 'Open - Not Contacted', 'Phone Inquiry', 'Skokie', 'IL'),
            lead('Russell', 'Dunmore', 'Dunmore Landscape Supply', 'Commercial Auto', 'Working - Contacted', 'Partner Referral', 'Elgin', 'IL'),
            lead('Yusuf', 'Karim', 'Karim Household', 'Personal Auto', 'Open - Not Contacted', 'Web', 'Milwaukee', 'WI'),
            lead('Helena', 'Brandt', 'Brandt & Lowe Architects', 'General Liability', 'Open - Not Contacted', 'Web', 'Chicago', 'IL'),
            lead('Beatrix', 'Lowell', 'Lowell Household', 'Homeowners', 'Open - Not Contacted', 'Web', 'Winnetka', 'IL'),
            lead('Andre', 'Baptiste', 'Baptiste Household', 'Personal Auto', 'Working - Contacted', 'Phone Inquiry', 'Chicago', 'IL'),
            lead('Sunita', 'Rao', 'Rao Household', 'Umbrella', 'Open - Not Contacted', 'Partner Referral', 'Naperville', 'IL'),
            lead('Calvin', 'Hargrove', 'Hargrove Household', 'Renters', 'Open - Not Contacted', 'Web', 'Milwaukee', 'WI'),
            lead('Odessa', 'Finch', 'Finch & Daughters Florist', 'Commercial Property', 'Working - Contacted', 'Web', 'Oak Park', 'IL'),
            lead('Mateo', 'Serrano', 'Serrano Brothers Concrete', 'General Liability', 'Working - Contacted', 'Partner Referral', 'Joliet', 'IL'),
            lead('Priyanka', 'Desai', 'Bright Path Childcare', 'Workers Compensation', 'Open - Not Contacted', 'Phone Inquiry', 'Schaumburg', 'IL'),
            lead('Gunnar', 'Holt', 'Holt Marine Service', 'Commercial Auto', 'Open - Not Contacted', 'Web', 'Sturgeon Bay', 'WI'),
            lead('Lorraine', 'Tate', 'Tate Household', 'Homeowners', 'Working - Contacted', 'Partner Referral', 'Fort Wayne', 'IN'),
            lead('Ibrahim', 'Saleh', 'Crescent Street Pharmacy', 'General Liability', 'Open - Not Contacted', 'Web', 'Dearborn', 'MI'),
            lead('Wren', 'Abbott', 'Abbott Household', 'Personal Auto', 'Open - Not Contacted', 'Web', 'Madison', 'WI'),
            lead('Dominic', 'Ferraro', 'Ferraro Tile & Flooring', 'Workers Compensation', 'Working - Contacted', 'Partner Referral', 'Elmwood Park', 'IL'),
            lead('Selma', 'Lindholm', 'Lindholm Household', 'Renters', 'Open - Not Contacted', 'Web', 'Minneapolis', 'MN'),
            lead('Quentin', 'Marsh', 'Marsh Creek Kennels', 'Commercial Property', 'Open - Not Contacted', 'Phone Inquiry', 'Cedar Rapids', 'IA'),
            lead('Felicity', 'Okoro', 'Okoro Household', 'Umbrella', 'Working - Contacted', 'Partner Referral', 'Evanston', 'IL')
        };
        saveAllowingDuplicates(leads);

        // A contacted lead has the call that made it so on its timeline.
        List<Task> calls = new List<Task>();
        for (Lead prospect : leads) {
            if (prospect.Status != 'Working - Contacted') {
                continue;
            }
            List<String> needs = LEAD_NEEDS.get(prospect.Product_Interest__c).split('\\|');
            calls.add(new Task(
                WhoId = prospect.Id, Subject = 'First call with ' + prospect.FirstName + ' ' + prospect.LastName, TaskSubtype = 'Call', Status = 'Completed',
                Priority = 'Normal', ActivityDate = Date.today().addDays(-(1 + Math.mod(Math.abs(prospect.LastName.hashCode()), 6))),
                Description = 'Talked through what they are after. ' + needs[0] + ' ' + needs[1] + ' Agreed to follow up with a quote.'
            ));
        }
        insert calls;
    }

    /** Inserts records even when a duplicate rule would raise an alert, as it does for two people who share a name. */
    private static void saveAllowingDuplicates(List<SObject> records) {
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        options.optAllOrNone = true;
        Database.insert(records, options);
    }

    // What a lead is after and why they are asking now, by the product they asked about.
    private static final Map<String, String> LEAD_NEEDS = new Map<String, String>{
        'Personal Auto' => 'Cover for two cars, with a teenager due to start driving next year.|Shopping around after a rate increase at renewal.',
        'Homeowners' => 'Cover for a home they close on next month.|The lender needs proof of insurance before closing.',
        'Renters' => 'Renters cover for a new lease.|The landlord requires $100,000 of liability cover.',
        'Umbrella' => 'A $1 million umbrella over auto and home.|Asked after a neighbor was sued over a dog bite.',
        'General Liability' => 'Liability cover to bid on a commercial contract.|The contract asks for $1 million each claim and additional insured wording.',
        'Commercial Property' => 'Cover for a building and the equipment in it.|The current policy renews in six weeks.',
        'Workers Compensation' => 'Workers compensation for a growing crew.|New hires took them past the point where cover is required.',
        'Commercial Auto' => 'Cover for work vehicles.|A second van arrives this quarter.'
    };
    private static final Map<String, String> LEAD_AREA_CODES = new Map<String, String>{ 'IL' => '630', 'WI' => '608', 'IN' => '317', 'MI' => '616', 'IA' => '319' };

    private static Integer leadsMade = 0;

    private static Lead lead(String firstName, String lastName, String company, String interest, String status, String source, String city, String state) {
        Boolean contacted = status == 'Working - Contacted';
        // Every lead its own number: the last two digits step by three, so no two leads share one.
        String lineNumber = String.valueOf(11 + 3 * leadsMade++).leftPad(2, '0');
        // Steady for a name, so a reload gives the same lead the same number and rating.
        Integer seed = Math.abs(Math.mod((firstName + lastName).hashCode(), 9000));
        List<String> needs = LEAD_NEEDS.containsKey(interest) ? LEAD_NEEDS.get(interest).split('\\|') : null;
        Lead record = new Lead(
            FirstName = firstName, LastName = lastName, Company = company, Product_Interest__c = interest, Status = status, LeadSource = source,
            City = city, Email = (firstName + '.' + lastName).toLowerCase() + '@example.com',
            Phone = '(' + (LEAD_AREA_CODES.containsKey(state) ? LEAD_AREA_CODES.get(state) : '312') + ') 555-01' + lineNumber,
            // A lead nobody has reached yet came in this week and asked for a quote, so it is warm, not cold.
            Rating = contacted ? (Math.mod(seed, 2) == 0 ? 'Hot' : 'Warm') : 'Warm',
            Description = needs == null
                ? null
                : '**Wants:** ' + needs[0] + '\n\n**Why now:** ' + needs[1] + '\n\n**Next:** ' +
                  (contacted ? 'Convert the lead and generate a quote.' : 'Call within one business day.')
        );
        AntsuranceAddress.put(record, '', state, 'US');
        return record;
    }
}
