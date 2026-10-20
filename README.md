# Unsubscribe Link by Jessie Rymph
Send an email to anyone from inside Salesforce and include an unsubscribe link right in the email! This app will find all contacts and leads with that email address and mark them “Email opt out.” It will also create an Unsubscribe (custom object) object so you can track unsubscribes over time. 

Unsubscribe Link Resources:

- [Installation instructions Updated 9/25/24](https://docs.google.com/document/d/1vevs5MKiTmHEtJXceSsenAm3sViQF38bAfoJ6WdATYA/edit#heading=h.3d7st1pta4ai)

## What this package does and doesn't do

The package records every Unsubscribe as an Unsubscribe Request. It also sets Email Opt Out on every Contact and Lead with that email address.

Email Opt Out is a checkbox. Setting it does not block email on its own. Each way of sending email in Salesforce decides whether to check it, so whether email actually stops depends on how you send it.

| Sending channel | Honors Email Opt Out |
| --- | --- |
| List Email and mass email | Yes |
| Send Email from a record | Yes, with a warning. Addresses typed into CC or BCC are not checked. |
| Email Alerts (workflow rules, Process Builder, flows) | No |
| Apex `SingleEmailMessage` | No, by default. `optOutPolicy` defaults to `SEND`. Raw email addresses are never checked. |
| Flow Send Email action | No. We tested it in a scratch org in October 2026. With Recipient ID set to an opted-out Contact, the action reported success and logged the email as sent. Raw email addresses are not checked either. |

If you send email through a channel marked No, add your own check. For example, give the flow a Decision element that skips records where Email Opt Out is true, or set `optOutPolicy` to `FILTER` in Apex.

Salesforce documents this behavior here:

- [Opting out individuals from email](https://help.salesforce.com/s/articleView?id=sales.emailadmin_opting_out_individuals.htm)
- [Email opt-out considerations](https://help.salesforce.com/s/articleView?id=sales.emailadmin_opting_out_considerations.htm)
- [Apex `SingleEmailMessage` reference](https://developer.salesforce.com/docs/atlas.en-us.apexref.meta/apexref/apex_classes_email_outbound_single.htm)

This package helps you comply with laws such as CAN-SPAM and GDPR. It does not guarantee that you comply.

## Community Sprints 

### [Upcoming] September 2024 Virtual Community Sprint - September 26th and 27th global virtual sprint

#### Team

* [Jessie Rymph](https://www.linkedin.com/in/rymph/)
* [Jon Sayer](https://www.linkedin.com/in/jonsayer/)
* Scott Jacobson
* Eileen K
* Dirk Keaton
* Aïcha Medjahed
* [Hua Ping Tan](https://www.linkedin.com/in/huapingtan/)
* [Igor Androsov](https://www.linkedin.com/in/iandrosov/)

#### Agenda TENTATIVE
* Revise `generateAllRandomStrings` class to generate `Public_Id__c` for Leads as well as Contacts.
* Write a test class for generateAllRandomStrings class.
* Improve upon existing code.
* Figure out a way to turn on and off record-triggered flows in a friendly way that works in a managed package.
* GitHub Collaboration practices, team agreement.
* Development env setup (VSCode, CLI tools versions etc.)
* Development workflow (collaboration, PR, code reviews, commits merges etc.)
* Work item/feature management (issues, projects, assignments, and boards)
* SDLC, (CICD, packaging, scratch orgs, source management)

#### Summary & Accomplishments
#### Recommendations for Future Sprints
