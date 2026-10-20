trigger ContactPublicIdTrigger on Contact(before insert, before update) {
  PublicIdTriggerHandler.assignPublicIds(Trigger.new, Trigger.oldMap);
}
