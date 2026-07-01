import { LightningElement, api } from 'lwc';
import getTimeEntries from '@salesforce/apex/UkgDataController.getTimeEntries';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

/**
 * ukgTimeTracker.js
 * * This LWC displays aggregated bench time data retrieved from the UKG system.
 * It shows 5 weeks of bench hours, grouped by user, with a dedicated icon link column
 * where a Contact match is found.
 */
export default class UkgTimeTracker extends LightningElement {
    @api recordId;

    benchSummaries = [];
    weekEndDates = [];

    isLoading = true;
    error = null;
    hasData = false;

    connectedCallback() {
        this.fetchBenchSummaries();
    }
    
    // NEW: Method called by the Refresh button
    handleRefresh() {
        this.fetchBenchSummaries();
    }

    fetchBenchSummaries() {
        this.isLoading = true;
        this.error = null;

        getTimeEntries({ contactId: this.recordId })
            .then(wrapper => {
                this.weekEndDates = wrapper.weekEndDates; 
                
                // Transformation: Prepare data for the datatable.
                const summaries = wrapper.summaries || [];
                
                this.benchSummaries = summaries.map((item, index) => {
                    const contactId = item.contactId;
                    const userName = item.userName;

                    // ContactLink: Set to URL if contactId exists, otherwise ''.
                    const linkUrl = contactId ? `/lightning/r/Contact/${contactId}/view` : '';

                    return {
                        ...item,
                        id: index,
                        // contactIconLink holds the URL ('') if no match)
                        contactIconLink: linkUrl,
                        // contactName holds the name text (always present)
                        contactName: userName
                    };
                });

                this.hasData = this.benchSummaries.length > 0;
            })
            .catch(error => {
                this.error = error;
                this.benchSummaries = [];
                this.hasData = false;
                
                const evt = new ShowToastEvent({
                    title: "UKG Bench Data Retrieval Error",
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
                // Apex returns 'YYYY-MM-DD' format; month is 0-indexed in JS Date
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
