/**
 * UkgBillableHoursW2Controller
 * * Handles dynamic login to UKG to retrieve a Bearer Token, and then uses that
 * token to securely call the UKG catch-all Billable Hours Report, which covers
 * both PW2 and HW2/1099 profiles in one report (report 124935578).
 * * getAllTimeEntries() fetches and parses that report once, splitting rows into
 * PW2 vs. HW2/1099 buckets via the report's trailing TimesheetProfile column -
 * this is the single source of truth UkgBillableHoursController delegates to as
 * well, so both employee types are covered by one UKG callout instead of two.
 * getTimeEntries() preserves the original PW2-only contract for ukgBillableHoursW2Tracker.
 * * getMonthlyTimeEntries() requests a wider (70-day) window via the report's
 * "selectors" capability, and buckets each row into Current Month / Last Month
 * To Date / Last Month Total using the report's Counter Date column (the actual
 * date the time was logged) - not the week-end date, since a week can straddle
 * a month boundary.
 * * This version hard-codes the 5 most recent SATURDAY week-end dates for the
 * weekly contract, inserting 0.0 for weeks where a user has no data.
 * * Conditionally filters the report by Contact's UKG_Employee_ID__c when
 * running on a Contact record page.
 */
public with sharing class UkgBillableHoursW2Controller {

    // --- Inner Classes for Data Transfer and Aggregation ---

    // Wrapper class to send the list of summaries and the dynamic column headers to the LWC
    public class BenchTimeWrapper {
        @AuraEnabled public List<UserWeeklyBillableSummary> summaries { get; set; }
        // The 5 week-end dates (Saturdays) found in the report. Index 0 is W1 (most recent).
        @AuraEnabled public List<String> weekEndDates { get; set; }

        public BenchTimeWrapper(List<UserWeeklyBillableSummary> summaries, List<String> weekEndDates) {
            this.summaries = summaries;
            this.weekEndDates = weekEndDates;
        }
    }

    // Both profile buckets from the single catch-all report call, plus the shared week headers.
    public class CombinedBillableHoursWrapper {
        @AuraEnabled public List<UserWeeklyBillableSummary> pw2Summaries { get; set; }
        @AuraEnabled public List<UserWeeklyBillableSummary> hw2Summaries { get; set; }
        @AuraEnabled public List<String> weekEndDates { get; set; }

        public CombinedBillableHoursWrapper(List<UserWeeklyBillableSummary> pw2Summaries, List<UserWeeklyBillableSummary> hw2Summaries, List<String> weekEndDates) {
            this.pw2Summaries = pw2Summaries;
            this.hw2Summaries = hw2Summaries;
            this.weekEndDates = weekEndDates;
        }
    }

    public class UserWeeklyBillableSummary {
        @AuraEnabled public String userName { get; set; }
        @AuraEnabled public String contactId { get; set; } // Salesforce Contact Id
        // These fields will hold the aggregated hours for the last 5 weeks (W1 = Most Recent)
        @AuraEnabled public Decimal w1Hours { get; set; }
        @AuraEnabled public Decimal w2Hours { get; set; }
        @AuraEnabled public Decimal w3Hours { get; set; }
        @AuraEnabled public Decimal w4Hours { get; set; }
        @AuraEnabled public Decimal w5Hours { get; set; }
        @AuraEnabled public Decimal total5WeekHours { get; set; }

        // On-Call Segments
        @AuraEnabled public Decimal w1_15hSegments { get; set; }
        @AuraEnabled public Decimal w1_24hSegments { get; set; }
        @AuraEnabled public Decimal w2_15hSegments { get; set; }
        @AuraEnabled public Decimal w2_24hSegments { get; set; }
        @AuraEnabled public Decimal w3_15hSegments { get; set; }
        @AuraEnabled public Decimal w3_24hSegments { get; set; }
        @AuraEnabled public Decimal w4_15hSegments { get; set; }
        @AuraEnabled public Decimal w4_24hSegments { get; set; }
        @AuraEnabled public Decimal w5_15hSegments { get; set; }
        @AuraEnabled public Decimal w5_24hSegments { get; set; }
        @AuraEnabled public Decimal total15hSegments { get; set; }
        @AuraEnabled public Decimal total24hSegments { get; set; }

        // Time Off (APL = All Purpose Leave, activity code 405; Holiday = activity code 404).
        // Reported separately from w1Hours..w5Hours (billable/worked hours) so time off never
        // inflates billable totals - it's used only for utilization math on the client.
        @AuraEnabled public Decimal w1_aplHours { get; set; }
        @AuraEnabled public Decimal w2_aplHours { get; set; }
        @AuraEnabled public Decimal w3_aplHours { get; set; }
        @AuraEnabled public Decimal w4_aplHours { get; set; }
        @AuraEnabled public Decimal w5_aplHours { get; set; }
        @AuraEnabled public Decimal total5WeekAplHours { get; set; }
        @AuraEnabled public Decimal w1_holidayHours { get; set; }
        @AuraEnabled public Decimal w2_holidayHours { get; set; }
        @AuraEnabled public Decimal w3_holidayHours { get; set; }
        @AuraEnabled public Decimal w4_holidayHours { get; set; }
        @AuraEnabled public Decimal w5_holidayHours { get; set; }
        @AuraEnabled public Decimal total5WeekHolidayHours { get; set; }

        // Date (yyyy-MM-dd) the associate was terminated, from the report's trailing
        // Date Terminated column - null if not terminated. Terminated associates still
        // appear in the weekly data (they may have worked part of the week), but the
        // client excludes them from utilization/low-utilization highlighting once their
        // termination date precedes the start of the most recent week.
        @AuraEnabled public String terminationDate { get; set; }

        public UserWeeklyBillableSummary() {
            w1Hours = 0.0; w2Hours = 0.0; w3Hours = 0.0; w4Hours = 0.0; w5Hours = 0.0; total5WeekHours = 0.0;
            w1_15hSegments = 0.0; w1_24hSegments = 0.0;
            w2_15hSegments = 0.0; w2_24hSegments = 0.0;
            w3_15hSegments = 0.0; w3_24hSegments = 0.0;
            w4_15hSegments = 0.0; w4_24hSegments = 0.0;
            w5_15hSegments = 0.0; w5_24hSegments = 0.0;
            total15hSegments = 0.0; total24hSegments = 0.0;
            w1_aplHours = 0.0; w2_aplHours = 0.0; w3_aplHours = 0.0; w4_aplHours = 0.0; w5_aplHours = 0.0; total5WeekAplHours = 0.0;
            w1_holidayHours = 0.0; w2_holidayHours = 0.0; w3_holidayHours = 0.0; w4_holidayHours = 0.0; w5_holidayHours = 0.0; total5WeekHolidayHours = 0.0;
        }
    }

    // Three date-precise buckets per associate for the monthly view: the current
    // (partial) calendar month, the previous month through the same elapsed day count
    // (for a fair pace comparison), and the previous month's full total (for context).
    public class MonthlyBillableSummary {
        @AuraEnabled public String userName { get; set; }
        @AuraEnabled public String contactId { get; set; }
        @AuraEnabled public Decimal currentMonthHours { get; set; }
        @AuraEnabled public Decimal lastMonthToDateHours { get; set; }
        @AuraEnabled public Decimal lastMonthTotalHours { get; set; }
        @AuraEnabled public Decimal currentMonthAplHours { get; set; }
        @AuraEnabled public Decimal lastMonthToDateAplHours { get; set; }
        @AuraEnabled public Decimal lastMonthTotalAplHours { get; set; }

        public MonthlyBillableSummary() {
            currentMonthHours = 0.0; lastMonthToDateHours = 0.0; lastMonthTotalHours = 0.0;
            currentMonthAplHours = 0.0; lastMonthToDateAplHours = 0.0; lastMonthTotalAplHours = 0.0;
        }
    }

    public class MonthlyCombinedWrapper {
        @AuraEnabled public List<MonthlyBillableSummary> pw2Summaries { get; set; }
        @AuraEnabled public List<MonthlyBillableSummary> hw2Summaries { get; set; }
        // The actual date (yyyy-MM-dd) Current Month is calculated through - either the
        // last completed Saturday, or, if fewer than 7 days have elapsed in the new
        // month, the last day of the previous month (see parseCsvRowsForMonthly).
        @AuraEnabled public String asOfDate { get; set; }

        public MonthlyCombinedWrapper(List<MonthlyBillableSummary> pw2Summaries, List<MonthlyBillableSummary> hw2Summaries, String asOfDate) {
            this.pw2Summaries = pw2Summaries;
            this.hw2Summaries = hw2Summaries;
            this.asOfDate = asOfDate;
        }
    }

    // Intermediate holder for the raw per-employee-per-week maps used by the fixed
    // 5-week path.
    private class ParsedRawData {
        Set<String> allFullNames = new Set<String>();
        Map<String, Map<String, Decimal>> rawHoursData = new Map<String, Map<String, Decimal>>();
        Map<String, Map<String, Decimal>> raw15hSegmentsData = new Map<String, Map<String, Decimal>>();
        Map<String, Map<String, Decimal>> raw24hSegmentsData = new Map<String, Map<String, Decimal>>();
        Map<String, Map<String, Decimal>> rawAplHoursData = new Map<String, Map<String, Decimal>>();
        Map<String, Map<String, Decimal>> rawHolidayHoursData = new Map<String, Map<String, Decimal>>();
        Map<String, String> userToEmployeeIdMap = new Map<String, String>();
        Map<String, String> userToProfileMap = new Map<String, String>();
        Map<String, String> userToTerminationDateMap = new Map<String, String>();
        Set<String> employeeIds = new Set<String>();
    }

    // Intermediate holder for the raw per-employee date-bucketed totals used by the
    // monthly path.
    private class MonthlyParsedData {
        Set<String> allFullNames = new Set<String>();
        Map<String, Decimal> currentMonthHours = new Map<String, Decimal>();
        Map<String, Decimal> lastMonthToDateHours = new Map<String, Decimal>();
        Map<String, Decimal> lastMonthTotalHours = new Map<String, Decimal>();
        Map<String, Decimal> currentMonthAplHours = new Map<String, Decimal>();
        Map<String, Decimal> lastMonthToDateAplHours = new Map<String, Decimal>();
        Map<String, Decimal> lastMonthTotalAplHours = new Map<String, Decimal>();
        Map<String, String> userToEmployeeIdMap = new Map<String, String>();
        Map<String, String> userToProfileMap = new Map<String, String>();
        Set<String> employeeIds = new Set<String>();
    }

    // --- Credential Loading ---

    private static String API_KEY;
    private static String LOGIN_USERNAME;
    private static String LOGIN_PASSWORD;
    private static String COMPANY_SHORT_NAME; // Store Company Short Name here
    // Catch-all report covering both PW2 and HW2/1099 profiles in one call.
    private static final String REPORT_ID = '124935578';
    // 70 days safely covers "current month + previous month" under any day-of-month
    // starting point (worst case ~62 days).
    private static final Integer MONTHLY_DAY_COUNT = 70;

    // TimesheetProfile values (trailing CSV column, before Counter Date) that identify
    // a row's employee type. Per UKG's data model this is assigned per employee, not
    // per row/activity, so a given associate's rows should all carry the same value.
    private static final String PROFILE_PW2_APL = 'Billable Recording Time - APL';
    private static final String PROFILE_PW2_VACATION_SICK = 'Billable Recording Time - Vacation/Sick';
    private static final String PROFILE_1099 = '1099 Contractors and Hourly W-2s';

    private static Boolean isPw2Profile(String profile) {
        return profile == PROFILE_PW2_APL || profile == PROFILE_PW2_VACATION_SICK;
    }

    private static Boolean is1099Profile(String profile) {
        return profile == PROFILE_1099;
    }

    // Activity Code 217 is non-billable time that happens to land in this billable-
    // hours report; it must never count toward billable-hours totals (weekly,
    // monthly, or Billable Hours / Billable Day). Matched with startsWith, the same
    // way the 177-15/177-24 on-call segment codes are, since a base code can carry a
    // "-XX" variant suffix.
    private static Boolean isCode217(String activityCode) {
        return activityCode != null && activityCode.startsWith('217');
    }

    private static void loadCredentials() {
        if (API_KEY == null) {
            // SAFE CMDT QUERY
            List<UKG_Integration_Settings__mdt> settingsList =
                [SELECT Api_Key__c, Login_Username__c, Login_Password__c, Company_Short_Name__c
                 FROM UKG_Integration_Settings__mdt
                 WHERE DeveloperName = 'ukgLogin'
                 LIMIT 1];

            if (settingsList.isEmpty()) {
                throw new AuraHandledException('Configuration Error: UKG Integration Settings CMDT record "ukgLogin" not found. Please create it in Setup.');
            }

            UKG_Integration_Settings__mdt settings = settingsList[0];
            API_KEY = settings.Api_Key__c;
            LOGIN_USERNAME = settings.Login_Username__c;
            LOGIN_PASSWORD = settings.Login_Password__c;
            COMPANY_SHORT_NAME = settings.Company_Short_Name__c;
        }
    }

    /**
     * Helper method to consistently calculate the 5 most recent Saturday week-end dates.
     */
    private static List<Date> calculateTargetWeekEnds() {
        List<Date> targetWeekEnds = new List<Date>();
        Date mostRecentSaturday = calculateMostRecentSaturday();

        for (Integer i = 0; i < 5; i++) {
            targetWeekEnds.add(mostRecentSaturday.addDays(-7 * i));
        }
        return targetWeekEnds;
    }

    /**
     * Returns the most recently COMPLETED Saturday (today's Saturday counts as
     * complete if today IS Saturday). Associates often submit time late in the week,
     * so this is the same "don't trust the in-progress week" anchor used by the
     * weekly 5-Saturday window, reused here as the upper bound for the monthly view
     * so Current Month never includes a still-in-progress week's partial data.
     */
    private static Date calculateMostRecentSaturday() {
        Date today = Date.today();
        Date sundayRef = today.toStartOfWeek();
        Integer daysSinceSunday = sundayRef.daysBetween(today);
        Integer daysToSubtract = (daysSinceSunday == 6) ? 0 : (daysSinceSunday + 1);
        return today.addDays(-daysToSubtract);
    }

    /**
     * The "Current Month" anchor date: normally the last completed Saturday, but
     * rolled back to the last day of the previous month if fewer than 7 days have
     * elapsed in the new month (so Current Month doesn't show an almost-empty new
     * month with no complete week in it yet - the previous month, by contrast, is
     * fully complete).
     */
    private static Date calculateReferenceAsOfDate() {
        Date today = Date.today();
        Date asOfDate = calculateMostRecentSaturday();
        Date startOfCurrentMonth = Date.newInstance(today.year(), today.month(), 1);
        // Roll back to the previous month (fully) unless the most recent completed
        // Saturday both falls in the new month AND is past its first week (day > 7).
        // A Saturday on day 1-7 means the most recent complete week is still
        // mostly/entirely in the previous month, so the new month shouldn't count as
        // "Current Month" yet.
        if (asOfDate >= startOfCurrentMonth && asOfDate.day() > 7) {
            return asOfDate;
        }
        return startOfCurrentMonth.addDays(-1);
    }

    private static String formatAsOfDate(Date d) {
        return DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0)).format('yyyy-MM-dd');
    }

    private static List<String> formatHeaderDates(List<Date> targetWeekEnds) {
        List<String> headerDates = new List<String>();
        for (Date d : targetWeekEnds) {
            headerDates.add(DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0)).format('yyyy-MM-dd'));
        }
        return headerDates;
    }

    /**
     * Retrieves grouped billable hours entries for PW2 only.
     * Preserves the original contract for ukgBillableHoursW2Tracker.
     */
    @AuraEnabled
    public static BenchTimeWrapper getTimeEntries(Id contactId) {
        CombinedBillableHoursWrapper combined = getAllTimeEntries(contactId);
        return new BenchTimeWrapper(combined.pw2Summaries, combined.weekEndDates);
    }

    /**
     * Retrieves grouped billable hours entries for BOTH PW2 and HW2/1099 in one
     * UKG callout, split via the report's TimesheetProfile column. 5-week window.
     */
    @AuraEnabled
    public static CombinedBillableHoursWrapper getAllTimeEntries(Id contactId) {
        loadCredentials();

        if (String.isBlank(COMPANY_SHORT_NAME)) {
            throw new AuraHandledException('Configuration Error: Company Short Name is missing from UKG Integration Settings CMDT record.');
        }

        String employeeId = null;

        if (contactId != null) {
            try {
                Contact c = [SELECT UKG_Employee_ID__c FROM Contact WHERE Id = :contactId LIMIT 1];
                employeeId = c.UKG_Employee_ID__c;
            } catch (Exception e) {
                System.debug('Failed to query Contact for UKG_Employee_ID__c: ' + e.getMessage());
            }

            if (String.isBlank(employeeId)) {
                System.debug('Running on Contact Page, but UKG_Employee_ID__c is blank. Returning empty data.');
                return new CombinedBillableHoursWrapper(new List<UserWeeklyBillableSummary>(), new List<UserWeeklyBillableSummary>(), formatHeaderDates(calculateTargetWeekEnds()));
            }
        }

        String bearerToken = generateUkgToken(COMPANY_SHORT_NAME);
        String csvBody = executeReportCallout(bearerToken, COMPANY_SHORT_NAME, employeeId, false);
        return groupBenchTime(csvBody);
    }

    /**
     * Retrieves grouped billable hours entries for BOTH PW2 and HW2/1099 over a wider
     * (70-day) window, bucketed into Current Month / Last Month To Date / Last Month
     * Total per associate via the report's Counter Date column.
     */
    @AuraEnabled
    public static MonthlyCombinedWrapper getMonthlyTimeEntries(Id contactId) {
        loadCredentials();

        if (String.isBlank(COMPANY_SHORT_NAME)) {
            throw new AuraHandledException('Configuration Error: Company Short Name is missing from UKG Integration Settings CMDT record.');
        }

        String employeeId = null;

        if (contactId != null) {
            try {
                Contact c = [SELECT UKG_Employee_ID__c FROM Contact WHERE Id = :contactId LIMIT 1];
                employeeId = c.UKG_Employee_ID__c;
            } catch (Exception e) {
                System.debug('Failed to query Contact for UKG_Employee_ID__c: ' + e.getMessage());
            }

            if (String.isBlank(employeeId)) {
                System.debug('Running on Contact Page, but UKG_Employee_ID__c is blank. Returning empty data.');
                return new MonthlyCombinedWrapper(new List<MonthlyBillableSummary>(), new List<MonthlyBillableSummary>(), formatAsOfDate(calculateReferenceAsOfDate()));
            }
        }

        String bearerToken = generateUkgToken(COMPANY_SHORT_NAME);
        String csvBody = executeReportCallout(bearerToken, COMPANY_SHORT_NAME, employeeId, true);
        return groupBenchTimeMonthly(csvBody);
    }

    /**
     * Executes the login call to UKG to retrieve a new Bearer Token.
     */
    private static String generateUkgToken(String companyShortName) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();

        request.setEndpoint('callout:UKG_BASE_API/ta/rest/v1/login');
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Accept', 'application/json');
        request.setHeader('api-key', API_KEY);

        String loginPayload = JSON.serialize(new Map<String, Object>{
            'credentials' => new Map<String, String>{
                'username' => LOGIN_USERNAME,
                'password' => LOGIN_PASSWORD,
                'company' => companyShortName
            }
        });
        request.setBody(loginPayload);
        request.setTimeout(60000);

        try {
            HttpResponse response = http.send(request);

            if (response.getStatusCode() == 200) {
                Map<String, Object> responseMap = (Map<String, Object>)JSON.deserializeUntyped(response.getBody());
                String token = (String)responseMap.get('token');

                if (String.isBlank(token)) {
                      throw new AuraHandledException('UKG Login failed: Token field is missing from response.');
                }
                return token;
            } else {
                System.debug('UKG Login Error: Status Code ' + response.getStatusCode() + ', Body: ' + response.getBody());
                throw new AuraHandledException('Error generating UKG Token: ' + response.getStatus());
            }

        } catch (Exception e) {
            System.debug('Login Callout Error: ' + e.getMessage());
            throw new AuraHandledException('UKG Login Callout failed: Check network or credentials.');
        }
    }

    /**
     * Executes the report call to UKG and returns the raw CSV body.
     * extendedRange controls whether the wider (70-day) selectors block is sent.
     */
    private static String executeReportCallout(String bearerToken, String companyShortName, String employeeId, Boolean extendedRange) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();

        request.setEndpoint('callout:UKG_BASE_API/ta/rest/v1/report/saved/' + REPORT_ID + '/');
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Accept', 'text/csv');
        request.setHeader('Authorization', 'Bearer ' + bearerToken);

        request.setBody(constructRequestBody(companyShortName, employeeId, extendedRange));
        request.setTimeout(60000);

        try {
            HttpResponse response = http.send(request);

            if (response.getStatusCode() == 200) {
                return response.getBody();
            } else {
                String errorBody = response.getBody();
                System.debug('UKG Report Error: Status Code ' + response.getStatusCode() + ', Body: ' + errorBody);

                if (response.getStatusCode() == 503) {
                    throw new AuraHandledException('UKG Error: Service Unavailable. Please try again later.');
                }
                if (response.getStatusCode() == 400) {
                    throw new AuraHandledException('UKG Report API Bad Request (400). Response Body: ' + (String.isNotBlank(errorBody) ? errorBody : 'No error body received.'));
                }
                if (response.getStatusCode() == 403) {
                    throw new AuraHandledException('UKG Error: Forbidden (403). Insufficient permissions on the Bearer Token to access report.');
                }

                throw new AuraHandledException('Error calling UKG Report API: ' + response.getStatus());
            }

        } catch (System.CalloutException e) {
            System.debug('Report Callout Error: ' + e.getMessage());
            throw new AuraHandledException('Report Callout failed: Check Named Credential configuration.');
        }
    }

    /**
     * Builds the JSON payload for the UKG report request.
     * Conditionally includes the EmplEmployeeIdNum filter, and, when extendedRange is
     * true, a selectors block widening the report window to MONTHLY_DAY_COUNT days
     * (Sunday-start weeks, per the report's WeekDay selector).
     */
    private static String constructRequestBody(String companyShortName, String employeeId, Boolean extendedRange) {

        Map<String, Object> payload = new Map<String, Object>{
            'company' => new Map<String, String>{
                'short_name' => companyShortName
            }
        };

        if (String.isNotBlank(employeeId)) {
            payload.put('filters', new List<Object>{
                new Map<String, Object>{
                    'field_name' => 'EmplEmployeeIdNum', // UKG filter field for Employee ID
                    'operator' => '=',
                    'values' => new List<String>{
                        employeeId
                    }
                }
            });
        }

        if (extendedRange) {
            payload.put('selectors', new List<Object>{
                new Map<String, Object>{
                    'type' => 'Date',
                    'name' => 'TACounterRecordDate',
                    'parameters' => new Map<String, String>{
                        'RangeType' => '1',
                        'CalendarType' => '40',
                        'CalendarNDays' => String.valueOf(MONTHLY_DAY_COUNT),
                        'CalendarNDaysIncludeToday' => '0'
                    }
                },
                new Map<String, Object>{
                    'type' => 'WeekDay',
                    'name' => 'FirstWeekDay',
                    'parameters' => new Map<String, String>{
                        'WeekDay' => '1'
                    }
                }
            });
        }

        return JSON.serialize(payload);
    }

    /**
     * Safely parses a trimmed CSV cell into a Decimal, handling blanks/dashes/bad data as 0.
     */
    private static Decimal parseDecimalSafe(String rawValue) {
        String trimmed = rawValue != null ? rawValue.trim() : '';
        if (String.isBlank(trimmed) || trimmed == '-') {
            return 0.0;
        }
        try {
            return Decimal.valueOf(trimmed);
        } catch (TypeException te) {
            System.debug('Warning: Skipping invalid numeric format: ' + trimmed);
            return 0.0;
        }
    }

    /**
     * Safely parses an MM/DD/YYYY cell into a Date, returning null on any failure.
     */
    private static Date parseDateSafe(String rawValue) {
        if (String.isBlank(rawValue)) {
            return null;
        }
        List<String> dateParts = rawValue.trim().split('/');
        if (dateParts.size() != 3) {
            return null;
        }
        try {
            Integer month = Integer.valueOf(dateParts[0].trim());
            Integer day = Integer.valueOf(dateParts[1].trim());
            Integer year = Integer.valueOf(dateParts[2].trim());
            return Date.newInstance(year, month, day);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Splits a large CSV blob into lines without using regex. String.split() runs the
     * whole input through the regex engine, which can throw "Regex too complicated"
     * once the CSV gets large enough (e.g. the 70-day monthly pull, or a report whose
     * grain is now per-day) - indexOf/substring avoids that entirely.
     */
    private static List<String> splitLines(String data) {
        List<String> lines = new List<String>();
        if (data == null) {
            return lines;
        }
        Integer start = 0;
        Integer idx = data.indexOf('\n');
        while (idx != -1) {
            lines.add(data.substring(start, idx));
            start = idx + 1;
            idx = data.indexOf('\n', start);
        }
        if (start < data.length()) {
            lines.add(data.substring(start));
        }
        return lines;
    }

    private static Map<String, Id> resolveContactIds(Set<String> employeeIds) {
        Map<String, Id> employeeIdToContactIdMap = new Map<String, Id>();
        if (!employeeIds.isEmpty()) {
            System.debug('UKG Integration (W2): Found Employee IDs to query: ' + employeeIds);
            for (Contact c : [SELECT Id, UKG_Employee_ID__c FROM Contact WHERE UKG_Employee_ID__c IN :employeeIds AND UKG_Employee_ID__c != null LIMIT 50000]) {
                employeeIdToContactIdMap.put(c.UKG_Employee_ID__c, c.Id);
            }
            System.debug('UKG Integration (W2): Contact matches found: ' + employeeIdToContactIdMap.size());
        } else {
            System.debug('UKG Integration (W2): No Employee IDs found in report to query.');
        }
        return employeeIdToContactIdMap;
    }

    /**
     * Parses the CSV response string into raw per-employee-per-week maps, gated to the
     * given target week-end dates. Used by the fixed 5-week path.
     */
    private static ParsedRawData parseCsvRows(String csvData, List<Date> targetWeekEnds) {
        List<String> lines = splitLines(csvData);
        ParsedRawData raw = new ParsedRawData();

        for (Integer i = 1; i < lines.size(); i++) {
            String line = lines[i];
            if (String.isNotBlank(line)) {
                String cleanLine = line.replace('\"', '');
                List<String> values = cleanLine.split(',');

                if (values.size() >= 6) {

                    String lastName = values[0].trim();
                    String firstName = values[1].trim();
                    String fullName = (String.isNotBlank(lastName) ? lastName : '') + ', ' + (String.isNotBlank(firstName) ? firstName : '');
                    fullName = fullName.trim().removeEnd(',');

                    if (String.isBlank(fullName)) continue;

                    try {
                        String weekEndStr = values[3].trim();     // Index 3: Week End (MM/DD/YYYY format)
                        String rawHours = values[4].trim();
                        Decimal hours = 0.0;

                        if (String.isNotBlank(rawHours) && rawHours != '-') {
                            try {
                                hours = Decimal.valueOf(rawHours);
                            } catch (TypeException te) {
                                System.debug('Warning: Skipping invalid numeric format for hours: ' + rawHours);
                                hours = 0.0;
                            }
                        }

                        String employeeId = values[5].trim();     // Index 5: Employee ID

                        String activityCode = '';
                        if (values.size() >= 7) {
                            activityCode = values[6].trim();
                        } else {
                            activityCode = values[2].trim();
                        }

                        Date weekEndDate = parseDateSafe(weekEndStr);
                        if (weekEndDate == null) {
                            System.debug('ERROR: Invalid date format in CSV line: ' + weekEndStr);
                            continue;
                        }

                        if (!targetWeekEnds.contains(weekEndDate)) {
                            continue;
                        }

                        if (String.isNotBlank(employeeId)) {
                            raw.userToEmployeeIdMap.put(fullName, employeeId);
                            raw.employeeIds.add(employeeId);
                        }

                        raw.allFullNames.add(fullName);

                        // TimesheetProfile: index 9, appended after Holiday Hours. Assigned per
                        // employee (not per row), so the last value seen for this name is used.
                        if (values.size() >= 10) {
                            String profile = values[9].trim();
                            if (String.isNotBlank(profile)) {
                                raw.userToProfileMap.put(fullName, profile);
                            }
                        }

                        // Date Terminated: index 11, appended after Counter Date. Assigned per
                        // employee (blank for active associates), so the last non-blank value
                        // seen for this name is used.
                        if (values.size() >= 12) {
                            Date terminationDate = parseDateSafe(values[11]);
                            if (terminationDate != null) {
                                raw.userToTerminationDateMap.put(fullName, formatAsOfDate(terminationDate));
                            }
                        }

                        Boolean is15h = activityCode.startsWith('177-15');
                        Boolean is24h = activityCode.startsWith('177-24');

                        if (is15h) {
                            if (!raw.raw15hSegmentsData.containsKey(fullName)) {
                                raw.raw15hSegmentsData.put(fullName, new Map<String, Decimal>());
                            }
                            Map<String, Decimal> weekMap = raw.raw15hSegmentsData.get(fullName);
                            Decimal currentCount = weekMap.containsKey(weekEndDate.format()) ? weekMap.get(weekEndDate.format()) : 0;
                            weekMap.put(weekEndDate.format(), currentCount + hours);
                        } else if (is24h) {
                            if (!raw.raw24hSegmentsData.containsKey(fullName)) {
                                raw.raw24hSegmentsData.put(fullName, new Map<String, Decimal>());
                            }
                            Map<String, Decimal> weekMap = raw.raw24hSegmentsData.get(fullName);
                            Decimal currentCount = weekMap.containsKey(weekEndDate.format()) ? weekMap.get(weekEndDate.format()) : 0;
                            weekMap.put(weekEndDate.format(), currentCount + hours);
                        } else if (!isCode217(activityCode)) {
                            // Code 217 rows are dropped here entirely - not billable hours,
                            // not an on-call segment, so they contribute nothing to any total.
                            if (!raw.rawHoursData.containsKey(fullName)) {
                                raw.rawHoursData.put(fullName, new Map<String, Decimal>());
                            }
                            Map<String, Decimal> weekMap = raw.rawHoursData.get(fullName);
                            Decimal currentHours = weekMap.containsKey(weekEndDate.format()) ? weekMap.get(weekEndDate.format()) : 0.0;
                            weekMap.put(weekEndDate.format(), currentHours + hours);
                        }

                        // Time Off columns: APL (index 7) then Holiday (index 8), appended after
                        // Activity Code. Parsed independently of the activity code branching above -
                        // guarded by values.size() so this stays backward-compatible.
                        if (values.size() >= 8) {
                            Decimal aplHours = parseDecimalSafe(values[7]);
                            if (aplHours != 0) {
                                if (!raw.rawAplHoursData.containsKey(fullName)) {
                                    raw.rawAplHoursData.put(fullName, new Map<String, Decimal>());
                                }
                                Map<String, Decimal> aplWeekMap = raw.rawAplHoursData.get(fullName);
                                Decimal currentApl = aplWeekMap.containsKey(weekEndDate.format()) ? aplWeekMap.get(weekEndDate.format()) : 0.0;
                                aplWeekMap.put(weekEndDate.format(), currentApl + aplHours);
                            }
                        }
                        if (values.size() >= 9) {
                            Decimal holidayHours = parseDecimalSafe(values[8]);
                            if (holidayHours != 0) {
                                if (!raw.rawHolidayHoursData.containsKey(fullName)) {
                                    raw.rawHolidayHoursData.put(fullName, new Map<String, Decimal>());
                                }
                                Map<String, Decimal> holidayWeekMap = raw.rawHolidayHoursData.get(fullName);
                                Decimal currentHoliday = holidayWeekMap.containsKey(weekEndDate.format()) ? holidayWeekMap.get(weekEndDate.format()) : 0.0;
                                holidayWeekMap.put(weekEndDate.format(), currentHoliday + holidayHours);
                            }
                        }

                    } catch (Exception e) {
                        System.debug('Error parsing hours/date/ID for row: ' + e.getMessage() + ' - Line: ' + line);
                    }
                }
            }
        }

        return raw;
    }

    /**
     * Groups billable hours data by user over the 5 fixed weeks, splitting each associate
     * into the PW2 or HW2/1099 bucket via their TimesheetProfile.
     */
    private static CombinedBillableHoursWrapper groupBenchTime(String csvData) {
        List<Date> targetWeekEnds = calculateTargetWeekEnds();
        ParsedRawData raw = parseCsvRows(csvData, targetWeekEnds);
        Map<String, Id> employeeIdToContactIdMap = resolveContactIds(raw.employeeIds);
        List<String> headerDates = formatHeaderDates(targetWeekEnds);

        List<UserWeeklyBillableSummary> pw2SummaryList = new List<UserWeeklyBillableSummary>();
        List<UserWeeklyBillableSummary> hw2SummaryList = new List<UserWeeklyBillableSummary>();

        for (String userName : raw.allFullNames) {
            UserWeeklyBillableSummary summary = new UserWeeklyBillableSummary();
            summary.userName = userName;

            String employeeId = raw.userToEmployeeIdMap.get(userName);
            if (String.isNotBlank(employeeId) && employeeIdToContactIdMap.containsKey(employeeId)) {
                 summary.contactId = employeeIdToContactIdMap.get(employeeId);
            } else {
                 summary.contactId = null;
            }

            summary.terminationDate = raw.userToTerminationDateMap.get(userName);

            Map<String, Decimal> userHours = raw.rawHoursData.containsKey(userName) ? raw.rawHoursData.get(userName) : new Map<String, Decimal>();
            Map<String, Decimal> user15h = raw.raw15hSegmentsData.containsKey(userName) ? raw.raw15hSegmentsData.get(userName) : new Map<String, Decimal>();
            Map<String, Decimal> user24h = raw.raw24hSegmentsData.containsKey(userName) ? raw.raw24hSegmentsData.get(userName) : new Map<String, Decimal>();
            Map<String, Decimal> userApl = raw.rawAplHoursData.containsKey(userName) ? raw.rawAplHoursData.get(userName) : new Map<String, Decimal>();
            Map<String, Decimal> userHoliday = raw.rawHolidayHoursData.containsKey(userName) ? raw.rawHolidayHoursData.get(userName) : new Map<String, Decimal>();

            Decimal totalHours = 0.0;
            Decimal total15 = 0.0;
            Decimal total24 = 0.0;
            Decimal totalApl = 0.0;
            Decimal totalHoliday = 0.0;

            for (Integer i = 0; i < 5; i++) {
                String targetDateStr = targetWeekEnds[i].format();
                Decimal hours = userHours.containsKey(targetDateStr) ? userHours.get(targetDateStr) : 0.0;
                Decimal count15 = user15h.containsKey(targetDateStr) ? user15h.get(targetDateStr) : 0;
                Decimal count24 = user24h.containsKey(targetDateStr) ? user24h.get(targetDateStr) : 0;
                Decimal aplHours = userApl.containsKey(targetDateStr) ? userApl.get(targetDateStr) : 0.0;
                Decimal holidayHours = userHoliday.containsKey(targetDateStr) ? userHoliday.get(targetDateStr) : 0.0;

                totalHours += hours;
                total15 += count15;
                total24 += count24;
                totalApl += aplHours;
                totalHoliday += holidayHours;

                if (i == 0) {
                    summary.w1Hours = hours;
                    summary.w1_15hSegments = count15;
                    summary.w1_24hSegments = count24;
                    summary.w1_aplHours = aplHours;
                    summary.w1_holidayHours = holidayHours;
                }
                if (i == 1) {
                    summary.w2Hours = hours;
                    summary.w2_15hSegments = count15;
                    summary.w2_24hSegments = count24;
                    summary.w2_aplHours = aplHours;
                    summary.w2_holidayHours = holidayHours;
                }
                if (i == 2) {
                    summary.w3Hours = hours;
                    summary.w3_15hSegments = count15;
                    summary.w3_24hSegments = count24;
                    summary.w3_aplHours = aplHours;
                    summary.w3_holidayHours = holidayHours;
                }
                if (i == 3) {
                    summary.w4Hours = hours;
                    summary.w4_15hSegments = count15;
                    summary.w4_24hSegments = count24;
                    summary.w4_aplHours = aplHours;
                    summary.w4_holidayHours = holidayHours;
                }
                if (i == 4) {
                    summary.w5Hours = hours;
                    summary.w5_15hSegments = count15;
                    summary.w5_24hSegments = count24;
                    summary.w5_aplHours = aplHours;
                    summary.w5_holidayHours = holidayHours;
                }
            }

            summary.total5WeekHours = totalHours;
            summary.total15hSegments = total15;
            summary.total24hSegments = total24;
            summary.total5WeekAplHours = totalApl;
            summary.total5WeekHolidayHours = totalHoliday;

            String profile = raw.userToProfileMap.get(userName);
            if (isPw2Profile(profile)) {
                pw2SummaryList.add(summary);
            } else if (is1099Profile(profile)) {
                hw2SummaryList.add(summary);
            } else {
                System.debug('UKG Integration: Unrecognized TimesheetProfile "' + profile + '" for ' + userName + ' - excluded from both PW2 and HW2/1099 buckets.');
            }
        }

        return new CombinedBillableHoursWrapper(pw2SummaryList, hw2SummaryList, headerDates);
    }

    /**
     * Parses the CSV response string into date-precise Current Month / Last Month To
     * Date / Last Month Total buckets per employee, using the report's Counter Date
     * column (the actual date the time was logged) rather than the week-end date.
     */
    private static MonthlyParsedData parseCsvRowsForMonthly(String csvData) {
        List<String> lines = splitLines(csvData);
        MonthlyParsedData raw = new MonthlyParsedData();

        // referenceAsOfDate is the upper bound for "Current Month" below (the last
        // completed Saturday, or the previous month's last day if we're less than a
        // full week into the new month - see calculateReferenceAsOfDate). Associates
        // submit time late in the week, so an in-progress week would otherwise
        // understate Current Month with partial data.
        Date referenceAsOfDate = calculateReferenceAsOfDate();
        Date referenceMonthStart = Date.newInstance(referenceAsOfDate.year(), referenceAsOfDate.month(), 1);
        Date startOfLastMonth = referenceMonthStart.addMonths(-1);
        Date endOfLastMonth = referenceMonthStart.addDays(-1);
        Integer daysInLastMonth = Date.daysInMonth(startOfLastMonth.year(), startOfLastMonth.month());
        Integer cutoffDay = Math.min(referenceAsOfDate.day(), daysInLastMonth);
        Date lastMonthToDateCutoff = Date.newInstance(startOfLastMonth.year(), startOfLastMonth.month(), cutoffDay);

        for (Integer i = 1; i < lines.size(); i++) {
            String line = lines[i];
            if (String.isNotBlank(line)) {
                String cleanLine = line.replace('\"', '');
                List<String> values = cleanLine.split(',');

                // Needs the new Counter Date column appended after TimesheetProfile (index 10).
                if (values.size() >= 11) {

                    String lastName = values[0].trim();
                    String firstName = values[1].trim();
                    String fullName = (String.isNotBlank(lastName) ? lastName : '') + ', ' + (String.isNotBlank(firstName) ? firstName : '');
                    fullName = fullName.trim().removeEnd(',');

                    if (String.isBlank(fullName)) continue;

                    try {
                        Date counterDate = parseDateSafe(values[10]);
                        if (counterDate == null) {
                            System.debug('ERROR: Invalid Counter Date format: ' + values[10]);
                            continue;
                        }

                        if (counterDate < startOfLastMonth || counterDate > referenceAsOfDate) {
                            continue; // outside the range we care about
                        }

                        Decimal hours = parseDecimalSafe(values[4]);
                        String employeeId = values[5].trim();
                        String activityCode = values[6].trim();
                        Decimal aplHours = parseDecimalSafe(values[7]);

                        if (String.isNotBlank(employeeId)) {
                            raw.userToEmployeeIdMap.put(fullName, employeeId);
                            raw.employeeIds.add(employeeId);
                        }
                        raw.allFullNames.add(fullName);

                        String profile = values[9].trim();
                        if (String.isNotBlank(profile)) {
                            raw.userToProfileMap.put(fullName, profile);
                        }

                        // Exclude on-call segment rows and Code 217 (non-billable) rows from
                        // "billable hours" (matches the weekly view's w1Hours definition).
                        // Holiday rows already carry 0 in the Regular Hours column by
                        // construction, so no separate check needed.
                        Boolean isOnCall = activityCode.startsWith('177-15') || activityCode.startsWith('177-24');
                        Decimal billableHours = (isOnCall || isCode217(activityCode)) ? 0.0 : hours;

                        Boolean inCurrentMonth = counterDate >= referenceMonthStart && counterDate <= referenceAsOfDate;
                        Boolean inLastMonthTotal = counterDate >= startOfLastMonth && counterDate <= endOfLastMonth;
                        Boolean inLastMonthToDate = inLastMonthTotal && counterDate <= lastMonthToDateCutoff;

                        if (inCurrentMonth) {
                            raw.currentMonthHours.put(fullName, (raw.currentMonthHours.containsKey(fullName) ? raw.currentMonthHours.get(fullName) : 0.0) + billableHours);
                            raw.currentMonthAplHours.put(fullName, (raw.currentMonthAplHours.containsKey(fullName) ? raw.currentMonthAplHours.get(fullName) : 0.0) + aplHours);
                        }
                        if (inLastMonthTotal) {
                            raw.lastMonthTotalHours.put(fullName, (raw.lastMonthTotalHours.containsKey(fullName) ? raw.lastMonthTotalHours.get(fullName) : 0.0) + billableHours);
                            raw.lastMonthTotalAplHours.put(fullName, (raw.lastMonthTotalAplHours.containsKey(fullName) ? raw.lastMonthTotalAplHours.get(fullName) : 0.0) + aplHours);
                        }
                        if (inLastMonthToDate) {
                            raw.lastMonthToDateHours.put(fullName, (raw.lastMonthToDateHours.containsKey(fullName) ? raw.lastMonthToDateHours.get(fullName) : 0.0) + billableHours);
                            raw.lastMonthToDateAplHours.put(fullName, (raw.lastMonthToDateAplHours.containsKey(fullName) ? raw.lastMonthToDateAplHours.get(fullName) : 0.0) + aplHours);
                        }

                    } catch (Exception e) {
                        System.debug('Error parsing monthly row: ' + e.getMessage() + ' - Line: ' + line);
                    }
                }
            }
        }

        return raw;
    }

    /**
     * Groups billable hours data by user into Current Month / Last Month To Date /
     * Last Month Total buckets, splitting each associate into the PW2 or HW2/1099
     * bucket via their TimesheetProfile.
     */
    private static MonthlyCombinedWrapper groupBenchTimeMonthly(String csvData) {
        MonthlyParsedData raw = parseCsvRowsForMonthly(csvData);
        Map<String, Id> employeeIdToContactIdMap = resolveContactIds(raw.employeeIds);

        List<MonthlyBillableSummary> pw2List = new List<MonthlyBillableSummary>();
        List<MonthlyBillableSummary> hw2List = new List<MonthlyBillableSummary>();

        for (String userName : raw.allFullNames) {
            MonthlyBillableSummary summary = new MonthlyBillableSummary();
            summary.userName = userName;

            String employeeId = raw.userToEmployeeIdMap.get(userName);
            summary.contactId = (String.isNotBlank(employeeId) && employeeIdToContactIdMap.containsKey(employeeId))
                ? employeeIdToContactIdMap.get(employeeId)
                : null;

            summary.currentMonthHours = raw.currentMonthHours.containsKey(userName) ? raw.currentMonthHours.get(userName) : 0.0;
            summary.lastMonthToDateHours = raw.lastMonthToDateHours.containsKey(userName) ? raw.lastMonthToDateHours.get(userName) : 0.0;
            summary.lastMonthTotalHours = raw.lastMonthTotalHours.containsKey(userName) ? raw.lastMonthTotalHours.get(userName) : 0.0;
            summary.currentMonthAplHours = raw.currentMonthAplHours.containsKey(userName) ? raw.currentMonthAplHours.get(userName) : 0.0;
            summary.lastMonthToDateAplHours = raw.lastMonthToDateAplHours.containsKey(userName) ? raw.lastMonthToDateAplHours.get(userName) : 0.0;
            summary.lastMonthTotalAplHours = raw.lastMonthTotalAplHours.containsKey(userName) ? raw.lastMonthTotalAplHours.get(userName) : 0.0;

            String profile = raw.userToProfileMap.get(userName);
            if (isPw2Profile(profile)) {
                pw2List.add(summary);
            } else if (is1099Profile(profile)) {
                hw2List.add(summary);
            } else {
                System.debug('UKG Integration: Unrecognized TimesheetProfile "' + profile + '" for ' + userName + ' - excluded from both buckets (monthly).');
            }
        }

        return new MonthlyCombinedWrapper(pw2List, hw2List, formatAsOfDate(calculateReferenceAsOfDate()));
    }
} //final code
