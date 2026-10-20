# The guest user only records Unsubscribe Requests

The unsubscribe page runs as the site's guest user. Today its flows run in `SystemModeWithoutSharing`, which lets anyone on the internet read Contacts and Leads and update their opt-out fields. We are cutting the guest's job down to two things:

- checking that the link's Public Id exists, which returns only true or false, and
- inserting one Pending Unsubscribe Request that holds that Public Id.

The guest never writes to Contacts or Leads. The guest flow keeps running in system mode, and the guest profile gets no object or field permissions, only access to the flows and the existence-check class. That way the guest can insert only what the flow inserts, and can't create records directly through the site's APIs. A scheduled batch running as the Admin picks up Pending and Error Requests. It resolves each Public Id to an email address, opts out the matching Contacts and Leads, sends the Confirmation Email and sets the final status.

## Considered options

- Synchronous opt-out in the guest's flow, as today. Rejected because the guest needs wide system-mode access.
- Processing each Request straight after insert through a Queueable or a trigger. Rejected because a job started by a guest insert runs as the guest.
- A record-triggered flow with an asynchronous path running as the Automated Process user. Rejected because that user has too many quirks to depend on.
- No existence check, keeping the guest away from Contacts and Leads entirely. Rejected because a script could then fill storage with well-formed junk links. The check reads by exact Public Id, and a UUID v4 can't be guessed, so the one-bit answer leaks nothing useful.

## Abuse limits

The page is public, so nothing here prevents abuse outright. These limits make a flood cheap to absorb:

- A validation rule rejects any Public Id that isn't `C` or `L` followed by a UUID v4.
- The existence check stops valid-looking links that match no record.
- A unique Pending Key allows only one Pending Request per link. It holds the Public Id, or `E:` plus the lower-case address for a type-in Request. A duplicate insert fails, and the guest still sees success.
- The batch sends one digest per run instead of one alert per Request.
- The batch deletes Not Found Requests after a retention period kept on the setup object, 30 days by default.

## Consequences

- The opt-out lags the click by up to one batch interval. Email sent in that gap still reaches the Recipient. This is within CAN-SPAM's 10 business days.
- The batch runs as whoever scheduled it, normally the Admin running the setup flow. If that user is deactivated, the job stops and Pending Requests pile up. The setup check has to catch this.
- The interval is a setup setting with a default of one hour. Changing it only takes effect when the setup flow reschedules the job.
- An Error Request is retried up to a limit set on the setup object, 5 by default. After the last attempt it stays Error, its Pending Key is cleared so a new click can create a fresh Request, and the digest reports it once.
- A typed address that matches no Contact or Lead ends as Not Found. The batch decides this, never the guest, so the page can't be used to test which addresses the org has.
- A record can be deleted or merged after the existence check passes. If the batch then finds no match, the Request ends as Not Found and is never retried.
- Type-in mode bypasses the existence check, because an email address is not a Public Id. A script with a list of addresses can therefore unsubscribe real Recipients. Until type-in Requests wait for confirmation through an email to the typed address, the setup flow must warn about this when the Admin turns type-in mode on.
