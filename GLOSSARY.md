# Unsubscribe Link

Lets people who receive email sent from inside Salesforce stop receiving it with one click, and keeps a history of who unsubscribed and when.

## People

**Admin**:
The person at a nonprofit who installs, configures and maintains the package, usually without developer help.
_Avoid_: User, owner

**Recipient**:
A person who receives email from the organization and may click the Unsubscribe Link.
_Avoid_: Subscriber, customer, donor

## Unsubscribing

**Unsubscribe**:
A Recipient's choice that an email address stops receiving all email from the organization. It applies to the address, so every person record carrying that address is covered. There are no per-topic or per-list unsubscribes.
_Avoid_: Opt-out (as a noun for the act), cancellation

**Unsubscribe Link**:
A permanent, personal URL in an email that lets the Recipient Unsubscribe with one click. Every Contact and Lead has its own, and links already sent never stop working.
_Avoid_: Opt-out link, unsubscribe URL

**Unsubscribe Request**:
The record of one Recipient asking to Unsubscribe, and whether the organization has honored it yet. Each click is its own Request, even for an address that is already unsubscribed. A click on a link that already has a Pending Request does not create another one.
_Avoid_: Unsubscribe log, error log

**Pending**:
An Unsubscribe Request that has been recorded but not processed yet.

**Unsubscribed**:
An Unsubscribe Request that has been honored: every Contact and Lead with that email address now has Email Opt Out set.

**Error**:
An Unsubscribe Request that failed to process. It is retried automatically, and the Admin is alerted. The Recipient is never shown an Error.

**Not Found**:
A final status for an Unsubscribe Request whose link matches no Contact or Lead, for example after a merge or a delete. It is never retried. The Admin is told in the next digest and has to honor the Request by hand.

**Resubscribe**:
The Admin reversing an Unsubscribe for an email address, recorded in the same history as Unsubscribe Requests. Recipients cannot Resubscribe themselves.
_Avoid_: Opt-in, undo

**Confirmation Email**:
An optional message sent to the email address after an Unsubscribe, telling the Recipient it took effect. It does not verify who asked.
_Avoid_: Verification email
