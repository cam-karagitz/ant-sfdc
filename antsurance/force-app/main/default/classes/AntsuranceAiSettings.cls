/**
 * @description Which Claude model this org uses and whether it asks for fast output, read from the
 * Default record of Antsurance_AI_Setting__mdt so an admin can change them in Setup without a deploy.
 * An org with no record, or an empty field, gets the values built in here. Tests always get the built-in values.
 */
public inherited sharing class AntsuranceAiSettings {
    public static final String BUILT_IN_MODEL = 'claude-opus-5-5';
    public static final String BUILT_IN_FAST_MODE_BETA = 'fast-mode-2026-02-01';

    // Set by a test to stand in for the stored record.
    @TestVisible
    private static Antsurance_AI_Setting__mdt standIn;
    @TestVisible
    private static Boolean hasNoRecord = false;
    // A test sees the built-in values unless it asks for the org's record, so no test depends on how an org is set up.
    @TestVisible
    private static Boolean readStoredRecordInTests = false;

    private static Antsurance_AI_Setting__mdt stored {
        get {
            if (hasNoRecord) {
                return null;
            }
            if (standIn != null) {
                return standIn;
            }
            if (Test.isRunningTest() && !readStoredRecordInTests) {
                return null;
            }
            return Antsurance_AI_Setting__mdt.getInstance('Default');
        }
    }

    /**
     * @description The model id to send with a request.
     * @return The configured model, or the built-in one when none is configured
     */
    public static String model() {
        String configured = stored?.Model__c;
        return String.isBlank(configured) ? BUILT_IN_MODEL : configured.trim();
    }

    /**
     * @description The class an org has named to tell the chat about its own records.
     * @return The class name, or null when none is named
     */
    public static String chatModelClass() {
        String configured = stored?.Chat_Model_Class__c;
        return String.isBlank(configured) ? null : configured.trim();
    }

    /**
     * @description Whether to ask for fast output. On only when the record says so; an org with no record
     * keeps the built-in behaviour, which is fast mode with a fall back to standard speed.
     * @return True to send the request in fast mode
     */
    public static Boolean useFastMode() {
        Antsurance_AI_Setting__mdt record = stored;
        return record == null ? true : record.Fast_Mode__c == true;
    }

    /**
     * @description The beta header value that turns fast mode on.
     * @return The configured value, or the built-in one
     */
    public static String fastModeBeta() {
        String configured = stored?.Fast_Mode_Beta__c;
        return String.isBlank(configured) ? BUILT_IN_FAST_MODE_BETA : configured.trim();
    }
}
