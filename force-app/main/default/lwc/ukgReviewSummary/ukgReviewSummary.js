import { LightningElement, api } from 'lwc';
import getReviewSummary from '@salesforce/apex/UkgReviewDataController.getReviewSummary';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/**
 * ukgReviewSummary.js
 * * Displays Billable, Non-Billable, and On-Call hours for the employee's review period
 * * The component is only intended for use on the Contact record page.
 */
export default class UkgReviewSummary extends LightningElement {
    @api recordId;

    summary = null;
    isLoading = true;
    error = null;
    showDebug = false; // NEW: Debug flag
    
    // Datatable Columns
    projectColumns = [
        { label: 'Project / Description', fieldName: 'description', type: 'text' },
        { label: 'Hours / Units', fieldName: 'hours', type: 'number', cellAttributes: { alignment: 'center' } }
    ];
    
    connectedCallback() {
        this.fetchReviewSummary();
    }
    
    handleRefresh() {
        this.fetchReviewSummary();
    }

    // NEW: Toggle debug panel visibility
    toggleDebug() {
        this.showDebug = !this.showDebug;
    }

    fetchReviewSummary() {
        this.isLoading = true;
        this.error = null;
        this.summary = null;

        getReviewSummary({ contactId: this.recordId })
            .then(result => {
                this.summary = result;
                if (!result.reviewPeriod) {
                    // If reviewPeriod is null, it means essential fields (like Hire Date) were missing.
                    this.error = { body: { message: 'Required Contact fields (Hire Date, UKG ID) are missing or invalid.' } };
                    this.summary = null;
                }
            })
            .catch(error => {
                this.error = error;
                const evt = new ShowToastEvent({
                    title: "UKG Review Data Retrieval Error",
                    message: this.getErrorMessage(error),
                    variant: "error",
                });
                this.dispatchEvent(evt);
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    get isDataAvailable() {
        if (!this.summary) return false;
        // Check if any of the three lists have data
        return (
            (this.summary.billableProjects && this.summary.billableProjects.length > 0) ||
            (this.summary.nonBillableItems && this.summary.nonBillableItems.length > 0) ||
            (this.summary.onCallUnits && this.summary.onCallUnits.length > 0)
        );
    }
    
    // Debug Getter for Billable Projects
    get debugBillable() {
        return this.summary && this.summary.billableProjects 
            ? JSON.stringify(this.summary.billableProjects, null, 2) 
            : '[]';
    }

    // Debug Getter for Non-Billable Items
    get debugNonBillable() {
        return this.summary && this.summary.nonBillableItems 
            ? JSON.stringify(this.summary.nonBillableItems, null, 2) 
            : '[]';
    }
    
    // Debug Getter for On-Call Units
    get debugOnCall() {
        return this.summary && this.summary.onCallUnits 
            ? JSON.stringify(this.summary.onCallUnits, null, 2) 
            : '[]';
    }

    get totalBillableHours() {
        if (!this.summary || !this.summary.billableProjects) return '0.00';
        return this.summary.billableProjects.reduce((acc, curr) => acc + curr.hours, 0).toFixed(2);
    }

    get totalNonBillableHours() {
        if (!this.summary || !this.summary.nonBillableItems) return '0.00';
        return this.summary.nonBillableItems.reduce((acc, curr) => acc + curr.hours, 0).toFixed(2);
    }

    get totalOnCallUnits() {
        if (!this.summary || !this.summary.onCallUnits) return '0.00';
        return this.summary.onCallUnits.reduce((acc, curr) => acc + curr.hours, 0).toFixed(2);
    }

    getErrorMessage(error) {
        if (error.body && error.body.message) {
            return error.body.message;
        } else if (error.message) {
            return error.message;
        }
        return "An unknown error occurred while fetching UKG data.";
    }
}