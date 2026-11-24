@isTest
private class UkgTimesheetCacheTest {

    private static final String HEADER = '"Full Name"," Activity Codes","Date","Hours","Is Time Off","Time Off Name","Approval State"," Project New Name (1)"," Project New Name (2)"," Project New Name (3)","Account Id"';

    // Last completed week, so it is always inside the cache window.
    private static Date sunday() {
        return UkgTimesheetController.toSunday(Date.today()).addDays(-7);
    }

    private static String usDate(Date d) {
        return d.month() + '/' + d.day() + '/' + d.year();
    }

    private static String row(String ukgId, Integer dayIndex, String hours, String client, String comment) {
        return '"User ' + ukgId + '","135 - Application Build","' + usDate(sunday().addDays(dayIndex)) + '","' + hours
            + '","","","Approved","' + client + '","' + comment + '","","' + ukgId + '"';
    }

    private static String weekCsv() {
        return HEADER + '\n'
            + row('111', 1, '8.00', 'Archbold Medical Center', 'Build') + '\n'
            + row('111', 2, '6.00', 'Archbold Medical Center', 'two\nline note') + '\n'
            + row('222', 3, '4.00', 'UAB Medicine Enterprise', 'Build') + '\n';
    }

    private class CompanyWideMock implements HttpCalloutMock {
        Integer code;
        CompanyWideMock(Integer code) { this.code = code; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/login')) {
                res.setStatusCode(200);
                res.setBody('{"token":"mock_token"}');
                return res;
            }
            System.assert(!req.getBody().contains('EmplAccountId'), 'Cache refresh must pull every associate');
            res.setStatusCode(code);
            res.setBody(code == 200 ? weekCsv() : '');
            return res;
        }
    }

    @testSetup
    static void setup() {
        insert new Contact(LastName = 'Associate', UKG_ID__c = '111');
        insert new Contact(LastName = 'Other', UKG_ID__c = '333');
    }

    @isTest
    static void refreshJobStoresEachAssociateAndGetWeekReadsIt() {
        Test.setMock(HttpCalloutMock.class, new CompanyWideMock(200));
        Test.startTest();
        new UkgTimesheetCacheJob(new List<Date>{ sunday() }).execute(null);
        Test.stopTest();

        String dataset = UkgTimesheetCache.datasetFor(sunday());
        System.assertEquals(3, [SELECT COUNT() FROM UKG_Snapshot__c WHERE Dataset__c = :dataset], 'Marker + 2 associates');
        System.assertEquals(null, [SELECT Last_Attempt_At__c FROM UKG_Snapshot__c WHERE Dataset__c = :dataset LIMIT 1].Last_Attempt_At__c,
            'Must not affect the cached dashboard refresh cooldown');

        Contact c = [SELECT Id FROM Contact WHERE UKG_ID__c = '111'];
        UkgTimesheetController.TimesheetWeek w = UkgTimesheetController.getWeek(c.Id, UkgTimesheetController.formatDate(sunday()));
        System.assertEquals('CACHE', w.source);
        System.assertNotEquals(null, w.refreshedAt);
        System.assertEquals(false, w.stale);
        System.assertEquals(true, w.inCacheWindow);
        System.assertEquals(14, w.billableTotal, 'Only this associate, including the row with a multi-line comment');
        System.assertEquals(1, w.clients.size());

        // An associate with no time that week gets an empty (but cached) week.
        Contact other = [SELECT Id FROM Contact WHERE UKG_ID__c = '333'];
        UkgTimesheetController.TimesheetWeek empty = UkgTimesheetController.getWeek(other.Id, UkgTimesheetController.formatDate(sunday()));
        System.assertEquals('CACHE', empty.source);
        System.assertEquals(0, empty.weekTotal);
    }

    @isTest
    static void refreshRemovesAssociatesNoLongerInTheReport() {
        String dataset = UkgTimesheetCache.datasetFor(sunday());
        insert new UKG_Snapshot__c(Name = 'old', Dataset__c = dataset, Chunk_Index__c = 1,
            Dataset_Key__c = dataset + '@999', Payload__c = HEADER, Refreshed_At__c = Datetime.now());

        UkgTimesheetCache.storeWeek(sunday(), weekCsv());

        System.assertEquals(0, [SELECT COUNT() FROM UKG_Snapshot__c WHERE Dataset_Key__c = :(dataset + '@999')]);
        System.assertEquals(1, [SELECT COUNT() FROM UKG_Snapshot__c WHERE Dataset_Key__c = :(dataset + '@222')]);
    }

    @isTest
    static void weekNotStoredAsksForLiveLoad() {
        Contact c = [SELECT Id FROM Contact WHERE UKG_ID__c = '111'];
        UkgTimesheetController.TimesheetWeek recent = UkgTimesheetController.getWeek(c.Id, UkgTimesheetController.formatDate(sunday()));
        System.assertEquals('NOT_CACHED', recent.source);
        System.assertEquals(true, recent.inCacheWindow);

        UkgTimesheetController.TimesheetWeek old = UkgTimesheetController.getWeek(c.Id, UkgTimesheetController.formatDate(sunday().addDays(-7 * 20)));
        System.assertEquals('NOT_CACHED', old.source);
        System.assertEquals(false, old.inCacheWindow);
    }

    @isTest
    static void failedRefreshKeepsDataAndFlagsStale() {
        UkgTimesheetCache.storeWeek(sunday(), weekCsv());
        Test.setMock(HttpCalloutMock.class, new CompanyWideMock(503));

        // Enqueued (not run inline) so the callout runs in its own transaction.
        Test.startTest();
        System.enqueueJob(new UkgTimesheetCacheJob(new List<Date>{ sunday() }));
        Test.stopTest();

        Contact c = [SELECT Id FROM Contact WHERE UKG_ID__c = '111'];
        UkgTimesheetController.TimesheetWeek w = UkgTimesheetController.getWeek(c.Id, UkgTimesheetController.formatDate(sunday()));
        System.assertEquals('CACHE', w.source);
        System.assertEquals(true, w.stale);
        System.assertEquals(14, w.billableTotal, 'Last good data still shown');
    }

    @isTest
    static void failureBeforeFirstLoadIsNotCached() {
        UkgTimesheetCache.recordFailure(sunday(), 'boom');
        UkgTimesheetCache.CachedWeek cw = UkgTimesheetCache.read(sunday(), '111');
        System.assertEquals(false, cw.cached);
        System.assertEquals(true, cw.stale);
    }

    @isTest
    static void prunesWeeksOutsideTheWindowOnly() {
        Date tooOld = sunday().addDays(-7 * UkgTimesheetCache.WEEKS_KEPT);
        String oldDataset = UkgTimesheetCache.datasetFor(tooOld);
        insert new List<UKG_Snapshot__c>{
            new UKG_Snapshot__c(Name = 'old', Dataset__c = oldDataset, Chunk_Index__c = 0, Dataset_Key__c = oldDataset + '#0'),
            new UKG_Snapshot__c(Name = 'dash', Dataset__c = 'BENCH_WEEKLY', Chunk_Index__c = 0, Dataset_Key__c = 'BENCH_WEEKLY#0'),
            new UKG_Snapshot__c(Name = 'bonus', Dataset__c = 'BONUS_2025-12', Chunk_Index__c = 0, Dataset_Key__c = 'BONUS_2025-12#0')
        };
        UkgTimesheetCache.storeWeek(sunday(), weekCsv());

        UkgTimesheetCache.pruneOldWeeks();

        System.assertEquals(0, [SELECT COUNT() FROM UKG_Snapshot__c WHERE Dataset__c = :oldDataset]);
        System.assertEquals(3, [SELECT COUNT() FROM UKG_Snapshot__c WHERE Dataset__c = :UkgTimesheetCache.datasetFor(sunday())]);
        System.assertEquals(2, [SELECT COUNT() FROM UKG_Snapshot__c WHERE Dataset__c IN ('BENCH_WEEKLY', 'BONUS_2025-12')],
            'Other snapshot datasets are never touched');
    }

    @isTest
    static void oversizedAssociateIsTruncatedNotFailed() {
        UkgTimesheetCache.maxPayload = HEADER.length() + 200;
        UkgTimesheetCache.storeWeek(sunday(), weekCsv());
        String payload = [SELECT Payload__c FROM UKG_Snapshot__c WHERE Dataset_Key__c = :(UkgTimesheetCache.datasetFor(sunday()) + '@111')].Payload__c;
        System.assert(payload.length() <= HEADER.length() + 200);
    }

    @isTest
    static void schedulesAndQueuesRefresh() {
        Test.startTest();
        UkgTimesheetCacheScheduler.scheduleDefault();
        System.assertEquals(2, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'UKG Timesheet Cache%']);
        new UkgTimesheetCacheScheduler(3).execute(null);
        System.assertEquals(null, UkgTimesheetCacheScheduler.refreshNow(3), 'No second refresh while one is queued');
        UkgTimesheetCacheScheduler.unschedule();
        Test.setMock(HttpCalloutMock.class, new CompanyWideMock(200));
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'UKG Timesheet Cache%']);
    }

    @isTest
    static void recentWeeksAreSundaysNewestFirst() {
        List<Date> weeks = UkgTimesheetCache.recentWeeks(3);
        System.assertEquals(3, weeks.size());
        System.assertEquals(UkgTimesheetController.toSunday(Date.today()), weeks[0]);
        System.assertEquals(weeks[0].addDays(-14), weeks[2]);
    }

    // ---- UkgHoursTabCacheController ----

    private static void storeSnapshot(String dataset, Map<String, Object> data) {
        UkgSnapshotService.writeSnapshot(dataset, JSON.serialize(data));
    }

    @isTest
    static void benchAndBillableAreFilteredToTheContact() {
        Contact c = [SELECT Id FROM Contact WHERE UKG_ID__c = '111'];
        Contact other = [SELECT Id FROM Contact WHERE UKG_ID__c = '333'];
        List<Object> weeks = new List<Object>{ '2026-11-07', '2026-11-14' };
        storeSnapshot(UkgSnapshotService.DS_BENCH_WEEKLY, new Map<String, Object>{
            'weekEndDates' => weeks,
            'summaries' => new List<Object>{
                new Map<String, Object>{ 'contactId' => String.valueOf(c.Id), 'userName' => 'A', 'w1Hours' => 4 },
                new Map<String, Object>{ 'contactId' => String.valueOf(other.Id), 'userName' => 'B', 'w1Hours' => 2 },
                new Map<String, Object>{ 'userName' => 'No contact' }
            }
        });
        storeSnapshot(UkgSnapshotService.DS_BILLABLE_WEEKLY, new Map<String, Object>{
            'weekEndDates' => weeks,
            'pw2Summaries' => new List<Object>{ new Map<String, Object>{ 'contactId' => String.valueOf(c.Id), 'userName' => 'A (PW2)' } },
            'hw2Summaries' => new List<Object>{ new Map<String, Object>{ 'contactId' => String.valueOf(c.Id).left(15), 'userName' => 'A (HW2)' } }
        });

        Map<String, Object> bench = UkgHoursTabCacheController.getBenchTimeEntries(c.Id);
        System.assertEquals(true, bench.get('cached'));
        System.assertEquals(1, ((List<Object>) bench.get('summaries')).size());
        System.assertEquals(2, ((List<Object>) bench.get('weekEndDates')).size());
        System.assertNotEquals(null, bench.get('refreshedAt'));

        Map<String, Object> billable = UkgHoursTabCacheController.getBillableTimeEntries(c.Id);
        List<Object> mine = (List<Object>) billable.get('summaries');
        System.assertEquals(1, mine.size(), 'HW2 slice only, matched on 15-char Id');
        System.assertEquals('A (HW2)', ((Map<String, Object>) mine[0]).get('userName'));
    }

    @isTest
    static void missingSnapshotReturnsEmpty() {
        Contact c = [SELECT Id FROM Contact WHERE UKG_ID__c = '111'];
        Map<String, Object> bench = UkgHoursTabCacheController.getBenchTimeEntries(c.Id);
        System.assertEquals(false, bench.get('cached'));
        System.assertEquals(0, ((List<Object>) bench.get('summaries')).size());
    }
}
