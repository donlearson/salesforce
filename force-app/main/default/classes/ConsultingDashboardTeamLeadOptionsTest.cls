/**
 * ConsultingDashboardTeamLeadOptionsTest
 * Covers the team lead picker in ConsultingDashboardController, which is driven by
 * user role (Team Lead / Support Center Manager) rather than profile.
 */
@isTest
private class ConsultingDashboardTeamLeadOptionsTest {

    private static User createUser(String lastName, Id roleId, Boolean isActive) {
        User u = new User(
            FirstName = 'Picker',
            LastName = lastName,
            Email = lastName.toLowerCase() + '@example.com',
            Username = 'ConsultingTeamLeadPicker' + lastName + '@example.com',
            Alias = lastName.left(8),
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Team Lead' LIMIT 1].Id,
            UserRoleId = roleId,
            IsActive = isActive
        );
        insert u;
        return u;
    }

    private static Id roleId(String developerName) {
        List<UserRole> roles = [SELECT Id FROM UserRole WHERE DeveloperName = :developerName LIMIT 1];
        System.assertEquals(1, roles.size(), 'Expected the ' + developerName + ' role to exist');
        return roles[0].Id;
    }

    @isTest
    static void testPickerIncludesTeamLeadAndSupportCenterManagerRoles() {
        User teamLead = createUser('PickerTL', roleId('Team_Lead'), true);
        User centerManager = createUser('PickerSCM', roleId('Support_Center_Manager'), true);

        Set<String> optionValues = new Set<String>();
        Test.startTest();
        for (ConsultingDashboardController.TeamLeadOption opt : ConsultingDashboardController.getDashboardContext().teamLeadOptions) {
            optionValues.add(opt.value);
        }
        Test.stopTest();

        System.assert(optionValues.contains(String.valueOf(teamLead.Id)), 'Expected a user in the Team Lead role');
        System.assert(optionValues.contains(String.valueOf(centerManager.Id)), 'Expected a user in the Support Center Manager role');
    }

    @isTest
    static void testPickerExcludesOtherRolesNoRoleAndInactiveUsers() {
        // Profile alone no longer qualifies someone: all of these hold the Team Lead profile.
        User noRole = createUser('PickerNoRole', null, true);
        User otherRole = createUser('PickerOther', roleId('Consulting_Director'), true);
        User inactiveTeamLead = createUser('PickerInact', roleId('Team_Lead'), false);

        Set<String> optionValues = new Set<String>();
        Test.startTest();
        for (ConsultingDashboardController.TeamLeadOption opt : ConsultingDashboardController.getDashboardContext().teamLeadOptions) {
            optionValues.add(opt.value);
        }
        Test.stopTest();

        System.assert(!optionValues.contains(String.valueOf(noRole.Id)), 'A user with the profile but no role should not be listed');
        System.assert(!optionValues.contains(String.valueOf(otherRole.Id)), 'A user in a different role should not be listed');
        System.assert(!optionValues.contains(String.valueOf(inactiveTeamLead.Id)), 'An inactive user should not be listed');
        System.assert(optionValues.contains(ConsultingDashboardController.SCM_ROSTER_VALUE), 'The SCM roster option should always be listed');
    }
}
