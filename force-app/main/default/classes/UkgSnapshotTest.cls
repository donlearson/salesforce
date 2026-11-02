/**
 * UkgSnapshotTest
 * Provides coverage for the snapshot cache: UkgSnapshotService, UkgSnapshotRefreshJob,
 * UkgSnapshotRefreshScheduler and UkgSnapshotController.
 */
@isTest
private class UkgSnapshotTest {

    // Serves both reports from the one mock, branching on the report ID in the endpoint.
    // Both reports' parsers are tolerant of the other's extra columns, so the same rows
    // work for the weekly and monthly datasets.
    public class UkgMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/login')) {
                res.setBody('{"token": "test_token"}');
                res.setStatusCode(200);
                return res;
            }

            Date today = Date.today();
            Date sunday = today.toStartOfWeek();
            Integer diff = sunday.daysBetween(today);
            Date sat = today.addDays(diff == 6 ? 0 : -(diff + 1));
            String satStr = DateTime.newInstance(sat, Time.newInstance(0, 0, 0, 0)).format('MM/dd/yyyy');

            String csv;
            if (req.getEndpoint().contains('124935578')) {
                csv = 'L,F,Start,End,H,ID,Code,APL,Holiday,Profile,CounterDate,DateTerminated\n' +
                      'Alberts,Tom,01/01/24,' + satStr + ',35.5,EMP001,100,0,0,Billable Recording Time - APL,' + satStr + ',\n' +
                      'Smith,Jane,01/01/24,' + satStr + ',20.0,EMP002,100,0,0,1099 Contractors and Hourly W-2s,' + satStr + ',';
            } else {
                // Bench report: Counter Date is column index 6.
                csv = 'Last Name,First Name,Start,End,Hours,Employee ID,CounterDate\n' +
                      'Alberts,Tom,01/01/2024,' + satStr + ',4.0,EMP001,' + satStr;
            }
            res.setBody(csv);
            res.setStatusCode(200);
            return res;
        }
    }

    public class ErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/login')) {
                res.setBody('{"token": "test_token"}');
                res.setStatusCode(200);
            } else {
                res.setStatusCode(503);
                res.setBody('Service Unavailable');
            }
            return res;
        }
    }

    // Counts snapshot chunk records for a dataset.
    private static Integer chunkCount(String dataset) {
        return [SELECT COUNT() FROM UKG_Snapshot__c WHERE Dataset__c = :dataset];
    }

    @isTest
    static void testFetchWriteAndReadAllDatasets() {
        Test.setMock(HttpCalloutMock.class, new UkgMock());

        // Callouts first, DML after - a callout can't follow uncommitted DML.
        Map<String, String> payloads = new Map<String, String>();
        Test.startTest();
        for (String ds : UkgSnapshotService.ALL_DATASETS) {
            payloads.put(ds, UkgSnapshotService.fetchPayload(ds));
        }
        Test.stopTest();

        for (String ds : UkgSnapshotService.ALL_DATASETS) {
            System.assert(String.isNotBlank(payloads.get(ds)), 'Expected a JSON payload for ' + ds);
            UkgSnapshotService.writeSnapshot(ds, payloads.get(ds));
        }

        Map<String, UkgSnapshotService.DatasetResult> results = UkgSnapshotController.getSnapshots();
        System.assertEquals(4, results.size(), 'Expected one result per dataset');
        for (String ds : UkgSnapshotService.ALL_DATASETS) {
            System.assertEquals(UkgSnapshotService.STATUS_SUCCESS, results.get(ds).status, 'Expected SUCCESS for ' + ds);
            System.assertNotEquals(null, results.get(ds).refreshedAt, 'Expected a refresh time for ' + ds);
            System.assertEquals(payloads.get(ds), results.get(ds).payload, 'Expected the stored payload to round-trip for ' + ds);
        }

        // The stored JSON must deserialize back into the same shape the original dashboard receives.
        UkgBillableHoursW2Controller.CombinedBillableHoursWrapper billable =
            (UkgBillableHoursW2Controller.CombinedBillableHoursWrapper) JSON.deserialize(
                results.get(UkgSnapshotService.DS_BILLABLE_WEEKLY).payload,
                UkgBillableHoursW2Controller.CombinedBillableHoursWrapper.class);
        System.assertEquals(5, billable.weekEndDates.size(), 'Expected 5 week-end dates');
        System.assertEquals(1, billable.pw2Summaries.size(), 'Expected one PW2 associate');
        System.assertEquals(35.5, billable.pw2Summaries[0].w1Hours, 'Expected PW2 w1 hours to survive the snapshot');
        System.assertEquals(1, billable.hw2Summaries.size(), 'Expected one HW2/1099 associate');
    }

    @isTest
    static void testReadAllWithNothingStored() {
        Map<String, UkgSnapshotService.DatasetResult> results = UkgSnapshotService.readAll();
        System.assertEquals(4, results.size(), 'Expected an entry for every dataset even when nothing is stored');
        for (UkgSnapshotService.DatasetResult r : results.values()) {
            System.assertEquals(UkgSnapshotService.STATUS_MISSING, r.status, 'Expected MISSING');
            System.assertEquals(null, r.payload, 'Expected no payload');
        }
    }

    @isTest
    static void testLargePayloadIsChunkedAndReassembled() {
        UkgSnapshotService.chunkSize = 100;
        String ds = UkgSnapshotService.DS_BILLABLE_WEEKLY;

        String big = '';
        for (Integer i = 0; i < 25; i++) {
            big += '0123456789';
        }
        big += 'END'; // 253 chars -> 3 chunks of 100/100/53
        UkgSnapshotService.writeSnapshot(ds, big);
        System.assertEquals(3, chunkCount(ds), 'Expected the payload to be split across 3 chunks');
        System.assertEquals(big, UkgSnapshotService.readAll().get(ds).payload, 'Expected chunks to reassemble in order');

        // A smaller payload must remove the leftover chunks from the larger one.
        UkgSnapshotService.writeSnapshot(ds, 'small');
        System.assertEquals(1, chunkCount(ds), 'Expected stale chunks to be deleted');
        System.assertEquals('small', UkgSnapshotService.readAll().get(ds).payload, 'Expected the new payload only');
    }

    @isTest
    static void testFailedRefreshKeepsLastGoodPayload() {
        String ds = UkgSnapshotService.DS_BENCH_WEEKLY;
        UkgSnapshotService.writeSnapshot(ds, '{"summaries":[]}');

        Test.setMock(HttpCalloutMock.class, new ErrorMock());
        Test.startTest();
        System.enqueueJob(new UkgSnapshotRefreshJob(new List<String>{ ds }));
        Test.stopTest();

        UkgSnapshotService.DatasetResult r = UkgSnapshotService.readAll().get(ds);
        System.assertEquals(UkgSnapshotService.STATUS_ERROR, r.status, 'Expected the failure to be recorded');
        System.assert(String.isNotBlank(r.lastError), 'Expected an error message');
        System.assertEquals('{"summaries":[]}', r.payload, 'Expected the last good payload to be kept');
        System.assertNotEquals(null, r.refreshedAt, 'Expected the last good refresh time to be kept');
    }

    @isTest
    static void testFailedRefreshWithNoPriorSnapshot() {
        String ds = UkgSnapshotService.DS_BENCH_MONTHLY;

        Test.setMock(HttpCalloutMock.class, new ErrorMock());
        Test.startTest();
        System.enqueueJob(new UkgSnapshotRefreshJob(new List<String>{ ds }));
        Test.stopTest();

        UkgSnapshotService.DatasetResult r = UkgSnapshotService.readAll().get(ds);
        System.assertEquals(UkgSnapshotService.STATUS_ERROR, r.status, 'Expected ERROR status');
        System.assertEquals(null, r.payload, 'Expected no payload when nothing ever succeeded');
        System.assertEquals(null, r.refreshedAt, 'Expected no refresh time when nothing ever succeeded');
    }

    @isTest
    static void testRefreshJobStoresSnapshot() {
        String ds = UkgSnapshotService.DS_BENCH_WEEKLY;

        Test.setMock(HttpCalloutMock.class, new UkgMock());
        Test.startTest();
        System.enqueueJob(new UkgSnapshotRefreshJob(new List<String>{ ds }));
        Test.stopTest();

        UkgSnapshotService.DatasetResult r = UkgSnapshotService.readAll().get(ds);
        System.assertEquals(UkgSnapshotService.STATUS_SUCCESS, r.status, 'Expected SUCCESS');
        System.assert(String.isNotBlank(r.payload), 'Expected a stored payload');
    }

    @isTest
    static void testRefreshJobWithNothingToDo() {
        new UkgSnapshotRefreshJob(new List<String>()).execute(null);
        System.assertEquals(0, [SELECT COUNT() FROM UKG_Snapshot__c], 'Expected no records');
    }

    @isTest
    static void testRequestRefreshStartsThenHonorsCooldown() {
        Test.setMock(HttpCalloutMock.class, new UkgMock());

        Test.startTest();
        UkgSnapshotController.RefreshResult first = UkgSnapshotController.requestRefresh();
        Test.stopTest(); // runs the queued job (first dataset only - chaining is skipped in tests)

        System.assertEquals(true, first.started, 'Expected the first request to start a refresh: ' + first.message);

        UkgSnapshotController.RefreshResult second = UkgSnapshotController.requestRefresh();
        System.assertEquals(false, second.started, 'Expected the second request to be blocked by the cooldown');
        System.assert(second.message.contains('limited'), 'Expected a cooldown message but got: ' + second.message);
    }

    @isTest
    static void testRequestRefreshBlockedWhileInFlight() {
        Test.setMock(HttpCalloutMock.class, new UkgMock());

        Test.startTest();
        UkgSnapshotService.enqueueRefresh();
        UkgSnapshotController.RefreshResult result = UkgSnapshotController.requestRefresh();
        Test.stopTest();

        System.assertEquals(false, result.started, 'Expected a request to be blocked while a refresh is queued');
        System.assert(result.message.contains('already running'), 'Expected an in-flight message but got: ' + result.message);
    }

    @isTest
    static void testSchedulerSchedulesAndUnschedules() {
        Test.startTest();
        UkgSnapshotRefreshScheduler.scheduleDefault();
        Integer scheduled = [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'UKG Snapshot Refresh%'];
        System.assertEquals(2, scheduled, 'Expected the hourly (Sun-Tue) and daily (Wed-Sat) jobs');

        // Rescheduling must not create duplicates.
        UkgSnapshotRefreshScheduler.scheduleDefault();
        System.assertEquals(2, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'UKG Snapshot Refresh%'],
            'Expected scheduleDefault to be idempotent');

        UkgSnapshotRefreshScheduler.unschedule();
        System.assertEquals(0, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'UKG Snapshot Refresh%'],
            'Expected unschedule to remove both jobs');
        Test.stopTest();
    }

    @isTest
    static void testSchedulerExecuteQueuesRefresh() {
        Test.setMock(HttpCalloutMock.class, new UkgMock());
        Test.startTest();
        new UkgSnapshotRefreshScheduler().execute(null);
        Test.stopTest();

        System.assertEquals(1, chunkCount(UkgSnapshotService.DS_BILLABLE_WEEKLY),
            'Expected the queued refresh to have stored the first dataset');
    }
}
