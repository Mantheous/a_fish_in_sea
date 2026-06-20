# Planning App

## Financial Planning
Currently this app only is focused on financial planning. It is important to remember that the context is broader for the finished app. **Prioritize flexibility** — many features will be added later, and the reason this app needs to exist is so that the plan is highly customizable.

### Water fall Ledger
There is a screen dedicated for displaying your accounts history combined with future projected expenses. These projections become more concrete as they approach the present. Much of this will be reported by the user. Periodically the user will upload a csv file that will be used to turn future abstract or concrete transactions and expenses into a history.

Approaching dates: A user may want to budget $100 for food on a given month, but when that month is closer they will want to see it as a weekly budget. These abstract amounts should be definable at any level of abstraction and modified as a group or as sub elements. Perhaps the user knows that next week they will need to spend extra on their food, they don't want to have to change their weekly budget just for that one week.

Repeating expenses need to be supported.

### Statistics
There is a page dedicated to helping the user understand their historical spending and income. It shows useful data for evaluating past performance. You can view by buget catagory.

# Budgets
Budgets are goals. They are like buckets that are fulfilled with transactions or expenses. They show planned expenses that fall into their time range and real expenses that have fallen into them. They can be viewed at different granularities like most things in this app. It is possible to generate an expense based off of the budget, however these will be changed over time. At the end of a budget's period it can optionally be passed to the next period of the same budget if it is a recuring budget. Most budgets are recuring and the default behavior is to roll over. This rollover can happen manually or automatically when the bugdet period ends and the next one begins.

### Expenses
Expenses are the fundamental way of representing spending. They are not goals; they are predicted or real transactions. They can be created at a specified granularity and can be subdivided, deleted, or merged by the user. 

#### Unity-style Inheritance (Prefabs)
Expenses behave like Unity's Prefabs to allow for powerful hierarchical editing:
- **Property Overrides**: When a sub-expense (a specific instance of a recurring rule) is modified (e.g., changing the amount), that specific field is marked as "overridden." It stops inheriting changes from the parent for that field but continues to inherit others (e.g., category or name).
- **Reversion**: Users can revert any overridden field back to the parent's value at any time.
- **Concrete State**: When an expense is tied to a real transaction (e.g., from Plaid), it becomes "concrete." It severs all inheritance from any parent template and becomes a unique historical record.

Example: User creates a monthly expense called "gas" for $50. Then they don't actually spend that money that month. When the expense is due it gets marked as due. The user might then update the due date. Then next week they fill up their gas tank and that expense comes through on bank statement. But it's $45. The user marks this transaction as the gas expense and then a smaller expense is created for the remaining $5. Then the user combines this with the gas for the following month. The user can see in their budget view that they were $5 below the goal.

### View Granularity
The waterfall ledger supports multiple view modes. Crucially, while the **view** may aggregate small expenses into larger buckets for readability, the **underlying data model** always preserves the granular transactions. The view modes are selectable via a dropdown similar to Google Calendar's week/month toggle:
- **Waterfall** (default): Dynamically shows far-future events at monthly granularity, near-future at weekly, and current week at daily. Thresholds are user-configurable via a sub-menu.
- **Fixed scale**: The user can also choose to view everything at a single scale (daily, weekly, monthly, quarterly, yearly, or a user-defined custom period like semesters).

### Recurring Rules
Recurring income and expenses (rent, paychecks, utilities, subscriptions) are first-class objects with a defined frequency, start date, and optional end date. The app auto-generates projected ledger entries from these rules up to a configurable horizon.

### Budget Templates
Abstract spending allocations (e.g. $400/month on food) that refine into finer-grained entries as their period approaches. Users can override specific sub-periods (a single week or day) without modifying the overall template.

### Plaid Reconciliation
Transaction data is loaded automatically via Plaid. The user can see these transactions in the waterfall ledger and report how those expenses fit into the budget. The user can assign an expense of any granularity to an transaction.
- **Auto-Categorization**: If an expense has the exact same name as a past transaction, it should be automatically assigned to the same budget category.
- **Subdivision**: If a transaction is smaller than the assigned expense, the expense should subdivide (creating a "remainder" expense). 
- **Over-spending**: If a transaction is larger than the assigned expense, the expense is logged as its actual value. This shows as "over-budget" in the view but does not modify the underlying recurring rule. Users can manually re-assign these transactions to less granular "bucket" expenses if they wish to balance the ledger.
- **Immutability**: Past transactions are immutable; the UI is only for modifying their *interpretation* as expenses and their impact on the budget. Currently, assigning a single transaction to multiple expenses is not supported.

### Starting Balance
Balance is always pulled from plaid.

### Time Scales
A unified time scale system is used throughout the app (recurring frequencies, budget granularity, view modes). Supported scales: daily, weekly, biweekly, monthly, quarterly, yearly, and user-defined custom periods.

