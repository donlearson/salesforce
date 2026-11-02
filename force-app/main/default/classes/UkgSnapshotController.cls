/**
 * UkgSnapshotController
 * * Apex behind ukgHoursDashboardCached. getSnapshots() reads the stored snapshots
 * (no UKG callout); requestRefresh() queues a refresh, with a cooldown and an
 * in-flight check so repeated clicks can't pile extra load onto UKG.
 */
public without sharing class UkgSnapshotController {

    public class RefreshResult {
        @AuraEnabled public Boolean started { get; set; }
        @AuraEnabled public String message { get; set; }

        public RefreshResult(Boolean started, String message) {
            this.started = started;
            this.message = message;
        }
    }

    @AuraEnabled
    public static Map<String, UkgSnapshotService.DatasetResult> getSnapshots() {
        return UkgSnapshotService.readAll();
    }

    @AuraEnabled
    public static RefreshResult requestRefresh() {
        if (UkgSnapshotService.isRefreshInFlight()) {
            return new RefreshResult(false, 'A refresh is already running.');
        }

        AggregateResult agg = [SELECT MAX(Last_Attempt_At__c) lastAttempt FROM UKG_Snapshot__c];
        Datetime lastAttempt = (Datetime) agg.get('lastAttempt');
        if (lastAttempt != null) {
            Long minutesAgo = (Datetime.now().getTime() - lastAttempt.getTime()) / 60000;
            if (minutesAgo < UkgSnapshotService.REFRESH_COOLDOWN_MINUTES) {
                return new RefreshResult(false, 'Data was refreshed ' + minutesAgo + ' min ago - refreshes are limited to once every '
                    + UkgSnapshotService.REFRESH_COOLDOWN_MINUTES + ' minutes.');
            }
        }

        UkgSnapshotService.enqueueRefresh();
        return new RefreshResult(true, 'Refresh started - this takes a minute or two.');
    }
}
