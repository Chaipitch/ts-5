/**
 * Sends meeting notes (Events) to Gemini and merges the answers into their Opportunities.
 *
 * One call per meeting, with the BA's prompt (static resource DealIntelligencePrompt)
 * and JSON-only output. Every callout runs before any DML, as Salesforce requires.
 * The answers are then merged oldest meeting first, so the insight fields end on the
 * latest one. A meeting is ticked AI_Processed__c only once its Opportunity has
 * saved; anything that failed stays unticked and is flagged IsFailed__c, which is what
 * the scheduled retry looks for. A meeting that later succeeds has the flag cleared.
 * Every call to Gemini leaves one Gemini_Opty_Log__c row: status, what changed on the
 * deal, errors and warnings, Gemini's JSON (or Google's error), model and tokens.
 *
 * Without sharing and in system mode: the rep who logs the meeting may not own the
 * deal or see the AI fields and the log, and they must still be written. (From API
 * 67.0, SOQL and DML respect field access unless told otherwise.)
 */
public without sharing class DealIntelligenceService {

    @TestVisible private static final String PROMPT_RESOURCE = 'DealIntelligencePrompt';
    @TestVisible private static final String MOM_PLACEHOLDER = '{{INSERT_MINUTES_OF_MEETING_HERE}}';
    @TestVisible private static final String ENDPOINT = 'callout:Gemini_AI_Studio/v1beta/models/';
    private static final String MODEL_KEY = 'GeminiMODEL';
    /*
     * Salesforce allows one callout 120 s, and all the callouts in a transaction 120 s
     * together. A slow model (gemini-3.8-flash with a long prompt) can take over 60 s,
     * so each call gets whatever is left of the 120 s, and a meeting that would start
     * with less than MIN_CALL_MS left waits for the next job instead.
     */
    private static final Integer TIMEOUT_MS = 120000;
    @TestVisible private static Integer calloutBudgetMs = 120000;
    @TestVisible private static final Integer MIN_CALL_MS = 30000;

    /** Gemini is busy for a moment: worth another try in a couple of minutes. */
    @TestVisible private static final Integer BUSY = 503;
    /**
     * We are over Gemini's rate limit or quota: everything waits for the rate-limit
     * retry (see DealIntelligenceJob). Its log Details start with this, which is how
     * the retry finds the meetings to put first.
     */
    @TestVisible private static final Integer RATE_LIMITED = 429;
    public static final String RATE_LIMITED_DETAIL = 'HTTP 429';

    @TestVisible private static final String SUCCESS     = 'Success';
    @TestVisible private static final String PARTIAL     = 'Partial';
    public static final String FAILED                    = 'Fail';   // the log's own value, from before this feature
    @TestVisible private static final String PARSE_ERROR = 'Parse Error';
    @TestVisible private static final String SAVE_FAILED = 'Save Failed';

    /** Counts for the caller, e.g. the backfill's summary email. */
    public class Summary {
        public Integer analysed = 0;
        public Integer failed = 0;
        public Integer skipped = 0;
        public Integer inputTokens = 0;
        public Integer outputTokens = 0;
        /** Meetings that failed only because Gemini was busy (503); retry them soon. */
        public List<Id> busy = new List<Id>();
        /** Meetings not sent at all, because Gemini had already refused one in this run. */
        public List<Id> deferred = new List<Id>();
        /** Gemini answered 429: stop calling until the rate-limit retry. */
        public Boolean rateLimited = false;
        /** The wait Gemini asked for with that 429 (RetryInfo), in seconds; null if it didn't say. */
        public Integer rateLimitWaitSeconds;
    }

    /** One meeting's trip to Gemini and back. */
    private class Call {
        Event mom;
        String status;
        String response;
        Map<String, Object> answer;
        Integer inputTokens;
        Integer outputTokens;
        Boolean busy = false;
        Boolean rateLimited = false;
        Integer retryAfterSeconds;
        DealIntelligenceRules.MergeResult merged;
        List<String> details = new List<String>();

        Call(Event mom) {
            this.mom = mom;
        }

        void fail(String status, String reason) {
            this.status = status;
            this.answer = null;
            this.details.add(reason);
        }
    }

    public static Summary analyse(List<Id> eventIds) {
        Summary summary = new Summary();
        List<Event> events = [
            SELECT Id, WhatId, Type, Subject, Description, AI_Processed__c
            FROM Event
            WHERE Id IN :eventIds
            WITH SYSTEM_MODE
            ORDER BY WhatId, StartDateTime, CreatedDate
        ];
        summary.skipped = eventIds.size() - events.size();

        List<Call> calls = new List<Call>();
        for (Event e : events) {
            if (DealIntelligenceRules.isMom(e)) {
                calls.add(new Call(e));
            } else {
                summary.skipped++;
            }
        }
        if (calls.isEmpty()) {
            return summary;
        }

        String model = model();
        String prompt = prompt();
        List<Call> sent = new List<Call>();
        Long startedAt = System.currentTimeMillis();
        for (Call c : calls) {
            // Once Gemini refuses one call, the rest of this run would only be refused
            // too, and each refusal still counts against the quota. They wait instead.
            if (!summary.busy.isEmpty() || summary.rateLimited) {
                summary.deferred.add(c.mom.Id);
                continue;
            }
            // Measured by the clock, which runs at least as fast as callout time, so
            // the transaction's 120 s is never overrun.
            Integer budgetLeft = calloutBudgetMs - (Integer) (System.currentTimeMillis() - startedAt);
            if (budgetLeft < MIN_CALL_MS) {
                summary.deferred.add(c.mom.Id);
                continue;
            }
            if (String.isBlank(model) || prompt == null) {
                c.fail(FAILED, String.isBlank(model)
                    ? 'No model set in Program_Constant__mdt.' + MODEL_KEY
                    : 'Static resource ' + PROMPT_RESOURCE + ' not found');
            } else {
                ask(c, prompt, model, Math.min(TIMEOUT_MS, budgetLeft));
            }
            if (c.busy) {
                summary.busy.add(c.mom.Id);
            }
            if (c.rateLimited) {
                summary.rateLimited = true;
                summary.rateLimitWaitSeconds = c.retryAfterSeconds;
            }
            sent.add(c);
        }

        Map<Id, String> saveErrors = mergeAndSave(sent);
        flagFailed(summary.deferred);
        for (Call c : sent) {
            if (c.busy && !summary.busy.contains(c.mom.Id)) {
                summary.busy.add(c.mom.Id);
            }
        }
        tickAndLog(sent, saveErrors, model, summary);
        return summary;
    }

    // ---- Gemini -------------------------------------------------------------

    private static void ask(Call c, String prompt, String model, Integer timeoutMs) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT + model + ':generateContent');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(timeoutMs);
        // No temperature: Google advises leaving Gemini 3 models at their default.
        req.setBody(JSON.serialize(new Map<String, Object>{
            'contents' => new List<Object>{
                new Map<String, Object>{
                    'role' => 'user',
                    'parts' => new List<Object>{
                        new Map<String, Object>{ 'text' => prompt.replace(MOM_PLACEHOLDER, c.mom.Description.trim()) }
                    }
                }
            },
            'generationConfig' => new Map<String, Object>{ 'responseMimeType' => 'application/json' }
        }));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            c.fail(FAILED, e.getTypeName() + ': ' + e.getMessage());
            return;
        }
        if (res.getStatusCode() != 200) {
            c.response = res.getBody();
            c.busy = res.getStatusCode() == BUSY;
            c.rateLimited = res.getStatusCode() == RATE_LIMITED;
            c.retryAfterSeconds = retryAfterSeconds(res.getBody());
            c.fail(FAILED, 'HTTP ' + res.getStatusCode() + ' ' + res.getStatus()
                + (c.retryAfterSeconds == null ? '' : ' (Gemini asks to wait ' + c.retryAfterSeconds + ' s)'));
            return;
        }

        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> usage = (Map<String, Object>) body.get('usageMetadata');
            if (usage != null) {
                c.inputTokens = (Integer) usage.get('promptTokenCount');
                c.outputTokens = (Integer) usage.get('candidatesTokenCount');
            }
            c.response = answerText(body);
            c.answer = (Map<String, Object>) JSON.deserializeUntyped(c.response);
        } catch (Exception e) {
            if (c.response == null) {
                c.response = res.getBody();
            }
            c.fail(PARSE_ERROR, e.getTypeName() + ': ' + e.getMessage());
        }
    }

    /** The wait Gemini asks for in an error's RetryInfo ("49995s"), or null. */
    @TestVisible private static Integer retryAfterSeconds(String errorBody) {
        try {
            Map<String, Object> error = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(errorBody)).get('error');
            for (Object o : (List<Object>) error.get('details')) {
                Object delay = ((Map<String, Object>) o).get('retryDelay');
                if (delay != null) {
                    return Decimal.valueOf(((String) delay).removeEnd('s')).intValue();
                }
            }
        } catch (Exception e) {
            // No RetryInfo, or not JSON: nothing to go on.
        }
        return null;
    }

    /** The text of the first candidate, leaving out any thinking parts. */
    private static String answerText(Map<String, Object> body) {
        Map<String, Object> candidate = (Map<String, Object>) ((List<Object>) body.get('candidates'))[0];
        Map<String, Object> content = (Map<String, Object>) candidate.get('content');
        String text = '';
        for (Object o : (List<Object>) content.get('parts')) {
            Map<String, Object> part = (Map<String, Object>) o;
            if (part.get('thought') != true && part.get('text') != null) {
                text += (String) part.get('text');
            }
        }
        return text;
    }

    // ---- Salesforce ---------------------------------------------------------

    /** Merges every answer, oldest meeting first, and saves. Returns save errors by Opportunity. */
    private static Map<Id, String> mergeAndSave(List<Call> calls) {
        Set<Id> oppIds = new Set<Id>();
        for (Call c : calls) {
            if (c.answer != null) {
                oppIds.add(c.mom.WhatId);
            }
        }
        Map<Id, String> saveErrors = new Map<Id, String>();
        if (oppIds.isEmpty()) {
            return saveErrors;
        }

        // FOR UPDATE: two jobs on the same deal (a retry next to a backfill chunk, say)
        // would otherwise each read it, merge their own meeting and save, and the second
        // save would wipe the first's competitors. Locked, the second waits and reads the
        // first's result. The callouts are already done, so the lock is held only briefly.
        //
        // The meetings are locked before the deal. Saving a meeting locks it and then its
        // deal (the Slack note flow ticks the Event, and the meeting-count flow then
        // updates the Opportunity); taking them the other way round, this job and that
        // flow each held what the other wanted and the tick failed with UNABLE_TO_LOCK_ROW.
        Set<Id> eventIds = new Set<Id>();
        for (Call c : calls) {
            eventIds.add(c.mom.Id);
        }
        Map<Id, Opportunity> opps;
        try {
            Database.query('SELECT Id FROM Event WHERE Id IN :eventIds FOR UPDATE', AccessLevel.SYSTEM_MODE);
            opps = new Map<Id, Opportunity>((List<Opportunity>) Database.query(
                'SELECT Id, ' + String.join(existingFields(), ', ') + ' FROM Opportunity WHERE Id IN :oppIds FOR UPDATE',
                AccessLevel.SYSTEM_MODE
            ));
        } catch (QueryException e) {
            // Still locked after Salesforce's wait: hand the meetings back to be retried.
            for (Call c : calls) {
                if (c.answer != null) {
                    c.busy = true;
                    c.fail(SAVE_FAILED, 'Meeting or Opportunity locked by another process: ' + e.getMessage());
                }
            }
            return saveErrors;
        }

        // Calls are already in WhatId, StartDateTime order, so each Opportunity sees its
        // meetings oldest first, and each merge builds on the one before.
        Map<Id, Opportunity> changed = new Map<Id, Opportunity>();
        for (Call c : calls) {
            if (c.answer == null) {
                continue;
            }
            Opportunity opp = opps.get(c.mom.WhatId);
            if (opp == null) {
                c.fail(SAVE_FAILED, 'Opportunity ' + c.mom.WhatId + ' not found');
                continue;
            }
            c.merged = DealIntelligenceRules.mergeAnswer(opp, c.answer);
            if (!c.merged.changes.isEmpty()) {
                Opportunity upd = changed.containsKey(opp.Id) ? changed.get(opp.Id) : new Opportunity(Id = opp.Id);
                for (String field : c.merged.changes.keySet()) {
                    upd.put(field, c.merged.changes.get(field));
                }
                changed.put(opp.Id, upd);
            }
        }

        List<Opportunity> toSave = changed.values();
        List<Database.SaveResult> results = Database.update(toSave, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                saveErrors.put(toSave[i].Id, errorText(results[i].getErrors()));
            }
        }
        return saveErrors;
    }

    /** The 33 fields that exist on Opportunity; a missing one is reported by the merge. */
    private static List<String> existingFields() {
        Map<String, Schema.SObjectField> oppFields = Schema.SObjectType.Opportunity.fields.getMap();
        List<String> result = new List<String>();
        for (String field : DealIntelligenceRules.fields()) {
            if (oppFields.containsKey(field)) {
                result.add(field);
            }
        }
        return result;
    }

    /**
     * Meetings never sent because Gemini had already refused one in this run. They are
     * flagged like a failure, so the scheduled retry (which only takes failed meetings)
     * picks them up even if no follow-up job does.
     */
    public static void flagFailed(List<Id> eventIds) {
        if (eventIds == null || eventIds.isEmpty()) {
            return;
        }
        List<Event> flags = new List<Event>();
        for (Id eventId : eventIds) {
            flags.add(new Event(Id = eventId, IsFailed__c = true));
        }
        Database.update(flags, false, AccessLevel.SYSTEM_MODE);
    }

    private static void tickAndLog(List<Call> calls, Map<Id, String> saveErrors, String model, Summary summary) {
        List<Event> ticks = new List<Event>();
        List<Call> ticked = new List<Call>();
        for (Call c : calls) {
            if (c.answer == null) {
                // Failed: flagged for the scheduled retry, not ticked as processed.
                ticks.add(new Event(Id = c.mom.Id, IsFailed__c = true));
                ticked.add(c);
                continue;
            }
            String saveError = saveErrors.get(c.mom.WhatId);
            if (saveError != null) {
                c.fail(SAVE_FAILED, saveError);
                ticks.add(new Event(Id = c.mom.Id, IsFailed__c = true));
                ticked.add(c);
                continue;
            }
            c.details.addAll(c.merged.warnings);
            c.status = c.merged.warnings.isEmpty() ? SUCCESS : PARTIAL;
            // Processed; clears the flag if an earlier attempt had failed.
            ticks.add(new Event(Id = c.mom.Id, AI_Processed__c = true, IsFailed__c = false));
            ticked.add(c);
        }

        List<Database.SaveResult> tickResults = Database.update(ticks, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < tickResults.size(); i++) {
            if (!tickResults[i].isSuccess()) {
                // The Opportunity is saved; the meeting is left unticked and unflagged, so
                // only an edit to its notes sends it again.
                ticked[i].details.add('Could not update Event tracking flags: ' + errorText(tickResults[i].getErrors()));
            }
        }

        List<Gemini_Opty_Log__c> logs = new List<Gemini_Opty_Log__c>();
        for (Call c : calls) {
            logs.add(toLog(c, model));
            if (c.status == SUCCESS || c.status == PARTIAL) {
                summary.analysed++;
            } else {
                summary.failed++;
            }
            summary.inputTokens += c.inputTokens == null ? 0 : c.inputTokens;
            summary.outputTokens += c.outputTokens == null ? 0 : c.outputTokens;
        }
        Database.insert(logs, false, AccessLevel.SYSTEM_MODE);
    }

    private static Gemini_Opty_Log__c toLog(Call c, String model) {
        List<String> changes = new List<String>();
        if (c.merged != null && (c.status == SUCCESS || c.status == PARTIAL)) {
            for (String field : c.merged.changes.keySet()) {
                changes.add(field + ' = ' + c.merged.changes.get(field));
            }
        }
        Integer tokens = (c.inputTokens == null ? 0 : c.inputTokens) + (c.outputTokens == null ? 0 : c.outputTokens);
        return new Gemini_Opty_Log__c(
            Opportunity__c = c.mom.WhatId,
            Event_Id__c = c.mom.Id,
            Model__c = model == null ? null : model.left(80),
            Status__c = c.status,
            Input_Token__c = c.inputTokens,
            Output_Token__c = c.outputTokens,
            Token_Used__c = tokens,
            Error_Message__c = c.details.isEmpty() ? null : String.join(c.details, '\n').left(32768),
            JSON_Log__c = c.response == null ? String.join(c.details, '\n').left(131072) : c.response.left(131072)
        );
    }

    // ---- Config -------------------------------------------------------------

    private static String model() {
        Program_Constant__mdt row = Program_Constant__mdt.getInstance(MODEL_KEY);
        return row == null || row.Value__c == null ? null : row.Value__c.trim();
    }

    private static String prompt() {
        List<StaticResource> rows = [SELECT Body FROM StaticResource WHERE Name = :PROMPT_RESOURCE WITH SYSTEM_MODE LIMIT 1];
        return rows.isEmpty() ? null : rows[0].Body.toString();
    }

    private static String errorText(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error e : errors) {
            messages.add(e.getStatusCode() + ': ' + e.getMessage());
        }
        return String.join(messages, '; ');
    }
}