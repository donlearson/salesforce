/**
 * UkgBillableHoursW2Controller
 * * Handles dynamic login to UKG to retrieve a Bearer Token, and then uses that
 * token to securely call the UKG PW2 Billable Hours Report.
 * * This version hard-codes the 5 most recent SATURDAY week-end dates to ensure 
 * consistent column headers, inserting 0.0 for weeks where a user has no data.
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

        // Explicit constructor
        public BenchTimeWrapper(List<UserWeeklyBillableSummary> summaries, List<String> weekEndDates) {
            this.summaries = summaries;
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
        
        public UserWeeklyBillableSummary() {
            w1Hours = 0.0; w2Hours = 0.0; w3Hours = 0.0; w4Hours = 0.0; w5Hours = 0.0; total5WeekHours = 0.0;
            w1_15hSegments = 0.0; w1_24hSegments = 0.0;
            w2_15hSegments = 0.0; w2_24hSegments = 0.0;
            w3_15hSegments = 0.0; w3_24hSegments = 0.0;
            w4_15hSegments = 0.0; w4_24hSegments = 0.0;
            w5_15hSegments = 0.0; w5_24hSegments = 0.0;
            total15hSegments = 0.0; total24hSegments = 0.0;
        }
    }

    // --- Credential Loading ---

    private static String API_KEY; 
    private static String LOGIN_USERNAME;
    private static String LOGIN_PASSWORD;
    private static String COMPANY_SHORT_NAME; // Store Company Short Name here
    // ** REPORT ID FOR THE PW2 BILLABLE HOURS REPORT (USING CURRENT REPORT ID AS PLACEHOLDER) **
    private static final String REPORT_ID = '124802508'; 

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
        
        // Find the most recent Saturday (Day 7) based on Sunday start (Day 1)
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
     * Retrieves grouped billable hours entries for PW2.
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
                return new BenchTimeWrapper(new List<UserWeeklyBillableSummary>(), headerDates);
            }
        }
        
        // --- STEP 2: EXECUTE CALLOUT ---
        String bearerToken = generateUkgToken(COMPANY_SHORT_NAME);
        return fetchReportAndGroup(bearerToken, COMPANY_SHORT_NAME, employeeId);
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
     * Executes the report call to UKG, fetches CSV, and performs grouping.
     */
    private static BenchTimeWrapper fetchReportAndGroup(String bearerToken, String companyShortName, String employeeId) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        
        request.setEndpoint('callout:UKG_BASE_API/ta/rest/v1/report/saved/' + REPORT_ID + '/'); 
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Accept', 'text/csv');
        request.setHeader('Authorization', 'Bearer ' + bearerToken); 
        
        String reportBody = constructRequestBody(companyShortName, employeeId); 
        request.setBody(reportBody);
        request.setTimeout(60000); 

        try {
            HttpResponse response = http.send(request);

            if (response.getStatusCode() == 200) {
                String csvBody = response.getBody();
                return groupBenchTime(csvBody);
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
     * Conditionally includes the EmplEmployeeIdNum filter.
     */
    private static String constructRequestBody(String companyShortName, String employeeId) {
        
        Map<String, Object> payload = new Map<String, Object>{
            'company' => new Map<String, String>{
                'short_name' => companyShortName
            }
        };

        // Conditionally add the filter block if an Employee ID is provided
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
     * Parses the CSV response string and groups billable hours data by user over the 5 fixed weeks.
     */
    private static BenchTimeWrapper groupBenchTime(String csvData) {
        List<String> lines = csvData.split('\n');
        
        // --- 1. Define the 5 Target Saturday Week-Ends (Fixed Structure) ---
        List<Date> targetWeekEnds = calculateTargetWeekEnds();
        
        // --- 2. Parse CSV, map data, and collect Employee IDs ---
        
        Set<String> allFullNames = new Set<String>();
        Map<String, Map<String, Decimal>> rawHoursData = new Map<String, Map<String, Decimal>>();
        Map<String, Map<String, Decimal>> raw15hSegmentsData = new Map<String, Map<String, Decimal>>();
        Map<String, Map<String, Decimal>> raw24hSegmentsData = new Map<String, Map<String, Decimal>>();
        Map<String, String> userToEmployeeIdMap = new Map<String, String>();
        Set<String> employeeIds = new Set<String>();

        for (Integer i = 1; i < lines.size(); i++) {
            String line = lines[i];
            if (String.isNotBlank(line)) {
                String cleanLine = line.replaceAll('\"', '');
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
                        
                        // Safely handle dashes, blanks, or non-numeric placeholders
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
                        
                        Date weekEndDate;
                        
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

                        if (!targetWeekEnds.contains(weekEndDate)) {
                            continue; 
                        }

                        if (String.isNotBlank(employeeId)) {
                             userToEmployeeIdMap.put(fullName, employeeId);
                             employeeIds.add(employeeId);
                        }

                        allFullNames.add(fullName);

                        Boolean is15h = activityCode.startsWith('177-15');
                        Boolean is24h = activityCode.startsWith('177-24');

                        if (is15h) {
                            if (!raw15hSegmentsData.containsKey(fullName)) {
                                raw15hSegmentsData.put(fullName, new Map<String, Decimal>());
                            }
                            Map<String, Decimal> weekMap = raw15hSegmentsData.get(fullName);
                            Decimal currentCount = weekMap.containsKey(weekEndDate.format()) ? weekMap.get(weekEndDate.format()) : 0;
                            weekMap.put(weekEndDate.format(), currentCount + hours);
                        } else if (is24h) {
                            if (!raw24hSegmentsData.containsKey(fullName)) {
                                raw24hSegmentsData.put(fullName, new Map<String, Decimal>());
                            }
                            Map<String, Decimal> weekMap = raw24hSegmentsData.get(fullName);
                            Decimal currentCount = weekMap.containsKey(weekEndDate.format()) ? weekMap.get(weekEndDate.format()) : 0;
                            weekMap.put(weekEndDate.format(), currentCount + hours);
                        } else {
                            if (!rawHoursData.containsKey(fullName)) {
                                rawHoursData.put(fullName, new Map<String, Decimal>());
                            }
                            Map<String, Decimal> weekMap = rawHoursData.get(fullName);
                            Decimal currentHours = weekMap.containsKey(weekEndDate.format()) ? weekMap.get(weekEndDate.format()) : 0.0;
                            weekMap.put(weekEndDate.format(), currentHours + hours);
                        }

                    } catch (Exception e) {
                        System.debug('Error parsing hours/date/ID for: ' + fullName + ' - ' + e.getMessage() + ' - Line: ' + line);
                    }
                }
            }
        }
        
        // --- 3. Query Salesforce for Contact IDs ---
        
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
         
         // --- 4. Aggregate and Zero-Fill into final output structure ---
         
         List<String> headerDates = new List<String>();
         for (Date d : targetWeekEnds) {
             headerDates.add(DateTime.newInstance(d, Time.newInstance(0,0,0,0)).format('yyyy-MM-dd'));
         }
 
         List<UserWeeklyBillableSummary> finalSummaryList = new List<UserWeeklyBillableSummary>();
         
         for (String userName : allFullNames) {
             UserWeeklyBillableSummary summary = new UserWeeklyBillableSummary();
             summary.userName = userName;
             
             String employeeId = userToEmployeeIdMap.get(userName);
             if (String.isNotBlank(employeeId) && employeeIdToContactIdMap.containsKey(employeeId)) {
                  summary.contactId = employeeIdToContactIdMap.get(employeeId);
             } else {
                  summary.contactId = null; 
             }
             
             Map<String, Decimal> userHours = rawHoursData.containsKey(userName) ? rawHoursData.get(userName) : new Map<String, Decimal>();
             Map<String, Decimal> user15h = raw15hSegmentsData.containsKey(userName) ? raw15hSegmentsData.get(userName) : new Map<String, Integer>();
             Map<String, Decimal> user24h = raw24hSegmentsData.containsKey(userName) ? raw24hSegmentsData.get(userName) : new Map<String, Integer>();

             Decimal totalHours = 0.0;
             Decimal total15 = 0.0;
             Decimal total24 = 0.0;
             
             for (Integer i = 0; i < 5; i++) {
                 String targetDateStr = targetWeekEnds[i].format(); 
                 Decimal hours = userHours.containsKey(targetDateStr) ? userHours.get(targetDateStr) : 0.0;
                 Decimal count15 = user15h.containsKey(targetDateStr) ? user15h.get(targetDateStr) : 0;
                 Decimal count24 = user24h.containsKey(targetDateStr) ? user24h.get(targetDateStr) : 0;
                 
                 totalHours += hours;
                 total15 += count15;
                 total24 += count24;
 
                 if (i == 0) {
                     summary.w1Hours = hours;
                     summary.w1_15hSegments = count15;
                     summary.w1_24hSegments = count24;
                 }
                 if (i == 1) {
                     summary.w2Hours = hours;
                     summary.w2_15hSegments = count15;
                     summary.w2_24hSegments = count24;
                 }
                 if (i == 2) {
                     summary.w3Hours = hours;
                     summary.w3_15hSegments = count15;
                     summary.w3_24hSegments = count24;
                 }
                 if (i == 3) {
                     summary.w4Hours = hours;
                     summary.w4_15hSegments = count15;
                     summary.w4_24hSegments = count24;
                 }
                 if (i == 4) {
                     summary.w5Hours = hours;
                     summary.w5_15hSegments = count15;
                     summary.w5_24hSegments = count24;
                 }
             }
             
             summary.total5WeekHours = totalHours;
             summary.total15hSegments = total15;
             summary.total24hSegments = total24;
             finalSummaryList.add(summary);
         }
        
         for(UserWeeklyBillableSummary summary : finalSummaryList) {
            if(summary.userName.contains('Knight')) {
                System.debug('--- DEBUG NICK KNIGHT ---');
                System.debug('w1_24hSegments Value: ' + summary.w1_24hSegments);
            }
         }
        
         return new BenchTimeWrapper(finalSummaryList, headerDates);
    }
} //final code