/**
 * Unified controller for the Consulting Dashboard LWC. Replaces
 * DirectorDashboardController, TeamLeadDashboardController, TaskLogController,
 * and FollowUpTaskComponent. Director-tier access is driven by the
 * View_All_Consulting_Teams custom permission rather than a hardcoded profile
 * check.
 */
public with sharing class ConsultingDashboardController {

    private static final String HOURLY_W2_TITLE = 'Senior Consultant Hourly W-2';
    private static final Integer MONTHS_BACK = 13;
    public static final String SCM_ROSTER_VALUE = 'SCM';
    private static final Set<String> SCM_TITLES = new Set<String>{
        'Senior Consulting Manager',
        'Senior Team Lead, Consulting Services'
    };

    // Users in these roles appear in the team lead picker. Driven by role rather than
    // profile so a profile change doesn't drop someone from the list.
    private static final Set<String> TEAM_LEAD_ROLES = new Set<String>{
        'Team_Lead',
        'Support_Center_Manager'
    };

    private static Id taskRecordTypeId() {
        return [SELECT Id FROM RecordType WHERE SObjectType = 'Task' AND DeveloperName = 'Associate_Communication' LIMIT 1].Id;
    }

    // ---------------------------------------------------------------------
    // Wrapper types
    // ---------------------------------------------------------------------

    public class DashboardContext {
        @AuraEnabled public Boolean isDirector;
        @AuraEnabled public Id currentUserId;
        @AuraEnabled public List<TeamLeadOption> teamLeadOptions;
    }

    public class TeamLeadOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public TeamLeadOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    public class TeamMember {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String hpgTitle;
        @AuraEnabled public Boolean isHourlyW2;
        @AuraEnabled public Boolean isBirthdayToday;
        @AuraEnabled public Map<String, Boolean> communicatedMonths;
        @AuraEnabled public String lastActivityDescription;
        @AuraEnabled public Id lastActivityTaskId;
        @AuraEnabled public String lastActivityDetail;
    }

    public class FollowUpTaskSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public Id whoId;
        @AuraEnabled public String whoName;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public String priority;
        @AuraEnabled public Date activityDate;
        @AuraEnabled public String description;
    }

    public class FollowUpTaskDetail {
        @AuraEnabled public Id id;
        @AuraEnabled public String subject;
        @AuraEnabled public Date activityDate;
        @AuraEnabled public String description;
        @AuraEnabled public String interactionType;
        @AuraEnabled public String taskOutcomeDetail;
        @AuraEnabled public String status;
    }

    public class ContactSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String title;
    }

    public class PicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public PicklistOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    // ---------------------------------------------------------------------
    // Dashboard context / access
    // ---------------------------------------------------------------------

    @AuraEnabled(cacheable=true)
    public static DashboardContext getDashboardContext() {
        DashboardContext ctx = new DashboardContext();
        ctx.currentUserId = UserInfo.getUserId();
        ctx.isDirector = FeatureManagement.checkPermission('View_All_Consulting_Teams');
        ctx.teamLeadOptions = getTeamLeadOptions();
        return ctx;
    }

    private static List<TeamLeadOption> getTeamLeadOptions() {
        List<TeamLeadOption> options = new List<TeamLeadOption>();
        options.add(new TeamLeadOption('Senior Consulting Managers', SCM_ROSTER_VALUE));
        for (User u : [
            SELECT Id, Name
            FROM User
            WHERE UserRole.DeveloperName IN :TEAM_LEAD_ROLES AND IsActive = TRUE
            ORDER BY Name
        ]) {
            options.add(new TeamLeadOption(u.Name, u.Id));
        }
        return options;
    }

    // ---------------------------------------------------------------------
    // Roster / communication grid
    // ---------------------------------------------------------------------

    @AuraEnabled
    public static List<TeamMember> getTeamRoster(String teamLeadSelection) {
        if (teamLeadSelection == SCM_ROSTER_VALUE) {
            List<Contact> scmContacts = [
                SELECT Id, AccountId, Account.Name, Name, HPG_Title__c, Birth_Month__c, Birth_Date__c
                FROM Contact
                WHERE HPG_Title__c IN :SCM_TITLES
            ];
            return buildRoster(scmContacts, UserInfo.getUserId());
        }

        Id ownerId = String.isNotBlank(teamLeadSelection) ? Id.valueOf(teamLeadSelection) : UserInfo.getUserId();

        String ownerName = null;
        List<User> ownerUsers = [SELECT Name FROM User WHERE Id = :ownerId LIMIT 1];
        if (!ownerUsers.isEmpty()) {
            ownerName = ownerUsers[0].Name;
        }

        List<Contact> contacts = [
            SELECT Id, AccountId, Account.Name, Name, HPG_Title__c, Birth_Month__c, Birth_Date__c
            FROM Contact
            WHERE Team_Lead__c = :ownerId
            AND Name != :ownerName
        ];

        return buildRoster(contacts, ownerId);
    }

    private static List<TeamMember> buildRoster(List<Contact> contacts, Id taskOwnerId) {
        Set<Id> contactIds = new Map<Id, Contact>(contacts).keySet();

        Map<Id, List<Task>> communicationTasksByContact = new Map<Id, List<Task>>();
        Map<Id, List<Task>> lastActivityTasksByContact = new Map<Id, List<Task>>();

        if (!contactIds.isEmpty()) {
            Date windowStart = Date.today().addMonths(-MONTHS_BACK).toStartOfMonth();

            for (Task t : [
                SELECT Id, WhoId, ActivityDate, CreatedDate
                FROM Task
                WHERE WhoId IN :contactIds
                AND OwnerId = :taskOwnerId
                AND (
                    (ActivityDate >= :windowStart AND ActivityDate <= :Date.today())
                    OR
                    (ActivityDate = null AND CreatedDate >= :windowStart AND CreatedDate <= :Date.today())
                )
            ]) {
                if (!communicationTasksByContact.containsKey(t.WhoId)) {
                    communicationTasksByContact.put(t.WhoId, new List<Task>());
                }
                communicationTasksByContact.get(t.WhoId).add(t);
            }

            for (Task t : [
                SELECT Id, WhoId, Description, Subject, CreatedDate, ActivityDate
                FROM Task
                WHERE WhoId IN :contactIds
                AND OwnerId = :taskOwnerId
                ORDER BY WhoId, ActivityDate DESC
            ]) {
                if (!lastActivityTasksByContact.containsKey(t.WhoId)) {
                    lastActivityTasksByContact.put(t.WhoId, new List<Task>());
                }
                lastActivityTasksByContact.get(t.WhoId).add(t);
            }
        }

        List<TeamMember> members = new List<TeamMember>();
        for (Contact c : contacts) {
            TeamMember m = new TeamMember();
            m.id = c.Id;
            m.name = c.Name;
            m.accountId = c.AccountId;
            m.accountName = c.Account != null ? c.Account.Name : null;
            m.hpgTitle = c.HPG_Title__c;
            m.isHourlyW2 = c.HPG_Title__c == HOURLY_W2_TITLE;
            m.isBirthdayToday = isBirthdayToday(c.Birth_Month__c, c.Birth_Date__c);
            m.communicatedMonths = buildCommunicatedMonths(communicationTasksByContact.get(c.Id));

            List<Task> lastActivityTasks = lastActivityTasksByContact.get(c.Id);
            if (lastActivityTasks != null && !lastActivityTasks.isEmpty()) {
                Task last = lastActivityTasks[0];
                m.lastActivityTaskId = last.Id;
                m.lastActivityDetail = last.Description;
                if (last.ActivityDate == null) {
                    m.lastActivityDescription = last.Subject + ' (' + last.CreatedDate.format('MM/dd/yyyy') + ')';
                } else {
                    m.lastActivityDescription = last.Subject + ' (' + last.ActivityDate.format() + ')';
                }
            } else {
                m.lastActivityDescription = 'No activity recorded';
            }

            members.add(m);
        }

        members.sort(new TeamMemberComparator());
        return members;
    }

    private static Boolean isBirthdayToday(Decimal birthMonth, Decimal birthDate) {
        if (birthMonth == null || birthDate == null) {
            return false;
        }
        Date today = Date.today();
        return today.month() == Integer.valueOf(birthMonth) && today.day() == Integer.valueOf(birthDate);
    }

    private static Map<String, Boolean> buildCommunicatedMonths(List<Task> tasks) {
        Map<String, Boolean> monthsMap = new Map<String, Boolean>();
        Set<String> monthsWithActivity = new Set<String>();

        if (tasks != null) {
            for (Task t : tasks) {
                Date effectiveDate = t.ActivityDate != null ? t.ActivityDate : t.CreatedDate.date();
                monthsWithActivity.add(String.valueOf(effectiveDate.year()) + '-' + String.valueOf(effectiveDate.month()).leftPad(2, '0'));
            }
        }

        Date currentMonthStart = Date.today().toStartOfMonth();
        for (Integer i = MONTHS_BACK; i >= 0; i--) {
            Date monthStart = currentMonthStart.addMonths(-i);
            String monthKey = String.valueOf(monthStart.year()) + '-' + String.valueOf(monthStart.month()).leftPad(2, '0');
            monthsMap.put(monthKey, monthsWithActivity.contains(monthKey));
        }
        return monthsMap;
    }

    private class TeamMemberComparator implements Comparator<TeamMember> {
        public Integer compare(TeamMember a, TeamMember b) {
            Boolean aHourly = a.isHourlyW2 == true;
            Boolean bHourly = b.isHourlyW2 == true;
            if (aHourly == bHourly) {
                return a.name.compareTo(b.name);
            }
            return aHourly ? 1 : -1;
        }
    }

    // ---------------------------------------------------------------------
    // Follow-up tasks (director-tier "assigned to me" queue)
    // ---------------------------------------------------------------------

    @AuraEnabled
    public static List<FollowUpTaskSummary> getFollowUpTasks() {
        List<FollowUpTaskSummary> results = new List<FollowUpTaskSummary>();
        for (Task t : [
            SELECT Id, WhoId, Subject, Status, Priority, ActivityDate, Who.Name, Description
            FROM Task
            WHERE OwnerId = :UserInfo.getUserId()
            AND Status != 'Completed'
            ORDER BY ActivityDate ASC
        ]) {
            FollowUpTaskSummary s = new FollowUpTaskSummary();
            s.id = t.Id;
            s.whoId = t.WhoId;
            s.whoName = t.Who != null ? t.Who.Name : null;
            s.subject = t.Subject;
            s.status = t.Status;
            s.priority = t.Priority;
            s.activityDate = t.ActivityDate;
            s.description = t.Description;
            results.add(s);
        }
        return results;
    }

    @AuraEnabled(cacheable=true)
    public static FollowUpTaskDetail getFollowUpTask(Id taskId) {
        List<Task> tasks = [
            SELECT Id, Subject, Description, Status, ActivityDate, Interaction_Type__c, Task_Outcome_Detail__c
            FROM Task
            WHERE Id = :taskId
            LIMIT 1
        ];
        if (tasks.isEmpty()) {
            return null;
        }
        Task t = tasks[0];
        FollowUpTaskDetail d = new FollowUpTaskDetail();
        d.id = t.Id;
        d.subject = t.Subject;
        d.activityDate = t.ActivityDate;
        d.description = t.Description;
        d.interactionType = t.Interaction_Type__c;
        d.taskOutcomeDetail = t.Task_Outcome_Detail__c;
        d.status = t.Status;
        return d;
    }

    @AuraEnabled
    public static void updateFollowUpTask(Id taskId, String interactionType, String taskOutcomeDetail, String status) {
        update new Task(
            Id = taskId,
            Interaction_Type__c = interactionType,
            Task_Outcome_Detail__c = taskOutcomeDetail,
            Status = status
        );
    }

    // ---------------------------------------------------------------------
    // Log activity (with optional escalation)
    // ---------------------------------------------------------------------

    @AuraEnabled(cacheable=true)
    public static ContactSummary getContactSummary(Id contactId) {
        List<Contact> contacts = [
            SELECT Id, Name, AccountId, Account.Name, HPG_Title__c
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];
        if (contacts.isEmpty()) {
            return null;
        }
        Contact c = contacts[0];
        ContactSummary summary = new ContactSummary();
        summary.id = c.Id;
        summary.name = c.Name;
        summary.accountId = c.AccountId;
        summary.accountName = c.Account != null ? c.Account.Name : null;
        summary.title = c.HPG_Title__c;
        return summary;
    }

    @AuraEnabled(cacheable=true)
    public static List<PicklistOption> getEscalationOptions() {
        List<PicklistOption> options = new List<PicklistOption>();
        options.add(new PicklistOption('None', '0'));
        for (User u : [
            SELECT Id, Name
            FROM User
            WHERE Title IN ('Sr. Vice President, Consulting Services', 'Application Services Director and CTO')
            AND IsActive = true
        ]) {
            options.add(new PicklistOption(u.Name, u.Id));
        }
        return options;
    }

    @AuraEnabled(cacheable=true)
    public static List<PicklistOption> getInteractionTypeOptions() {
        return picklistOptions(Task.Interaction_Type__c.getDescribe());
    }

    @AuraEnabled(cacheable=true)
    public static List<PicklistOption> getTaskStatusOptions() {
        return picklistOptions(Task.Status.getDescribe());
    }

    private static List<PicklistOption> picklistOptions(Schema.DescribeFieldResult fieldDescribe) {
        List<PicklistOption> options = new List<PicklistOption>();
        for (Schema.PicklistEntry entry : fieldDescribe.getPicklistValues()) {
            if (entry.isActive()) {
                options.add(new PicklistOption(entry.getLabel(), entry.getValue()));
            }
        }
        return options;
    }

    @AuraEnabled
    public static void logActivity(Id whoId, String whoName, Id whatId, String interactionType, Date activityDate, String comments, Id escalateToUserId) {
        Task t = new Task(
            WhoId = whoId,
            WhatId = whatId,
            OwnerId = UserInfo.getUserId(),
            RecordTypeId = taskRecordTypeId(),
            Interaction_Type__c = interactionType,
            Subject = interactionType,
            Status = 'Completed',
            ActivityDate = activityDate,
            Description = comments
        );
        insert t;

        if (escalateToUserId != null) {
            Task escalation = new Task(
                Subject = 'Follow Up With ' + whoName,
                ActivityDate = Date.today().addDays(7),
                Status = 'In Progress',
                OwnerId = escalateToUserId,
                Description = 'Follow Up With ' + whoName + ' about ' + comments,
                WhatId = whatId,
                WhoId = whoId,
                RecordTypeId = taskRecordTypeId()
            );
            insert escalation;
        }
    }
}