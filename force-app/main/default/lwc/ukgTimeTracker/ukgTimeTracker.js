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

    columns = [];
    
    constructor() {
        super();
        this.columns = [];
    }
    
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
                        contactName: userName,
                        totalClass: 'slds-text-heading_small slds-text-color_success'
                    };
                });
                
                this.columns = this.getBenchTimeColumns();
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

    // Helper to generate columns, now using a dedicated "Link" text column.
    getBenchTimeColumns() {
        const dateFormatter = new Intl.DateTimeFormat('en-US', { month: '2-digit', day: '2-digit', year: '2-digit' });

        const formatDateLabel = (dateString) => {
            if (dateString === 'N/A') return 'N/A';
            try {
                // Apex returns 'YYYY-MM-DD' format
                const dateParts = dateString.split('-').map(p => parseInt(p));
                // Month is 0-indexed in JavaScript Date constructor (dateParts[1] - 1)
                const date = new Date(dateParts[0], dateParts[1] - 1, dateParts[2]);
                return dateFormatter.format(date);
            } catch (e) {
                console.error('Failed to parse date string from Apex:', dateString, e);
                return dateString;
            }
        };

        let cols = [];
        
        // Only show the link column if recordId is NOT present (i.e., Home Page or App Page)
        if (!this.recordId) {
            cols.push({ 
                label: 'Link', // Column header is "Link"
                fieldName: 'contactIconLink', 
                type: 'url', 
                // Keep fixed width for the small link column
                fixedWidth: 80, 
                typeAttributes: { 
                    label: 'View', // The text displayed for the link
                    target: '_blank',
                } 
            });
        }

        cols.push({ 
            label: 'Employee Name', 
            fieldName: 'contactName', // Pure text field, always visible
            type: 'text', 
            // Removed initialWidth for dynamic resizing
        });
        
        // Weekly Columns
        for (let i = 0; i < 5; i++) {
            const dateStr = this.weekEndDates[i] || 'N/A';
            cols.push({
                // Header centering is handled by CSS injection in HTML
                label: `${formatDateLabel(dateStr)}`, 
                fieldName: `w${i + 1}Hours`, 
                type: 'number', 
                // Removed initialWidth for dynamic resizing
                cellAttributes: { 
                    alignment: 'center' // Only need alignment here for cell content
                }
            });
        }
        
        // Total Column
        cols.push({
            label: 'Total (5 Weeks)', 
            fieldName: 'total5WeekHours', 
            type: 'number', 
            // Removed initialWidth for dynamic resizing
            cellAttributes: { 
                // Keep classes for text styling, but rely on CSS for header centering
                class: 'slds-text-heading_small slds-text-color_success',
                alignment: 'center'
            }
        });

        return cols;
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
        return this.hasData && !this.isLoading && !this.error && this.columns.length > 0;
    }

    get showNoData() {
        return !this.hasData && !this.isLoading && !this.error;
    }
}
