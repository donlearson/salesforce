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
                
                String csv = 'L,F,Start,End,H,ID,Code,APL,Holiday\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',35.5,EMP001,100,0,0\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',24.0,EMP001,177-24-OnCall,0,0\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',15.0,EMP001,177-15-OnCall,0,0\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',0,EMP001,405-APL,8.0,0\n' +
                             'Alberts,Tom,01/01/24,' + satStr + ',0,EMP001,404-Holiday,0,4.0';
                res.setBody(csv);
                res.setStatusCode(200);
            }
            return res;
        }
    }

    @testSetup
    static void setup() {
        insert new Contact(LastName = 'Alberts', UKG_Employee_ID__c = 'EMP001');
    }

    @isTest
    static void testBillableReporting() {
        Test.setMock(HttpCalloutMock.class, new UkgMock());
        Test.startTest();
        UkgBillableHoursW2Controller.BenchTimeWrapper result = UkgBillableHoursW2Controller.getTimeEntries(null);
        Test.stopTest();
        System.assertNotEquals(0, result.summaries.size(), 'Should have data rows');
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
