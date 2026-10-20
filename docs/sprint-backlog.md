# Sprint backlog

These items came out of a design session during the Salesforce Community Sprint, October 2026. [GLOSSARY.md](../GLOSSARY.md) defines the terms used here. The ADRs in [docs/adr/](adr/) explain why each decision was made.

## This sprint

Smaller, independent items are listed first.

- [x] **Skip Contacts that are already opted out.** The Contacts lookup in `Unsubscribe_Contacts` filters on Email only. It should also filter `HasOptedOutOfEmail = false`, as the Leads lookup already does and as its own description says.
- [x] **Leave converted Leads out of the opt-out.** `Unsubscribe_Leads` does not filter on `IsConverted`, and converted Leads can't be updated. Reproduce the failure in a scratch org first. A link sent to a Lead before conversion must still resolve. Result: Apex fails with `CANNOT_UPDATE_CONVERTED_LEAD`, but the flow in `SystemModeWithoutSharing` updated the converted Lead without error, so the filter is a cleanup rather than a crash fix.
- [x] **Write the README section "What this package does and doesn't do".** It should say that the package records each Unsubscribe and sets Email Opt Out, and that whether email stops depends on the sending channel. Include the channel table:

  | Sending channel | Honors Email Opt Out |
  | --- | --- |
  | List Email and mass email | Yes |
  | Email Alerts | No |
  | Apex `SingleEmailMessage` | No, by default |
  | Flow Send Email action | No, tested October 2026 (see the next item) |

  Close the section with "helps with compliance, does not guarantee it".
- [x] **Test whether the Flow Send Email action honors Email Opt Out.** Run it in a scratch org and fill in that row of the README table. Result is No. With Recipient ID set to an opted-out Contact, the action returned success and logged an EmailMessage with status Sent, the same as for a Contact that had not opted out. In the same org, Apex `SingleEmailMessage` with `optOutPolicy` set to `FILTER` or `REJECT` failed for that Contact with `EMAIL_OPTED_OUT`, so the org did see the opt-out.
- [x] **Assign Public Ids in an Apex before-insert trigger.** It replaces the Draft after-save flows `Contact_After_Create_Update_Set_Public_Id` and `Lead_After_Create_Update_Set_Public_Id`. Add a bypass switch for large imports. The existing backfill batch stays for records created before the trigger. Doing this drops the agenda item "friendly way to turn record-triggered flows on/off".
- [ ] **Add a setup check to the setup flow.** It reports pass or fail for each of these:
  - [x] The site exists and is published.
  - [x] The org-wide email address is verified.
  - [ ] The scheduled batch exists, and the user who scheduled it is active. TODO: pending [ADR 0002](adr/0002-guest-only-records-requests.md), because the batch doesn't exist yet. Add this check to `SetupCheckInvocable` and `Setup_Check_Screen` when the batch is built.
  - [x] Every Contact and Lead with an email address has a Public Id.
- [x] **Warn about type-in mode in the setup flow.** When the Admin turns type-in mode on, the setup flow says plainly that a script can unsubscribe any list of email addresses.
- [ ] **Make the guest only record a Request** ([ADR 0002](adr/0002-guest-only-records-requests.md)). This is the largest item and may need splitting.
  - Add the Pending and Not Found statuses to `Unsubscribe__c.Status__c`.
  - Remove the guest flows' `SystemModeWithoutSharing` writes to Contacts and Leads.
  - Add an existence-check action that runs without sharing and returns only true or false for a Public Id.
  - Add a validation rule that requires `C` or `L` followed by a UUID v4.
  - Add a unique Pending Key so a link has at most one Pending Request. The flow treats a duplicate insert as success.
  - Build the scheduled batch. It processes Pending and Error Requests, opts out every Contact and Lead with the matching address, sends the Confirmation Email and sets the final status.
  - The batch sends one digest per run, such as "312 Not Found, 2 Error", instead of one alert per Request.
  - The batch deletes Not Found Requests after a retention period.
  - Put the interval (default 1 hour) and the retention period (default 30 days) on `Unsubscribe_Link_Setup__c`. The setup flow schedules or reschedules the batch as the Admin running it.

## Next sprint or known issues

- **Pick the right site in the setup flow.** `Get_Experience_Site` takes the first Site with no filter, so an org with several sites can get the wrong one.
- **Enable Translation Workbench in the scratch org definition.** Scratch orgs reject `nl_NL.translation-meta.xml` with "Not available for deploy for this organization", so the Dutch labels have never been deployed.
- **Retire the Set Public Id flows in subscriber orgs.** Orgs that activated `Contact_After_Create_Update_Set_Public_Id` or `Lead_After_Create_Update_Set_Public_Id` must deactivate them after upgrading, because they ignore the import bypass. The setup flow's screen text that mentions these flows is out of date.
- **Build the link from the Public Id instead of storing it.** Compute the URL in a formula from the Public Id plus the site URL kept in custom metadata. This removes the `+` split hack and the domain string replacement. It means migrating off `Part1_Unsubscribe_Link__c`. Links already sent are unaffected ([ADR 0001](adr/0001-unsubscribe-links-never-expire.md)).
- **Keep links working after a merge.** Copy the losing record's Public Id onto the record that survives. Until then, those links end as Not Found Requests.
- **Confirm type-in Requests by email.** A type-in Request stays Pending until someone clicks a link sent to the typed address.
- **Move settings to custom metadata.** If this happens, the batch interval and the retention period move along with the other settings.
- **Warn about active Email Alerts.** Tell the Admin about Email Alerts or flows that send to Contacts or Leads, because those ignore Email Opt Out.
- **Preference center.** Let Recipients unsubscribe per topic. Out of scope until global Unsubscribe works well.

## Decisions for ADR 0002 work

1. Merged or deleted records: open, see below.
2. Links from the unmanaged predecessor (`varRecId=<CASESAFEID(Id)>`) keep working, with no setting to turn them off. The existence check accepts 15- and 18-character Contact and Lead Ids.
3. Type-in Requests dedupe by address through the Pending Key (`E:` plus the lower-case address). A typed address that matches nothing ends as Not Found.
4. Error Requests retry up to `Max_Retry_Attempts__c` on the setup object, 5 by default. After that they stay Error and their Pending Key is cleared.
5. The guest flow stays in system mode, and the guest profile gets no object permissions.
6. Admin screen texts stay as they are, and the release notes ask Admins to check them.
7. The email address and output variables in the guest flow get their own fix on `fix/quick-flow-inputs`, ahead of ADR 0002.

Still open: a click on a link whose record was merged or deleted fails the existence check, so no Request is created. The proposal is that the check also looks at deleted records (`ALL ROWS`), and the batch follows `MasterRecordId` to the record that survived the merge.
