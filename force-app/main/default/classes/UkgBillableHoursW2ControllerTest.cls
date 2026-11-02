/**
 * UkgBillableHoursW2ControllerTest
 * Provides coverage for the UkgBillableHoursW2Controller controller.
 */
@isTest
private class UkgBillableHoursW2ControllerTest {

    public class UkgMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/login')) {
                res.setBody('{"token": "test_token"}');
                res.setStatusCode(200);
            } else {
                // Match the Saturday logic
                Date today = Date.today();
                Date sunday = today.toStartOfWeek();
                Integer diff = sunday.daysBetween(today);
                Date sat = today.addDays(diff == 6 ? 0 : -(diff + 1));
                String satStr = DateTime.newInstance(sat, Time.newInstance(0,0,0,0)).format('MM/dd/yyyy');
                
                String csv = 'L,F,Start,End,H,ID,Code,APL,Holiday,Profile\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',35.5,EMP001,100,0,0,Billable Recording Time - APL\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',24.0,EMP001,177-24-OnCall,0,0,Billable Recording Time - APL\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',15.0,EMP001,177-15-OnCall,0,0,Billable Recording Time - APL\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',0,EMP001,405-APL,8.0,0,Billable Recording Time - APL\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',0,EMP001,404-Holiday,0,4.0,Billable Recording Time - APL\n' +
                             'Smith,Jane,01/01/24,' + satStr + ',20.0,EMP002,100,0,0,1099 Contractors and Hourly W-2s';
                res.setBody(csv);
                res.setStatusCode(200);
            }
            return res;
        }
    }

    @testSetup
    static void setup() {
        insert new Contact(LastName = 'Alberts', UKG_Employee_ID__c = 'EMP001');
        insert new Contact(LastName = 'Smith', UKG_Employee_ID__c = 'EMP002');
    }

    @isTest
    static void testBillableReporting() {
        Test.setMock(HttpCalloutMock.class, new UkgMock());
        Test.startTest();
        UkgBillableHoursW2Controller.BenchTimeWrapper result = UkgBillableHoursW2Controller.getTimeEntries(null);
        Test.stopTest();
        System.assertEquals(1, result.summaries.size(), 'Expected getTimeEntries to return only the PW2 profile row, excluding the 1099 row');
        UkgBillableHoursW2Controller.UserWeeklyBillableSummary sum = result.summaries[0];
        System.assertEquals('Alberts, Tom', sum.userName, 'Expected username Alberts, Tom');
        System.assertEquals(35.5, sum.w1Hours, 'Expected w1 hours to exclude on-call rows');
        System.assertEquals(15.0, sum.w1_15hSegments, 'Expected 15h segments total');
        System.assertEquals(24.0, sum.w1_24hSegments, 'Expected 24h segments total');
        System.assertEquals(15.0, sum.total15hSegments, 'Expected total 15h segments total');
        System.assertEquals(24.0, sum.total24hSegments, 'Expected total 24h segments total');
        System.assertEquals(35.5, sum.total5WeekHours, 'Expected total 5 week hours to exclude on-call rows');
        System.assertEquals(8.0, sum.w1_aplHours, 'Expected APL hours parsed from the appended APL column');
        System.assertEquals(8.0, sum.total5WeekAplHours, 'Expected total APL hours');
        System.assertEquals(4.0, sum.w1_holidayHours, 'Expected Holiday hours parsed from the appended Holiday column');
        System.assertEquals(4.0, sum.total5WeekHolidayHours, 'Expected total Holiday hours');
    }

    @isTest
    static void testGetAllTimeEntriesSplitsByProfile() {
        Test.setMock(HttpCalloutMock.class, new UkgMock());
        Test.startTest();
        UkgBillableHoursW2Controller.CombinedBillableHoursWrapper combined = UkgBillableHoursW2Controller.getAllTimeEntries(null);
        Test.stopTest();

        System.assertEquals(1, combined.pw2Summaries.size(), 'Expected exactly one PW2 associate');
        System.assertEquals('Alberts, Tom', combined.pw2Summaries[0].userName, 'Expected PW2 bucket to contain Alberts');

        System.assertEquals(1, combined.hw2Summaries.size(), 'Expected exactly one HW2/1099 associate');
        System.assertEquals('Smith, Jane', combined.hw2Summaries[0].userName, 'Expected HW2/1099 bucket to contain Smith');
        System.assertEquals(20.0, combined.hw2Summaries[0].w1Hours, 'Expected Smith\'s billable hours to parse correctly');
    }

    // Mock including the new trailing Date Terminated column (index 11, after Counter
    // Date). Alberts has a termination date populated; Smith's is blank, simulating an
    // active associate.
    public class TerminationDateMock implements HttpCalloutMock {
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

                String csv = 'L,F,Start,End,H,ID,Code,APL,Holiday,Profile,CounterDate,DateTerminated\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',10.0,EMP001,100,0,0,Billable Recording Time - APL,' + satStr + ',06/15/2024\n' +
                             'Smith,Jane,01/01/24,' + satStr + ',5.0,EMP002,100,0,0,Billable Recording Time - APL,' + satStr + ',';
                res.setBody(csv);
                res.setStatusCode(200);
            }
            return res;
        }
    }

    @isTest
    static void testTerminationDateParsing() {
        Test.setMock(HttpCalloutMock.class, new TerminationDateMock());
        Test.startTest();
        UkgBillableHoursW2Controller.BenchTimeWrapper result = UkgBillableHoursW2Controller.getTimeEntries(null);
        Test.stopTest();

        UkgBillableHoursW2Controller.UserWeeklyBillableSummary albertsSummary;
        UkgBillableHoursW2Controller.UserWeeklyBillableSummary smithSummary;
        for (UkgBillableHoursW2Controller.UserWeeklyBillableSummary s : result.summaries) {
            if (s.userName == 'Alberts, Tom') albertsSummary = s;
            if (s.userName == 'Smith, Jane') smithSummary = s;
        }

        System.assertNotEquals(null, albertsSummary, 'Expected Alberts to be present');
        System.assertEquals('2024-06-15', albertsSummary.terminationDate, 'Expected the Date Terminated column to parse into ISO format');

        System.assertNotEquals(null, smithSummary, 'Expected Smith to be present');
        System.assertEquals(null, smithSummary.terminationDate, 'Expected a blank Date Terminated column to leave terminationDate null');
    }

    // Mock verifying Activity Code 217 (non-billable) rows are excluded from billable
    // hours entirely - not just diverted into a segment bucket like 177-15/177-24.
    public class Code217Mock implements HttpCalloutMock {
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

                String csv = 'L,F,Start,End,H,ID,Code,APL,Holiday,Profile\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',20.0,EMP001,100,0,0,Billable Recording Time - APL\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',12.0,EMP001,217-NonBillable,0,0,Billable Recording Time - APL';
                res.setBody(csv);
                res.setStatusCode(200);
            }
            return res;
        }
    }

    @isTest
    static void testCode217ExcludedFromBillableHours() {
        Test.setMock(HttpCalloutMock.class, new Code217Mock());
        Test.startTest();
        UkgBillableHoursW2Controller.BenchTimeWrapper result = UkgBillableHoursW2Controller.getTimeEntries(null);
        Test.stopTest();

        System.assertEquals(1, result.summaries.size(), 'Expected one PW2 associate');
        UkgBillableHoursW2Controller.UserWeeklyBillableSummary sum = result.summaries[0];
        System.assertEquals(20.0, sum.w1Hours, 'Expected Code 217 hours to be excluded from w1Hours');
        System.assertEquals(20.0, sum.total5WeekHours, 'Expected Code 217 hours to be excluded from total5WeekHours');
    }

    // Mock for the monthly path - rows dated by the report's Counter Date column
    // (the actual date the time was logged), not the week-end date. One row lands on
    // the controller's referenceAsOfDate (guaranteed by construction to always fall in
    // the current-month bucket, thanks to the rollback logic in
    // calculateReferenceAsOfDate), and two rows land exactly on the last-month-to-date
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
                String csv = 'L,F,Start,End,H,ID,Code,APL,Holiday,Profile,CounterDate\n' +
                             'Alberts,Tom,01/01/24,01/06/24,10.0,EMP001,100,0,0,Billable Recording Time - APL,' + asOfDateStr + '\n' +
                             'Alberts,Tom,01/01/24,01/06/24,6.0,EMP001,100,0,0,Billable Recording Time - APL,' + cutoffStr + '\n' +
                             'Alberts,Tom,01/01/24,01/06/24,0,EMP001,405-APL,2.0,0,Billable Recording Time - APL,' + cutoffStr + '\n' +
                             'Smith,Jane,01/01/24,01/06/24,5.0,EMP002,100,0,0,1099 Contractors and Hourly W-2s,' + asOfDateStr;
                res.setBody(csv);
                res.setStatusCode(200);
            }
            return res;
        }
    }

    // Mirrors UkgBillableHoursW2Controller.calculateReferenceAsOfDate() (private, so not
    // directly callable from the test) so the mock and assertions always agree with the
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
        UkgBillableHoursW2Controller.MonthlyCombinedWrapper monthly = UkgBillableHoursW2Controller.getMonthlyTimeEntries(null);
        Test.stopTest();

        System.assertNotEquals(null, monthly.asOfDate, 'Expected the wrapper to report the as-of date it calculated through');

        System.assertEquals(1, monthly.pw2Summaries.size(), 'Expected exactly one PW2 associate');
        UkgBillableHoursW2Controller.MonthlyBillableSummary pw2Summary = monthly.pw2Summaries[0];
        System.assertEquals('Alberts, Tom', pw2Summary.userName, 'Expected PW2 bucket to contain Alberts');
        System.assertEquals(10.0, pw2Summary.currentMonthHours, 'Expected the referenceAsOfDate-dated row to land in the current month bucket');
        System.assertEquals(0.0, pw2Summary.currentMonthAplHours, 'Expected no APL hours in the current month bucket');
        System.assertEquals(6.0, pw2Summary.lastMonthToDateHours, 'Expected the cutoff-dated row to land in the last-month-to-date bucket');
        System.assertEquals(6.0, pw2Summary.lastMonthTotalHours, 'Expected the cutoff-dated row to also land in the last-month-total bucket');
        System.assertEquals(2.0, pw2Summary.lastMonthToDateAplHours, 'Expected the cutoff-dated APL row to land in the last-month-to-date APL bucket');
        System.assertEquals(2.0, pw2Summary.lastMonthTotalAplHours, 'Expected the cutoff-dated APL row to also land in the last-month-total APL bucket');

        System.assertEquals(1, monthly.hw2Summaries.size(), 'Expected exactly one HW2/1099 associate');
        UkgBillableHoursW2Controller.MonthlyBillableSummary hw2Summary = monthly.hw2Summaries[0];
        System.assertEquals('Smith, Jane', hw2Summary.userName, 'Expected HW2/1099 bucket to contain Smith');
        System.assertEquals(5.0, hw2Summary.currentMonthHours, 'Expected Smith\'s referenceAsOfDate-dated hours to land in the current month bucket');
    }

    // Mock verifying Activity Code 217 rows are excluded from the monthly Current
    // Month bucket the same way they are from the weekly one.
    public class MonthlyCode217Mock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/login')) {
                res.setBody('{"token": "test_token"}');
                res.setStatusCode(200);
            } else {
                Date referenceAsOfDate = computeReferenceAsOfDateForTest();
                String asOfDateStr = DateTime.newInstance(referenceAsOfDate, Time.newInstance(0, 0, 0, 0)).format('MM/dd/yyyy');

                String csv = 'L,F,Start,End,H,ID,Code,APL,Holiday,Profile,CounterDate\n' +
                             'Alberts,Tom,01/01/24,01/06/24,10.0,EMP001,100,0,0,Billable Recording Time - APL,' + asOfDateStr + '\n' +
                             'Alberts,Tom,01/01/24,01/06/24,7.0,EMP001,217-NonBillable,0,0,Billable Recording Time - APL,' + asOfDateStr;
                res.setBody(csv);
                res.setStatusCode(200);
            }
            return res;
        }
    }

    @isTest
    static void testCode217ExcludedFromMonthlyBillableHours() {
        Test.setMock(HttpCalloutMock.class, new MonthlyCode217Mock());
        Test.startTest();
        UkgBillableHoursW2Controller.MonthlyCombinedWrapper monthly = UkgBillableHoursW2Controller.getMonthlyTimeEntries(null);
        Test.stopTest();

        System.assertEquals(1, monthly.pw2Summaries.size(), 'Expected one PW2 associate');
        UkgBillableHoursW2Controller.MonthlyBillableSummary sum = monthly.pw2Summaries[0];
        System.assertEquals(10.0, sum.currentMonthHours, 'Expected Code 217 hours to be excluded from currentMonthHours');
    }

    @isTest
    static void testApiErrors() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new ErrorMock(400));
        try { UkgBillableHoursW2Controller.getTimeEntries(c.Id); } catch (Exception e) {}
        Test.setMock(HttpCalloutMock.class, new ErrorMock(503));
        try { UkgBillableHoursW2Controller.getTimeEntries(c.Id); } catch (Exception e) {}
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
