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