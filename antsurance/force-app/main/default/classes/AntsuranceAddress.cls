/**
 * @description Reads and writes the state and country of an address, so the same code runs in an org with
 * state and country picklists (where the code fields such as BillingStateCode exist) and in one without them
 * (where only the text fields exist). Nothing else in the app names a state or country code field, so the
 * app compiles either way. The check for the picklists is made once per transaction.
 */
public inherited sharing class AntsuranceAddress {
    @TestVisible
    private static Boolean picklists;

    private static final Map<String, String> CODES = new Map<String, String>{
        'alabama' => 'AL', 'alaska' => 'AK', 'arizona' => 'AZ', 'arkansas' => 'AR', 'california' => 'CA', 'colorado' => 'CO',
        'connecticut' => 'CT', 'delaware' => 'DE', 'district of columbia' => 'DC', 'florida' => 'FL', 'georgia' => 'GA', 'hawaii' => 'HI',
        'idaho' => 'ID', 'illinois' => 'IL', 'indiana' => 'IN', 'iowa' => 'IA', 'kansas' => 'KS', 'kentucky' => 'KY', 'louisiana' => 'LA',
        'maine' => 'ME', 'maryland' => 'MD', 'massachusetts' => 'MA', 'michigan' => 'MI', 'minnesota' => 'MN', 'mississippi' => 'MS',
        'missouri' => 'MO', 'montana' => 'MT', 'nebraska' => 'NE', 'nevada' => 'NV', 'new hampshire' => 'NH', 'new jersey' => 'NJ',
        'new mexico' => 'NM', 'new york' => 'NY', 'north carolina' => 'NC', 'north dakota' => 'ND', 'ohio' => 'OH', 'oklahoma' => 'OK',
        'oregon' => 'OR', 'pennsylvania' => 'PA', 'rhode island' => 'RI', 'south carolina' => 'SC', 'south dakota' => 'SD',
        'tennessee' => 'TN', 'texas' => 'TX', 'utah' => 'UT', 'vermont' => 'VT', 'virginia' => 'VA', 'washington' => 'WA',
        'west virginia' => 'WV', 'wisconsin' => 'WI', 'wyoming' => 'WY'
    };

    /**
     * @description Whether this org has state and country picklists switched on.
     * @return True when the code fields exist
     */
    public static Boolean usesPicklists() {
        if (picklists == null) {
            picklists = Schema.SObjectType.Account.fields.getMap().containsKey('Billing' + 'StateCode');
        }
        return picklists;
    }

    /**
     * @description The field that holds a state in this org.
     * @param prefix Billing, Mailing, Shipping, Other, or blank for a lead or a user
     * @return For example BillingStateCode with the picklists on and BillingState without
     */
    public static String stateField(String prefix) {
        return (prefix == null ? '' : prefix) + (usesPicklists() ? 'StateCode' : 'State');
    }

    /**
     * @description The field that holds a country in this org.
     * @param prefix Billing, Mailing, Shipping, Other, or blank for a lead or a user
     * @return For example BillingCountryCode with the picklists on and BillingCountry without
     */
    public static String countryField(String prefix) {
        return (prefix == null ? '' : prefix) + (usesPicklists() ? 'CountryCode' : 'Country');
    }

    /**
     * @description Sets the state and country of an address on a record that has not been saved yet.
     * The country goes first, because the picklists refuse a state whose country is not set.
     * @param record The account, contact, lead or user
     * @param prefix Billing, Mailing, Shipping, Other, or blank for a lead or a user
     * @param state The two-letter state, for example IL
     * @param country The two-letter country, for example US
     */
    public static void put(SObject record, String prefix, String state, String country) {
        if (record == null) {
            return;
        }
        if (String.isNotBlank(country)) {
            record.put(countryField(prefix), country);
        }
        if (String.isNotBlank(state)) {
            record.put(stateField(prefix), state);
        }
    }

    /**
     * @description The two-letter state of an address, from a record built in memory or read from the org.
     * A query asks for the text field (BillingState), which every org has; with the picklists on that holds
     * the state's name, which is turned back into its code here.
     * @param record The account, contact or lead, or null
     * @param prefix Billing, Mailing, Shipping, Other, or blank for a lead
     * @return For example IL, or null when no state is recorded
     */
    public static String state(SObject record, String prefix) {
        if (record == null) {
            return null;
        }
        String start = prefix == null ? '' : prefix;
        if (usesPicklists() && record.isSet(start + 'StateCode')) {
            return (String) record.get(start + 'StateCode');
        }
        return record.isSet(start + 'State') ? code((String) record.get(start + 'State')) : null;
    }

    /**
     * @description A state as its two-letter code.
     * @param text A state's name or code, in any case
     * @return The code for a name this class knows; a two-letter value in capitals; anything else unchanged
     */
    public static String code(String text) {
        if (String.isBlank(text)) {
            return null;
        }
        String trimmed = text.trim();
        if (CODES.containsKey(trimmed.toLowerCase())) {
            return CODES.get(trimmed.toLowerCase());
        }
        return trimmed.length() == 2 ? trimmed.toUpperCase() : trimmed;
    }
}
