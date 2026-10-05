@IsTest
private class AntsuranceEventControllerTest {
    /** Answers with one canned response and keeps the request for inspection. */
    private class ClaudeMock implements HttpCalloutMock {
        Integer status;
        String body;
        HttpRequest request;

        ClaudeMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            this.request = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody(body);
            return response;
        }
    }

    /** A callout that never answers, as when Claude takes longer than the transaction allows. */
    private class TimeoutMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            throw new CalloutException('Read timed out');
        }
    }

    // The test's own map: a storm centered on 40.00, -90.00. Nothing here is a real address.
    private static final Decimal CENTER_LATITUDE = 40.0;
    private static final Decimal CENTER_LONGITUDE = -90.0;

    @TestSetup
    static void createBook() {
        Account harbor = new Account(Name = 'Harbor Household', BillingCity = 'Midtown');
        Account quay = new Account(Name = 'Quay Hardware', BillingCity = 'Midtown');
        Account ridge = new Account(Name = 'Ridge Household', BillingCity = 'Edgeville');
        Account far = new Account(Name = 'Faraway Household', BillingCity = 'Elsewhere');
        insert new List<Account>{ harbor, quay, ridge, far };
        Contact maya = new Contact(AccountId = harbor.Id, FirstName = 'Maya', LastName = 'Harbor', Phone = '(555) 010-0101');
        Contact owen = new Contact(AccountId = quay.Id, FirstName = 'Owen', LastName = 'Quay');
        insert new List<Contact>{ maya, owen };

        Date start = Date.today().addDays(-90);
        Policy__c home = policy('T-HOME-1', harbor.Id, maya.Id, 'Homeowners', 'Active', start);
        home.Underwriting_Notes__c = '**Risk:** 1998 home with a cedar shake roof. **Watch at renewal:** The roof is original.';
        Policy__c auto = policy('T-AUTO-1', harbor.Id, maya.Id, 'Personal Auto', 'Active', start);
        Policy__c shop = policy('T-PROP-1', quay.Id, owen.Id, 'Commercial Property', 'Pending Renewal', start);
        Policy__c liability = policy('T-GL-1', quay.Id, owen.Id, 'General Liability', 'Active', start);
        Policy__c nearby = policy('T-HOME-2', ridge.Id, null, 'Homeowners', 'Active', start);
        Policy__c distant = policy('T-HOME-3', far.Id, null, 'Homeowners', 'Active', start);
        Policy__c lapsed = policy('T-HOME-4', harbor.Id, maya.Id, 'Homeowners', 'Lapsed', start);
        Policy__c umbrella = policy('T-UMB-1', harbor.Id, maya.Id, 'Umbrella', 'Active', start);
        insert new List<Policy__c>{ home, auto, shop, liability, nearby, distant, lapsed, umbrella };

        insert new List<Policy_Coverage__c>{
            coverage(home.Id, 'Dwelling', 'Dwelling', 2500, 'Rebuilds the home after a covered loss. Flood and earth movement are excluded.'),
            coverage(home.Id, 'Personal Liability', 'Liability', null, 'Injury to others.'),
            coverage(auto.Id, 'Comprehensive', 'Comprehensive', 500, 'Hail, theft, fire and flood damage to the vehicle.'),
            coverage(auto.Id, 'Collision', 'Collision', 500, 'Crash damage.'),
            coverage(shop.Id, 'Building', 'Business Property', 5000, 'Repairs the building after a covered loss.'),
            coverage(liability.Id, 'General Liability', 'Liability', null, 'Injury to others.'),
            coverage(nearby.Id, 'Dwelling', 'Dwelling', 1000, 'Rebuilds the home.')
        };
        insert new List<Policy_Endorsement__c>{
            new Policy_Endorsement__c(Name = 'Water Backup and Sump Overflow', Policy__c = home.Id, Type__c = 'Endorsement', Form_Number__c = 'T 04 95', Limit_Amount__c = 10000, Status__c = 'Active'),
            new Policy_Endorsement__c(Name = 'Flood Exclusion', Policy__c = shop.Id, Type__c = 'Exclusion', Form_Number__c = 'T 02 10', Status__c = 'Active')
        };
        insert new List<Policy_Asset__c>{
            // About 1.4 miles north of the center: a home and two cars at one spot.
            asset(home.Id, '1 Test Way', 'Dwelling', 400000, 40.02, -90.0, 'Frame construction, roof 21 years old'),
            asset(auto.Id, '2022 Test Sedan', 'Vehicle', 30000, 40.02, -90.0, null),
            asset(auto.Id, '2019 Test Wagon', 'Vehicle', 20000, 40.02, -90.0, null),
            // About 3.5 miles south: a shop, and the same business's liability policy.
            asset(shop.Id, '9 Sample Rd', 'Commercial Building', 1500000, 39.95, -90.0, null),
            asset(liability.Id, 'Shop floor', 'Operations', null, 39.95, -90.0, null),
            // About 11 miles north: just outside a 10 mile storm.
            asset(nearby.Id, '5 Edge Ln', 'Dwelling', 300000, 40.16, -90.0, null),
            // About 69 miles north: nowhere near.
            asset(distant.Id, '7 Far St', 'Dwelling', 250000, 41.0, -90.0, null),
            // Inside, but the policy has lapsed.
            asset(lapsed.Id, '3 Old Ct', 'Dwelling', 999999, 40.01, -90.0, null),
            // An umbrella policy's entry for the policies under it: not something insured at the spot.
            asset(umbrella.Id, 'Underlying policies', 'Operations', null, 40.02, -90.0, null)
        };

        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        insert new List<Case>{
            new Case(RecordTypeId = claimType, Subject = 'Hail dented the roof', Policy__c = home.Id, Status = 'New', Severity__c = 'Low', Loss_Type__c = 'Wind or Hail', Date_of_Loss__c = Date.today().addDays(-1), Reported_Date__c = Date.today()),
            new Case(RecordTypeId = claimType, Subject = 'Stolen bicycle', Policy__c = home.Id, Status = 'New', Severity__c = 'Low', Loss_Type__c = 'Theft', Date_of_Loss__c = Date.today().addDays(-20), Reported_Date__c = Date.today().addDays(-19)),
            new Case(RecordTypeId = claimType, Subject = 'Old closed claim', Policy__c = shop.Id, Status = 'Closed', Severity__c = 'Low', Loss_Type__c = 'Fire', Date_of_Loss__c = Date.today().addDays(-60), Reported_Date__c = Date.today().addDays(-59))
        };
    }

    private static Policy__c policy(String name, Id accountId, Id contactId, String line, String status, Date start) {
        return new Policy__c(
            Name = name, Account__c = accountId, Primary_Insured__c = contactId, Line_of_Business__c = line, Status__c = status,
            Effective_Date__c = start, Expiration_Date__c = start.addYears(1)
        );
    }

    private static Policy_Coverage__c coverage(Id policyId, String name, String category, Decimal deductible, String wording) {
        return new Policy_Coverage__c(Name = name, Policy__c = policyId, Category__c = category, Deductible_Amount__c = deductible, What_Is_Covered__c = wording, Status__c = 'Active');
    }

    private static Policy_Asset__c asset(Id policyId, String name, String assetType, Decimal value, Decimal latitude, Decimal longitude, String details) {
        return new Policy_Asset__c(Name = name, Policy__c = policyId, Asset_Type__c = assetType, Insured_Value__c = value, Latitude__c = latitude, Longitude__c = longitude, Details__c = details);
    }

    private static Antsurance_Event__mdt event(String name, String peril, Decimal radius) {
        return new Antsurance_Event__mdt(
            DeveloperName = name, MasterLabel = 'Test ' + peril.toLowerCase() + ' event', Peril__c = peril, Days_Ago__c = 2,
            Center_Latitude__c = CENTER_LATITUDE, Center_Longitude__c = CENTER_LONGITUDE, Radius_Miles__c = radius,
            Area__c = 'Midtown', Severity_Note__c = 'A test storm.', Claim_Rate_Low__c = 25, Claim_Rate_High__c = 50, Sort_Order__c = 1
        );
    }

    private static void useEvents() {
        AntsuranceEventController.testEvents = new List<Antsurance_Event__mdt>{
            event('Hail', 'Hail', 10),
            event('Flood', 'Flood', 10),
            new Antsurance_Event__mdt(DeveloperName = 'Nowhere', MasterLabel = 'Storm over empty fields', Peril__c = 'Tornado', Days_Ago__c = 0, Center_Latitude__c = 30, Center_Longitude__c = -100, Radius_Miles__c = 10),
            new Antsurance_Event__mdt(DeveloperName = 'NoArea', MasterLabel = 'Event with no area', Peril__c = 'Wind', Days_Ago__c = 0)
        };
    }

    private static AntsuranceEventController.Place placeOf(AntsuranceEventController.Exposure exposure, String customer) {
        for (AntsuranceEventController.Place place : exposure.places) {
            if (place.customerName == customer) {
                return place;
            }
        }
        return null;
    }

    private static String planReply(List<String> keys) {
        List<Object> calls = new List<Object>();
        for (String key : keys) {
            calls.add(new Map<String, Object>{ 'key' => key, 'reason' => 'Largest insured value in the area.', 'message' => 'We know the storm came through Midtown. Are you safe?' });
        }
        Map<String, Object> answer = new Map<String, Object>{
            'headline' => 'Call the two largest locations today.',
            'expect' => 'Hail of this size dents roofs and cars parked outside.',
            'calls' => calls,
            'staffing' => new List<Object>{ 'Put two adjusters on call.' },
            'coverage_watch' => new List<Object>{ 'Deductibles run from $500 to $5,000.' },
            'not_held' => new List<Object>{ 'There is no weather feed.' }
        };
        return JSON.serialize(
            new Map<String, Object>{
                'model' => 'claude-opus-5-5',
                'stop_reason' => 'end_turn',
                'content' => new List<Object>{ new Map<String, Object>{ 'type' => 'text', 'text' => JSON.serialize(answer) } }
            }
        );
    }

    @IsTest
    static void theListShowsEachEventWithItsDateAndArea() {
        useEvents();
        List<AntsuranceEventController.EventInfo> events = AntsuranceEventController.getEvents();
        Assert.areEqual(4, events.size(), 'Every event is listed');
        Assert.areEqual('Hail', events[0].name, 'By its API name');
        Assert.areEqual(Date.today().addDays(-2), events[0].eventDate, 'Days ago counts back from today');
        Assert.areEqual(2, events[0].daysAgo, 'And says how long ago');
        Assert.isTrue(events[0].hasArea, 'A center and a radius are an area');
        Assert.isTrue(Math.abs(events[0].radiusMiles - 10) < 0.0001, 'With its radius');
        Assert.isFalse(events[3].hasArea, 'An event with neither has none');
    }

    @IsTest
    static void hailCountsWhatIsInsideAndWhatRespondsToIt() {
        useEvents();
        AntsuranceEventController.Exposure exposure = AntsuranceEventController.getExposure('Hail');

        Assert.areEqual(2, exposure.locations, 'Two customers have a location inside: the home with its cars, and the shop');
        Assert.areEqual(2, exposure.customers, 'Two customers');
        Assert.areEqual(4, exposure.policies, 'Four policies in force: home, auto, shop and its liability policy. The lapsed one and the umbrella are left out.');
        Assert.areEqual(1950000, exposure.insuredValue, 'Home 400,000, cars 50,000, shop 1,500,000');
        Assert.areEqual(1950000, exposure.respondingValue, 'All of it under a coverage that responds to hail');
        Assert.areEqual(4, exposure.exposedUnits, 'A home, two vehicles and a building');
        Assert.areEqual(1, exposure.nearby, 'One home is just outside');
        Assert.areEqual(3, exposure.places.size(), 'The far one is not shown at all');
        Assert.isFalse(exposure.truncated, 'Nothing was cut');

        AntsuranceEventController.Place home = placeOf(exposure, 'Harbor Household');
        Assert.isTrue(home.inside, 'The home is inside');
        Assert.areEqual('Home', home.kind, 'It is a home');
        Assert.areEqual('Home and 2 vehicles', home.what, 'Said in words');
        Assert.areEqual(450000, home.insuredValue, 'Home and cars together');
        Assert.areEqual('Maya Harbor', home.contactName, 'With who to call');
        Assert.areEqual(2, home.openClaims, 'And both open claims counted');
        Assert.areEqual(3, home.items.size(), 'Three insured things');
        Assert.areEqual(AntsuranceEventController.RESPONDS, home.items[0].coverage, 'The dwelling coverage responds to hail');

        AntsuranceEventController.Place shop = placeOf(exposure, 'Quay Hardware');
        Assert.areEqual('Business', shop.kind, 'A building is a business location');
        Assert.areEqual('Building and workplace', shop.what, 'With the workplace on the liability policy');
        AntsuranceEventController.Place edge = placeOf(exposure, 'Ridge Household');
        Assert.isFalse(edge.inside, 'The edge home is outside');
        Assert.isTrue(edge.milesFromEdge > 0.5 && edge.milesFromEdge < 2, 'By about a mile, got ' + edge.milesFromEdge);
        Assert.areEqual(shop.key, exposure.places[0].key, 'Largest insured value first');
        Assert.areEqual(edge.key, exposure.places[2].key, 'Outside last');

        Assert.areEqual('Commercial Property', exposure.byLine[0].line, 'Lines by insured value');
        Assert.areEqual(1500000, exposure.byLine[0].insuredValue, 'The shop');
        Assert.areEqual(4, exposure.byLine.size(), 'Four lines of business are inside');

        Assert.areEqual(1, exposure.claimsSince, 'One claim since the event');
        Assert.areEqual(1, exposure.claimsSinceRelated, 'And it is a hail claim');
        Assert.areEqual(1, exposure.claimsOpenBefore, 'One was already open');
        Assert.areEqual(2, exposure.claims.size(), 'The closed one from before is left out');

        Assert.areEqual(1, exposure.expectedLow, '25 percent of 4');
        Assert.areEqual(2, exposure.expectedHigh, '50 percent of 4');
        Assert.isTrue(exposure.expectedBasis.contains('25% to 50%'), 'With the assumption shown');
    }

    @IsTest
    static void aBurstPipeIsWaterDamageButNotAFloodClaim() {
        Id claimType = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Claim').getRecordTypeId();
        Id shopId = [SELECT Id FROM Policy__c WHERE Name = 'T-PROP-1'].Id;
        Id homeId = [SELECT Id FROM Policy__c WHERE Name = 'T-HOME-1'].Id;
        insert new List<Case>{
            new Case(
                RecordTypeId = claimType, Subject = 'Burst sprinkler line soaked inventory', Policy__c = shopId, Status = 'New', Severity__c = 'Medium', Loss_Type__c = 'Water Damage',
                Date_of_Loss__c = Date.today().addDays(-1), Reported_Date__c = Date.today()
            ),
            new Case(
                RecordTypeId = claimType, Subject = 'Water in the basement', Description = 'Rain overnight. The supply line to the water heater also failed.', Policy__c = homeId, Status = 'New',
                Severity__c = 'Medium', Loss_Type__c = 'Water Damage', Date_of_Loss__c = Date.today().addDays(-1), Reported_Date__c = Date.today()
            ),
            new Case(
                RecordTypeId = claimType, Subject = 'Street water came in through the garage', Policy__c = homeId, Status = 'New', Severity__c = 'Medium', Loss_Type__c = 'Water Damage',
                Date_of_Loss__c = Date.today().addDays(-1), Reported_Date__c = Date.today()
            )
        };
        useEvents();

        Test.startTest();
        AntsuranceEventController.Exposure exposure = AntsuranceEventController.getExposure('Flood');
        Test.stopTest();

        Map<String, AntsuranceEventController.ClaimRow> rows = new Map<String, AntsuranceEventController.ClaimRow>();
        for (AntsuranceEventController.ClaimRow row : exposure.claims) {
            rows.put(row.subject, row);
        }
        Assert.areEqual(4, exposure.claimsSince, 'Four claims have a loss since the event: these three and the hail claim');
        Assert.areEqual(1, exposure.claimsSinceRelated, 'One of them is a kind a flood causes');
        Assert.isFalse(rows.get('Burst sprinkler line soaked inventory').related, 'A sprinkler line is water damage from inside the building');
        Assert.isFalse(rows.get('Water in the basement').related, 'So is a failed supply line, named in the description');
        Assert.isTrue(rows.get('Street water came in through the garage').related, 'Water from outside is the flood\'s kind');
    }

    @IsTest
    static void hailCoverageRowsSayWhatRespondsAndItsDeductibles() {
        useEvents();
        AntsuranceEventController.Exposure exposure = AntsuranceEventController.getExposure('Hail');
        Map<String, AntsuranceEventController.CoverageRow> rows = new Map<String, AntsuranceEventController.CoverageRow>();
        for (AntsuranceEventController.CoverageRow row : exposure.coverages) {
            rows.put(row.name, row);
        }
        Assert.areEqual(3, rows.size(), 'Dwelling, Building and Comprehensive: liability and collision do not pay for hail');
        Assert.areEqual(AntsuranceEventController.RESPONDS, rows.get('Dwelling').status, 'Flood is excluded in its wording, not hail');
        Assert.areEqual(2500, rows.get('Dwelling').deductibleLow, 'With its deductible');
        Assert.areEqual(1, rows.get('Comprehensive').policies, 'On one auto policy');
        String notes = String.join(exposure.coverageNotes, ' ');
        Assert.isTrue(notes.contains('No separate wind or hail deductible'), 'It says no wind or hail deductible is recorded');
        Assert.isTrue(notes.contains(AntsuranceEventController.FORMS_CAVEAT), 'And where the answer was read from');
    }

    @IsTest
    static void floodIsExcludedOrNotStatedOnPropertyAndCoveredOnVehicles() {
        useEvents();
        AntsuranceEventController.Exposure exposure = AntsuranceEventController.getExposure('Flood');
        Map<String, AntsuranceEventController.CoverageRow> rows = new Map<String, AntsuranceEventController.CoverageRow>();
        for (AntsuranceEventController.CoverageRow row : exposure.coverages) {
            rows.put(row.name, row);
        }
        Assert.areEqual(AntsuranceEventController.EXCLUDED, rows.get('Dwelling').status, 'The dwelling wording excludes flood');
        Assert.areEqual(AntsuranceEventController.EXCLUDED, rows.get('Building').status, 'The shop carries a flood exclusion form');
        Assert.areEqual(AntsuranceEventController.RESPONDS, rows.get('Comprehensive').status, 'Comprehensive pays for a flooded car');
        Assert.areEqual(AntsuranceEventController.RESPONDS, exposure.coverages[0].status, 'What responds is listed first');
        Assert.areEqual(1950000, exposure.insuredValue, 'The same value is inside');
        Assert.areEqual(50000, exposure.respondingValue, 'But only the two cars are under a coverage that responds');
        Assert.areEqual(2, exposure.exposedUnits, 'Two vehicles');
        Assert.areEqual(0, exposure.expectedLow, '25 percent of 2, rounded down');
        Assert.areEqual(1, exposure.expectedHigh, '50 percent of 2, rounded up, so a small book never reads 0 to 0');
        String notes = String.join(exposure.coverageNotes, ' ');
        Assert.isTrue(notes.contains('Flood Exclusion (T 02 10) is on 1 policy.'), 'The exclusion form is named');
        Assert.isTrue(notes.contains('Water Backup and Sump Overflow (T 04 95) is on 1 policy, up to $10,000 each.'), 'So is the water backup endorsement, which is not flood cover');
        Assert.isTrue(notes.contains('Flood is not covered by a standard property policy'), 'And the warning about property forms');
        Assert.areEqual(0, exposure.claimsSinceRelated, 'A hail claim is not a flood claim');
        Assert.areEqual(1, exposure.claimsSince, 'Though it is still a claim since the event');
    }

    @IsTest
    static void aPropertyPolicyThatSaysNothingAboutFloodIsNotStated() {
        delete [SELECT Id FROM Policy_Endorsement__c WHERE Name = 'Flood Exclusion'];
        useEvents();
        AntsuranceEventController.Exposure exposure = AntsuranceEventController.getExposure('Flood');
        for (AntsuranceEventController.CoverageRow row : exposure.coverages) {
            if (row.name == 'Building') {
                Assert.areEqual(AntsuranceEventController.NOT_STATED, row.status, 'Nothing on the record says either way');
                return;
            }
        }
        Assert.fail('The building coverage is listed');
    }

    @IsTest
    static void aSentenceMustNameTheEventToExcludeIt() {
        List<String> flood = new List<String>{ 'flood' };
        Assert.isTrue(AntsuranceEventController.saysExcluded('Rebuilds the home. Flood and earth movement are excluded.', flood), 'It names flood and excludes it');
        Assert.isFalse(AntsuranceEventController.saysExcluded('Flood damage is repaired. Wear and tear is excluded.', flood), 'The exclusion is in another sentence');
        Assert.isTrue(AntsuranceEventController.saysExcluded('Surface water and flood are not covered', flood), 'Not covered counts');
        Assert.isFalse(AntsuranceEventController.saysExcluded(null, flood), 'No wording, no exclusion');
    }

    @IsTest
    static void anEventOverNothingShowsNothing() {
        useEvents();
        AntsuranceEventController.Exposure exposure = AntsuranceEventController.getExposure('Nowhere');
        Assert.areEqual(0, exposure.locations, 'No locations');
        Assert.areEqual(0, exposure.places.size(), 'Nothing on the map');
        Assert.areEqual(0, exposure.insuredValue, 'No value');
        Assert.isTrue(exposure.coverages.isEmpty() && exposure.coverageNotes.isEmpty(), 'No coverages to speak of');
        Assert.isNull(exposure.expectedLow, 'And no estimate');
        try {
            AntsuranceEventController.writePlan('Nowhere');
            Assert.fail('There is nothing to plan');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceEventController.NOTHING_INSIDE, e.getMessage(), 'It says so');
        }
    }

    @IsTest
    static void anEventThatIsMissingOrHasNoAreaSaysSo() {
        useEvents();
        try {
            AntsuranceEventController.getExposure('Gone');
            Assert.fail('No such event');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceEventController.NO_EVENT, e.getMessage(), 'It says the event is gone');
        }
        try {
            AntsuranceEventController.getExposure('NoArea');
            Assert.fail('No area');
        } catch (AuraHandledException e) {
            Assert.areEqual(AntsuranceEventController.NO_AREA, e.getMessage(), 'It says the event has no area');
        }
    }

    @IsTest
    static void thePlanGivesClaudeOnlyWhatThePageWorkedOut() {
        useEvents();
        ClaudeMock mock = new ClaudeMock(200, planReply(new List<String>{ 'P2', 'P9', 'P1', 'P1' }));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        AntsuranceEventController.Plan plan = AntsuranceEventController.writePlan('Hail');
        Test.stopTest();

        Assert.areEqual('Call the two largest locations today.', plan.headline, 'The headline is kept');
        Assert.areEqual(2, plan.calls.size(), 'A key that was never given and a repeat are dropped');
        Assert.areEqual('Harbor Household', plan.calls[0].customerName, 'P2 is the home, second by value');
        Assert.areEqual('Maya Harbor', plan.calls[0].contactName, 'With its contact');
        Assert.areEqual('(555) 010-0101', plan.calls[0].contactPhone, 'And phone');
        Assert.isTrue(plan.calls[0].message.contains('Midtown'), 'And the message to use');
        Assert.areEqual('Quay Hardware', plan.calls[1].customerName, 'P1 is the shop');
        Assert.areEqual(1, plan.staffing.size(), 'Staffing is kept');
        Assert.areEqual(1, plan.notHeld.size(), 'So is what the plan cannot know');
        Assert.isNotNull(plan.writtenAt, 'It is stamped');

        String sent = mock.request.getBody();
        Assert.isTrue(sent.contains('Harbor Household'), 'Claude is given the locations');
        Assert.isTrue(sent.contains('roof 21 years old'), 'With what the record says about the roof');
        Assert.isTrue(sent.contains('cedar shake roof'), 'And the underwriting note on it');
        Assert.isTrue(sent.contains('Hail dented the roof'), 'And the open claims');
        Assert.isTrue(sent.contains('1 to 2 claims'), 'And the estimate it must not change');
        Assert.isFalse(sent.contains('Underlying policies'), 'The umbrella entry is not a thing at the location');
        Assert.isFalse(sent.contains('Ridge Household'), 'A location outside the area is not offered for a first call');
        Assert.isFalse(sent.contains('Faraway Household'), 'Nor one far away');
        Assert.isTrue(sent.contains('P1') && sent.contains('P2'), 'Each location has a key');
        Assert.isFalse(sent.contains('P3'), 'And there are only two');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Call %about the hail event'], 'Writing a plan creates nothing');
    }

    @IsTest
    static void aPlanThatTimesOutSaysSoInWords() {
        useEvents();
        Test.setMock(HttpCalloutMock.class, new TimeoutMock());
        Test.startTest();
        String told;
        try {
            AntsuranceEventController.writePlan('Hail');
            Assert.fail('The call timed out');
        } catch (AuraHandledException e) {
            told = e.getMessage();
        }
        Test.stopTest();
        Assert.isTrue(String.isNotBlank(told), 'The person is told what happened');
        Assert.isFalse(told.containsIgnoreCase('CalloutException'), 'Not shown the platform error');
    }

    @IsTest
    static void callTasksAreCreatedForTheChosenCustomersOnly() {
        useEvents();
        AntsuranceEventController.Exposure exposure = AntsuranceEventController.getExposure('Hail');
        AntsuranceEventController.Place home = placeOf(exposure, 'Harbor Household');
        AntsuranceEventController.CallRequest call = new AntsuranceEventController.CallRequest();
        call.key = home.key;
        call.message = '  We know the storm came through Midtown. Are you safe?  ';
        AntsuranceEventController.CallRequest again = new AntsuranceEventController.CallRequest();
        again.key = home.key;

        Test.startTest();
        List<AntsuranceEventController.CreatedTask> created = AntsuranceEventController.createCallTasks('Hail', new List<AntsuranceEventController.CallRequest>{ call, again });
        Test.stopTest();

        Assert.areEqual(1, created.size(), 'One task for one customer, even when chosen twice');
        Task task = [SELECT Subject, WhatId, WhoId, ActivityDate, Priority, Description FROM Task WHERE Id = :created[0].taskId];
        Assert.areEqual('Call Maya Harbor about the hail event', task.Subject, 'Named for who to call and why');
        Assert.areEqual(home.customerId, task.WhatId, 'On the customer');
        Assert.areEqual(home.contactId, task.WhoId, 'For their contact');
        Assert.areEqual(Date.today(), task.ActivityDate, 'Due today');
        Assert.areEqual('High', task.Priority, 'And high priority');
        Assert.isTrue(task.Description.endsWith('Are you safe?'), 'With the message, trimmed');
        Assert.isTrue(task.Description.contains('Home and 2 vehicles in Midtown'), 'And what is there');
    }

    @IsTest
    static void callTasksAreRefusedWhenThereAreNoneTooManyOrOneIsOutside() {
        useEvents();
        AntsuranceEventController.Exposure exposure = AntsuranceEventController.getExposure('Hail');
        AntsuranceEventController.CallRequest outside = new AntsuranceEventController.CallRequest();
        outside.key = placeOf(exposure, 'Ridge Household').key;
        List<AntsuranceEventController.CallRequest> six = new List<AntsuranceEventController.CallRequest>();
        for (Integer index = 0; index < 6; index++) {
            AntsuranceEventController.CallRequest call = new AntsuranceEventController.CallRequest();
            call.key = placeOf(exposure, 'Harbor Household').key;
            six.add(call);
        }
        Map<String, List<AntsuranceEventController.CallRequest>> cases = new Map<String, List<AntsuranceEventController.CallRequest>>{
            AntsuranceEventController.NO_CALLS => new List<AntsuranceEventController.CallRequest>(),
            AntsuranceEventController.TOO_MANY_CALLS => six,
            AntsuranceEventController.NOT_INSIDE => new List<AntsuranceEventController.CallRequest>{ outside }
        };
        for (String expected : cases.keySet()) {
            try {
                AntsuranceEventController.createCallTasks('Hail', cases.get(expected));
                Assert.fail('Refused: ' + expected);
            } catch (AuraHandledException e) {
                Assert.areEqual(expected, e.getMessage(), 'It says why');
            }
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Call %about the hail event'], 'And nothing was created');
    }

    /** Someone in the org with no Antsurance permission set: policies, what they insure and their coverages are closed to them. */
    private static User outsider() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'outsider' + Crypto.getRandomInteger() + '@antsurance.example.com';
        return new User(
            ProfileId = standard.Id, Username = unique, Email = unique, LastName = 'Outsider', Alias = 'outsidr',
            TimeZoneSidKey = 'America/Chicago', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
    }

    /** What the page is told when one of its three requests is refused, or null when it is answered. */
    private static String refusal(String request, AntsuranceEventController.CallRequest call) {
        try {
            if (request == 'exposure') {
                AntsuranceEventController.getExposure('Hail');
            } else if (request == 'plan') {
                AntsuranceEventController.writePlan('Hail');
            } else {
                AntsuranceEventController.createCallTasks('Hail', new List<AntsuranceEventController.CallRequest>{ call });
            }
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @IsTest
    static void someoneWithoutAccessToTheBookIsRefusedTheExposure() {
        useEvents();
        String told;
        Test.startTest();
        System.runAs(outsider()) {
            told = refusal('exposure', null);
        }
        Test.stopTest();
        Assert.areEqual(AntsuranceEventController.LOAD_ERROR, told, 'The records are read with their own access, so they are shown nothing');
    }

    @IsTest
    static void someoneWithoutAccessToTheBookSendsNothingToClaude() {
        useEvents();
        ClaudeMock mock = new ClaudeMock(200, planReply(new List<String>{ 'P1' }));
        Test.setMock(HttpCalloutMock.class, mock);
        String told;
        Test.startTest();
        System.runAs(outsider()) {
            told = refusal('plan', null);
        }
        Test.stopTest();
        Assert.areEqual(AntsuranceEventController.LOAD_ERROR, told, 'No plan is written from records they may not read');
        Assert.isNull(mock.request, 'And Claude is sent nothing');
    }

    @IsTest
    static void someoneWithoutAccessToTheBookCreatesNoCallTasks() {
        useEvents();
        AntsuranceEventController.CallRequest call = new AntsuranceEventController.CallRequest();
        call.key = placeOf(AntsuranceEventController.getExposure('Hail'), 'Harbor Household').key;
        call.message = 'Are you safe?';
        String told;
        Test.startTest();
        System.runAs(outsider()) {
            told = refusal('tasks', call);
        }
        Test.stopTest();
        Assert.areEqual(AntsuranceEventController.LOAD_ERROR, told, 'A key copied from someone else\'s page creates nothing');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Call %about the hail event'], 'No task was created');
    }

    @IsTest
    static void whatIsAtALocationIsSaidInWords() {
        List<AntsuranceEventController.Item> items = new List<AntsuranceEventController.Item>();
        for (String assetType : new List<String>{ 'Vehicle' }) {
            AntsuranceEventController.Item item = new AntsuranceEventController.Item();
            item.assetType = assetType;
            items.add(item);
        }
        Assert.areEqual('Vehicle', AntsuranceEventController.whatIsThere(items), 'One vehicle alone');
        AntsuranceEventController.Item second = new AntsuranceEventController.Item();
        second.assetType = 'Vehicle';
        items.add(second);
        Assert.areEqual('2 vehicles', AntsuranceEventController.whatIsThere(items), 'Two are counted');
        AntsuranceEventController.Item building = new AntsuranceEventController.Item();
        building.assetType = 'Commercial Building';
        AntsuranceEventController.Item contents = new AntsuranceEventController.Item();
        contents.assetType = 'Business Property';
        items.addAll(new List<AntsuranceEventController.Item>{ building, contents });
        Assert.areEqual('Building, business property and 2 vehicles', AntsuranceEventController.whatIsThere(items), 'In a steady order, joined as a sentence would');
        Assert.areEqual('Insured location', AntsuranceEventController.whatIsThere(new List<AntsuranceEventController.Item>()), 'Nothing listed still has a name');
    }

    @IsTest
    static void theShippedEventsEachHaveAnArea() {
        // The real records, as deployed: every sample event must be drawable.
        for (AntsuranceEventController.EventInfo event : AntsuranceEventController.getEvents()) {
            Assert.isTrue(event.hasArea, event.label + ' has a center and a radius, or an outline');
            Assert.isNotNull(event.eventDate, event.label + ' has a date');
        }
    }
}
