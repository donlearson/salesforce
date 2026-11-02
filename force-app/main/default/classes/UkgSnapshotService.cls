/**
 * UkgSnapshotService
 * * Stores UKG report results as snapshots in UKG_Snapshot__c so the cached
 * dashboard (ukgHoursDashboardCached) can read them from Salesforce instead of
 * calling UKG on every page load.
 * * Each dataset is the exact JSON the existing controllers already return to the
 * original dashboard, so the two dashboards can be compared side by side:
 *   BILLABLE_WEEKLY  - UkgBillableHoursW2Controller.getAllTimeEntries
 *   BILLABLE_MONTHLY - UkgBillableHoursW2Controller.getMonthlyTimeEntries
 *   BENCH_WEEKLY     - UkgDataController.getTimeEntries
 *   BENCH_MONTHLY    - UkgDataController.getMonthlyTimeEntries
 * * A payload larger than one long text field is split across chunk records
 * (Dataset_Key__c = dataset#index). All chunks of a dataset are written in a single
 * DML, so a reader never sees a mix of old and new chunks.
 * * without sharing: snapshots are company-wide and the object is private - access is
 * controlled by who can run the Apex classes (see the UKG_Cached_Dashboard_Access
 * permission set), not by record sharing.
 */
public without sharing class UkgSnapshotService {

    public static final String DS_BILLABLE_WEEKLY = 'BILLABLE_WEEKLY';
    public static final String DS_BILLABLE_MONTHLY = 'BILLABLE_MONTHLY';
    public static final String DS_BENCH_WEEKLY = 'BENCH_WEEKLY';
    public static final String DS_BENCH_MONTHLY = 'BENCH_MONTHLY';

    public static final List<String> ALL_DATASETS = new List<String>{
        DS_BILLABLE_WEEKLY, DS_BILLABLE_MONTHLY, DS_BENCH_WEEKLY, DS_BENCH_MONTHLY
    };

    public static final String STATUS_SUCCESS = 'SUCCESS';
    public static final String STATUS_ERROR = 'ERROR';
    public static final String STATUS_MISSING = 'MISSING';

    // Payload__c holds 131,072 characters; stay comfortably under it.
    @TestVisible private static Integer chunkSize = 120000;

    // Manual refreshes are ignored if any dataset was attempted more recently than this.
    public static final Integer REFRESH_COOLDOWN_MINUTES = 15;

    public class DatasetResult {
        @AuraEnabled public String payload { get; set; }
        @AuraEnabled public Datetime refreshedAt { get; set; }
        @AuraEnabled public Datetime lastAttemptAt { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String lastError { get; set; }
    }

    /**
     * Calls the existing controller for a dataset (this is the UKG callout) and returns
     * its result as JSON. Performs no DML, so it is safe to call before writeSnapshot.
     */
    public static String fetchPayload(String dataset) {
        Object result;
        if (dataset == DS_BILLABLE_WEEKLY) {
            result = UkgBillableHoursW2Controller.getAllTimeEntries(null);
        } else if (dataset == DS_BILLABLE_MONTHLY) {
            result = UkgBillableHoursW2Controller.getMonthlyTimeEntries(null);
        } else if (dataset == DS_BENCH_WEEKLY) {
            result = UkgDataController.getTimeEntries(null);
        } else if (dataset == DS_BENCH_MONTHLY) {
            result = UkgDataController.getMonthlyTimeEntries(null);
        } else {
            throw new IllegalArgumentException('Unknown UKG snapshot dataset: ' + dataset);
        }
        return JSON.serialize(result, true);
    }

    private static List<String> splitChunks(String payload) {
        List<String> chunks = new List<String>();
        String value = payload == null ? '' : payload;
        Integer pos = 0;
        do {
            chunks.add(value.substring(pos, Math.min(pos + chunkSize, value.length())));
            pos += chunkSize;
        } while (pos < value.length());
        return chunks;
    }

    private static String chunkKey(String dataset, Integer index) {
        return dataset + '#' + index;
    }

    /**
     * Replaces the stored snapshot for a dataset. Upserts every chunk and deletes any
     * leftover higher-numbered chunks from a previous, larger payload - one transaction.
     */
    public static void writeSnapshot(String dataset, String payload) {
        List<String> chunks = splitChunks(payload);
        Datetime now = Datetime.now();
        List<UKG_Snapshot__c> rows = new List<UKG_Snapshot__c>();
        for (Integer i = 0; i < chunks.size(); i++) {
            rows.add(new UKG_Snapshot__c(
                Name = dataset + ' #' + i,
                Dataset__c = dataset,
                Chunk_Index__c = i,
                Dataset_Key__c = chunkKey(dataset, i),
                Payload__c = chunks[i],
                Refreshed_At__c = now,
                Last_Attempt_At__c = now,
                Status__c = STATUS_SUCCESS,
                Last_Error__c = null
            ));
        }
        upsert rows UKG_Snapshot__c.Dataset_Key__c;

        Integer keep = chunks.size();
        delete [SELECT Id FROM UKG_Snapshot__c WHERE Dataset__c = :dataset AND Chunk_Index__c >= :keep];
    }

    /**
     * Records a failed refresh without touching the stored payload, so the dashboard
     * keeps showing the last good data (flagged as stale).
     */
    public static void writeFailure(String dataset, String message) {
        String trimmed = message == null ? 'Unknown error' : message.left(32000);
        List<UKG_Snapshot__c> existing = [
            SELECT Id FROM UKG_Snapshot__c WHERE Dataset_Key__c = :chunkKey(dataset, 0) LIMIT 1
        ];
        UKG_Snapshot__c row = existing.isEmpty()
            ? new UKG_Snapshot__c(
                Name = dataset + ' #0',
                Dataset__c = dataset,
                Chunk_Index__c = 0,
                Dataset_Key__c = chunkKey(dataset, 0))
            : existing[0];
        row.Status__c = STATUS_ERROR;
        row.Last_Error__c = trimmed;
        row.Last_Attempt_At__c = Datetime.now();
        upsert row;
    }

    /**
     * Reads every dataset back, reassembling chunked payloads. Always returns one entry
     * per dataset; a dataset that has never been refreshed comes back as MISSING.
     */
    public static Map<String, DatasetResult> readAll() {
        Map<String, DatasetResult> results = new Map<String, DatasetResult>();
        Map<String, List<String>> payloadParts = new Map<String, List<String>>();
        for (String ds : ALL_DATASETS) {
            DatasetResult r = new DatasetResult();
            r.status = STATUS_MISSING;
            results.put(ds, r);
            payloadParts.put(ds, new List<String>());
        }

        for (UKG_Snapshot__c row : [
            SELECT Dataset__c, Chunk_Index__c, Payload__c, Refreshed_At__c, Last_Attempt_At__c, Status__c, Last_Error__c
            FROM UKG_Snapshot__c
            WHERE Dataset__c IN :ALL_DATASETS
            ORDER BY Dataset__c, Chunk_Index__c
        ]) {
            payloadParts.get(row.Dataset__c).add(row.Payload__c == null ? '' : row.Payload__c);
            if (row.Chunk_Index__c == 0) {
                DatasetResult r = results.get(row.Dataset__c);
                r.refreshedAt = row.Refreshed_At__c;
                r.lastAttemptAt = row.Last_Attempt_At__c;
                r.status = row.Status__c;
                r.lastError = row.Last_Error__c;
            }
        }

        for (String ds : ALL_DATASETS) {
            String joined = String.join(payloadParts.get(ds), '');
            results.get(ds).payload = String.isBlank(joined) ? null : joined;
        }
        return results;
    }

    public static Boolean isRefreshInFlight() {
        return [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'UkgSnapshotRefreshJob'
            AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
        ] > 0;
    }

    public static Id enqueueRefresh() {
        return System.enqueueJob(new UkgSnapshotRefreshJob(ALL_DATASETS.clone()));
    }
}
