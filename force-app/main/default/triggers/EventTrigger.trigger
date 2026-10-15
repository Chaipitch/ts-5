trigger EventTrigger on Event (before insert, before update, before delete, after insert, after update, after delete) {
    EventTriggerHandler handler = new EventTriggerHandler();
    if (Trigger.isBefore) {
        if(Trigger.isUpdate){
            handler.onBeforeUpdate(Trigger.new, Trigger.oldMap);
        }else if(Trigger.isDelete){
            handler.onBeforeDelete(Trigger.Old);
        }
    }
    if (Trigger.isAfter && Trigger.isInsert) {
        handler.onAfterInsert(Trigger.new);
    } else if (Trigger.isAfter && Trigger.isUpdate) {
        handler.onAfterUpdate(Trigger.new, Trigger.oldMap);
    }
}