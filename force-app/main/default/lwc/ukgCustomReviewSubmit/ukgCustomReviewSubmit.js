import { LightningElement, api, wire } from 'lwc';
import getReviewSummary from '@salesforce/apex/UkgReviewDataController.getReviewSummary';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// Define the fields needed for initial date population
const CONTACT_FIELDS = [
    'Contact.Hire_Date_Anniversary__c',
    'Contact.UKG_ID__c',
];

/**
 * ukgCustomReviewSubmit.js
 * * Component allows user to manually select Start and End dates for the UKG review summary.
 * * It defaults the dates based on the Contact's Hire_Date_Anniversary__c field.
 */
export default class UkgCustomReviewSubmit extends LightningElement {
    @api recordId;

    startDate;
    endDate;
    
    summary = null;
    isLoading = false; // Start as false since we wait for button click
    error = null;
    
    // Datatable Columns (Same as previous component)
    projectColumns = [
        { label: 'Project / Description', fieldName: 'description', type: 'text' },
        { label: 'Hours / Units', fieldName: 'hours', type: 'number', cellAttributes: { alignment: 'center' } }
    ];

    // --- Wire Service to Get Initial Dates from Contact Record ---

    @wire(getRecord, { recordId: '$recordId', fields: CONTACT_FIELDS })
    wiredContact({ error, data }) {
        if (data) {
            const hireDate = getFieldValue(data, CONTACT_FIELDS[0]);
            const ukgId = getFieldValue(data, CONTACT_FIELDS[1]);
            
            if (hireDate) {
                this.initializeDates(hireDate);
            }
            if (!ukgId) {
                this.error = { body: { message: 'UKG Employee ID is missing from this Contact record. Cannot run report.' } };
            }

        } else if (error) {
            this.error = { body: { message: 'Could not load Contact data. Ensure required fields are accessible.' } };
        }
    }

    // --- Helper to Calculate Default Dates ---

    initializeDates(hireDateAnniversaryStr) {
        try {
            // Convert Salesforce YYYY-MM-DD string to Date object
            const parts = hireDateAnniversaryStr.split('-').map(Number);
            // Date constructor: new Date(year, monthIndex, day)
            const hireDate = new Date(parts[0], parts[1] - 1, parts[2]);

            // Review End Date = Hire Date Anniversary - 1 day
            const reviewEndDate = new Date(hireDate);
            reviewEndDate.setDate(reviewEndDate.getDate() - 1);
            
            // Review Start Date = Review End Date - 1 year + 1 day
            const reviewStartDate = new Date(reviewEndDate);
            reviewStartDate.setFullYear(reviewStartDate.getFullYear() - 1);
            reviewStartDate.setDate(reviewStartDate.getDate() + 1);

            // Format dates back to YYYY-MM-DD for lightning-input type="date"
            this.startDate = this.formatDateForInput(reviewStartDate);
            this.endDate = this.formatDateForInput(reviewEndDate);

        } catch (e) {
            this.error = { body: { message: 'Error calculating default review dates from Hire Date Anniversary.' } };
        }
    }

    formatDateForInput(date) {
        // Formats a Date object to YYYY-MM-DD string
        const yyyy = date.getFullYear();
        const mm = String(date.getMonth() + 1).padStart(2, '0'); // Months are 0-indexed
        const dd = String(date.getDate()).padStart(2, '0');
        return `${yyyy}-${mm}-${dd}`;
    }

    // --- Sorting Helper ---
    
    sortProjects(projects) {
        if (!projects) return [];
        // Sorts alphabetically based on the 'description' field
        return projects.sort((a, b) => {
            const descA = a.description ? a.description.toUpperCase() : '';
            const descB = b.description ? b.description.toUpperCase() : '';
            if (descA < descB) return -1;
            if (descA > descB) return 1;
            return 0;
        });
    }

    // --- Event Handlers ---

    handleStartDateChange(event) {
        this.startDate = event.target.value;
        this.summary = null;
        this.error = null;
    }

    handleEndDateChange(event) {
        this.endDate = event.target.value;
        this.summary = null;
        this.error = null;
    }

    handleRunReport() {
        if (!this.startDate || !this.endDate) {
            this.error = { body: { message: 'Please select both a Start Date and an End Date.' } };
            return;
        }
        
        this.fetchReviewSummary();
    }

    // --- Data Fetching ---

    fetchReviewSummary() {
        this.isLoading = true;
        this.error = null;
        this.summary = null;

        // Apex method now receives the explicit dates from the LWC inputs
        getReviewSummary({ 
            contactId: this.recordId,
            startDateStr: this.startDate, // Pass custom date string
            endDateStr: this.endDate     // Pass custom date string
        })
        .then(result => {
            // Apply sorting immediately after receiving results
            result.billableProjects = this.sortProjects(result.billableProjects);
            result.nonBillableItems = this.sortProjects(result.nonBillableItems);
            result.onCallUnits = this.sortProjects(result.onCallUnits);

            this.summary = result;
            if (!result.reviewPeriod) {
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

    // --- Getters for Display ---

    get isDataAvailable() {
        if (!this.summary) return false;
        return (
            (this.summary.billableProjects && this.summary.billableProjects.length > 0) ||
            (this.summary.nonBillableItems && this.summary.nonBillableItems.length > 0) ||
            (this.summary.onCallUnits && this.summary.onCallUnits.length > 0)
        );
    }
    
    // ... Total calculation getters (same as before) ...
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

    // --- Debug Getters ---
    
    get debugButtonLabel() {
        return this.showDebug ? 'Hide Debug' : 'Show Debug';
    }
    
    get debugBillable() {
        return this.summary && this.summary.billableProjects 
            ? JSON.stringify(this.summary.billableProjects, null, 2) 
            : '[]';
    }
    
    get debugNonBillable() {
        return this.summary && this.summary.nonBillableItems 
            ? JSON.stringify(this.summary.nonBillableItems, null, 2) 
            : '[]';
    }
    
    get debugOnCall() {
        return this.summary && this.summary.onCallUnits 
            ? JSON.stringify(this.summary.onCallUnits, null, 2) 
            : '[]';
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
