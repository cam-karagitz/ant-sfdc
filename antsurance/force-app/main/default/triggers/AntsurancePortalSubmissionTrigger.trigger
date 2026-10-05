/**
 * Files the claims and service requests customers send from the portal. Runs as the internal user named in
 * the PlatformEventSubscriberConfig, so the case automation behaves as it does for staff.
 */
trigger AntsurancePortalSubmissionTrigger on Antsurance_Portal_Submission__e(after insert) {
    AntsurancePortalSubmissions.receive(Trigger.new);
}
