/**
 * Name lexicon for the model router's person-name masker (m5-03, ADR 0005 second pass). Written fresh for v2.
 *
 * GIVEN_NAMES: common given names across languages. A word in this list is a name on its own.
 * AMBIGUOUS_GIVEN_NAMES: given names that are also ordinary English words; a name only when followed by a capitalised
 * surname or preceded by a cue.
 * HONORIFICS: a capitalised word after one of these is a surname.
 * CUES: a capitalised word after one of these (case-sensitive) is a name even when it is not in the lexicon.
 * NOT_NAMES: capitalised words that are never treated as names (days, months, common app and document words).
 */

export const GIVEN_NAMES: readonly string[] = [
  // English and Irish
  "Aaron", "Abigail", "Adam", "Adrian", "Aidan", "Alan", "Albert", "Alex", "Alexander", "Alexandra", "Alice", "Alicia",
  "Alison", "Amanda", "Amelia", "Amy", "Andrew", "Angela", "Anna", "Anne", "Anthony", "Arthur", "Ashley",
  "Barbara", "Benjamin", "Beth", "Brandon", "Brenda", "Brian", "Bridget", "Caitlin", "Caleb", "Cameron", "Carl",
  "Caroline", "Catherine", "Charles", "Charlotte", "Chloe", "Christina", "Christopher", "Claire", "Colin", "Connor",
  "Daniel", "David", "Deborah", "Declan", "Dennis", "Diana", "Donald", "Dorothy", "Douglas", "Dylan", "Edward",
  "Eleanor", "Elizabeth", "Ella", "Emily", "Emma", "Eric", "Ethan", "Evan", "Fiona", "Frances", "Gareth", "Gary",
  "George", "Gemma", "Gregory", "Hannah", "Harold", "Harry", "Heather", "Helen", "Henry", "Ian", "Isaac", "Isabel",
  "Isabella", "Jack", "Jacob", "James", "Jane", "Janet", "Jason", "Jeffrey", "Jennifer", "Jeremy", "Jessica", "Joanna",
  "John", "Jonathan", "Joseph", "Joshua", "Julia", "Justin", "Karen", "Katherine", "Kathleen", "Keith", "Kelly",
  "Kenneth", "Kevin", "Kimberly", "Laura", "Lauren", "Leah", "Liam", "Linda", "Lisa", "Logan", "Lucy", "Madeline",
  "Margaret", "Martha", "Matthew", "Megan", "Melissa", "Michael", "Michelle", "Nathan", "Nicholas", "Nicole", "Niamh",
  "Noah", "Oliver", "Olivia", "Owen", "Patrick", "Paul", "Peter", "Philip", "Rachel", "Rebecca", "Richard", "Robert",
  "Ronald", "Ryan", "Samantha", "Samuel", "Sarah", "Scott", "Sean", "Sharon", "Shirley", "Siobhan", "Sophie",
  "Stephanie", "Stephen", "Steven", "Susan", "Thomas", "Timothy", "Tyler", "Victoria", "Walter", "William", "Zachary",
  "Sam", "Dana", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Avery", "Quinn", "Jamie", "Robin", "Leslie",
  // Spanish, Portuguese, Italian, French
  "Alejandro", "Ana", "Andrea", "Antonio", "Beatriz", "Camila", "Carlos", "Carmen", "Diego", "Elena", "Fernando",
  "Francisco", "Gabriel", "Isabela", "Javier", "Joao", "Jorge", "Jose", "Juan", "Lucia", "Luis", "Manuel", "Marco",
  "Maria", "Mateo", "Miguel", "Pablo", "Pedro", "Rafael", "Ricardo", "Rosa", "Sofia", "Valentina", "Alessandro",
  "Chiara", "Francesca", "Giovanni", "Giulia", "Lorenzo", "Matteo", "Paolo", "Amelie", "Antoine", "Camille", "Claude",
  "Elodie", "Etienne", "Francois", "Julien", "Louis", "Manon", "Mathieu", "Nicolas", "Pierre", "Sylvie", "Thierry",
  // German, Dutch, Nordic, Slavic
  "Anke", "Bernd", "Dieter", "Florian", "Franziska", "Hans", "Jan", "Jens", "Johanna", "Jurgen", "Katrin", "Klaus",
  "Lars", "Lena", "Lukas", "Maximilian", "Niklas", "Sabine", "Stefan", "Ulrike", "Wolfgang", "Annika", "Astrid",
  "Bjorn", "Erik", "Freya", "Ingrid", "Henrik", "Magnus", "Sigrid", "Sven", "Aleksandra", "Anastasia", "Dmitri",
  "Ivan", "Katarzyna", "Marek", "Natalia", "Olga", "Pavel", "Piotr", "Sergei", "Tatiana", "Tomasz", "Yulia",
  // Arabic, Persian, Turkish, Hebrew
  "Ahmed", "Ali", "Amir", "Aisha", "Fatima", "Hassan", "Hussein", "Karim", "Khalid", "Layla", "Leila", "Mariam",
  "Mohammed", "Muhammad", "Mustafa", "Nadia", "Omar", "Rania", "Samir", "Tariq", "Yasmin", "Youssef", "Zainab",
  "Darius", "Farah", "Reza", "Shirin", "Ayse", "Elif", "Emre", "Mehmet", "Zeynep", "Avi", "Noa", "Tamar", "Yael",
  // South Asian
  "Aarav", "Aditya", "Ananya", "Anil", "Arjun", "Deepa", "Divya", "Gaurav", "Kavya", "Lakshmi", "Neha", "Nikhil",
  "Pooja", "Priya", "Rahul", "Raj", "Ravi", "Rohan", "Sanjay", "Sunita", "Vikram", "Imran", "Ayesha", "Bilal",
  "Hamza", "Sana", "Usman", "Zara",
  // East and Southeast Asian
  "Hiroshi", "Haruto", "Kenji", "Yuki", "Yuto", "Sakura", "Akira", "Takeshi", "Mei", "Wei", "Jun", "Li", "Ming",
  "Xiao", "Yan", "Hao", "Jia", "Min", "Seo", "Jisoo", "Minho", "Hyun", "Linh", "Minh", "Thanh", "Anh",
  // African
  "Abena", "Adwoa", "Amara", "Chidi", "Chiamaka", "Kwame", "Kofi", "Ngozi", "Nia", "Obinna", "Thabo", "Zanele",
  "Tendai", "Wanjiru", "Kamau", "Ayodele", "Folake", "Tunde", "Yaw",
];

export const AMBIGUOUS_GIVEN_NAMES: readonly string[] = [
  "April", "May", "June", "August", "Will", "Mark", "Bill", "Grace", "Hope", "Joy", "Faith", "Rose", "Summer", "Dawn",
  "Art", "Rich", "Sky", "Page", "Max", "Frank", "Gene", "Ray", "Drew", "Chase", "Lane", "Hunter", "Pat", "Sue",
  "Penny", "Ruby", "Iris", "Ivy", "Holly", "Jade", "Amber", "Crystal", "Destiny", "Reed", "Wade", "Cliff", "Glen",
  "Dean", "Don", "Jean", "Carol", "Victor", "Miles", "Rob", "Sandy", "Brook",
];

export const HONORIFICS: readonly string[] = ["Mr", "Mrs", "Ms", "Mx", "Dr", "Prof", "Sir", "Dame", "Madam"];

/** Words that introduce a person. Compared case-sensitively, at a word boundary, before a capitalised word. */
export const CUES: readonly string[] = [
  "Hi", "Hello", "Hey", "Dear", "Thanks", "Thank you", "Cheers", "Regards", "Best", "cc", "Cc", "CC", "From:", "To:",
  "Attn:", "Assigned to:", "Owner:", "Reviewer:", "Signed,",
];

export const NOT_NAMES: readonly string[] = [
  "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "January", "February", "March",
  "September", "October", "November", "December", "I", "The", "A", "An", "This", "That", "These", "Those", "We", "You",
  "They", "He", "She", "It", "Please", "Team", "All", "Everyone", "Sheets", "Docs", "Drive", "Slack", "Gmail",
  "Calendar", "Excel", "Word", "Notion", "Jira", "Invoice", "Report", "Re", "Fwd", "Subject",
];
