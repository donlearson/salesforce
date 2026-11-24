/**
 * UkgHoursTabCacheController
 * Serves the Contact Hours tab's bench and billable trackers from the snapshots the
 * cached dashboard already stores (UkgSnapshotService datasets), instead of a live UKG
 * call per page view:
 *   getBenchTimeEntries     -> BENCH_WEEKLY    (UkgDataController.getTimeEntries(null))
 *   getBillableTimeEntries  -> BILLABLE_WEEKLY (UkgBillableHoursW2Controller.getAllTimeEntries(null)), HW2/1099 slice
 * Each returns the same shape the live methods return ({summaries, weekEndDates}),
 * filtered to this Contact, plus refreshedAt / stale / cached for an "as of" note.
 *
 * Reads only; refreshing is done by the existing UkgSnapshotRefreshScheduler.
 * without sharing: snapshot rows are private; access is via UKG_Hours_Tab_Access.
 */
public without sharing class UkgHoursTabCacheController {

    @AuraEnabled
    public static Map<String, Object> getBenchTimeEntries(Id contactId) {
        return forContact(UkgSnapshotService.DS_BENCH_WEEKLY, 'summaries', contactId);
    }

    @AuraEnabled
    public static Map<String, Object> getBillableTimeEntries(Id contactId) {
        return forContact(UkgSnapshotService.DS_BILLABLE_WEEKLY, 'hw2Summaries', contactId);
    }

    @TestVisible
    private static Map<String, Object> forContact(String dataset, String summariesKey, Id contactId) {
        Map<String, Object> result = new Map<String, Object>{
            'summaries' => new List<Object>(),
            'weekEndDates' => new List<Object>(),
            'cached' => false,
            'stale' => false,
            'refreshedAt' => null
        };

        List<String> parts = new List<String>();
        for (UKG_Snapshot__c row : [
            SELECT Chunk_Index__c, Payload__c, Refreshed_At__c, Status__c
            FROM UKG_Snapshot__c
            WHERE Dataset__c = :dataset
            ORDER BY Chunk_Index__c
        ]) {
            parts.add(row.Payload__c == null ? '' : row.Payload__c);
            if (row.Chunk_Index__c == 0) {
                result.put('refreshedAt', row.Refreshed_At__c);
                result.put('stale', row.Status__c == UkgSnapshotService.STATUS_ERROR);
            }
        }
        String payload = String.join(parts, '');
        if (String.isBlank(payload)) {
            return result;
        }
        result.put('cached', true);

        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(payload);
        if (data.get('weekEndDates') != null) {
            result.put('weekEndDates', data.get('weekEndDates'));
        }

        List<Object> mine = new List<Object>();
        Object all = data.get(summariesKey);
        if (all instanceof List<Object> && contactId != null) {
            String target = String.valueOf(contactId).left(15);
            for (Object o : (List<Object>) all) {
                Map<String, Object> summary = (Map<String, Object>) o;
                String summaryContactId = (String) summary.get('contactId');
                if (summaryContactId != null && summaryContactId.left(15) == target) {
                    mine.add(summary);
                }
            }
        }
        result.put('summaries', mine);
        return result;
    }
}
