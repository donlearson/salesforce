/**
 * UkgDataController
 * * Handles dynamic login to UKG to retrieve a Bearer Token, and then uses that
 * token to securely call the UKG Bench Time Report (124135110).
 * * This version hard-codes the 5 most recent SATURDAY week-end dates to ensure 
 * consistent column headers, inserting 0.0 for weeks where a user has no data.
 * * **NEW:** Conditionally filters the report by Contact's UKG_Employee_ID__c when 
 * running on a Contact record page.
 */
public with sharing class UkgDataController {

    // --- Inner Classes for Data Transfer and Aggregation ---
    
    // Wrapper class to send the list of summaries and the dynamic column headers to the LWC
    public class BenchTimeWrapper {
        @AuraEnabled public List<UserWeeklyBenchSummary> summaries { get; set; }
        // The 5 week-end dates (Saturdays) found in the report. Index 0 is W1 (most recent).
        @AuraEnabled public List<String> weekEndDates { get; set; } 

        // Explicit constructor
        public BenchTimeWrapper(List<UserWeeklyBenchSummary> summaries, List<String> weekEndDates) {
            this.summaries = summaries;
            this.weekEndDates = weekEndDates;
        }
    }

    public class UserWeeklyBenchSummary {
        @AuraEnabled public String userName { get; set; }
        @AuraEnabled public String contactId { get; set; } // Salesforce Contact Id
        // These fields will hold the aggregated hours for the last 5 weeks (W1 = Most Recent)
        @AuraEnabled public Decimal w1Hours { get; set; } 
        @AuraEnabled public Decimal w2Hours { get; set; }
        @AuraEnabled public Decimal w3Hours { get; set; }
        @AuraEnabled public Decimal w4Hours { get; set; }
        @AuraEnabled public Decimal w5Hours { get; set; }
        @AuraEnabled public Decimal total5WeekHours { get; set; }
        
        public UserWeeklyBenchSummary() {
            w1Hours = 0.0; w2Hours = 0.0; w3Hours = 0.0; w4Hours = 0.0; w5Hours = 0.0; total5WeekHours = 0.0;
        }
    }

    // --- Credential Loading ---

    private static String API_KEY; 
    private static String LOGIN_USERNAME;
    private static String LOGIN_PASSWORD;
    private static String COMPANY_SHORT_NAME; // Store Company Short Name here
    private static final String REPORT_ID = '124135110'; 

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
     * Helper method to consistently calculate the 5 target Saturday week-end dates.
     */
    private static List<Date> calculateTargetWeekEnds() {
        List<Date> targetWeekEnds = new List<Date>();
        Date today = Date.today();
        
        Date sundayRef = today.toStartOfWeek(); 
        Integer daysSinceSunday = sundayRef.daysBetween(today); 
        Integer daysToSubtract = (daysSinceSunday == 6) ? 0 : (daysSinceSunday + 1);
        Date mostRecentSaturday = today.addDays(-daysToSubtract);
        
        for (Integer i = 0; i < 5; i++) {
            targetWeekEnds.add(mostRecentSaturday.addDays(-7 * i));
        }
        return targetWeekEnds;
    }

    /**
     * Retrieves grouped bench time entries.
     */
    @AuraEnabled
    public static BenchTimeWrapper getTimeEntries(Id contactId) {
        loadCredentials();

        if (String.isBlank(COMPANY_SHORT_NAME)) {
            throw new AuraHandledException('Configuration Error: Company Short Name is missing from UKG Integration Settings CMDT record.');
        }

        String employeeId = null;
        
        // --- STEP 1: CONDITIONAL FILTERING LOGIC ---
        if (contactId != null) {
            try {
                // Query the contact for the UKG Employee ID
                Contact c = [SELECT UKG_Employee_ID__c FROM Contact WHERE Id = :contactId LIMIT 1];
                employeeId = c.UKG_Employee_ID__c;
            } catch (Exception e) {
                System.debug('Failed to query Contact for UKG_Employee_ID__c: ' + e.getMessage());
            }
            
            // If running on a Contact page but the employee ID field is blank, 
            // return empty data to avoid running a company-wide report unintentionally.
            if (String.isBlank(employeeId)) {
                System.debug('Running on Contact Page, but UKG_Employee_ID__c is blank. Returning empty data.');
                List<Date> targetWeekEnds = calculateTargetWeekEnds();
                List<String> headerDates = new List<String>();
                for (Date d : targetWeekEnds) {
                    headerDates.add(DateTime.newInstance(d, Time.newInstance(0,0,0,0)).format('yyyy-MM-dd'));
                }
                return new BenchTimeWrapper(new List<UserWeeklyBenchSummary>(), headerDates);
            }
        }
        
        // --- STEP 2: EXECUTE CALLOUT ---
        String bearerToken = generateUkgToken(COMPANY_SHORT_NAME);
        // Pass the employeeId (will be null for Home Page/App Page, or a value for Contact Page)
        return fetchReportAndGroup(bearerToken, COMPANY_SHORT_NAME, employeeId);
    }
    
    /**
     * Executes the login call to UKG to retrieve a new Bearer Token. (Unchanged)
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
     * Executes the report call to UKG, fetches CSV, and performs grouping.
     * Takes employeeId parameter to conditionally filter the report.
     */
    private static BenchTimeWrapper fetchReportAndGroup(String bearerToken, String companyShortName, String employeeId) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        
        request.setEndpoint('callout:UKG_BASE_API/ta/rest/v1/report/saved/' + REPORT_ID + '/'); 
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Accept', 'text/csv');
        request.setHeader('Authorization', 'Bearer ' + bearerToken); 
        
        // Pass employeeId to constructRequestBody
        String reportBody = constructRequestBody(companyShortName, employeeId); 
        request.setBody(reportBody);
        request.setTimeout(60000); 

        try {
            HttpResponse response = http.send(request);

            if (response.getStatusCode() == 200) {
                String csvBody = response.getBody();
                return groupBenchTime(csvBody);
            } else {
                // Error handling based on status code
                // ... (error logging and handling remains the same) ...
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
     * Conditionally includes the EmplEmployeeIdNum filter.
     */
    private static String constructRequestBody(String companyShortName, String employeeId) {
        
        Map<String, Object> payload = new Map<String, Object>{
            'company' => new Map<String, String>{
                'short_name' => companyShortName
            }
        };

        // NEW: Conditionally add the filter block if an Employee ID is provided
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
        
        String body = JSON.serialize(payload);
        return body;
    }

    /**
     * Parses the CSV response string and groups bench time data by user over the 5 fixed weeks. (Unchanged)
     */
    private static BenchTimeWrapper groupBenchTime(String csvData) {
        List<String> lines = csvData.split('\n');
        
        // --- 1. Define the 5 Target Saturday Week-Ends (Fixed Structure) ---
        List<Date> targetWeekEnds = calculateTargetWeekEnds();
        
        // --- 2. Parse CSV, map data, and collect Employee IDs ---
        
        // Map: User Name -> Map<WeekEndDateString (Apex Format), Hours>
        Map<String, Map<String, Decimal>> rawBenchData = new Map<String, Map<String, Decimal>>();
        // Map: User Name -> Employee ID (to find Contact later)
        Map<String, String> userToEmployeeIdMap = new Map<String, String>();
        Set<String> employeeIds = new Set<String>();

        for (Integer i = 1; i < lines.size(); i++) {
            String line = lines[i];
            if (String.isNotBlank(line)) {
                // Remove quotes from line before splitting to handle quoted fields like "Last, First Name"
                String cleanLine = line.replaceAll('\"', '');
                List<String> values = cleanLine.split(','); 
                
                // CRITICAL CHECK: Due to the comma in the name ("Last, First Name"), a 5-column report produces 6 tokens.
                if (values.size() >= 6) { 
                    
                    // Always try to parse the name first, so it's available for assignment later, 
                    // even if subsequent lines throw an exception.
                    String lastName = values[0].trim();
                    String firstName = values[1].trim();
                    String fullName = (String.isNotBlank(lastName) ? lastName : '') + ', ' + (String.isNotBlank(firstName) ? firstName : ''); 
                    fullName = fullName.trim().removeEnd(','); 

                    if (String.isBlank(fullName)) continue; 

                    try {
                        // Remaining indices:
                        // [2]: Week Start (Ignored)
                        String weekEndStr = values[3].trim();     // Index 3: Week End (MM/DD/YYYY format)
                        Decimal hours = Decimal.valueOf(values[4].trim()); // Index 4: Regular Hours
                        String employeeId = values[5].trim();     // Index 5: Employee ID (NEW)
                        
                        Date weekEndDate;
                        
                        // Robust parsing for MM/DD/YYYY format from CSV
                        List<String> dateParts = weekEndStr.split('/');
                        if (dateParts.size() == 3) {
                            Integer month = Integer.valueOf(dateParts[0].trim());
                            Integer day = Integer.valueOf(dateParts[1].trim());
                            Integer year = Integer.valueOf(dateParts[2].trim());
                            weekEndDate = Date.newInstance(year, month, day);
                        } else {
                            System.debug('ERROR: Invalid date format in CSV line: ' + weekEndStr);
                            continue; 
                        }

                        // We only care about this data if the Week End matches one of our 5 target dates.
                        if (!targetWeekEnds.contains(weekEndDate)) {
                            continue; 
                        }

                        // Collect Employee ID and associate with User Name
                        if (String.isNotBlank(employeeId)) {
                             userToEmployeeIdMap.put(fullName, employeeId);
                             employeeIds.add(employeeId);
                        }

                        if (!rawBenchData.containsKey(fullName)) {
                            rawBenchData.put(fullName, new Map<String, Decimal>());
                        }
                        rawBenchData.get(fullName).put(weekEndDate.format(), hours);

                    } catch (Exception e) {
                        // Log errors for data/hours parsing, but keep the current row's name if parsed
                        System.debug('Error parsing hours/date/ID for: ' + fullName + ' - ' + e.getMessage() + ' - Line: ' + line);
                    }
                }
            }
        }
        
        // --- 3. Query Salesforce for Contact IDs ---
        
        // Map: UKG Employee ID -> Salesforce Contact ID
        Map<String, Id> employeeIdToContactIdMap = new Map<String, Id>();
        
        if (!employeeIds.isEmpty()) {
             System.debug('UKG Integration: Found Employee IDs to query: ' + employeeIds); // DEBUG LOG
             // Query Contact records based on the UKG Employee ID
             for (Contact c : [SELECT Id, UKG_Employee_ID__c FROM Contact WHERE UKG_Employee_ID__c IN :employeeIds AND UKG_Employee_ID__c != null LIMIT 50000]) {
                 employeeIdToContactIdMap.put(c.UKG_Employee_ID__c, c.Id);
             }
             System.debug('UKG Integration: Contact matches found: ' + employeeIdToContactIdMap.size()); // DEBUG LOG
        } else {
             System.debug('UKG Integration: No Employee IDs found in report to query.');
        }
        
        // --- 4. Aggregate and Zero-Fill into final output structure ---
        
        // Store week end strings in W1 (index 0) to W5 (index 4) order for LWC headers
        List<String> headerDates = new List<String>();
        for (Date d : targetWeekEnds) {
            headerDates.add(DateTime.newInstance(d, Time.newInstance(0,0,0,0)).format('yyyy-MM-dd'));
        }

        List<UserWeeklyBenchSummary> finalSummaryList = new List<UserWeeklyBenchSummary>();
        
        for (String userName : rawBenchData.keySet()) {
            UserWeeklyBenchSummary summary = new UserWeeklyBenchSummary();
            summary.userName = userName;
            
            // Link Contact ID if available
            String employeeId = userToEmployeeIdMap.get(userName);
            if (String.isNotBlank(employeeId) && employeeIdToContactIdMap.containsKey(employeeId)) {
                 summary.contactId = employeeIdToContactIdMap.get(employeeId);
                 System.debug('UKG Integration: Linked User ' + userName + ' to Contact ID: ' + summary.contactId); // DEBUG LOG
            } else {
                 // ** This is the path for displaying the name without the link **
                 summary.contactId = null; 
                 System.debug('UKG Integration: Failed to link User ' + userName + ' (Employee ID: ' + employeeId + ')'); // DEBUG LOG
            }
            
            Map<String, Decimal> userHours = rawBenchData.get(userName);
            Decimal totalHours = 0.0;
            
            // Loop through the fixed 5 target weeks (W1 through W5)
            for (Integer i = 0; i < 5; i++) {
                String targetDateStr = targetWeekEnds[i].format(); 
                Decimal hours = userHours.containsKey(targetDateStr) ? userHours.get(targetDateStr) : 0.0;
                
                totalHours += hours;

                // Assign to the correct week property (i=0 is W1, i=1 is W2, etc.)
                if (i == 0) summary.w1Hours = hours;
                if (i == 1) summary.w2Hours = hours;
                if (i == 2) summary.w3Hours = hours;
                if (i == 3) summary.w4Hours = hours;
                if (i == 4) summary.w5Hours = hours;
            }
            
            summary.total5WeekHours = totalHours;
            finalSummaryList.add(summary);
        }

        return new BenchTimeWrapper(finalSummaryList, headerDates);
    }
}
