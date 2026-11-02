/**
 * UkgSnapshotRefreshJob
 * * Refreshes one dataset per job, then chains itself for the next. UKG calls are slow
 * (60s timeout each) and a transaction allows only 120s of total callout time, so one
 * dataset per transaction keeps a slow report from starving the others, and one
 * failing dataset doesn't stop the rest from refreshing.
 */
public without sharing class UkgSnapshotRefreshJob implements Queueable, Database.AllowsCallouts {

    private List<String> remaining;

    public UkgSnapshotRefreshJob(List<String> datasets) {
        this.remaining = datasets;
    }

    public void execute(QueueableContext context) {
        if (remaining == null || remaining.isEmpty()) {
            return;
        }
        String dataset = remaining[0];
        List<String> rest = remaining.clone();
        rest.remove(0);

        try {
            String payload = UkgSnapshotService.fetchPayload(dataset);
            UkgSnapshotService.writeSnapshot(dataset, payload);
        } catch (Exception e) {
            // Note: AuraHandledException (what the UKG controllers throw) reports a
            // generic message here; the specific cause is in the debug log.
            System.debug('UKG snapshot refresh failed for ' + dataset + ': ' + e.getTypeName() + ' - ' + e.getMessage() + ' ' + e.getStackTraceString());
            UkgSnapshotService.writeFailure(dataset, e.getTypeName() + ': ' + e.getMessage());
        }

        // Queueable chaining isn't allowed in tests; the chain is exercised by running
        // each dataset's job directly instead.
        if (!rest.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new UkgSnapshotRefreshJob(rest));
        }
    }
}
