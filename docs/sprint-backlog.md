# Sprint backlog

These items came out of a design session during the Salesforce Community Sprint, October 2026. [GLOSSARY.md](../GLOSSARY.md) defines the terms used here. The ADRs in [docs/adr/](adr/) explain why each decision was made.

## This sprint

Smaller, independent items are listed first.

- [ ] **Skip Contacts that are already opted out.** The Contacts lookup in `Unsubscribe_Contacts` filters on Email only. It should also filter `HasOptedOutOfEmail = false`, as the Leads lookup already does and as its own description says.
- [ ] **Leave converted Leads out of the opt-out.** `Unsubscribe_Leads` does not filter on `IsConverted`, and converted Leads can't be updated. Reproduce the failure in a scratch org first. A link sent to a Lead before conversion must still resolve.
- [ ] **Write the README section "What this package does and doesn't do".** It should say that the package records each Unsubscribe and sets Email Opt Out, and that whether email stops depends on the sending channel. Include the channel table:

  | Sending channel | Honors Email Opt Out |
  | --- | --- |
  | List Email and mass email | Yes |
  | Email Alerts | No |
  | Apex `SingleEmailMessage` | No, by default |
  | Flow Send Email action | Unknown, see the next item |

  Close the section with "helps with compliance, does not guarantee it".
- [ ] **Test whether the Flow Send Email action honors Email Opt Out.** Run it in a scratch org and fill in that row of the README table.
- [ ] **Assign Public Ids in an Apex before-insert trigger.** It replaces the Draft after-save flows `Contact_After_Create_Update_Set_Public_Id` and `Lead_After_Create_Update_Set_Public_Id`. Add a bypass switch for large imports. The existing backfill batch stays for records created before the trigger. Doing this drops the agenda item "friendly way to turn record-triggered flows on/off".
- [ ] **Add a setup check to the setup flow.** It reports pass or fail for each of these:
  - The site exists and is published.
  - The org-wide email address is verified.
  - The scheduled batch exists, and the user who scheduled it is active.
  - Every Contact and Lead with an email address has a Public Id.
- [ ] **Warn about type-in mode in the setup flow.** When the Admin turns type-in mode on, the setup flow says plainly that a script can unsubscribe any list of email addresses.
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

- **Build the link from the Public Id instead of storing it.** Compute the URL in a formula from the Public Id plus the site URL kept in custom metadata. This removes the `+` split hack and the domain string replacement. It means migrating off `Part1_Unsubscribe_Link__c`. Links already sent are unaffected ([ADR 0001](adr/0001-unsubscribe-links-never-expire.md)).
- **Keep links working after a merge.** Copy the losing record's Public Id onto the record that survives. Until then, those links end as Not Found Requests.
- **Confirm type-in Requests by email.** A type-in Request stays Pending until someone clicks a link sent to the typed address.
- **Move settings to custom metadata.** If this happens, the batch interval and the retention period move along with the other settings.
- **Warn about active Email Alerts.** Tell the Admin about Email Alerts or flows that send to Contacts or Leads, because those ignore Email Opt Out.
- **Rename the unsubscribe page.** Give the flexipage `Unsubscribe_Link_4_0_020324_Unsubscribe` a shorter API name, and drop the old one from the package.
- **Support LWR sites.** Tested by hand in a Trailhead Playground on an enhanced Build Your Own (LWR) site. A guest Unsubscribe worked end to end, and an old `/s/` link worked through a redirect. To finish:
  - Build the link without `/s/` when the site is LWR. Enhanced LWR sites have no `/s` in the URL, so the links that `UUIDBatchJob` and both Set Public Id flows build today return 404. This overlaps with "Build the link from the Public Id" above.
  - Set `allowPause` to false on the three `Unsubscribe_Link_Quick` screens that have it on. LWR doesn't support pausing.
  - Document the LWR setup in the wiki. The packaged page template is Aura-only, so the Admin adds the Flow component by hand with `varRecId` set to `{!Route.varRecId}`. LWR also needs "Allow guest users to access public APIs" in Administration > Preferences.
  - Find out whether that preference can be set by CLI or metadata.
  - Keep old links working when a site moves from Aura to LWR ([ADR 0001](adr/0001-unsubscribe-links-never-expire.md)). A dynamic URL redirect `/Unsubscribe/s/unsubscribe?varRecId=(recId)` to `/unsubscribe?varRecId=(recId)` does this. It only matches when `varRecId` is the first query parameter. The Admin has to delete the Aura site to free the `Unsubscribe` prefix, so links are dead until the LWR site and the redirect are live.
- **Open the setup flow from a tab.** Ship a Lightning App Page that holds only `Unsubscribe_Link_Setup`, plus a tab for it that the `Unsubscribe_Link` permission set makes visible. This replaces Setup > Flows > Run. First check that running the setup flow again doesn't create a second setup record. Give the tab a label that doesn't clash with the `Unsubscribe_Link_Setup__c` object tab.
- **Preference center.** Let Recipients unsubscribe per topic. Out of scope until global Unsubscribe works well.
