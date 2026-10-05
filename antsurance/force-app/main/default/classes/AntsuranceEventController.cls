/**
 * @description Behind the Event response page. For a weather event it works out, from the records,
 * which insured locations lie inside the area the event crossed, what is insured there, which
 * coverages respond, and which claims have come in. On request it asks Claude for a response plan
 * and drafts of the first calls, and it creates call tasks a person has chosen. Nothing is sent to a customer.
 *
 * Everything is read and saved with the running user's own access. A record or a field they may not
 * see is never shown, never given to Claude and never written into a task: the page is refused instead.
 */
public with sharing class AntsuranceEventController {
    /** Locations this far past the edge are shown faintly as "just outside". */
    @TestVisible
    private static final Double NEARBY_MILES = 3;
    /** The most call tasks one request may create. The demo org is short of data storage. */
    public static final Integer MAX_CALLS = 5;
    /** How many of the largest locations Claude is shown to choose first calls from. */
    private static final Integer MAX_CANDIDATES = 12;
    private static final Integer PLAN_TOKENS = 3000;
    private static final Integer ASSET_LIMIT = 2000;

    private static final Set<String> IN_FORCE = new Set<String>{ 'Active', 'Pending Renewal' };
    private static final Set<String> HOME_TYPES = new Set<String>{ 'Dwelling', 'Rented Residence' };
    private static final Set<String> BUSINESS_TYPES = new Set<String>{ 'Commercial Building', 'Business Property' };
    private static final Set<String> VEHICLE_TYPES = new Set<String>{ 'Vehicle', 'Fleet' };
    /** Coverage categories that pay for damage to property at a location. */
    private static final Set<String> PROPERTY_CATEGORIES = new Set<String>{ 'Dwelling', 'Personal Property', 'Loss of Use', 'Business Property', 'Business Income' };
    private static final String VEHICLE_CATEGORY = 'Comprehensive';
    /** What each kind of insured thing is called when a location is described in words. */
    private static final Map<String, String> WORDS_FOR = new Map<String, String>{
        'Dwelling' => 'Home',
        'Rented Residence' => 'Rented home',
        'Commercial Building' => 'Building',
        'Business Property' => 'Business property',
        'Fleet' => 'Fleet',
        'Vehicle' => 'Vehicle'
    };
    /** Words that tie a coverage's wording or an endorsement to each kind of event. */
    private static final Map<String, List<String>> PERIL_WORDS = new Map<String, List<String>>{
        'Hail' => new List<String>{ 'hail', 'wind' },
        'Wind' => new List<String>{ 'wind', 'hail' },
        'Tornado' => new List<String>{ 'tornado', 'wind' },
        'Flood' => new List<String>{ 'flood', 'water backup', 'sump' }
    };
    /** The claim loss types that could come from each kind of event. */
    private static final Map<String, Set<String>> PERIL_LOSS_TYPES = new Map<String, Set<String>>{
        'Hail' => new Set<String>{ 'Wind or Hail', 'Glass' },
        'Wind' => new Set<String>{ 'Wind or Hail' },
        'Tornado' => new Set<String>{ 'Wind or Hail' },
        'Flood' => new Set<String>{ 'Water Damage' }
    };
    /**
     * A loss type is how a claim is filed, not what caused it: "Water Damage" is a burst pipe as often as
     * a flood. A claim of a matching type is still not this event's kind when its own words name a cause
     * inside the building.
     */
    private static final Map<String, List<String>> PERIL_OTHER_CAUSES = new Map<String, List<String>>{
        'Flood' => new List<String>{
            'pipe', 'sprinkler', 'supply line', 'plumbing', 'water heater', 'dishwasher', 'washing machine', 'appliance', 'faucet', 'toilet', 'bathtub', 'overflow', 'neighbor', 'leak'
        }
    };

    public static final String RESPONDS = 'Responds';
    public static final String EXCLUDED = 'Excluded on record';
    public static final String NOT_STATED = 'Not stated on record';
    public static final String NO_EVENT = 'That event is no longer set up. Choose another from the list.';
    public static final String NO_AREA = 'This event has no area yet. Give it a center and a radius, or an outline, in Setup.';
    public static final String NOTHING_INSIDE = 'No insured location is inside this event\'s area, so there is nothing to plan.';
    public static final String TOO_MANY_CALLS = 'Choose up to five customers at a time.';
    public static final String NO_CALLS = 'Choose at least one customer to call.';
    public static final String NOT_INSIDE = 'One of those customers is not inside this event\'s area. Refresh the page and choose again.';
    public static final String LOAD_ERROR = 'This event could not be worked out. Check your access to customers, policies, their coverages and claims.';
    public static final String NO_TASK_ACCESS = 'The call tasks could not be created. Check that you can create tasks for these customers.';
    public static final String FORMS_CAVEAT = 'Read from the coverages and endorsements recorded on each policy, not the wording of the policy forms.';

    @TestVisible
    private static List<Antsurance_Event__mdt> testEvents;

    /** One event in the list. */
    public class EventInfo {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String peril;
        @AuraEnabled
        public Date eventDate;
        @AuraEnabled
        public Integer daysAgo;
        @AuraEnabled
        public String area;
        @AuraEnabled
        public String note;
        @AuraEnabled
        public Boolean hasArea;
        @AuraEnabled
        public Double centerLatitude;
        @AuraEnabled
        public Double centerLongitude;
        @AuraEnabled
        public Double reachMiles;
        @AuraEnabled
        public Double radiusMiles;
        /** The outline's corners as [latitude, longitude] pairs, empty for a circle. */
        @AuraEnabled
        public List<List<Double>> points = new List<List<Double>>();
    }

    /** One insured thing at a location. */
    public class Item {
        @AuraEnabled
        public Id assetId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String assetType;
        @AuraEnabled
        public Decimal insuredValue;
        @AuraEnabled
        public Id policyId;
        @AuraEnabled
        public String policyName;
        @AuraEnabled
        public String line;
        /** Whether a coverage on its policy responds to this kind of event: Responds, Excluded on record, Not stated on record, or blank when none applies. */
        @AuraEnabled
        public String coverage;
    }

    /** One customer's location: everything they insure at one spot on the map. */
    public class Place {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public Double latitude;
        @AuraEnabled
        public Double longitude;
        @AuraEnabled
        public Boolean inside;
        @AuraEnabled
        public Double milesFromEdge;
        /** Home, Business, Vehicle or Workplace. */
        @AuraEnabled
        public String kind;
        /** What is there, in words: "Home and 2 vehicles". */
        @AuraEnabled
        public String what;
        @AuraEnabled
        public Id customerId;
        @AuraEnabled
        public String customerName;
        @AuraEnabled
        public String town;
        @AuraEnabled
        public Decimal insuredValue = 0;
        /** The part of the insured value under a coverage that responds to this kind of event. */
        @AuraEnabled
        public Decimal respondingValue = 0;
        @AuraEnabled
        public List<Item> items = new List<Item>();
        @AuraEnabled
        public List<String> lines = new List<String>();
        @AuraEnabled
        public Id contactId;
        @AuraEnabled
        public String contactName;
        @AuraEnabled
        public String contactPhone;
        /** Open claims on this customer's policies here. */
        @AuraEnabled
        public Integer openClaims = 0;
        /** What the record says about the risk here, and the open claims, for Claude to weigh. Not sent to the page. */
        List<String> notes = new List<String>();
        List<String> claimLines = new List<String>();
    }

    /** One line of business in the area. */
    public class LineRow {
        @AuraEnabled
        public String line;
        @AuraEnabled
        public Integer policies = 0;
        @AuraEnabled
        public Integer locations = 0;
        @AuraEnabled
        public Decimal insuredValue = 0;
        @AuraEnabled
        public Decimal respondingValue = 0;
        Set<Id> policyIds = new Set<Id>();
        Set<String> placeKeys = new Set<String>();
    }

    /** One coverage, across the policies in the area. */
    public class CoverageRow {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Integer policies = 0;
        @AuraEnabled
        public Decimal deductibleLow;
        @AuraEnabled
        public Decimal deductibleHigh;
        Set<Id> policyIds = new Set<Id>();
    }

    /** One claim on a policy in the area. */
    public class ClaimRow {
        @AuraEnabled
        public Id claimId;
        @AuraEnabled
        public String claimNumber;
        @AuraEnabled
        public String subject;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String lossType;
        @AuraEnabled
        public Date lossDate;
        @AuraEnabled
        public String customerName;
        @AuraEnabled
        public Id customerId;
        /** Whether the loss type is one this kind of event causes. */
        @AuraEnabled
        public Boolean related;
        /** Whether the loss happened on or after the day of the event. */
        @AuraEnabled
        public Boolean sinceEvent;
    }

    /** Everything the page shows for one event before Claude is asked for anything. */
    public class Exposure {
        @AuraEnabled
        public EventInfo event;
        @AuraEnabled
        public Integer locations = 0;
        @AuraEnabled
        public Integer customers = 0;
        @AuraEnabled
        public Integer policies = 0;
        @AuraEnabled
        public Decimal insuredValue = 0;
        @AuraEnabled
        public Decimal respondingValue = 0;
        /** Homes, buildings and vehicles inside under a coverage that responds: what the claim estimate counts. */
        @AuraEnabled
        public Integer exposedUnits = 0;
        @AuraEnabled
        public Integer expectedLow;
        @AuraEnabled
        public Integer expectedHigh;
        @AuraEnabled
        public String expectedBasis;
        @AuraEnabled
        public List<Place> places = new List<Place>();
        @AuraEnabled
        public List<LineRow> byLine = new List<LineRow>();
        @AuraEnabled
        public List<CoverageRow> coverages = new List<CoverageRow>();
        @AuraEnabled
        public List<String> coverageNotes = new List<String>();
        @AuraEnabled
        public List<ClaimRow> claims = new List<ClaimRow>();
        @AuraEnabled
        public Integer claimsSince = 0;
        @AuraEnabled
        public Integer claimsSinceRelated = 0;
        @AuraEnabled
        public Integer claimsOpenBefore = 0;
        @AuraEnabled
        public Integer nearby = 0;
        /** Whether more assets matched than the page reads at once. */
        @AuraEnabled
        public Boolean truncated = false;
    }

    /** One customer Claude says to call first. */
    public class Call {
        @AuraEnabled
        public String key;
        @AuraEnabled
        public Id customerId;
        @AuraEnabled
        public String customerName;
        @AuraEnabled
        public Id contactId;
        @AuraEnabled
        public String contactName;
        @AuraEnabled
        public String contactPhone;
        @AuraEnabled
        public String town;
        @AuraEnabled
        public String what;
        @AuraEnabled
        public Decimal insuredValue;
        @AuraEnabled
        public String reason;
        @AuraEnabled
        public String message;
    }

    /** Claude's response plan for one event. It is not stored. */
    public class Plan {
        @AuraEnabled
        public String headline;
        @AuraEnabled
        public String expectNote;
        @AuraEnabled
        public List<Call> calls = new List<Call>();
        @AuraEnabled
        public List<String> staffing = new List<String>();
        @AuraEnabled
        public List<String> coverageWatch = new List<String>();
        @AuraEnabled
        public List<String> notHeld = new List<String>();
        @AuraEnabled
        public Datetime writtenAt;
    }

    /** A call task to create, as the page sends it. */
    public class CallRequest {
        @AuraEnabled
        public String key { get; set; }
        @AuraEnabled
        public String message { get; set; }
    }

    /** A call task that was created. */
    public class CreatedTask {
        @AuraEnabled
        public Id taskId;
        @AuraEnabled
        public String subject;
        @AuraEnabled
        public String customerName;
    }

    /**
     * @description The events set up for this org, in their order.
     * @return The events, each with its area
     */
    @AuraEnabled(cacheable=true)
    public static List<EventInfo> getEvents() {
        List<EventInfo> events = new List<EventInfo>();
        for (Antsurance_Event__mdt record : eventRecords()) {
            events.add(infoOf(record));
        }
        return events;
    }

    /**
     * @description What is exposed to one event: the insured locations inside and just outside its
     * area, the totals, the coverages that respond, and the claims on those policies.
     * @param eventName The event's API name
     * @return The exposure, worked out from the records
     * @throws AuraHandledException when the event does not exist or has no area, or the user cannot read the records behind it
     */
    @AuraEnabled(cacheable=true)
    public static Exposure getExposure(String eventName) {
        return exposureOf(eventNamed(eventName));
    }

    /**
     * @description Asks Claude for a response plan: what to expect, who to call first and why, with
     * a short message for each call, staffing, and what to watch in coverage. Claude is given only
     * what the page worked out. The plan is returned, not stored. One Claude call.
     * @param eventName The event's API name
     * @return The plan
     * @throws AuraHandledException when the event is missing, nothing is inside its area, the user cannot read the records, or Claude cannot be reached
     */
    @AuraEnabled
    public static Plan writePlan(String eventName) {
        Exposure exposure = exposureOf(eventNamed(eventName));
        Map<String, Place> candidates = candidatesOf(exposure);
        if (candidates.isEmpty()) {
            throw error(NOTHING_INSIDE);
        }
        try {
            AntsuranceAiClient.Question question = new AntsuranceAiClient.Question(instructions(), describe(exposure, candidates)).returning(planShape(candidates.keySet()));
            question.maxTokens = PLAN_TOKENS;
            Plan plan = toPlan(AntsuranceAiClient.ask(question).data, candidates);
            plan.writtenAt = Datetime.now();
            return plan;
        } catch (AntsuranceAiClient.AiException e) {
            throw error(e.getMessage());
        }
    }

    /**
     * @description Creates one call task for each chosen customer, holding the message for the
     * caller to use. At most five at a time. Nothing is sent to the customer.
     * @param eventName The event's API name
     * @param calls The chosen customers, by the key the exposure gave their location, each with its message
     * @return The tasks created
     * @throws AuraHandledException when none or too many are chosen, a customer is not inside the event's area, or the user may not read the records or create tasks
     */
    @AuraEnabled
    public static List<CreatedTask> createCallTasks(String eventName, List<CallRequest> calls) {
        if (calls == null || calls.isEmpty()) {
            throw error(NO_CALLS);
        }
        if (calls.size() > MAX_CALLS) {
            throw error(TOO_MANY_CALLS);
        }
        Antsurance_Event__mdt record = eventNamed(eventName);
        Exposure exposure = exposureOf(record);
        Map<String, Place> inside = new Map<String, Place>();
        for (Place place : exposure.places) {
            if (place.inside) {
                inside.put(place.key, place);
            }
        }
        List<Task> tasks = new List<Task>();
        List<CreatedTask> created = new List<CreatedTask>();
        Set<String> seen = new Set<String>();
        for (CallRequest call : calls) {
            Place place = call == null ? null : inside.get(call.key);
            if (place == null) {
                throw error(NOT_INSIDE);
            }
            if (!seen.add(place.key)) {
                continue;
            }
            String who = String.isBlank(place.contactName) ? place.customerName : place.contactName;
            Task task = new Task(
                Subject = ('Call ' + who + ' about the ' + exposure.event.peril.toLowerCase() + ' event').left(255),
                WhatId = place.customerId,
                WhoId = place.contactId,
                ActivityDate = Date.today(),
                Priority = 'High',
                Description = (exposure.event.label + '. ' + place.what + ' in ' + place.town + '.\n\n' + (String.isBlank(call.message) ? '' : call.message.trim())).left(30000)
            );
            tasks.add(task);
            CreatedTask row = new CreatedTask();
            row.subject = task.Subject;
            row.customerName = place.customerName;
            created.add(row);
        }
        try {
            insert as user tasks;
        } catch (DmlException e) {
            throw error('The call tasks could not be created: ' + e.getDmlMessage(0));
        } catch (SecurityException e) {
            throw error(NO_TASK_ACCESS);
        }
        for (Integer index = 0; index < tasks.size(); index++) {
            created[index].taskId = tasks[index].Id;
        }
        return created;
    }

    private static List<Antsurance_Event__mdt> eventRecords() {
        if (Test.isRunningTest() && testEvents != null) {
            return testEvents;
        }
        // Events are configuration, not customer data, so they are read whatever the user's access to the type.
        return [
            SELECT DeveloperName, MasterLabel, Peril__c, Event_Date__c, Days_Ago__c, Center_Latitude__c, Center_Longitude__c, Radius_Miles__c,
                Footprint_Points__c, Area__c, Severity_Note__c, Claim_Rate_Low__c, Claim_Rate_High__c, Sort_Order__c
            FROM Antsurance_Event__mdt
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c NULLS LAST, MasterLabel
            LIMIT 50
        ];
    }

    private static Antsurance_Event__mdt eventNamed(String eventName) {
        for (Antsurance_Event__mdt record : eventRecords()) {
            if (record.DeveloperName == eventName) {
                return record;
            }
        }
        throw error(NO_EVENT);
    }

    private static Date dateOf(Antsurance_Event__mdt record) {
        if (record.Event_Date__c != null) {
            return record.Event_Date__c;
        }
        return Date.today().addDays(-(record.Days_Ago__c == null ? 0 : record.Days_Ago__c.intValue()));
    }

    private static EventInfo infoOf(Antsurance_Event__mdt record) {
        EventInfo info = new EventInfo();
        info.name = record.DeveloperName;
        info.label = record.MasterLabel;
        info.peril = String.isBlank(record.Peril__c) ? 'Hail' : record.Peril__c;
        info.eventDate = dateOf(record);
        info.daysAgo = info.eventDate.daysBetween(Date.today());
        info.area = record.Area__c;
        info.note = record.Severity_Note__c;
        AntsuranceEventGeometry.Footprint area = AntsuranceEventGeometry.footprint(record.Center_Latitude__c, record.Center_Longitude__c, record.Radius_Miles__c, record.Footprint_Points__c);
        info.hasArea = area != null;
        if (area != null) {
            List<Double> middle = area.middle();
            info.centerLatitude = middle[0];
            info.centerLongitude = middle[1];
            info.reachMiles = area.reachMiles();
            info.radiusMiles = area.isOutline() ? null : area.radiusMiles;
            info.points = area.points;
        }
        return info;
    }

    /**
     * The exposure, read with the running user's own access. A query that touches an object or a field
     * they may not see fails as a whole, and the page says so; nothing is shown in part.
     */
    private static Exposure exposureOf(Antsurance_Event__mdt record) {
        try {
            return readExposure(record);
        } catch (QueryException e) {
            throw error(LOAD_ERROR);
        }
    }

    private static Exposure readExposure(Antsurance_Event__mdt record) {
        Exposure exposure = new Exposure();
        exposure.event = infoOf(record);
        AntsuranceEventGeometry.Footprint area = AntsuranceEventGeometry.footprint(record.Center_Latitude__c, record.Center_Longitude__c, record.Radius_Miles__c, record.Footprint_Points__c);
        if (area == null) {
            throw error(NO_AREA);
        }
        String peril = exposure.event.peril;

        // A box around the area narrows the query; the exact test is made on each row.
        List<Double> box = area.boundingBox(NEARBY_MILES);
        Double south = box[0];
        Double north = box[1];
        Double west = box[2];
        Double east = box[3];
        Integer oneMore = ASSET_LIMIT + 1;
        List<Policy_Asset__c> assets = [
            SELECT Id, Name, Asset_Type__c, Insured_Value__c, Latitude__c, Longitude__c, Details__c,
                Policy__c, Policy__r.Name, Policy__r.Line_of_Business__c, Policy__r.Account__c, Policy__r.Account__r.Name, Policy__r.Account__r.BillingCity,
                Policy__r.Primary_Insured__c, Policy__r.Primary_Insured__r.Name, Policy__r.Primary_Insured__r.Phone, Policy__r.Underwriting_Notes__c
            FROM Policy_Asset__c
            WHERE Latitude__c >= :south AND Latitude__c <= :north AND Longitude__c >= :west AND Longitude__c <= :east
                AND Policy__r.Status__c IN :IN_FORCE AND Policy__r.Account__c != NULL
            WITH USER_MODE
            ORDER BY Insured_Value__c DESC NULLS LAST, Name
            LIMIT :oneMore
        ];
        if (assets.size() > ASSET_LIMIT) {
            exposure.truncated = true;
            assets.remove(ASSET_LIMIT);
        }

        Map<String, Place> places = new Map<String, Place>();
        Map<String, List<Policy_Asset__c>> assetsByPlace = new Map<String, List<Policy_Asset__c>>();
        Set<Id> policyIds = new Set<Id>();
        for (Policy_Asset__c asset : assets) {
            Double latitude = asset.Latitude__c.doubleValue();
            Double longitude = asset.Longitude__c.doubleValue();
            Double milesOutside = area.milesOutside(latitude, longitude);
            if (milesOutside > NEARBY_MILES) {
                continue;
            }
            // An umbrella policy sits over other policies. Its entry is not something insured at this spot.
            if (asset.Policy__r.Line_of_Business__c == 'Umbrella' && !HOME_TYPES.contains(asset.Asset_Type__c) && !BUSINESS_TYPES.contains(asset.Asset_Type__c) && !VEHICLE_TYPES.contains(asset.Asset_Type__c)) {
                continue;
            }
            String key = asset.Policy__r.Account__c + ':' + asset.Latitude__c.setScale(5) + ',' + asset.Longitude__c.setScale(5);
            Place place = places.get(key);
            if (place == null) {
                place = new Place();
                place.key = key;
                place.latitude = latitude;
                place.longitude = longitude;
                place.inside = milesOutside <= 0;
                place.milesFromEdge = Decimal.valueOf(Math.abs(milesOutside)).setScale(1).doubleValue();
                place.customerId = asset.Policy__r.Account__c;
                place.customerName = asset.Policy__r.Account__r.Name;
                place.town = asset.Policy__r.Account__r.BillingCity;
                places.put(key, place);
                assetsByPlace.put(key, new List<Policy_Asset__c>());
            }
            assetsByPlace.get(key).add(asset);
            policyIds.add(asset.Policy__c);
            if (place.contactId == null && asset.Policy__r.Primary_Insured__c != null) {
                place.contactId = asset.Policy__r.Primary_Insured__c;
                place.contactName = asset.Policy__r.Primary_Insured__r.Name;
                place.contactPhone = asset.Policy__r.Primary_Insured__r.Phone;
            }
        }

        Map<Id, PolicyCover> coverByPolicy = coverOf(policyIds, peril, exposure, places, assetsByPlace);

        Map<String, LineRow> lines = new Map<String, LineRow>();
        Set<Id> customersInside = new Set<Id>();
        Set<Id> policiesInside = new Set<Id>();
        for (String key : places.keySet()) {
            Place place = places.get(key);
            Set<String> seenNotes = new Set<String>();
            for (Policy_Asset__c asset : assetsByPlace.get(key)) {
                PolicyCover cover = coverByPolicy.get(asset.Policy__c);
                Item item = new Item();
                item.assetId = asset.Id;
                item.name = asset.Name;
                item.assetType = asset.Asset_Type__c;
                item.insuredValue = asset.Insured_Value__c;
                item.policyId = asset.Policy__c;
                item.policyName = asset.Policy__r.Name;
                item.line = asset.Policy__r.Line_of_Business__c;
                item.coverage = cover == null ? null : cover.statusFor(asset.Asset_Type__c);
                place.items.add(item);
                Decimal value = asset.Insured_Value__c == null ? 0 : asset.Insured_Value__c;
                place.insuredValue += value;
                Boolean isCovered = item.coverage == RESPONDS;
                if (isCovered) {
                    place.respondingValue += value;
                }
                if (item.line != null && !place.lines.contains(item.line)) {
                    place.lines.add(item.line);
                }
                noteRisk(place, asset, peril, seenNotes);
                if (!place.inside) {
                    continue;
                }
                policiesInside.add(asset.Policy__c);
                exposure.insuredValue += value;
                if (isCovered) {
                    exposure.respondingValue += value;
                    exposure.exposedUnits++;
                }
                String lineName = String.isBlank(item.line) ? 'Other' : item.line;
                LineRow row = lines.get(lineName);
                if (row == null) {
                    row = new LineRow();
                    row.line = lineName;
                    lines.put(lineName, row);
                }
                row.policyIds.add(asset.Policy__c);
                row.placeKeys.add(key);
                row.insuredValue += value;
                if (isCovered) {
                    row.respondingValue += value;
                }
            }
            place.kind = kindOf(place.items);
            place.what = whatIsThere(place.items);
            if (place.inside) {
                exposure.locations++;
                customersInside.add(place.customerId);
            } else {
                exposure.nearby++;
            }
        }
        exposure.customers = customersInside.size();
        exposure.policies = policiesInside.size();
        for (LineRow row : lines.values()) {
            row.policies = row.policyIds.size();
            row.locations = row.placeKeys.size();
            exposure.byLine.add(row);
        }
        sortLines(exposure.byLine);
        claimsOf(policyIds, policiesInside, exposure, places, assetsByPlace);
        exposure.places = sortPlaces(places.values());
        estimate(exposure, record);
        return exposure;
    }

    /** What one policy's recorded coverages say about this kind of event. */
    private class PolicyCover {
        String property;
        String vehicles;

        String statusFor(String assetType) {
            if (HOME_TYPES.contains(assetType) || BUSINESS_TYPES.contains(assetType)) {
                return property;
            }
            return VEHICLE_TYPES.contains(assetType) ? vehicles : null;
        }
    }

    /**
     * Reads the coverages and endorsements of the policies in and around the area, decides for each
     * policy whether its property and vehicle coverages respond to this kind of event, and fills the
     * exposure's coverage rows and notes for the policies inside.
     */
    private static Map<Id, PolicyCover> coverOf(Set<Id> policyIds, String peril, Exposure exposure, Map<String, Place> places, Map<String, List<Policy_Asset__c>> assetsByPlace) {
        Map<Id, PolicyCover> covers = new Map<Id, PolicyCover>();
        if (policyIds.isEmpty()) {
            return covers;
        }
        Set<Id> insidePolicies = new Set<Id>();
        for (String key : places.keySet()) {
            if (places.get(key).inside) {
                for (Policy_Asset__c asset : assetsByPlace.get(key)) {
                    insidePolicies.add(asset.Policy__c);
                }
            }
        }
        List<String> words = PERIL_WORDS.containsKey(peril) ? PERIL_WORDS.get(peril) : new List<String>();
        Boolean isFlood = peril == 'Flood';

        Map<Id, List<Policy_Coverage__c>> coverages = new Map<Id, List<Policy_Coverage__c>>();
        for (Policy_Coverage__c coverage : [
            SELECT Policy__c, Name, Category__c, Deductible_Amount__c, What_Is_Covered__c
            FROM Policy_Coverage__c
            WHERE Policy__c IN :policyIds AND Status__c != 'Removed'
            WITH USER_MODE
            ORDER BY Name
        ]) {
            if (!coverages.containsKey(coverage.Policy__c)) {
                coverages.put(coverage.Policy__c, new List<Policy_Coverage__c>());
            }
            coverages.get(coverage.Policy__c).add(coverage);
        }
        Map<Id, List<Policy_Endorsement__c>> endorsements = new Map<Id, List<Policy_Endorsement__c>>();
        for (Policy_Endorsement__c endorsement : [
            SELECT Policy__c, Name, Type__c, Form_Number__c, Limit_Amount__c, Description__c
            FROM Policy_Endorsement__c
            WHERE Policy__c IN :policyIds AND Status__c != 'Removed'
            WITH USER_MODE
            ORDER BY Name
        ]) {
            if (!endorsements.containsKey(endorsement.Policy__c)) {
                endorsements.put(endorsement.Policy__c, new List<Policy_Endorsement__c>());
            }
            endorsements.get(endorsement.Policy__c).add(endorsement);
        }

        Map<String, CoverageRow> rows = new Map<String, CoverageRow>();
        Map<String, Set<Id>> exclusions = new Map<String, Set<Id>>();
        Map<String, Set<Id>> extras = new Map<String, Set<Id>>();
        Map<String, Decimal> extraLimits = new Map<String, Decimal>();
        Boolean ownDeductible = false;
        for (Id policyId : policyIds) {
            PolicyCover cover = new PolicyCover();
            covers.put(policyId, cover);
            List<Policy_Coverage__c> policyCoverages = coverages.containsKey(policyId) ? coverages.get(policyId) : new List<Policy_Coverage__c>();
            List<Policy_Endorsement__c> policyEndorsements = endorsements.containsKey(policyId) ? endorsements.get(policyId) : new List<Policy_Endorsement__c>();
            Boolean isInside = insidePolicies.contains(policyId);

            Boolean isExcluded = false;
            Boolean added = false;
            for (Policy_Endorsement__c endorsement : policyEndorsements) {
                String name = endorsement.Name == null ? '' : endorsement.Name.toLowerCase();
                if (!mentions(name, words)) {
                    continue;
                }
                String label = endorsement.Name + (String.isBlank(endorsement.Form_Number__c) ? '' : ' (' + endorsement.Form_Number__c + ')');
                if (endorsement.Type__c == 'Exclusion') {
                    isExcluded = true;
                    if (isInside) {
                        gather(exclusions, label, policyId);
                    }
                } else {
                    // Only cover written for the event itself changes the answer: water backup is not flood cover.
                    if (name.contains(peril.toLowerCase()) && !name.contains('deductible')) {
                        added = true;
                    }
                    if (name.contains('deductible')) {
                        ownDeductible = ownDeductible || isInside;
                    }
                    if (isInside) {
                        gather(extras, label, policyId);
                        if (endorsement.Limit_Amount__c != null) {
                            extraLimits.put(label, endorsement.Limit_Amount__c);
                        }
                    }
                }
            }
            Boolean hasProperty = false;
            for (Policy_Coverage__c coverage : policyCoverages) {
                if (PROPERTY_CATEGORIES.contains(coverage.Category__c)) {
                    hasProperty = true;
                    isExcluded = isExcluded || saysExcluded(coverage.What_Is_Covered__c, words);
                }
            }
            if (hasProperty) {
                if (added) {
                    cover.property = RESPONDS;
                } else if (isExcluded) {
                    cover.property = EXCLUDED;
                } else {
                    cover.property = isFlood ? NOT_STATED : RESPONDS;
                }
            }
            for (Policy_Coverage__c coverage : policyCoverages) {
                Boolean isProperty = PROPERTY_CATEGORIES.contains(coverage.Category__c);
                Boolean isVehicle = coverage.Category__c == VEHICLE_CATEGORY;
                if (isVehicle) {
                    cover.vehicles = RESPONDS;
                }
                if (!isInside || (!isProperty && !isVehicle)) {
                    continue;
                }
                String status = isVehicle ? RESPONDS : cover.property;
                String rowKey = coverage.Name + '|' + status;
                CoverageRow row = rows.get(rowKey);
                if (row == null) {
                    row = new CoverageRow();
                    row.name = coverage.Name;
                    row.status = status;
                    rows.put(rowKey, row);
                }
                row.policyIds.add(policyId);
                if (coverage.Deductible_Amount__c != null && coverage.Deductible_Amount__c > 0) {
                    row.deductibleLow = row.deductibleLow == null || coverage.Deductible_Amount__c < row.deductibleLow ? coverage.Deductible_Amount__c : row.deductibleLow;
                    row.deductibleHigh = row.deductibleHigh == null || coverage.Deductible_Amount__c > row.deductibleHigh ? coverage.Deductible_Amount__c : row.deductibleHigh;
                }
            }
        }
        for (CoverageRow row : rows.values()) {
            row.policies = row.policyIds.size();
            exposure.coverages.add(row);
        }
        sortCoverages(exposure.coverages);

        for (String label : exclusions.keySet()) {
            exposure.coverageNotes.add(label + ' is on ' + countOf(exclusions.get(label).size(), 'policy', 'policies') + '.');
        }
        for (String label : extras.keySet()) {
            Decimal limitAmount = extraLimits.get(label);
            exposure.coverageNotes.add(label + ' is on ' + countOf(extras.get(label).size(), 'policy', 'policies') + (limitAmount == null ? '.' : ', up to ' + money(limitAmount) + ' each.'));
        }
        if (!exposure.coverages.isEmpty()) {
            if (isFlood) {
                exposure.coverageNotes.add('Flood is not covered by a standard property policy. Where the record does not say, check the form before telling a customer.');
            } else if (!ownDeductible) {
                exposure.coverageNotes.add('No separate wind or hail deductible is recorded on these policies. The coverage deductible applies.');
            }
            exposure.coverageNotes.add(FORMS_CAVEAT);
        }
        return covers;
    }

    private static void gather(Map<String, Set<Id>> byLabel, String label, Id policyId) {
        if (!byLabel.containsKey(label)) {
            byLabel.put(label, new Set<Id>());
        }
        byLabel.get(label).add(policyId);
    }

    private static Boolean mentions(String lowerText, List<String> words) {
        for (String word : words) {
            if (lowerText.contains(word)) {
                return true;
            }
        }
        return false;
    }

    /** Whether one sentence of a coverage's wording both names the event and says it is excluded. */
    @TestVisible
    private static Boolean saysExcluded(String wording, List<String> words) {
        if (String.isBlank(wording)) {
            return false;
        }
        for (String sentence : wording.toLowerCase().split('[.\\n]')) {
            if ((sentence.contains('exclud') || sentence.contains('not covered')) && mentions(sentence, words)) {
                return true;
            }
        }
        return false;
    }

    /** Keeps what the record says about a risk that matters for this kind of event: a roof for hail and wind, a basement for flood. */
    private static void noteRisk(Place place, Policy_Asset__c asset, String peril, Set<String> seen) {
        List<String> clues = peril == 'Flood' ? new List<String>{ 'basement', 'sump', 'flood', 'ground floor', 'water' } : new List<String>{ 'roof', 'skylight', 'siding', 'hail', 'wind' };
        if (String.isNotBlank(asset.Details__c) && mentions(asset.Details__c.toLowerCase(), clues) && seen.add(asset.Details__c)) {
            place.notes.add(asset.Name + ': ' + asset.Details__c);
        }
        String notes = asset.Policy__r.Underwriting_Notes__c;
        if (String.isBlank(notes) || !seen.add(asset.Policy__c + 'notes')) {
            return;
        }
        for (String sentence : notes.replace('**', '').split('[.\\n]')) {
            if (String.isNotBlank(sentence) && mentions(sentence.toLowerCase(), clues)) {
                place.notes.add('Underwriting note on ' + asset.Policy__r.Name + ': ' + sentence.trim().left(240));
            }
        }
    }

    /** Reads the claims on the policies in the area: those since the event, and those already open before it. */
    private static void claimsOf(Set<Id> policyIds, Set<Id> policiesInside, Exposure exposure, Map<String, Place> places, Map<String, List<Policy_Asset__c>> assetsByPlace) {
        if (policiesInside.isEmpty()) {
            return;
        }
        Map<Id, List<Place>> placesByPolicy = new Map<Id, List<Place>>();
        for (String key : places.keySet()) {
            Place place = places.get(key);
            if (!place.inside) {
                continue;
            }
            for (Policy_Asset__c asset : assetsByPlace.get(key)) {
                if (!placesByPolicy.containsKey(asset.Policy__c)) {
                    placesByPolicy.put(asset.Policy__c, new List<Place>());
                }
                if (!placesByPolicy.get(asset.Policy__c).contains(place)) {
                    placesByPolicy.get(asset.Policy__c).add(place);
                }
            }
        }
        Date eventDate = exposure.event.eventDate;
        Set<String> related = PERIL_LOSS_TYPES.containsKey(exposure.event.peril) ? PERIL_LOSS_TYPES.get(exposure.event.peril) : new Set<String>();
        for (Case claim : [
            SELECT Id, CaseNumber, Subject, Description, Status, IsClosed, Loss_Type__c, Date_of_Loss__c, Policy__c, Policy__r.Account__c, Policy__r.Account__r.Name
            FROM Case
            WHERE Policy__c IN :policiesInside AND RecordType.DeveloperName = 'Claim' AND (IsClosed = FALSE OR Date_of_Loss__c >= :eventDate)
            WITH USER_MODE
            ORDER BY Date_of_Loss__c DESC NULLS LAST, CaseNumber DESC
            LIMIT 200
        ]) {
            Boolean since = claim.Date_of_Loss__c != null && claim.Date_of_Loss__c >= eventDate;
            if (!since && claim.IsClosed) {
                continue;
            }
            ClaimRow row = new ClaimRow();
            row.claimId = claim.Id;
            row.claimNumber = claim.CaseNumber;
            row.subject = claim.Subject;
            row.status = claim.Status;
            row.lossType = claim.Loss_Type__c;
            row.lossDate = claim.Date_of_Loss__c;
            row.customerId = claim.Policy__r.Account__c;
            row.customerName = claim.Policy__r.Account__r.Name;
            row.related = related.contains(claim.Loss_Type__c) && !namesAnotherCause(exposure.event.peril, claim);
            row.sinceEvent = since;
            exposure.claims.add(row);
            if (since) {
                exposure.claimsSince++;
                if (row.related) {
                    exposure.claimsSinceRelated++;
                }
            } else {
                exposure.claimsOpenBefore++;
            }
            if (!claim.IsClosed && placesByPolicy.containsKey(claim.Policy__c)) {
                for (Place place : placesByPolicy.get(claim.Policy__c)) {
                    place.openClaims++;
                    place.claimLines.add(claim.Subject + ' (' + claim.Status + (claim.Loss_Type__c == null ? '' : ', ' + claim.Loss_Type__c) + ')');
                }
            }
        }
    }

    /** True when the claim's own words give a cause this kind of event does not: a burst pipe is not a flood. */
    private static Boolean namesAnotherCause(String peril, Case claim) {
        if (!PERIL_OTHER_CAUSES.containsKey(peril)) {
            return false;
        }
        String words = ((claim.Subject == null ? '' : claim.Subject) + ' ' + (claim.Description == null ? '' : claim.Description)).toLowerCase();
        for (String cause : PERIL_OTHER_CAUSES.get(peril)) {
            if (words.contains(cause)) {
                return true;
            }
        }
        return false;
    }

    /** The planning estimate: the event's assumed share of the exposed homes, buildings and vehicles. */
    private static void estimate(Exposure exposure, Antsurance_Event__mdt record) {
        if (exposure.exposedUnits == 0 || record.Claim_Rate_Low__c == null || record.Claim_Rate_High__c == null) {
            return;
        }
        Decimal low = Math.min(record.Claim_Rate_Low__c, record.Claim_Rate_High__c);
        Decimal high = Math.max(record.Claim_Rate_Low__c, record.Claim_Rate_High__c);
        exposure.expectedLow = (exposure.exposedUnits * low / 100).round(System.RoundingMode.FLOOR).intValue();
        exposure.expectedHigh = Math.max(exposure.expectedLow, (exposure.exposedUnits * high / 100).round(System.RoundingMode.CEILING).intValue());
        exposure.expectedBasis =
            'An estimate, not a forecast: ' +
            low.intValue() +
            '% to ' +
            high.intValue() +
            '% of the ' +
            countOf(exposure.exposedUnits, 'home, building or vehicle', 'homes, buildings and vehicles') +
            ' here under a coverage that responds. The percentages are this event\'s planning assumption, set in Setup.';
    }

    private static String kindOf(List<Item> items) {
        Boolean hasBusiness = false;
        Boolean hasVehicle = false;
        for (Item item : items) {
            if (HOME_TYPES.contains(item.assetType)) {
                return 'Home';
            }
            hasBusiness = hasBusiness || BUSINESS_TYPES.contains(item.assetType);
            hasVehicle = hasVehicle || VEHICLE_TYPES.contains(item.assetType);
        }
        if (hasBusiness) {
            return 'Business';
        }
        return hasVehicle ? 'Vehicle' : 'Workplace';
    }

    /** What is at a location, in words: "Home and 2 vehicles". */
    @TestVisible
    private static String whatIsThere(List<Item> items) {
        Map<String, Integer> counts = new Map<String, Integer>{ 'Home' => 0, 'Rented home' => 0, 'Building' => 0, 'Business property' => 0, 'Fleet' => 0, 'Vehicle' => 0, 'Workplace' => 0 };
        for (Item item : items) {
            String word = WORDS_FOR.containsKey(item.assetType) ? WORDS_FOR.get(item.assetType) : 'Workplace';
            counts.put(word, counts.get(word) + 1);
        }
        List<String> parts = new List<String>();
        for (String word : new List<String>{ 'Home', 'Rented home', 'Building', 'Business property', 'Fleet', 'Vehicle', 'Workplace' }) {
            Integer count = counts.get(word);
            if (count == 0) {
                continue;
            }
            Boolean counted = word == 'Vehicle' || word == 'Building';
            String text = counted && (count > 1 || !parts.isEmpty()) ? count + ' ' + word.toLowerCase() + (count == 1 ? '' : 's') : word;
            parts.add(parts.isEmpty() ? text : text.toLowerCase());
        }
        if (parts.size() < 2) {
            return parts.isEmpty() ? 'Insured location' : parts[0];
        }
        String last = parts.remove(parts.size() - 1);
        return String.join(parts, ', ') + ' and ' + last;
    }

    private static void sortLines(List<LineRow> rows) {
        for (Integer index = 1; index < rows.size(); index++) {
            LineRow current = rows[index];
            Integer spot = index - 1;
            while (spot >= 0 && rows[spot].insuredValue < current.insuredValue) {
                rows[spot + 1] = rows[spot];
                spot--;
            }
            rows[spot + 1] = current;
        }
    }

    private static void sortCoverages(List<CoverageRow> rows) {
        Map<String, Integer> rank = new Map<String, Integer>{ RESPONDS => 0, EXCLUDED => 1, NOT_STATED => 2 };
        for (Integer index = 1; index < rows.size(); index++) {
            CoverageRow current = rows[index];
            Integer spot = index - 1;
            while (spot >= 0 && (rank.get(rows[spot].status) > rank.get(current.status) || (rank.get(rows[spot].status) == rank.get(current.status) && rows[spot].policies < current.policies))) {
                rows[spot + 1] = rows[spot];
                spot--;
            }
            rows[spot + 1] = current;
        }
    }

    /** Inside first, largest insured value first; then the ones just outside, nearest first. */
    private static List<Place> sortPlaces(List<Place> unsorted) {
        List<Place> rows = new List<Place>(unsorted);
        for (Integer index = 1; index < rows.size(); index++) {
            Place current = rows[index];
            Integer spot = index - 1;
            while (spot >= 0 && comesBefore(current, rows[spot])) {
                rows[spot + 1] = rows[spot];
                spot--;
            }
            rows[spot + 1] = current;
        }
        return rows;
    }

    private static Boolean comesBefore(Place first, Place second) {
        if (first.inside != second.inside) {
            return first.inside;
        }
        if (!first.inside && first.milesFromEdge != second.milesFromEdge) {
            return first.milesFromEdge < second.milesFromEdge;
        }
        if (first.insuredValue != second.insuredValue) {
            return first.insuredValue > second.insuredValue;
        }
        return first.customerName < second.customerName;
    }

    /** The locations Claude may choose first calls from, each under a short key. */
    private static Map<String, Place> candidatesOf(Exposure exposure) {
        Map<String, Place> candidates = new Map<String, Place>();
        Set<Id> customers = new Set<Id>();
        // Largest first, then anyone with a note on the risk or an open claim who would otherwise be cut.
        for (Integer pass = 0; pass < 2; pass++) {
            for (Place place : exposure.places) {
                if (!place.inside || candidates.size() >= MAX_CANDIDATES || customers.contains(place.customerId)) {
                    continue;
                }
                if (pass == 0 && candidates.size() >= MAX_CANDIDATES - 4 && place.notes.isEmpty() && place.openClaims == 0) {
                    continue;
                }
                customers.add(place.customerId);
                candidates.put('P' + (candidates.size() + 1), place);
            }
        }
        return candidates;
    }

    private static String instructions() {
        return 'You are helping a claims leader at Antsurance, an insurance carrier, plan the response to a weather event that crossed part of the book of business. ' +
            'You are given what the system worked out from its own records: the event, the insured locations inside its area, the totals, the coverages that respond, the claims so far and a planning estimate. ' +
            'Use only those facts. Never invent a figure, a customer, a vendor name, a weather detail or a coverage term. Repeat a number only as it is given. ' +
            'The claim estimate is given to you: explain what drives it, do not change it. ' +
            'Choose the customers to call first from the listed locations only, by their key, and give each a reason drawn from the record: the insured value, a note on the roof or the building, an open claim, or cover that does not respond. Choose at most ' +
            MAX_CALLS +
            '. ' +
            'For each, write the short message a service representative would say or send: warm, plain, two or three sentences, naming the event and the town, asking if they are safe and whether anything was damaged, and saying how to start a claim with us. Never promise coverage or payment, and never mention a deductible amount in the message. ' +
            'Where coverage does not respond or is not stated on the record, say so plainly in the coverage points so nobody over-promises. ' +
            'Say what this plan cannot know because the system does not hold it: there is no weather feed, no storm track beyond the area given, and no inspection data beyond the notes shown. ' +
            'Write for a busy executive: short sentences, plain words, no jargon left unexplained, no dashes used as punctuation. Write in American English.';
    }

    private static AntsuranceAiClient.Shape planShape(Set<String> keys) {
        AntsuranceAiClient.Shape call = new AntsuranceAiClient.Shape()
            .field('key', AntsuranceAiClient.choice(new List<String>(keys), 'The key of the location, exactly as listed.'))
            .field('reason', AntsuranceAiClient.text('Why this customer comes first, in one sentence from the record.'))
            .field('message', AntsuranceAiClient.text('What to say or send to this customer: two or three plain sentences.'));
        return new AntsuranceAiClient.Shape()
            .field('headline', AntsuranceAiClient.text('The plan in one sentence of at most 25 words.'))
            .field('expect', AntsuranceAiClient.text('What drives the claim estimate given to you, in one or two sentences. Do not restate it as a different number.'))
            .field('calls', AntsuranceAiClient.listOf(call.toJson(), 'The customers to call first, most urgent first, at most ' + MAX_CALLS + '.'))
            .field('staffing', AntsuranceAiClient.listOf(AntsuranceAiClient.text('One step, in one sentence.'), 'Staffing and vendors to line up, at most 4, without naming a vendor.'))
            .field('coverage_watch', AntsuranceAiClient.listOf(AntsuranceAiClient.text('One point, in one sentence.'), 'What to watch in coverage: deductibles, exclusions, cover that is not stated. At most 4.'))
            .field('not_held', AntsuranceAiClient.listOf(AntsuranceAiClient.text('One thing, in one sentence.'), 'What this plan cannot know because the system does not hold it. At most 3.'));
    }

    /** The facts Claude plans from, as text. */
    @TestVisible
    private static String describe(Exposure exposure, Map<String, Place> candidates) {
        EventInfo event = exposure.event;
        List<String> lines = new List<String>{
            'EVENT: ' + event.label + '. Kind: ' + event.peril + '. Date: ' + day(event.eventDate) + ' (' + howLongAgo(event.daysAgo) + ').',
            'AREA: ' + (String.isBlank(event.area) ? 'not named' : event.area) + '.',
            'REPORTED: ' + (String.isBlank(event.note) ? 'nothing recorded' : event.note),
            '',
            'INSIDE THE AREA: ' +
                countOf(exposure.locations, 'insured location', 'insured locations') +
                ', ' +
                countOf(exposure.customers, 'customer', 'customers') +
                ', ' +
                countOf(exposure.policies, 'policy', 'policies') +
                ', ' +
                money(exposure.insuredValue) +
                ' insured value, of which ' +
                money(exposure.respondingValue) +
                ' is under a coverage that responds to this kind of event.',
            'JUST OUTSIDE (within ' + NEARBY_MILES.intValue() + ' miles of the edge): ' + countOf(exposure.nearby, 'location', 'locations') + '.',
            '',
            'BY LINE OF BUSINESS:'
        };
        for (LineRow row : exposure.byLine) {
            lines.add('- ' + row.line + ': ' + countOf(row.policies, 'policy', 'policies') + ', ' + countOf(row.locations, 'location', 'locations') + ', ' + money(row.insuredValue) + ' insured, ' + money(row.respondingValue) + ' under a coverage that responds.');
        }
        lines.add('');
        lines.add('COVERAGES ON THESE POLICIES:');
        for (CoverageRow row : exposure.coverages) {
            String deductible = 'no deductible recorded';
            if (row.deductibleLow != null) {
                deductible = row.deductibleLow == row.deductibleHigh ? 'deductible ' + money(row.deductibleLow) : 'deductibles ' + money(row.deductibleLow) + ' to ' + money(row.deductibleHigh);
            }
            lines.add('- ' + row.name + ': ' + row.status + ' on ' + countOf(row.policies, 'policy', 'policies') + ', ' + deductible + '.');
        }
        for (String note : exposure.coverageNotes) {
            lines.add('- ' + note);
        }
        lines.add('');
        lines.add('CLAIMS: ' + countOf(exposure.claimsSince, 'claim', 'claims') + ' with a loss on or after the event date (' + exposure.claimsSinceRelated + ' of a kind this event causes); ' + countOf(exposure.claimsOpenBefore, 'claim', 'claims') + ' already open before it.');
        for (ClaimRow claim : exposure.claims) {
            lines.add('- ' + claim.customerName + ': ' + claim.subject + ' (' + claim.status + (claim.lossType == null ? '' : ', ' + claim.lossType) + (claim.lossDate == null ? '' : ', loss ' + day(claim.lossDate)) + ').');
        }
        lines.add('');
        if (exposure.expectedLow == null) {
            lines.add('CLAIM ESTIMATE: none, because nothing here is under a coverage that responds or no planning assumption is set.');
        } else {
            lines.add('CLAIM ESTIMATE: ' + (exposure.expectedLow == 0 ? 'up to ' + exposure.expectedHigh : exposure.expectedLow + ' to ' + exposure.expectedHigh) + ' claims. ' + exposure.expectedBasis);
        }
        lines.add('');
        lines.add('LOCATIONS YOU MAY CHOOSE FIRST CALLS FROM:');
        for (String key : candidates.keySet()) {
            Place place = candidates.get(key);
            lines.add(
                key +
                    ': ' +
                    place.customerName +
                    ', ' +
                    place.town +
                    '. ' +
                    place.what +
                    '. Insured value ' +
                    money(place.insuredValue) +
                    ', ' +
                    money(place.respondingValue) +
                    ' under a coverage that responds. Lines: ' +
                    String.join(place.lines, ', ') +
                    '. Contact: ' +
                    (String.isBlank(place.contactName) ? 'none recorded' : place.contactName) +
                    '.'
            );
            for (String note : place.notes) {
                lines.add('   Record: ' + note);
            }
            for (String claim : place.claimLines) {
                lines.add('   Open claim: ' + claim);
            }
        }
        return String.join(lines, '\n');
    }

    /** Turns Claude's answer into the plan, keeping only calls to locations it was given. */
    @TestVisible
    private static Plan toPlan(Map<String, Object> data, Map<String, Place> candidates) {
        Plan plan = new Plan();
        plan.headline = text(data.get('headline'));
        plan.expectNote = text(data.get('expect'));
        plan.staffing = AntsuranceAiClient.toStrings(data.get('staffing'));
        plan.coverageWatch = AntsuranceAiClient.toStrings(data.get('coverage_watch'));
        plan.notHeld = AntsuranceAiClient.toStrings(data.get('not_held'));
        Set<String> used = new Set<String>();
        Object calls = data.get('calls');
        if (calls instanceof List<Object>) {
            for (Object entry : (List<Object>) calls) {
                if (!(entry instanceof Map<String, Object>) || plan.calls.size() >= MAX_CALLS) {
                    continue;
                }
                Map<String, Object> fields = (Map<String, Object>) entry;
                String key = text(fields.get('key'));
                Place place = candidates.get(key);
                if (place == null || !used.add(key)) {
                    continue;
                }
                Call call = new Call();
                call.key = place.key;
                call.customerId = place.customerId;
                call.customerName = place.customerName;
                call.contactId = place.contactId;
                call.contactName = place.contactName;
                call.contactPhone = place.contactPhone;
                call.town = place.town;
                call.what = place.what;
                call.insuredValue = place.insuredValue;
                call.reason = text(fields.get('reason'));
                call.message = text(fields.get('message'));
                plan.calls.add(call);
            }
        }
        return plan;
    }

    private static String text(Object value) {
        return value == null ? null : String.valueOf(value).trim();
    }

    /** A date as a person writes it: Sep 15, 2026. */
    private static String day(Date value) {
        return Datetime.newInstance(value.year(), value.month(), value.day()).format('MMM d, yyyy');
    }

    private static String howLongAgo(Integer daysAgo) {
        if (daysAgo == 0) {
            return 'today';
        }
        return daysAgo == 1 ? 'yesterday' : daysAgo + ' days ago';
    }

    private static String countOf(Integer count, String one, String many) {
        return count + ' ' + (count == 1 ? one : many);
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
