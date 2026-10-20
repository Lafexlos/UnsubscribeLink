# Unsubscribe Links never expire

Recipients keep emails for years and expect the unsubscribe link in an old one to work. A broken link leaves them no way to Unsubscribe except marking the email as spam. So every Unsubscribe Link the package has ever generated must keep resolving: the host, page path, `varRecId` parameter and Public Id format stay valid for good. A redesign may add a new link format next to the old one, but it must never retire the old one.

Links from the unmanaged predecessor app carry the raw record Id (`varRecId=<CASESAFEID(Id)>`) instead of a Public Id. They are the one exception. They work only after the Admin turns on a setup setting, which is off by default, because record Ids are much easier to guess than UUIDs. Orgs that moved over from the unmanaged app turn it on to keep their old links working.

## Considered options

- Signed or expiring tokens. Rejected because expiry breaks old emails, which is the failure this decision exists to prevent.
- Rotating the Public Id when a record changes. Rejected for the same reason.

## Consequences

- The Public Id is a bearer token that never expires. Anyone holding a link can unsubscribe that Recipient's email address. We accept this because the worst result of misuse is that someone stops receiving email.
- Moving the unsubscribe page to another host, such as a Visualforce site, means the old Experience Cloud URL has to keep working through a redirect or by staying live.
- Merging or deleting a Contact or Lead breaks the links sent to the record that disappears. That is a known gap we accept. The guest's existence check finds no live record, so no Request is created. The Recipient still sees the success page, and nobody is told.
