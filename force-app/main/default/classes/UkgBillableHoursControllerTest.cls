/**
 * UkgBillableHoursControllerTest
 * Provides coverage for the Billable Hours Tracker controller. Since this
 * controller now delegates to UkgBillableHoursW2Controller.getAllTimeEntries()
 * for the actual callout, the mock CSV includes both PW2 and 1099 profile rows
 * to verify getTimeEntries() correctly returns only the HW2/1099 slice.
 */
@isTest
private class UkgBillableHoursControllerTest {

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
                             'Smith,Jane,01/01/24,' + satStr + ',20.0,EMP002,100,0,0,1099 Contractors and Hourly W-2s\n' +
                             'Smith,Jane,01/01/24,' + satStr + ',24.0,EMP002,177-24-OnCall,0,0,1099 Contractors and Hourly W-2s\n' +
                             'Smith,Jane,01/01/24,' + satStr + ',15.0,EMP002,177-15-OnCall,0,0,1099 Contractors and Hourly W-2s';
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
        UkgBillableHoursController.BenchTimeWrapper result = UkgBillableHoursController.getTimeEntries(null);
        Test.stopTest();
        System.assertEquals(1, result.summaries.size(), 'Expected getTimeEntries to return only the 1099 profile row, excluding the PW2 row');
        UkgBillableHoursController.UserWeeklyBillableSummary sum = result.summaries[0];
        System.assertEquals('Smith, Jane', sum.userName, 'Expected username Smith, Jane');
        System.assertEquals(20.0, sum.w1Hours, 'Expected w1 hours to exclude on-call rows');
        System.assertEquals(15.0, sum.w1_15hSegments, 'Expected 15h segments total');
        System.assertEquals(24.0, sum.w1_24hSegments, 'Expected 24h segments total');
        System.assertEquals(15.0, sum.total15hSegments, 'Expected total 15h segments total');
        System.assertEquals(24.0, sum.total24hSegments, 'Expected total 24h segments total');
        System.assertEquals(20.0, sum.total5WeekHours, 'Expected total 5 week hours to exclude on-call rows');
    }

    @isTest
    static void testApiErrors() {
        Contact c = [SELECT Id FROM Contact WHERE LastName = 'Alberts' LIMIT 1];
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new ErrorMock(400));
        try { UkgBillableHoursController.getTimeEntries(c.Id); } catch (Exception e) {}
        Test.setMock(HttpCalloutMock.class, new ErrorMock(503));
        try { UkgBillableHoursController.getTimeEntries(c.Id); } catch (Exception e) {}
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
