trigger LeadPublicIdTrigger on Lead(before insert, before update) {
  PublicIdTriggerHandler.assignPublicIds(Trigger.new, Trigger.oldMap);
}
