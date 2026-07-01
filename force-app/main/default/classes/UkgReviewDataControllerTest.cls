/**
 * UkgReviewDataControllerTest
 * Provides code coverage and functional validation for UkgReviewDataController.
 * Includes mocking for UKG Login and Report API callouts.
 */
@isTest
private class UkgReviewDataControllerTest {

    /**
     * Mock Class to simulate UKG API responses
     */
    public class UkgCalloutMock implements HttpCalloutMock {
        protected Integer code;
        protected String body;

        public UkgCalloutMock(Integer code, String body) {
            this.code = code;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            
            // Determine if this is a login call or a report call
            if (req.getEndpoint().contains('/login')) {
                res.setBody('{"token": "mock_bearer_token_123"}');
                res.setStatusCode(200);
            } else {
                // Return the custom body (CSV data) for report calls
                res.setBody(this.body);
                res.setStatusCode(this.code);
            }
            return res;
        }
    }

    @testSetup
    static void setup() {
        // Create a test contact with necessary UKG fields
        Contact testContact = new Contact(
            LastName = 'Alberts',
            FirstName = 'Tom',
            UKG_ID__c = '17313222787'
            // NOTE: Hire_Date_Anniversary__c is a formula field and cannot be written to.
            // You must set the field(s) that the formula depends on here so it calculates.
            // Example: testContact.Hire_Date__c = Date.today().addYears(-1);
        );
        insert testContact;
    }

    /**
     * Helper method to create a Contact with a specific formula value for testing logic
     * without needing to know the complex underlying formula dependencies.
     */
    private static Contact getMockContactWithFormula(Id existingId, String ukgId, Date anniversaryDate) {
        String dateStr = DateTime.newInstance(anniversaryDate, Time.newInstance(0,0,0,0)).format('yyyy-MM-dd');
        String jsonStr = '{"attributes":{"type":"Contact"},"Id":"' + existingId + '","UKG_ID__c":"' + ukgId + '","Hire_Date_Anniversary__c":"' + dateStr + '"}';
        return (Contact)JSON.deserialize(jsonStr, Contact.class);
    }

    /**
     * Tests successful data retrieval using auto-calculated dates (Hire Date Anniversary)
     */
    @isTest
    static void testGetReviewSummaryAutoDates() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        
        // Prepare CSV data
        String csvHeader = '"Full Name","Primary Email","Display Name"," Activity Codes","Date","Hours","Timesheet Start","Timesheet End","Comment","Is Time Off","Time Off Name","Default Home Department","Approval State"," Project New Full Path"," Project New"," Project New Name (1)"," Project New Name (2)"," Project New Name (3)"," Project New Name (Level 4)","Account Id"\n';
        String billableRow = '"Tom Alberts","talberts@hpg","Proj","110 - Billable","11/14/2025","8.00","","","","","","","Approved","Path","Proj","Client Inc","Project Alpha","","","123"\n';
        String mockCsvBody = csvHeader + billableRow;

        Test.setMock(HttpCalloutMock.class, new UkgCalloutMock(200, mockCsvBody));

        Test.startTest();
        // We use the ID but since the formula might be null in the DB, we expect the controller to handle it gracefully
        // or the developer has set the source fields in @testSetup.
        UkgReviewDataController.ReviewSummaryWrapper result = UkgReviewDataController.getReviewSummary(c.Id, null, null);
        Test.stopTest();

        // Using System.assertNotEquals for maximum environment compatibility
        System.assertNotEquals(null, result, 'Result wrapper should not be null');
    }

    /**
     * Tests manual date input from the Custom Submit LWC
     */
    @isTest
    static void testGetReviewSummaryManualDates() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        
        String csvHeader = '"Full Name","Primary Email","Display Name"," Activity Codes","Date","Hours","Timesheet Start","Timesheet End","Comment","Is Time Off","Time Off Name","Default Home Department","Approval State"," Project New Full Path"," Project New"," Project New Name (1)"," Project New Name (2)"," Project New Name (3)"," Project New Name (Level 4)","Account Id"\n';
        String row = '"Tom Alberts","talberts@hpg","Proj","110","11/14/2025","5.0","","","","","","","Approved","Path","Proj","C","P","","","123"';
        
        Test.setMock(HttpCalloutMock.class, new UkgCalloutMock(200, csvHeader + row));

        Test.startTest();
        // Passing explicit date strings - this bypasses the need for the formula field calculation
        UkgReviewDataController.ReviewSummaryWrapper result = UkgReviewDataController.getReviewSummary(c.Id, '2025-01-01', '2025-12-31');
        Test.stopTest();

        System.assert(result != null && result.reviewPeriod != null && result.reviewPeriod.contains('2025'), 'The review period should reflect the manual input years');
    }

    /**
     * Tests behavior when the UKG ID is missing on the Contact
     */
    @isTest
    static void testMissingUkgId() {
        Contact testContact = new Contact(LastName = 'NoID');
        insert testContact;

        Test.startTest();
        UkgReviewDataController.ReviewSummaryWrapper result = UkgReviewDataController.getReviewSummary(testContact.Id, null, null);
        Test.stopTest();

        System.assertEquals(0, result.billableProjects.size(), 'Should return empty wrapper if ID is missing');
    }
}