@isTest
private class UkgTimesheetControllerTest {

    private static final String HEADER = '"Full Name","Primary Email","Display Name"," Activity Codes","Date","Hours","Timesheet Start","Timesheet End","Comment","Is Time Off","Time Off Name","Default Home Department","Approval State"," Project New Full Path"," Project New"," Project New Name (1)"," Project New Name (2)"," Project New Name (3)"," Project New Name (Level 4)","Account Id"\n';

    private class UkgMock implements HttpCalloutMock {
        Integer code;
        String body;
        UkgMock(Integer code, String body) { this.code = code; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/login')) {
                res.setStatusCode(200);
                res.setBody('{"token":"mock_token"}');
            } else {
                System.assert(req.getBody().contains('"FromDate":"2026-10-25"'), 'Week should start on Sunday');
                System.assert(req.getBody().contains('"ToDate":"2026-10-31"'), 'Week should end on Saturday');
                res.setStatusCode(code);
                res.setBody(body);
            }
            return res;
        }
    }

    private static String row(String code, String dt, String hours, String timeOff, String client, String project, String sub) {
        return '"Test User","t@hpg","x","' + code + '","' + dt + '","' + hours + '","10/25/2026","10/31/2026","","' + timeOff + '","","Dept","Approved (PayPrep Ready)","path","p","' + client + '","' + project + '","' + sub + '","","111"\n';
    }

    @testSetup
    static void setup() {
        insert new Account(Name = 'Archbold Medical Center');
        insert new Contact(LastName = 'Associate', UKG_ID__c = '111');
    }

    @isTest
    static void pivotsWeekByClientAndDay() {
        String csv = HEADER
            + row('106 - Analysis and Specification', '10/30/2026', '2.00', '', 'Archbold Medical Center, Inc', 'Application Support Services - SCS', 'HPG Upgrade Services - SCS')
            + row('110 - Project Meeting/Admin', '10/29/2026', '1.50', '', 'Archbold Medical Center, Inc', 'Application Support Services - SCS', 'HPG Managed Services - SCS')
            + row('135 - Application Build', '10/26/2026', '3.00', '', 'UAB Medicine Enterprise', 'Oracle to Epic', '')
            + row('184 - Internal Meeting', '10/27/2026', '1.00', '', '', '', '')
            + row('177-15 Hour On-Call Unit', '10/28/2026', '1.00', '', '', '', '')
            + row('PTO', '10/27/2026', '8.00', 'true', '', '', '')
            + row('135 - Application Build', '11/02/2026', '5.00', '', 'UAB Medicine Enterprise', 'Out of week', '');
        Test.setMock(HttpCalloutMock.class, new UkgMock(200, csv));
        Contact c = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        UkgTimesheetController.TimesheetWeek w = UkgTimesheetController.getWeek(c.Id, '2026-10-28');
        Test.stopTest();

        System.assertEquals('2026-10-25', w.weekStart);
        System.assertEquals(7, w.days.size());
        System.assertEquals(2, w.clients.size(), 'Two billable clients');
        UkgTimesheetController.ClientRow archbold = w.clients[0];
        System.assertEquals('Archbold Medical Center, Inc', archbold.clientName);
        System.assertEquals(3.5, archbold.total);
        System.assertEquals(2.0, archbold.hours[5], 'Friday');
        System.assertEquals(1.5, archbold.hours[4], 'Thursday');
        System.assertNotEquals(null, archbold.accountId, 'Matched to Salesforce Account');
        System.assertEquals(2, archbold.projects.size(), 'One row per project + activity code');
        System.assertEquals(false, w.hasTaskColumn);
        System.assertNotEquals(null, archbold.projects[0].activityCode);
        System.assertEquals(null, w.clients[1].accountId, 'UAB has no Account in test data');
        System.assertEquals(6.5, w.billableTotal, 'Out-of-week row ignored');
        System.assertEquals(9.0, w.nonBillableTotal, 'Internal meeting + PTO');
        System.assertEquals(15.5, w.weekTotal);
        System.assertEquals(1, w.onCall.size());
        System.assertEquals(9.0, w.dayTotals[2], 'Tuesday: PTO + internal');
        System.assertEquals(1, w.approvalStates.size());
    }

    @isTest
    static void noUkgIdReturnsFlag() {
        Contact c = new Contact(LastName = 'NoId');
        insert c;
        UkgTimesheetController.TimesheetWeek w = UkgTimesheetController.getWeek(c.Id, null);
        System.assertEquals(false, w.hasUkgId);
        System.assertEquals(7, w.days.size());
    }

    @isTest
    static void reportErrorThrows() {
        Test.setMock(HttpCalloutMock.class, new UkgMock(503, ''));
        Contact c = [SELECT Id FROM Contact WHERE UKG_ID__c = '111' LIMIT 1];
        Boolean threw = false;
        try {
            UkgTimesheetController.getWeek(c.Id, '2026-10-31');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Expected an error for a 503');
    }

    @isTest
    static void weekStartIsAlwaysSunday() {
        System.assertEquals(Date.newInstance(2026, 10, 25), UkgTimesheetController.resolveWeekStart('2026-10-25'));
        System.assertEquals(Date.newInstance(2026, 10, 25), UkgTimesheetController.resolveWeekStart('2026-10-31'));
    }

    @isTest
    static void groupsByTaskWhenColumnPresent() {
        String header = '"Full Name"," Activity Codes","Date","Hours","Approval State"," Project New Name (1)"," Project New Name (2)"," Project New Name (3)","Task"\n';
        String csv = header
            + '"U","135 - Application Build","10/26/2026","2.00","Approved","UAB Medicine Enterprise","Oracle to Epic","Lights On","Build Work Efforts"\n'
            + '"U","110 - Project Meeting/Admin","10/26/2026","1.00","Approved","UAB Medicine Enterprise","Oracle to Epic","Lights On","Admin/Meetings"\n'
            + '"U","110 - Project Meeting/Admin","10/27/2026","1.50","Approved","UAB Medicine Enterprise","Oracle to Epic","Lights On","Admin/Meetings"\n';
        UkgTimesheetController.TimesheetWeek w = new UkgTimesheetController.TimesheetWeek();
        UkgTimesheetController.buildWeek(w, csv, Date.newInstance(2026, 10, 25));
        System.assertEquals(true, w.hasTaskColumn);
        System.assertEquals(1, w.clients.size());
        System.assertEquals(2, w.clients[0].projects.size());
        UkgTimesheetController.LineRow admin = w.clients[0].projects[0];
        System.assertEquals('110 - Project Meeting/Admin', admin.activityCode);
        System.assertEquals('Admin/Meetings', admin.task);
        System.assertEquals(2.5, admin.total);
        System.assertEquals('Oracle to Epic / Lights On', admin.label);
    }

    @isTest
    static void stripsCompanySuffix() {
        System.assertEquals('Archbold Medical Center', UkgTimesheetController.stripCompanySuffix('Archbold Medical Center, Inc'));
        System.assertEquals('Christiana Care Health Services', UkgTimesheetController.stripCompanySuffix('Christiana Care Health Services, Inc.'));
        System.assertEquals('Northbay Healthcare', UkgTimesheetController.stripCompanySuffix('Northbay Healthcare'));
    }

    @isTest
    static void parsesQuotedCommas() {
        List<String> v = UkgTimesheetController.parseCsvLine('"a, b","c""d",e,');
        System.assertEquals(4, v.size());
        System.assertEquals('a, b', v[0]);
        System.assertEquals('c"d', v[1]);
        System.assertEquals('e', v[2]);
        System.assertEquals('', v[3]);
    }
}
