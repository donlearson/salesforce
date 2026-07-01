import { LightningElement, api } from 'lwc';
import getTimeEntries from '@salesforce/apex/UkgBillableHoursW2Controller.getTimeEntries';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/**
 * ukgBillableHoursW2Tracker.js
 * * This LWC displays aggregated PW2 billable hours data retrieved from the UKG system.
 */
export default class UkgBillableHoursW2Tracker extends LightningElement {
    @api recordId;

    benchSummaries = [];
    weekEndDates = [];

    isLoading = true;
    error = null;
    hasData = false;

    columns = [];
    
    constructor() {
        super();
        this.columns = [];
    }
    
    connectedCallback() {
        this.fetchBenchSummaries();
    }
    
    handleRefresh() {
        this.fetchBenchSummaries();
    }

    fetchBenchSummaries() {
        this.isLoading = true;
        this.error = null;

        getTimeEntries({ contactId: this.recordId })
            .then(wrapper => {
                this.weekEndDates = wrapper.weekEndDates; 
                
                const summaries = wrapper.summaries || [];
                
                let processedSummaries = summaries.map((item, index) => {
                    const contactId = item.contactId;
                    const userName = item.userName;

                    const linkUrl = contactId ? `/lightning/r/Contact/${contactId}/view` : '';

                    return {
                        ...item,
                        id: index,
                        contactIconLink: linkUrl,
                        contactName: userName,
                        hasW1Segments: (item.w1_15hSegments > 0 || item.w1_24hSegments > 0),
                        hasW2Segments: (item.w2_15hSegments > 0 || item.w2_24hSegments > 0),
                        hasW3Segments: (item.w3_15hSegments > 0 || item.w3_24hSegments > 0),
                        hasW4Segments: (item.w4_15hSegments > 0 || item.w4_24hSegments > 0),
                        hasW5Segments: (item.w5_15hSegments > 0 || item.w5_24hSegments > 0),
                        hasTotalSegments: (item.total15hSegments > 0 || item.total24hSegments > 0)
                    };
                });
                
                // Sort the data alphabetically by Employee Name (userName)
                processedSummaries.sort((a, b) => {
                    const nameA = a.contactName.toUpperCase();
                    const nameB = b.contactName.toUpperCase();
                    if (nameA < nameB) return -1;
                    if (nameA > nameB) return 1;
                    return 0;
                });
                
                this.benchSummaries = processedSummaries;
                this.hasData = this.benchSummaries.length > 0;
            })
            .catch(error => {
                this.error = error;
                this.benchSummaries = [];
                this.hasData = false;
                
                const evt = new ShowToastEvent({
                    title: "UKG PW2 Billable Hours Retrieval Error",
                    message: this.getErrorMessage(error),
                    variant: "error",
                });
                this.dispatchEvent(evt);
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    get formattedWeekHeaders() {
        const dateFormatter = new Intl.DateTimeFormat('en-US', { month: '2-digit', day: '2-digit', year: '2-digit' });
        return this.weekEndDates.map(dateStr => {
            let formatted = dateStr;
            try {
                const dateParts = dateStr.split('-').map(p => parseInt(p));
                const date = new Date(dateParts[0], dateParts[1] - 1, dateParts[2]);
                formatted = dateFormatter.format(date);
            } catch (e) {
                console.error('Failed to parse date string:', dateStr, e);
            }
            return {
                date: dateStr,
                formatted: formatted
            };
        });
    }

    getErrorMessage(error) {
        if (error.body && error.body.message) {
            return error.body.message;
        } else if (error.message) {
            return error.message;
        } else if (error.body && error.body.exceptionType && error.body.stackTrace) {
            return `Apex Error: ${error.body.exceptionType}`;
        }
        return "An unknown error occurred while fetching UKG data.";
    }

    get showTable() {
        return this.hasData && !this.isLoading && !this.error && this.weekEndDates.length > 0;
    }

    get showNoData() {
        return !this.hasData && !this.isLoading && !this.error;
    }
}
