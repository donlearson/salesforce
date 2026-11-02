/**
 * UkgDataControllerTest
 * Provides coverage for the Bench Time Tracker controller.
 * Exercises: Login, Report Callout, Saturday calculation, and Contact mapping.
 */
@isTest
private class UkgDataControllerTest {

    public class UkgMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/login')) {
                res.setBody('{"token": "test_token"}');
                res.setStatusCode(200);
            } else {
                // Dynamically find the correct Saturday to match the controller's targetWeekEnds logic
                Date today = Date.today();
                Date sunday = today.toStartOfWeek();
                Integer diff = sunday.daysBetween(today);
                Date sat = today.addDays(diff == 6 ? 0 : -(diff + 1));
                String satStr = DateTime.newInstance(sat, Time.newInstance(0,0,0,0)).format('MM/dd/yyyy');
                
                String csv = 'Last Name,First Name,Start,End,Hours,Employee ID\n' +
                             'Alberts,Tom,01/01/2024,' + satStr + ',40.0,EMP001\n' +
                             'Smith,Jane,01/01/2024,' + satStr + ',20.0,EMP002';
                res.setBody(csv);
                res.setStatusCode(200);
            }
            return res;
        }
    }

    @testSetup
    static void setup() {
        insert new Contact(
            LastName = 'Alberts',
            FirstName = 'Tom',
            UKG_Employee_ID__c = 'EMP001'
        );
    }

    @isTest
    static void testCompanyWideReport() {
        Test.setMock(HttpCalloutMock.class, new UkgMock());
        Test.startTest();
        UkgDataController.BenchTimeWrapper result = UkgDataController.getTimeEntries(null);
        Test.stopTest();

        System.assertNotEquals(0, result.summaries.size(), 'Should have parsed rows');
        System.assertEquals(5, result.weekEndDates.size(), 'Should have 5 header dates');
    }

    @isTest
    static void testSpecificContactReport() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new UkgMock());
        Test.startTest();
        UkgDataController.BenchTimeWrapper result = UkgDataController.getTimeEntries(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertNotEquals(0, result.summaries.size());
    }

    // Now that the report includes Counter Date, a single employee/week can have
    // multiple rows (one per day) rather than one pre-aggregated weekly row. The
    // weekly parser must SUM those rows, not overwrite - regression test for that bug.
    public class MultiRowPerWeekMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/login')) {
                res.setBody('{"token": "test_token"}');
                res.setStatusCode(200);
            } else {
                Date today = Date.today();
                Date sunday = today.toStartOfWeek();
                Integer diff = sunday.daysBetween(today);
                Date sat = today.addDays(diff == 6 ? 0 : -(diff + 1));
                String satStr = DateTime.newInstance(sat, Time.newInstance(0, 0, 0, 0)).format('MM/dd/yyyy');

                String csv = 'Last Name,First Name,Start,End,Hours,Employee ID\n' +
                             'Alberts,Tom,01/01/2024,' + satStr + ',8.0,EMP001\n' +
                             'Alberts,Tom,01/01/2024,' + satStr + ',6.5,EMP001\n' +
                             'Alberts,Tom,01/01/2024,' + satStr + ',4.0,EMP001';
                res.setBody(csv);
                res.setStatusCode(200);
            }
            return res;
        }
    }

    @isTest
    static void testWeeklySumsMultipleRowsPerWeek() {
        Test.setMock(HttpCalloutMock.class, new MultiRowPerWeekMock());
        Test.startTest();
        UkgDataController.BenchTimeWrapper result = UkgDataController.getTimeEntries(null);
        Test.stopTest();

        System.assertEquals(1, result.summaries.size(), 'Expected one associate');
        UkgDataController.UserWeeklyBenchSummary sum = result.summaries[0];
        System.assertEquals('Alberts, Tom', sum.userName, 'Expected username Alberts, Tom');
        System.assertEquals(18.5, sum.w1Hours, 'Expected the 3 same-week rows to sum (8.0 + 6.5 + 4.0), not overwrite');
        System.assertEquals(18.5, sum.total5WeekHours, 'Expected total 5 week hours to reflect the summed value');
    }

    // Mock for the monthly path - rows dated by the report's Counter Date column
    // (the actual date the time was logged), not the week-end date. One row lands on
    // the controller's referenceAsOfDate (guaranteed by construction to always fall in
    // the current-month bucket, thanks to the rollback logic in
    // calculateReferenceAsOfDate), and one lands exactly on the last-month-to-date
    // cutoff (guaranteed by construction to fall in both the to-date and total buckets).
    public class MonthlyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/login')) {
                res.setBody('{"token": "test_token"}');
                res.setStatusCode(200);
            } else {
                Date referenceAsOfDate = computeReferenceAsOfDateForTest();
                Date referenceMonthStart = Date.newInstance(referenceAsOfDate.year(), referenceAsOfDate.month(), 1);
                Date startOfLastMonth = referenceMonthStart.addMonths(-1);
                Integer daysInLastMonth = Date.daysInMonth(startOfLastMonth.year(), startOfLastMonth.month());
                Integer cutoffDay = Math.min(referenceAsOfDate.day(), daysInLastMonth);
                Date lastMonthToDateCutoff = Date.newInstance(startOfLastMonth.year(), startOfLastMonth.month(), cutoffDay);

                String asOfDateStr = DateTime.newInstance(referenceAsOfDate, Time.newInstance(0, 0, 0, 0)).format('MM/dd/yyyy');
                String cutoffStr = DateTime.newInstance(lastMonthToDateCutoff, Time.newInstance(0, 0, 0, 0)).format('MM/dd/yyyy');

                // WeekEnd (index 3) isn't used by the monthly parser, so any placeholder date works there.
                String csv = 'Last Name,First Name,Start,End,Hours,Employee ID,CounterDate\n' +
                             'Alberts,Tom,01/01/2024,01/06/2024,40.0,EMP001,' + asOfDateStr + '\n' +
                             'Alberts,Tom,01/01/2024,01/06/2024,15.0,EMP001,' + cutoffStr;
                res.setBody(csv);
                res.setStatusCode(200);
            }
            return res;
        }
    }

    // Mirrors UkgDataController.calculateReferenceAsOfDate() (private, so not directly
    // callable from the test) so the mock and assertions always agree with the
    // controller's own rollback decision, regardless of what day this test runs.
    private static Date computeReferenceAsOfDateForTest() {
        Date today = Date.today();
        Date sunday = today.toStartOfWeek();
        Integer diff = sunday.daysBetween(today);
        Date mostRecentSaturday = today.addDays(diff == 6 ? 0 : -(diff + 1));
        Date startOfCurrentMonth = Date.newInstance(today.year(), today.month(), 1);
        return (mostRecentSaturday >= startOfCurrentMonth && mostRecentSaturday.day() > 7) ? mostRecentSaturday : startOfCurrentMonth.addDays(-1);
    }

    @isTest
    static void testGetMonthlyTimeEntriesBucketsByCounterDate() {
        Test.setMock(HttpCalloutMock.class, new MonthlyMock());
        Test.startTest();
        UkgDataController.MonthlyBenchTimeWrapper result = UkgDataController.getMonthlyTimeEntries(null);
        Test.stopTest();

        System.assertNotEquals(null, result.asOfDate, 'Expected the wrapper to report the as-of date it calculated through');

        System.assertEquals(1, result.summaries.size(), 'Expected one associate in the monthly result');
        UkgDataController.MonthlyBenchSummary albertsSummary = result.summaries[0];
        System.assertEquals('Alberts, Tom', albertsSummary.userName, 'Expected Alberts to be present in the monthly result');
        System.assertEquals(40.0, albertsSummary.currentMonthHours, 'Expected the referenceAsOfDate-dated row to land in the current month bucket');
        System.assertEquals(15.0, albertsSummary.lastMonthToDateHours, 'Expected the cutoff-dated row to land in the last-month-to-date bucket');
        System.assertEquals(15.0, albertsSummary.lastMonthTotalHours, 'Expected the cutoff-dated row to also land in the last-month-total bucket');
    }

    @isTest
    static void testApiErrors() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        Test.startTest();
        
        // Test 400
        Test.setMock(HttpCalloutMock.class, new ErrorMock(400));
        try { UkgDataController.getTimeEntries(c.Id); } catch (Exception e) {}
        
        // Test 403
        Test.setMock(HttpCalloutMock.class, new ErrorMock(403));
        try { UkgDataController.getTimeEntries(c.Id); } catch (Exception e) {}
        
        // Test 503
        Test.setMock(HttpCalloutMock.class, new ErrorMock(503));
        try { UkgDataController.getTimeEntries(c.Id); } catch (Exception e) {}
        
        Test.stopTest();
    }

    private class ErrorMock implements HttpCalloutMock {
        Integer code;
        ErrorMock(Integer c) { code = c; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/login')) {
                res.setBody('{"token": "test_token"}');
                res.setStatusCode(200);
            } else {
                res.setStatusCode(code);
                res.setBody('Error Body');
            }
            return res;
        }
    }
}