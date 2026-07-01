/**
 * UkgReviewDataController
 * * Handles dynamic login to UKG and calls the Annual Review Report (123617418).
 * * Calculates the review period dates (1 year preceding Hire Date Anniversary) 
 * and filters the UKG report by Contact's UKG_ID__c (mapped to EmplAccountId).
 * * Parses the time entries into Billable, Non-Billable, and On-Call categories based on ACTIVITY CODE.
 * * **UPDATED:** Accepts optional start/end date strings from the LWC input.
 */
public with sharing class UkgReviewDataController {

    // --- Inner Classes for Data Transfer and Aggregation ---
    
    // Wrapper class to send all three summary lists and the review period dates
    public class ReviewSummaryWrapper {
        @AuraEnabled public String reviewPeriod { get; set; }
        @AuraEnabled public List<ProjectHours> billableProjects { get; set; }
        @AuraEnabled public List<ProjectHours> nonBillableItems { get; set; }
        @AuraEnabled public List<ProjectHours> onCallUnits { get; set; } 

        public ReviewSummaryWrapper() {
            billableProjects = new List<ProjectHours>();
            nonBillableItems = new List<ProjectHours>();
            onCallUnits = new List<ProjectHours>();
        }
    }

    // Standard structure for displaying project hours/units
    public class ProjectHours {
        @AuraEnabled public String id { get; set; } // Required for lightning-datatable key
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal hours { get; set; }

        // Explicit parameterless constructor added to allow standard property assignment
        public ProjectHours() { } 
    }

    // --- Credential Loading ---

    private static String API_KEY; 
    private static String LOGIN_USERNAME;
    private static String LOGIN_PASSWORD;
    private static String COMPANY_SHORT_NAME;
    private static final String REPORT_ID = '123617418'; 
    

    private static void loadCredentials() {
        if (API_KEY == null) {
            List<UKG_Integration_Settings__mdt> settingsList = 
                [SELECT Api_Key__c, Login_Username__c, Login_Password__c, Company_Short_Name__c 
                 FROM UKG_Integration_Settings__mdt 
                 WHERE DeveloperName = 'ukgLogin' 
                 LIMIT 1];
            
            if (settingsList.isEmpty()) {
                throw new AuraHandledException('Configuration Error: UKG Integration Settings CMDT record "ukgLogin" not found.');
            }
            
            UKG_Integration_Settings__mdt settings = settingsList[0];
            API_KEY = settings.Api_Key__c;
            LOGIN_USERNAME = settings.Login_Username__c;
            LOGIN_PASSWORD = settings.Login_Password__c;
            COMPANY_SHORT_NAME = settings.Company_Short_Name__c;
        }
    }
    
    /**
     * Retrieves the Annual Review Summary data for the given Contact.
     * @param contactId The Salesforce Contact ID.
     * @param startDateStr Optional start date string (YYYY-MM-DD) from LWC input.
     * @param endDateStr Optional end date string (YYYY-MM-DD) from LWC input.
     */
    @AuraEnabled
    public static ReviewSummaryWrapper getReviewSummary(Id contactId, String startDateStr, String endDateStr) {
        loadCredentials();

        // 1. Get Contact Details and Calculate Dates
        Contact c;
        try {
            // Query the contact for the Hire Date Anniversary and UKG ID
            c = [SELECT Hire_Date_Anniversary__c, UKG_ID__c FROM Contact WHERE Id = :contactId LIMIT 1];
        } catch (Exception e) {
            throw new AuraHandledException('Contact query failed: Ensure the user has read access to Contact and required fields.');
        }

        if (c.UKG_ID__c == null || String.isBlank(c.UKG_ID__c)) {
            // Return empty wrapper if UKG ID is missing
            return new ReviewSummaryWrapper();
        }
        
        Date reviewStartDate;
        Date reviewEndDate;
        String dateSourceDebug = 'AUTO_CALCULATED';

        // If dates are provided by LWC input, use them.
        if (String.isNotBlank(startDateStr) && String.isNotBlank(endDateStr)) {
            try {
                // LWC passes YYYY-MM-DD, convert directly to Date objects. TRIM is critical here.
                reviewStartDate = Date.valueOf(startDateStr.trim());
                reviewEndDate = Date.valueOf(endDateStr.trim());
                dateSourceDebug = 'USER_INPUT';
            } catch (Exception e) {
                 throw new AuraHandledException('Invalid Date Format: Please ensure dates are valid YYYY-MM-DD format.');
            }
        } 
        // Fallback: Use calculated dates from Hire Date Anniversary (for the original component or if input is bypassed)
        else if (c.Hire_Date_Anniversary__c != null) {
            reviewEndDate = c.Hire_Date_Anniversary__c.addDays(-1);
            reviewStartDate = reviewEndDate.addYears(-1).addDays(1);
        } else {
             // Cannot proceed without either LWC input or Hire Date field.
             return new ReviewSummaryWrapper();
        }
        
        // Final date string formatting for API payload
        String apiStartDateStr = DateTime.newInstance(reviewStartDate, Time.newInstance(0,0,0,0)).format('yyyy-MM-dd');
        String apiEndDateStr = DateTime.newInstance(reviewEndDate, Time.newInstance(0,0,0,0)).format('yyyy-MM-dd');
        
        String employeeAccountId = c.UKG_ID__c;

        // DEBUG Confirmation of dates used:
        System.debug('*** DATE SOURCE: ' + dateSourceDebug);
        System.debug('*** API DATES: FromDate=' + apiStartDateStr + ', ToDate=' + apiEndDateStr);

        // 2. Execute Callout
        String bearerToken = generateUkgToken(COMPANY_SHORT_NAME);
        // Pass the API-formatted date strings
        String csvData = fetchReportData(bearerToken, COMPANY_SHORT_NAME, employeeAccountId, apiStartDateStr, apiEndDateStr);
        
        // 3. Process Data
        ReviewSummaryWrapper result = processCSVData(csvData);
        result.reviewPeriod = reviewStartDate.format() + ' to ' + reviewEndDate.format();
        return result;
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
            throw new AuraHandledException('UKG Login Callout failed: Check network or credentials.');
        }
    }
    
    /**
     * Fetches the raw CSV data from the UKG Report API. Includes date and ID filtering in payload.
     */
    private static String fetchReportData(String bearerToken, String companyShortName, String employeeAccountId, String startDateStr, String endDateStr) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        
        request.setEndpoint('callout:UKG_BASE_API/ta/rest/v1/report/saved/' + REPORT_ID); 
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Accept', 'text/csv');
        request.setHeader('Authorization', 'Bearer ' + bearerToken); 
        
        String reportBody = constructRequestBody(companyShortName, employeeAccountId, startDateStr, endDateStr);
        request.setBody(reportBody);
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
            throw new AuraHandledException('Report Callout failed: Check Named Credential configuration.');
        }
    }


    /**
     * Builds the JSON payload for the UKG report request, including date and ID filters.
     */
    private static String constructRequestBody(String companyShortName, String employeeAccountId, String startDateStr, String endDateStr) {
        
        Map<String, Object> payload = new Map<String, Object>{
            'company' => new Map<String, String>{
                'short_name' => companyShortName
            },
            'filters' => new List<Object>{
                new Map<String, Object>{
                    'field_name' => 'EmplAccountId', // Filter by Employee's Account ID
                    'operator' => '=',
                    'values' => new List<String>{
                        employeeAccountId
                    }
                }
            },
            // Re-including date selectors as validated by Postman structure
            'selectors' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'Date',
                    'name' => 'PPDate', 
                    'parameters' => new Map<String, String>{
                        'RangeType' => '2',
                        'FromDate' => startDateStr, // YYYY-MM-DD format
                        'ToDate' => endDateStr      // YYYY-MM-DD format
                    }
                }
            }
        };
        
        String body = JSON.serialize(payload);
        return body;
    }
    
    /**
     * Helper function to reliably clean tokens by trimming and stripping outer quotes.
     */
    private static String cleanToken(String token) {
        if (token == null) return '';
        
        String cleanPart = token.trim();
        // Manually check and strip outer quotes, which are usually left by the custom splitter
        if (cleanPart.startsWith('"') && cleanPart.endsWith('"')) {
            cleanPart = cleanPart.substring(1, cleanPart.length() - 1);
        }
        return cleanPart;
    }
    
    /**
     * Helper method that splits a CSV line into tokens, respecting double quotes 
     * around fields that contain commas, bypassing the global String.split regex issues.
     */
    private static List<String> splitCSVLine(String line) {
        List<String> tokens = new List<String>();
        Boolean inQuotes = false;
        Integer lastIndex = 0;

        for (Integer i = 0; i < line.length(); i++) {
            String currentChar = line.substring(i, i + 1);

            if (currentChar == '"') {
                inQuotes = !inQuotes;
            } else if (currentChar == ',' && !inQuotes) {
                // Split on comma only if we are outside quotes
                tokens.add(line.substring(lastIndex, i));
                lastIndex = i + 1;
            }
        }
        
        // Add the last token
        tokens.add(line.substring(lastIndex));
        
        return tokens;
    }

    /**
     * Helper method to replace csvData.split('\n') with a safe iteration loop,
     * bypassing the 'Regex too complicated' error on large files.
     */
    private static List<String> getLinesFromCSV(String csvData) {
        List<String> lines = new List<String>();
        Integer lastIndex = 0;
        
        // Use a simple indexOf loop to find newlines, which avoids the regex engine
        while (true) {
            Integer newlineIndex = csvData.indexOf('\n', lastIndex);
            if (newlineIndex == -1) {
                // Add the last line fragment if it's not empty
                if (csvData.length() > lastIndex) {
                    lines.add(csvData.substring(lastIndex));
                }
                break;
            }
            lines.add(csvData.substring(lastIndex, newlineIndex));
            lastIndex = newlineIndex + 1;
        }
        return lines;
    }


    /**
     * Parses the CSV response string and categorizes time entries.
     * @param csvData The raw CSV string from the API.
     */
    private static ReviewSummaryWrapper processCSVData(String csvData) {
        // FIX: Use custom line splitter to bypass the 'Regex too complicated' error
        List<String> lines = getLinesFromCSV(csvData);
        ReviewSummaryWrapper wrapper = new ReviewSummaryWrapper();
        
        Map<String, Decimal> consolidatedBillable = new Map<String, Decimal>();
        Map<String, Decimal> consolidatedNonBillable = new Map<String, Decimal>();
        Map<String, Decimal> consolidatedOnCall = new Map<String, Decimal>();
        
        for (Integer i = 1; i < lines.size(); i++) {
            String line = lines[i];
            if (String.isNotBlank(line)) {
                
                // Use robust custom splitter to handle commas inside quotes
                List<String> values;
                try {
                    values = splitCSVLine(line); 
                } catch (Exception e) {
                    System.debug('CRITICAL SPLIT ERROR on line ' + i + ': ' + e.getMessage());
                    continue;
                }

                // CRITICAL CHECK: We need at least 6 tokens for Category and Hours
                if (values.size() >= 6) { 
                    
                    try {
                        
                        // Clean tokens for conversion/comparison
                        // 3: Activity Codes (Category)
                        // 5: Hours
                        
                        String category = cleanToken(values[3]);        
                        Decimal hours = Decimal.valueOf(cleanToken(values[5])); 
                        
                        // --- PROJECT NAME CONSTRUCTION (Indices 15, 16, 17, 18) ---
                        // Note: We MUST check array bounds before accessing index (safest method)
                        
                        String projectParts = '';
                        List<Integer> projectIndices = new List<Integer>{15, 16, 17, 18};
                        
                        for (Integer index : projectIndices) {
                            if (values.size() > index) { 
                                String part = cleanToken(values[index]);
                                
                                if (String.isNotBlank(part)) {
                                    if (String.isNotBlank(projectParts)) {
                                        projectParts += ' / '; // Separator
                                    }
                                    projectParts += part;
                                }
                            }
                        }
                        
                        String displayName = projectParts; 
                        
                        if (hours <= 0 || String.isBlank(displayName)) continue; 
                        
                        // --- CATEGORIZATION LOGIC ---
                        
                        Boolean isBillableCode = category.startsWith('1') || category.startsWith('217');
                        
                        Boolean isExplicitOnCall = category.startsWith('177-') || 
                                                  category.containsIgnoreCase('15 Hour On-Call Unit') || 
                                                  category.containsIgnoreCase('24 Hour On-Call Unit');

                        Boolean isExplicitNonBillableCode = category.startsWith('176') || 
                                                            category.startsWith('184') || 
                                                            category.startsWith('187');

                        // 1. Check for ON-CALL
                        if (isExplicitOnCall) {
                            consolidatedOnCall.put(category, (consolidatedOnCall.get(category) ?? 0.0) + hours);
                        }
                        
                        // 2. Check for EXPLICIT NON-BILLABLE CODES
                        else if (isExplicitNonBillableCode) { 
                            consolidatedNonBillable.put(category, (consolidatedNonBillable.get(category) ?? 0.0) + hours);
                        }
                        
                        // 3. Check for BILLABLE
                        else if (isBillableCode) { 
                            consolidatedBillable.put(displayName, (consolidatedBillable.get(displayName) ?? 0.0) + hours);
                        }
                        
                        // 4. Everything else is GENERAL NON-BILLABLE
                        else {
                            consolidatedNonBillable.put(category, (consolidatedNonBillable.get(category) ?? 0.0) + hours);
                        }

                    } catch (Exception e) {
                        System.debug('Error parsing hours/category (Conversion Failure): ' + e.getMessage() + ' - Line: ' + line);
                    }
                }
            }
        }
        
        // --- CONVERT MAPS TO LISTS (ProjectHours) ---

        Integer idCounter = 0;
        
        // Billable Projects (Grouped by Display Name)
        for (String description : consolidatedBillable.keySet()) {
            ProjectHours p = new ProjectHours();
            p.id = String.valueOf(idCounter++);
            p.description = description; 
            p.hours = consolidatedBillable.get(description);
            wrapper.billableProjects.add(p);
        }

        // Non-Billable Activities (Grouped by Category)
        for (String description : consolidatedNonBillable.keySet()) {
            ProjectHours p = new ProjectHours();
            p.id = String.valueOf(idCounter++);
            p.description = description; 
            p.hours = consolidatedNonBillable.get(description);
            wrapper.nonBillableItems.add(p);
        }

        // On-Call Shifts (Grouped by Category)
        for (String description : consolidatedOnCall.keySet()) {
            ProjectHours p = new ProjectHours();
            p.id = String.valueOf(idCounter++);
            p.description = description; 
            p.hours = consolidatedOnCall.get(description);
            wrapper.onCallUnits.add(p);
        }
        
        // Sort Billable projects alphabetically
        wrapper.billableProjects.sort(new ProjectHoursSorter());

        return wrapper;
    }
    
    // Custom sorter class to alphabetize Billable Projects
    private class ProjectHoursSorter implements Comparator<ProjectHours> {
        public Integer compare(ProjectHours p1, ProjectHours p2) {
            return p1.description.compareTo(p2.description);
        }
    }
}
