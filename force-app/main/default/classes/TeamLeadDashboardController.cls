public class TeamLeadDashboardController {

    public List<String> columnHeaders { get; set; }
    public List<TeamMemberWrapper> teamMembers { get; set; }
	public List<Account> tableData { get; set; }
    
    public class TaskActivityWrapper {
        public String description { get; set; }
        public String taskId { get; set; }
        public String display { get; set; }
        
        public TaskActivityWrapper(String description, String taskId, String display) {
            this.description = description;
            this.taskId = taskId;
            this.display = display;
        }
    }
    
    public TeamLeadDashboardController(ApexPages.StandardController stdController) {
        this.teamMembers = getTeamMembers();
        this.columnHeaders = getLast14MonthsHeaders();
    }
    
    public PageReference refreshData() {
        //this.teamMembers = getTeamMembers(this.selectedTeamLeadId);
        //return null; // Return null if no page navigation is needed

        // Refresh the team members based on the selected team lead
        this.teamMembers = getTeamMembers();
        
        return null; // Return null if no page navigation is needed
    }
    
    public List<TeamMemberWrapper> getTeamMembers() {
        List<TeamMemberWrapper> members = new List<TeamMemberWrapper>();
		// Debug UserInfo.getUserName() value
		System.debug('UserInfo.getUserName(): ' + UserInfo.getName());
        
        // Customize the query to get the team members related to the team lead.
        List<Contact> contacts = [SELECT Id, AccountId, Name, HPG_Title__c, Today_Is_Birthday__c, Birth_Month__c
                                  FROM Contact 
                                  	WHERE Team_Lead__c = :UserInfo.getUserId() 
                                  	AND Name != :UserInfo.getName()];

        for (Contact member : contacts) {
            TeamMemberWrapper wrapper = new TeamMemberWrapper(member);
            members.add(wrapper);
        }
		System.debug(members);
        members.sort();
        System.debug('Members: ' + members);
        return members;
    }

    // Custom object class to store Task ID and new date field
    public class TaskCustomObject implements Comparable {
        public Id taskId;
        public Datetime newDateField;
        
        // Implement the compareTo method to sort by the new date field
        public Integer compareTo(Object obj) {
            TaskCustomObject other = (TaskCustomObject)obj;
            // Compare the newDateField attributes of the TaskCustomObjects
            if (this.newDateField < other.newDateField) {
                return -1;
            } else if (this.newDateField > other.newDateField) {
                return 1;
            } else {
                return 0;
            }
        }
    }
    
    //public void sortTaskCustomObjects(List<TaskCustomObject> taskObjects) {
    //    taskObjects.sort();
    //}
    
    public List<String> getLast14MonthsHeaders() {
        List<String> headers = new List<String>();

        // Get the start of the current month
        Date currentMonthStart = Date.today().toStartOfMonth();

        // Iterate through the last 14 months
        //Datetime monthStart = Datetime.newInstance(Date.today().toStartOfMonth().addMonths(-13), Time.newInstance(0, 0, 0, 0));
        for (Integer i = 13; i >= 0; i--) { 
            Date monthStart = currentMonthStart.addMonths(-i);
            Datetime monthStartDateTime = Datetime.newInstance(monthStart, Time.newInstance(0, 0, 0, 0));
            headers.add(monthStartDateTime.format('MMM yyyy'));
            System.debug('headers: ' + headers);
        } 
        return headers;
    }

    public class TeamMemberWrapper implements Comparable {
        public Contact member { get; set; }
        public Map<String, Boolean> communicatedMonths { get; set; }
        
        public TeamMemberWrapper(Contact member) {
            this.member = member;
            this.communicatedMonths = checkCommunicatedMonths();
        }

        public Map<String, Boolean> checkCommunicatedMonths() {
            Map<String, Boolean> monthsMap = new Map<String, Boolean>();
           	
            List<Task> tasks = [SELECT Id, ActivityDate, CreatedDate
                    FROM Task
                    WHERE WhoId = :member.Id
                          AND (
                              (ActivityDate >= :Date.today().addMonths(-13).toStartOfMonth() AND ActivityDate <= :Date.today())
                              OR
                              (ActivityDate = null AND CreatedDate >= :Date.today().addMonths(-13).toStartOfMonth() AND CreatedDate <= :Date.today())
                          )
                          //AND CreatedById = :UserInfo.getUserId()
                          AND OwnerId = :UserInfo.getUserId()
                    ORDER BY ActivityDate DESC NULLS LAST, CreatedDate DESC];
            
            //output the task list to system
            System.debug('tasks: ' + tasks);
            
            // Create a list to store the custom objects
			List<TaskCustomObject> customObjects = new List<TaskCustomObject>();
            
            // Iterate through the last 14 months
            for (Task task : tasks) {
                // Create a new TaskCustomObject instance
                TaskCustomObject customObject = new TaskCustomObject();
                // Set the Task ID
                customObject.taskId = task.Id;
                // Set the new date field as either ActivityDate if it exists, or CreatedDate if not
                customObject.newDateField = task.ActivityDate != null ? task.ActivityDate : task.CreatedDate;
                
                // Add 1 day to account for variables in a DATE type in Salesforce
                customObject.newDateField = customObject.newDateField.date().addDays(1);
                
                
                
                // Set the time component to noon (12:00 PM)
                Time noonTime = Time.newInstance(12, 0, 0, 0);
                
                // Convert current datetime to user's timezone
				Datetime adjustedDateTime = Datetime.newInstance(customObject.newDateField.date().addDays(1), noonTime);
                System.debug('adjustedDateTime: ' + adjustedDateTime);
                customObject.newDateField = adjustedDateTime;
                System.debug('customObject.newDateField: ' + customObject.newDateField);
                
                // Add the custom object to the list
                customObjects.add(customObject);
            }

            customObjects.sort(); // Sort the list of custom objects
            System.debug('customObjects: ' + customObjects);
            
            // Iterate through the last 14 months
            for (Integer i = 0; i >= -13; i--) {
                Datetime monthStart = Datetime.newInstance(Date.today().toStartOfMonth().addMonths(i), Time.newInstance(23, 59, 59, 999));
                String monthKey = monthStart.format('yyyy-MM');
                
                // Check if there's a TaskCustomObject instance for the current month
                Boolean hasValue = false;
                for (TaskCustomObject customObject : customObjects) {
                    System.debug('customObject.day: ' + customObject.newDateField.day());
                    System.debug('customObject.taskId: ' + customObject.taskId + ' / customObject.newDateField.month(): ' + customObject.newDateField + ' / monthStart.month: ' + monthStart.month() + ' / monthStart.year: ' + monthStart.year());
                    if (customObject.newDateField.year() == monthStart.year() && 
                        customObject.newDateField.month() == monthStart.month()) {
                        System.debug('This is True');
                        hasValue = true;
                        break;
                    }
                }
                monthsMap.put(monthKey, hasValue);
            }
            
            return monthsMap;
        }
        
        
        public TaskActivityWrapper getlastActivity() {
            // Customize this method to get the last task from the related task object.
            List<Task> tasks = [SELECT Id, Description, Subject, CreatedDate, ActivityDate
                                FROM Task
                                //WHERE WhoId = :'member.Id'
                                WHERE WhoId = :member.Id
                                  //AND CreatedBy.Id = :UserInfo.getUserId()
                                  AND OwnerId = :UserInfo.getUserId()
                                  //AND ActivityDate = THIS_MONTH
                                ORDER BY ActivityDate DESC
                                LIMIT 1];
            if (tasks.size() > 0) {
                String description;
                String taskId;
                if(tasks[0].ActivityDate == null) {
                    description = tasks[0].Subject + ' (' + tasks[0].CreatedDate.format('MM/dd/yyyy') + ')';
                } else {
                    description = tasks[0].Subject + ' (' + tasks[0].ActivityDate.format() + ')';
                }
                taskId = tasks[0].Id;
                return new TaskActivityWrapper(description, taskId, tasks[0].Description);
            }
            return new TaskActivityWrapper('No activity recorded', null, null);
        }

		public Integer compareTo(Object obj) {
            TeamMemberWrapper otherMember = (TeamMemberWrapper)obj;
            
            // Check if the current member has the specific HPG_Title__c
            Boolean thisMemberHasSpecificTitle = this.member.HPG_Title__c != null && this.member.HPG_Title__c.equals('Senior Consultant, Hourly W-2');
            // Check if the other member has the specific HPG_Title__c
            Boolean otherMemberHasSpecificTitle = otherMember.member.HPG_Title__c != null && otherMember.member.HPG_Title__c.equals('Senior Consultant, Hourly W-2');
            
            // Compare by member name
            //return this.member.Name.compareTo(otherMember.member.Name);
			// If both members have the specific HPG_Title__c, or neither have it, compare by member name
    		if ((thisMemberHasSpecificTitle && otherMemberHasSpecificTitle) || (!thisMemberHasSpecificTitle && !otherMemberHasSpecificTitle)) {
                return this.member.Name.compareTo(otherMember.member.Name);
            } else if (thisMemberHasSpecificTitle) {
                // If the current member has the specific HPG_Title__c but the other member doesn't, place the other member before
                return 1;
            } else {
                // If the other member has the specific HPG_Title__c but the current member doesn't, place the current member before
                return -1;
            }	
        }
         
        // Explicit getter for the Id property
        public Id getId() {
            return member.Id;
        }
        // Explicit getter for the Name property
        public String getName() {
            return member.Name;
        }
         // Explicit getter for the Id property
        public Id getAccountId() {
            return member.AccountId;
        }
    }
}