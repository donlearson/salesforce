/**
 * UkgTimesheetCacheJob
 * Refreshes one week of the time sheet cache per job, then chains itself for the next
 * week, so a slow UKG call for one week can't starve the others (each transaction
 * allows 120s of callouts) and one failed week doesn't stop the rest. After the last
 * week it deletes weeks older than the cache window.
 */
public without sharing class UkgTimesheetCacheJob implements Queueable, Database.AllowsCallouts {

    private List<Date> remaining;

    public UkgTimesheetCacheJob(List<Date> weeks) {
        this.remaining = weeks;
    }

    public void execute(QueueableContext context) {
        if (remaining == null || remaining.isEmpty()) {
            return;
        }
        Date sunday = remaining[0];
        List<Date> rest = remaining.clone();
        rest.remove(0);

        try {
            UkgTimesheetCache.refreshWeek(sunday);
        } catch (Exception e) {
            // AuraHandledException (thrown by the UKG helpers) reports a generic message
            // here; the specific cause is in the debug log.
            System.debug('UKG time sheet cache refresh failed for ' + sunday + ': ' + e.getTypeName() + ' - ' + e.getMessage() + ' ' + e.getStackTraceString());
            UkgTimesheetCache.recordFailure(sunday, e.getTypeName() + ': ' + e.getMessage());
        }

        if (rest.isEmpty()) {
            UkgTimesheetCache.pruneOldWeeks();
        } else if (!Test.isRunningTest()) {
            // Chaining isn't allowed in tests; tests run each week's job directly.
            System.enqueueJob(new UkgTimesheetCacheJob(rest));
        }
    }
}
