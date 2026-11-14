/**
 * Capitalised words the person-name masker never treats as a name, on top of NOT_NAMES (m5-03, ADR 0005 second pass).
 * Ordinary English words that start sentences, greetings and sign-offs, team and role words, and common product and
 * company names. A word here is never a surname after a given name, never a name after a cue or honorific.
 */
export const STOP_WORDS: readonly string[] = [
  // Articles, pronouns, determiners, question words
  "A", "An", "The", "I", "Me", "My", "Mine", "We", "Us", "Our", "You", "Your", "He", "Him", "His", "She", "Her",
  "It", "Its", "They", "Them", "Their", "This", "That", "These", "Those", "There", "Here", "What", "Which", "Who",
  "Whom", "Whose", "When", "Where", "Why", "How", "Some", "Any", "All", "Each", "Every", "Both", "Either", "Neither",
  "No", "None", "Nothing", "Something", "Anything", "Everything", "Someone", "Anyone", "Everyone", "Nobody",
  "Somebody", "Anybody", "Everybody", "Other", "Others", "Another", "Such", "Same", "Few", "Many", "Much", "More",
  "Most", "Less", "Least", "Several", "Own",
  // Auxiliaries and common sentence-start verbs
  "Is", "Are", "Was", "Were", "Be", "Been", "Being", "Am", "Do", "Does", "Did", "Done", "Have", "Has", "Had", "Can",
  "Could", "Shall", "Should", "Would", "Must", "Might", "Let", "Lets", "Let's", "Ask", "Asked", "Send", "Sent",
  "Reply", "Replied", "Forward", "Forwarded", "Schedule", "Scheduled", "Check", "Review", "Update", "Updated", "Add",
  "Added", "Remove", "Make", "Get", "Got", "Go", "Going", "See", "Seen", "Saw", "Look", "Find", "Call", "Meet",
  "Join", "Follow", "Confirm", "Confirmed", "Approve", "Approved", "Sign", "Signed", "Note", "Notes", "Attached",
  "Assigned", "Assign", "Move", "Moved", "Set", "Use", "Try", "Start", "Stop", "Open", "Close", "Closed", "Keep",
  "Need", "Needs", "Want", "Wants", "Write", "Read", "Print", "Save", "Share", "Shared", "Submit", "Submitted",
  "Create", "Created", "Delete", "Deleted", "Edit", "Edited", "Pay", "Paid", "Book", "Booked", "Cancel",
  "Cancelled", "Remind", "Reminder", "Thank", "Thanks", "Welcome", "Congrats", "Congratulations", "Sorry", "Yes",
  "Ok", "Okay", "Sure", "Great", "Good", "Nice", "Fine", "Done", "Fyi", "Asap", "Urgent", "Important", "Quick",
  "Just", "Also", "Then", "Now", "Today", "Tomorrow", "Yesterday", "Tonight", "Later", "Soon", "Again", "Still",
  "Already", "Maybe", "Perhaps", "Please", "Kindly", "Not", "Never", "Always", "Only", "Even", "Very", "So", "Too",
  "As", "If", "Unless", "Until", "While", "Because", "Since", "Though", "Although", "But", "And", "Or", "Nor", "Yet",
  "For", "Of", "On", "In", "At", "By", "To", "From", "With", "Without", "Into", "Onto", "Over", "Under", "About",
  "After", "Before", "During", "Between", "Through", "Per", "Via", "Re", "Fwd", "Fw", "Cc", "Bcc", "Attn",
  // Greetings and sign-offs
  "Hi", "Hello", "Hey", "Dear", "Cheers", "Regards", "Best", "Kind", "Warm", "Warmest", "Wishes", "Sincerely",
  "Yours", "Truly", "Faithfully", "Morning", "Afternoon", "Evening", "Night", "World", "There", "Folks", "Guys",
  "Sir", "Madam", "Team", "Teams", "Colleague", "Colleagues", "Friend", "Friends", "Customer", "Customers", "Client",
  "Clients", "Partner", "Partners", "Member", "Members", "User", "Users", "Hiring", "Manager", "Managers",
  // Roles, departments, documents
  "Finance", "Sales", "Marketing", "Support", "Legal", "Engineering", "Product", "Operations", "Ops", "Accounts",
  "Accounting", "Billing", "Payroll", "Admin", "Admins", "Info", "Office", "Board", "Committee", "Department",
  "Director", "Manager", "Owner", "Reviewer", "Assistant", "Officer", "President", "Lead", "Head", "Staff", "Group",
  "Company", "Inc", "Ltd", "Llc", "Corp", "Bank", "University", "School", "Hospital", "Council", "Ministry",
  "Meeting", "Meetings", "Call", "Sync", "Standup", "Agenda", "Minutes", "Project", "Projects", "Task", "Tasks",
  "Ticket", "Issue", "Issues", "Contract", "Proposal", "Draft", "Document", "Documents", "File", "Files", "Folder",
  "Spreadsheet", "Sheet", "Tab", "Page", "Slide", "Slides", "Deck", "Budget", "Expense", "Expenses", "Receipt",
  "Order", "Purchase", "Quote", "Statement", "Account", "Payment", "Lunch", "Dinner", "Breakfast", "Coffee",
  "Q1", "Q2", "Q3", "Q4", "Lab", "Lease", "Renewal", "Onboarding", "Checklist", "Timesheet", "Deadline", "Vendor",
  "Contact", "Subject", "Body", "Inbox", "Email", "Mail", "Message", "Messages", "Chat", "Thread", "Event", "Events",
  "Status", "Total", "Totals", "Summary", "Results", "Data", "Table", "Chart", "Dashboard", "New", "Old", "Next",
  "Last", "First", "Second", "Third", "Final", "Weekly", "Monthly", "Daily", "Annual", "Quarterly", "Week", "Month",
  "Year", "Day", "Hour", "Mon", "Tue", "Tues", "Wed", "Thu", "Thurs", "Fri", "Sat", "Sun", "Feb", "Mar", "Apr",
  "Jul", "Aug", "Sep", "Sept", "Oct", "Nov", "Dec", "North", "South", "East", "West", "Street", "Road", "Avenue",
  // Common apps, companies and places
  "Google", "Gmail", "Microsoft", "Outlook", "Office", "Excel", "PowerPoint", "Word", "OneDrive", "SharePoint",
  "Apple", "Mac", "iPhone", "Safari", "Chrome", "Firefox", "Amazon", "Zoom", "Slack", "Notion", "Jira",
  "Confluence", "Asana", "Trello", "Figma", "GitHub", "Gitlab", "Salesforce", "HubSpot", "Stripe", "Dropbox",
  "LinkedIn", "Twitter", "Facebook", "Instagram", "WhatsApp", "Telegram", "Xero", "QuickBooks", "Airtable",
  "Calendly", "Docusign", "DocuSign", "Linear", "Monday", "Offload", "Claude", "Anthropic", "OpenAI", "Sheets",
  "Docs", "Drive", "Calendar", "Meet", "Forms", "Keynote", "Numbers", "Pages", "Finder", "Terminal", "Visa",
  "Mastercard", "PayPal", "Uber", "Airbnb", "London", "Paris", "Berlin", "Tokyo", "York", "Europe", "America", "Asia",
  "Africa", "English", "French", "German", "Spanish", "Christmas", "Easter",
];
