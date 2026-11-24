/**
 * UkgTimesheetCache
 * Stores the UKG Review report (123617418) for recent weeks in UKG_Snapshot__c so
 * the Weekly Time Sheet (ukgTimesheetWeek) reads Salesforce instead of calling UKG
 * every time someone opens the Contact Hours tab.
 *
 * One company-wide report call per week (no employee filter). The CSV is split by
 * the UKG "Account Id" column (= Contact.UKG_ID__c) and stored as:
 *   TIMESHEET_yyyy-MM-dd#0        week marker: refresh time, status, last error
 *   TIMESHEET_yyyy-MM-dd@<ukgId>  that associate's CSV rows for the week (with header)
 * (Dataset__c = TIMESHEET_yyyy-MM-dd, the week's Sunday.)
 *
 * Shares UKG_Snapshot__c with the cached dashboard and bonus datasets but never
 * touches their rows: everything here is scoped to the TIMESHEET_ prefix.
 * Last_Attempt_At__c is deliberately left blank on these rows, because the cached
 * dashboard's manual-refresh cooldown reads MAX(Last_Attempt_At__c) across the object.
 *
 * without sharing: snapshot rows are private, company-wide data; access is controlled
 * by who can run the Apex (UKG_Hours_Tab_Access), not by record sharing.
 */
public without sharing class UkgTimesheetCache {

    public static final String PREFIX = 'TIMESHEET_';
    public static final Integer WEEKS_KEPT = 8;
    public static final Integer RECENT_WEEKS = 3;

    private static final Integer MARKER_CHUNK = 0;
    private static final Integer EMPLOYEE_CHUNK = 1;
    // Payload__c holds 131,072 characters.
    @TestVisible private static Integer maxPayload = 131000;

    public class CachedWeek {
        public Boolean cached = false;     // the week has been loaded at least once
        public Datetime refreshedAt;
        public Boolean stale = false;      // the latest refresh failed; showing older data
        public String lastError;
        public String csv;                 // this associate's rows, or null if none
    }

    // ---------------------------------------------------------------------
    // Keys and weeks
    // ---------------------------------------------------------------------

    public static String datasetFor(Date sunday) {
        return PREFIX + UkgTimesheetController.formatDate(sunday);
    }

    private static String markerKey(Date sunday) {
        return datasetFor(sunday) + '#' + MARKER_CHUNK;
    }

    private static String employeeKey(Date sunday, String ukgId) {
        return datasetFor(sunday) + '@' + ukgId;
    }

    /** The current week's Sunday and the (count - 1) weeks before it, newest first. */
    public static List<Date> recentWeeks(Integer count) {
        Date current = UkgTimesheetController.toSunday(Date.today());
        List<Date> weeks = new List<Date>();
        for (Integer i = 0; i < count; i++) {
            weeks.add(current.addDays(-7 * i));
        }
        return weeks;
    }

    public static Boolean isWithinCacheWindow(Date sunday) {
        List<Date> kept = recentWeeks(WEEKS_KEPT);
        return sunday <= kept[0] && sunday >= kept[kept.size() - 1];
    }

    // ---------------------------------------------------------------------
    // Read
    // ---------------------------------------------------------------------

    public static CachedWeek read(Date sunday, String ukgId) {
        CachedWeek result = new CachedWeek();
        List<String> keys = new List<String>{ markerKey(sunday), employeeKey(sunday, ukgId) };
        for (UKG_Snapshot__c row : [
            SELECT Dataset_Key__c, Payload__c, Refreshed_At__c, Status__c, Last_Error__c
            FROM UKG_Snapshot__c
            WHERE Dataset_Key__c IN :keys
        ]) {
            if (row.Dataset_Key__c == keys[0]) {
                result.cached = row.Refreshed_At__c != null;
                result.refreshedAt = row.Refreshed_At__c;
                result.stale = row.Status__c == UkgSnapshotService.STATUS_ERROR;
                result.lastError = row.Last_Error__c;
            } else {
                result.csv = row.Payload__c;
            }
        }
        return result;
    }

    // ---------------------------------------------------------------------
    // Refresh
    // ---------------------------------------------------------------------

    /** One UKG report call for every associate's week, then stores it. */
    public static void refreshWeek(Date sunday) {
        UKG_Integration_Settings__mdt settings = UkgTimesheetController.loadSettings();
        String token = UkgTimesheetController.login(settings);
        String csv = UkgTimesheetController.fetchReport(token, settings.Company_Short_Name__c, null, sunday, sunday.addDays(6));
        storeWeek(sunday, csv);
    }

    /** Splits a company-wide week CSV by associate and replaces the stored week. */
    @TestVisible
    private static void storeWeek(Date sunday, String csv) {
        String dataset = datasetFor(sunday);
        List<String> records = UkgTimesheetController.splitLines(csv);
        Map<String, List<String>> linesByUkgId = new Map<String, List<String>>();
        String header = records.isEmpty() ? '' : records[0];

        if (!records.isEmpty()) {
            Integer idCol = accountIdColumn(UkgTimesheetController.parseCsvLine(header));
            for (Integer i = 1; i < records.size(); i++) {
                if (String.isBlank(records[i])) continue;
                List<String> values = UkgTimesheetController.parseCsvLine(records[i]);
                String ukgId = idCol < values.size() ? values[idCol].trim() : '';
                if (String.isBlank(ukgId)) continue;
                if (!linesByUkgId.containsKey(ukgId)) linesByUkgId.put(ukgId, new List<String>());
                linesByUkgId.get(ukgId).add(records[i]);
            }
        }

        Datetime now = Datetime.now();
        List<UKG_Snapshot__c> rows = new List<UKG_Snapshot__c>();
        Set<String> keptKeys = new Set<String>();
        Integer truncated = 0;
        for (String ukgId : linesByUkgId.keySet()) {
            String payload = header;
            for (String line : linesByUkgId.get(ukgId)) {
                if (payload.length() + line.length() + 1 > maxPayload) { truncated++; break; }
                payload += '\n' + line;
            }
            String key = employeeKey(sunday, ukgId);
            keptKeys.add(key);
            rows.add(new UKG_Snapshot__c(
                Name = (dataset + ' ' + ukgId).left(80),
                Dataset__c = dataset,
                Chunk_Index__c = EMPLOYEE_CHUNK,
                Dataset_Key__c = key,
                Payload__c = payload,
                Refreshed_At__c = now,
                Status__c = UkgSnapshotService.STATUS_SUCCESS
            ));
        }
        if (truncated > 0) {
            System.debug(LoggingLevel.WARN, 'UKG time sheet cache: ' + truncated + ' associate(s) exceeded the payload size for ' + dataset);
        }

        rows.add(new UKG_Snapshot__c(
            Name = dataset,
            Dataset__c = dataset,
            Chunk_Index__c = MARKER_CHUNK,
            Dataset_Key__c = markerKey(sunday),
            Payload__c = linesByUkgId.size() + ' associates, ' + Math.max(records.size() - 1, 0) + ' rows',
            Refreshed_At__c = now,
            Status__c = UkgSnapshotService.STATUS_SUCCESS,
            Last_Error__c = null
        ));
        upsert rows UKG_Snapshot__c.Dataset_Key__c;

        // Associates with no time this week any more (e.g. a timesheet was unapproved).
        delete [
            SELECT Id FROM UKG_Snapshot__c
            WHERE Dataset__c = :dataset AND Chunk_Index__c = :EMPLOYEE_CHUNK AND Dataset_Key__c NOT IN :keptKeys
        ];
    }

    private static Integer accountIdColumn(List<String> header) {
        for (Integer i = 0; i < header.size(); i++) {
            if (header[i].trim().equalsIgnoreCase('Account Id')) return i;
        }
        return 19; // known position in report 123617418
    }

    /** Flags a failed refresh; the stored rows (if any) stay and are shown as stale. */
    public static void recordFailure(Date sunday, String message) {
        String dataset = datasetFor(sunday);
        List<UKG_Snapshot__c> existing = [
            SELECT Id FROM UKG_Snapshot__c WHERE Dataset_Key__c = :markerKey(sunday) LIMIT 1
        ];
        UKG_Snapshot__c marker = existing.isEmpty()
            ? new UKG_Snapshot__c(Name = dataset, Dataset__c = dataset, Chunk_Index__c = MARKER_CHUNK, Dataset_Key__c = markerKey(sunday))
            : existing[0];
        marker.Status__c = UkgSnapshotService.STATUS_ERROR;
        marker.Last_Error__c = (Datetime.now().format() + ' - ' + (message == null ? 'Unknown error' : message)).left(32000);
        upsert marker;
    }

    /** Deletes stored weeks older than the cache window. */
    public static void pruneOldWeeks() {
        List<Date> kept = recentWeeks(WEEKS_KEPT);
        String oldestKept = datasetFor(kept[kept.size() - 1]);
        delete [
            SELECT Id FROM UKG_Snapshot__c
            WHERE Dataset__c LIKE :(PREFIX + '%') AND Dataset__c < :oldestKept
        ];
    }

    public static Boolean isRefreshInFlight() {
        return [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'UkgTimesheetCacheJob'
            AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
        ] > 0;
    }
}
