/**
 * @description Starts Claude's shift on a schedule, so the desk is ready when people arrive.
 * It is not scheduled by default. To run it at 5 AM every day, as a user who has the
 * Antsurance Desk and Antsurance Claude permission sets:
 *
 *     System.schedule('Claude shift, nightly', '0 0 5 * * ?', new AntsuranceDeskNightly());
 *
 * The shift works one piece per job, because each piece is its own call to Claude.
 */
public with sharing class AntsuranceDeskNightly implements Schedulable {
    /**
     * @description Plans a shift and queues its first piece.
     * @param context The schedule's context
     */
    public void execute(SchedulableContext context) {
        AntsuranceDeskShift.Job job = new AntsuranceDeskShift.Job(AntsuranceDeskShift.plan());
        if (!job.isEmpty()) {
            System.enqueueJob(job);
        }
    }
}
