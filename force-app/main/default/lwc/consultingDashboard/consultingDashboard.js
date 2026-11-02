import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import BIRTHDAY_ICON from '@salesforce/resourceUrl/Icon_HPG_Birthday';
import HOURLY_W2_ICON from '@salesforce/resourceUrl/Icon_HPG_HW2';
import getDashboardContext from '@salesforce/apex/ConsultingDashboardController.getDashboardContext';
import getTeamRoster from '@salesforce/apex/ConsultingDashboardController.getTeamRoster';
import getFollowUpTasks from '@salesforce/apex/ConsultingDashboardController.getFollowUpTasks';
import TaskLogModal from 'c/taskLogModal';
import FollowUpTaskModal from 'c/followUpTaskModal';

const MONTHS_BACK = 13;
const HOURLY_W2_TITLE = 'Senior Consultant Hourly W-2';
const SCM_ROSTER_VALUE = 'SCM';

export default class ConsultingDashboard extends NavigationMixin(LightningElement) {
    isDirector = false;
    teamLeadOptions = [];
    selectedTeamLeadId;

    roster = [];
    monthHeaders = [];
    followUpTasks = [];

    isLoadingContext = true;
    isLoadingRoster = false;
    isLoadingFollowUps = false;
    errorMessage;

    monthHeaderKeys = [];

    birthdayIconUrl = BIRTHDAY_ICON;
    hourlyW2IconUrl = HOURLY_W2_ICON;

    connectedCallback() {
        this.monthHeaderKeys = this.buildMonthKeys();
        this.monthHeaders = this.monthHeaderKeys.map((m) => ({ key: m.key, label: m.label }));
        this.loadContext();
    }

    buildMonthKeys() {
        const keys = [];
        const now = new Date();
        for (let i = MONTHS_BACK; i >= 0; i--) {
            const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
            const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
            const label = d.toLocaleDateString('en-US', { month: 'short', year: 'numeric' });
            keys.push({ key, label });
        }
        return keys;
    }

    async loadContext() {
        this.isLoadingContext = true;
        this.errorMessage = undefined;
        try {
            const ctx = await getDashboardContext();
            this.isDirector = ctx.isDirector;
            this.teamLeadOptions = (ctx.teamLeadOptions || []).map((o) => ({ label: o.label, value: o.value }));
            if (this.isDirector && this.teamLeadOptions.length > 0) {
                const firstRealTeamLead = this.teamLeadOptions.find((o) => o.value !== SCM_ROSTER_VALUE);
                this.selectedTeamLeadId = firstRealTeamLead ? firstRealTeamLead.value : this.teamLeadOptions[0].value;
            }
            const loads = [this.loadRoster()];
            if (this.isDirector) {
                loads.push(this.loadFollowUpTasks());
            }
            await Promise.all(loads);
        } catch (e) {
            this.errorMessage = this.reduceError(e);
        } finally {
            this.isLoadingContext = false;
        }
    }

    async loadRoster() {
        this.isLoadingRoster = true;
        try {
            const members = await getTeamRoster({
                teamLeadSelection: this.isDirector ? this.selectedTeamLeadId : null
            });
            this.roster = members.map((m) => this.decorateMember(m));
        } catch (e) {
            this.errorMessage = this.reduceError(e);
        } finally {
            this.isLoadingRoster = false;
        }
    }

    async loadFollowUpTasks() {
        this.isLoadingFollowUps = true;
        try {
            this.followUpTasks = await getFollowUpTasks();
        } catch (e) {
            this.errorMessage = this.reduceError(e);
        } finally {
            this.isLoadingFollowUps = false;
        }
    }

    decorateMember(member) {
        const monthCells = this.monthHeaderKeys.map((m) => ({
            key: `${member.id}-${m.key}`,
            checked: member.communicatedMonths ? member.communicatedMonths[m.key] === true : false
        }));
        const hasLastActivity = member.lastActivityDescription !== 'No activity recorded';
        return {
            ...member,
            monthCells,
            hasLastActivity,
            showHourlyIcon: member.hpgTitle === HOURLY_W2_TITLE,
            birthdayTitle: `It's ${member.name}'s Birthday!`
        };
    }

    get hasRoster() {
        return this.roster && this.roster.length > 0;
    }

    get hasFollowUpTasks() {
        return this.followUpTasks && this.followUpTasks.length > 0;
    }

    get showTeamLeadPicker() {
        return this.isDirector && this.teamLeadOptions.length > 0;
    }

    handleTeamLeadChange(event) {
        this.selectedTeamLeadId = event.detail.value;
        this.loadRoster();
    }

    handleRefreshAll() {
        this.loadRoster();
        if (this.isDirector) {
            this.loadFollowUpTasks();
        }
    }

    async handleLogActivity(event) {
        event.preventDefault();
        const { contactId, contactName, accountId, accountName } = event.currentTarget.dataset;
        const result = await TaskLogModal.open({
            size: 'small',
            label: 'Log New Activity',
            whoId: contactId,
            whoName: contactName,
            whatId: accountId,
            accountName
        });
        if (result === 'saved') {
            this.showToast('Success', 'Task has been logged successfully.', 'success');
            this.loadRoster();
        }
    }

    async handleLogActivityWithAnyone() {
        const result = await TaskLogModal.open({
            size: 'small',
            label: 'Log New Activity'
        });
        if (result === 'saved') {
            this.showToast('Success', 'Task has been logged successfully.', 'success');
            this.loadRoster();
        }
    }

    async handleOpenFollowUp(event) {
        event.preventDefault();
        const { taskId } = event.currentTarget.dataset;
        const result = await FollowUpTaskModal.open({
            size: 'small',
            label: 'Edit Task Details',
            taskId
        });
        if (result === 'saved') {
            this.showToast('Success', 'Task updated successfully.', 'success');
            this.loadFollowUpTasks();
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    handleOpenRecord(event) {
        event.preventDefault();
        const { recordId } = event.currentTarget.dataset;
        if (!recordId) {
            return;
        }
        this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                actionName: 'view'
            }
        }).then((url) => {
            window.open(url, '_blank');
        });
    }

    reduceError(error) {
        return (error && error.body && error.body.message) || (error && error.message) || 'An unknown error occurred.';
    }
}