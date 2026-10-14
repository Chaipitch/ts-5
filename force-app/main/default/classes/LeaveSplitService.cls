public without sharing class LeaveSplitService {

    @TestVisible private static final String TYPE_UNPAID = 'Unpaid leave';
    private static final String STATUS_APPROVED = 'Approved';

    private static final String ALL_DAY  = 'All day';
    private static final String AM_LEAVE = 'AM leave';
    private static final String PM_LEAVE = 'PM leave';
    private static final Integer MAX_CHAIN_HOPS = 6;
    @TestVisible private static Set<Id> handled = new Set<Id>();
    private static Boolean rebuilding = false;

    private class Half {
        Date day;
        Boolean isMorning;
        Half(Date day, Boolean isMorning) {
            this.day = day;
            this.isMorning = isMorning;
        }
    }

    /** One contiguous run of half days, funded by one pool. */
    private class Segment {
        String leaveType;
        Integer firstHalf;  // index into the request's half days
        Integer halfCount;
        Segment(String leaveType, Integer firstHalf, Integer halfCount) {
            this.leaveType = leaveType;
            this.firstHalf = firstHalf;
            this.halfCount = halfCount;
        }
    }

    private class Piece {
        String leaveType;
        Date startsOn;
        Date endsOn;
        String period;
        Piece(String leaveType, Date startsOn, Date endsOn, String period) {
            this.leaveType = leaveType;
            this.startsOn = startsOn;
            this.endsOn = endsOn;
            this.period = period;
        }
    }

    /* What one balance row can fund, and between which dates. */
    private class Pool {
        Decimal available;
        Date closesOn;      // null for a balance that does not expire
        Date opensOn;
        /*
         * The carry over inside `available`, and the date it stops being reachable.
         *
         * Held apart because the two halves of an annual pool do not fund the same dates:
         * accrued days fund any day of the year, carried days only those on or before
         * June 30. Folded together, the splitter offered days that had already lapsed and
         * the row settled negative once the June sweep declined to credit them back.
         */
        Decimal carryAvailable;
        Date carryClosesOn;
    }

    /**
     * Splits any newly created leave request whose days run past the balance.
     * Runs after insert, because the continuations have to point back at a saved parent.
     */
    public static void splitOverBalance(List<ApplicationItem__c> newRecords) {
        evaluate(newRecords, false);
    }

    public static void reevaluate(List<ApplicationItem__c> records) {
        evaluate(records, true, null);
    }

    public static void resplitOnEdit(List<ApplicationItem__c> records) {
        if (rebuilding) {
            return; // our own shortening update, not somebody moving the dates
        }
        List<ApplicationItem__c> candidates = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : records) {

            handled.remove(appl.Id);
            if (isSplittable(appl, false)) {
                candidates.add(appl);
            }
        }
        if (candidates.isEmpty()) {
            return;
        }

        Map<Id, List<ApplicationItem__c>> supersededByParent = new Map<Id, List<ApplicationItem__c>>();
        Set<Id> hasApprovedTail = new Set<Id>();
        for (ApplicationItem__c sib : [
            SELECT Id, Split_From__c, Status__c
            FROM ApplicationItem__c
            WHERE Split_From__c IN :new Map<Id, ApplicationItem__c>(candidates).keySet()
        ]) {

            if (STATUS_APPROVED.equals(sib.Status__c)) {
                hasApprovedTail.add(sib.Split_From__c);
                continue;
            }
            if (!supersededByParent.containsKey(sib.Split_From__c)) {
                supersededByParent.put(sib.Split_From__c, new List<ApplicationItem__c>());
            }
            supersededByParent.get(sib.Split_From__c).add(sib);
        }

        List<ApplicationItem__c> toEvaluate = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : candidates) {
            if (!hasApprovedTail.contains(appl.Id)) {
                toEvaluate.add(appl);
            }
        }
        if (!toEvaluate.isEmpty()) {
            evaluate(toEvaluate, false, supersededByParent);
        }
    }

    /**
     * A type that spends a fixed balance but has nowhere to overflow to is refused at save
     * when its days run past what that balance funds - beyond the days left, before the
     * grant or after the expiry - rather than saved as a request nobody can approve.
     *
     * Measured the way the split measures it, working day by working day, so weekends
     * and holidays inside the range cost nothing. A type with no balance row is left to
     * the deduction on approval, which already says so.
     */
    public static void refuseUnfunded(List<ApplicationItem__c> requests, Map<Id, ApplicationItem__c> oldMap) {
        List<ApplicationItem__c> candidates = new List<ApplicationItem__c>();
        Set<String> keys = new Set<String>();
        for (ApplicationItem__c appl : requests) {
            // A request already refused on other grounds fails on those alone.
            if (appl.hasErrors() || appl.Term_From__c == null || zeroIfNull(appl.Leave_Days__c) <= 0
                || STATUS_APPROVED.equals(appl.Status__c) || 'Rejected'.equals(appl.Status__c)
                || !isReshaped(appl, oldMap)) {
                continue;
            }
            Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(appl.Request_Type__c);
            if (policy == null || policy.Deducts_Balance__c != true
                || policy.Grants_On_Use__c == true || String.isNotBlank(policy.Overflow_To__c)) {
                continue;
            }
            candidates.add(appl);
            keys.add(ApplicationItemTriggerLogic.balanceKey(
                appl.OwnerId, appl.Request_Type__c, appl.Term_From__c.year()));
        }
        if (candidates.isEmpty()) {
            return;
        }

        Map<String, Pool> poolByKey = poolsFor(keys);
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysForBatch(candidates);
        for (ApplicationItem__c appl : candidates) {
            Pool pool = poolByKey.get(ApplicationItemTriggerLogic.balanceKey(
                appl.OwnerId, appl.Request_Type__c, appl.Term_From__c.year()));
            if (pool == null) {
                continue;
            }
            List<Half> halves = halvesFor(appl, ApplicationItemTriggerLogic.workingDaysFor(appl, holidays));
            Integer usable = capacityOf(pool, halves, 0, halves.size());
            if (usable < halves.size()) {
                appl.addError(unfundedMessage(appl, pool, halves, usable));
            }
        }
    }

    private static Boolean isReshaped(ApplicationItem__c appl, Map<Id, ApplicationItem__c> oldMap) {
        ApplicationItem__c prior = oldMap == null ? null : oldMap.get(appl.Id);
        return prior == null
            || prior.Term_From__c != appl.Term_From__c
            || prior.Term_To__c != appl.Term_To__c
            || prior.Request_Type__c != appl.Request_Type__c
            || prior.Period_Leave__c != appl.Period_Leave__c;
    }

    private static String unfundedMessage(ApplicationItem__c appl, Pool pool,
                                          List<Half> halves, Integer usable) {
        String message = appl.Request_Type__c + ': this request is for '
            + (halves.size() / 2.0).stripTrailingZeros().toPlainString() + ' working day(s), but ';
        message += usable == 0
            ? 'your balance covers none of them.'
            : 'your balance covers only ' + (usable / 2.0).stripTrailingZeros().toPlainString()
              + ' (up to ' + shown(halves[usable - 1].day) + ').';
        message += ' You have ' + zeroIfNull(pool.available).stripTrailingZeros().toPlainString()
            + ' day(s) left';
        if (pool.opensOn != null && pool.closesOn != null) {
            message += ', to be taken between ' + shown(pool.opensOn) + ' and ' + shown(pool.closesOn);
        } else if (pool.closesOn != null) {
            message += ', to be taken by ' + shown(pool.closesOn);
        }
        return message + '. Shorten the request to fit, and raise any further days as a separate request.';
    }

    private static String shown(Date day) {
        return Datetime.newInstance(day, Time.newInstance(0, 0, 0, 0)).format('yyyy/MM/dd');
    }

    public static void rebuildFrom(List<ApplicationItem__c> keep, List<ApplicationItem__c> discard) {
        if (keep.isEmpty()) {
            return;
        }
        Boolean wasRebuilding = rebuilding;
        rebuilding = true;
        try {
            if (discard != null && !discard.isEmpty()) {
                delete discard;
            }
            update keep;
        } finally {
            rebuilding = wasRebuilding;
        }

        Set<Id> ids = new Map<Id, ApplicationItem__c>(keep).keySet();
        handled.removeAll(new List<Id>(ids));
        // Re-read rather than reuse: the update above recalculated Leave_Days__c, which
        // is the figure the walk measures against the pools.
        reevaluate([
            SELECT Id, OwnerId, Request_Type__c, Status__c, Term_From__c, Term_To__c,
                   Leave_Days__c, Split_From__c, RecordTypeId, Remark__c, Period_Leave__c
            FROM ApplicationItem__c WHERE Id IN :ids
        ]);
    }

    private static void evaluate(List<ApplicationItem__c> newRecords, Boolean allowTails) {
        evaluate(newRecords, allowTails, null);
    }

    private static void evaluate(List<ApplicationItem__c> newRecords, Boolean allowTails,
                                 Map<Id, List<ApplicationItem__c>> supersededByParent) {
        List<ApplicationItem__c> candidates = new List<ApplicationItem__c>();
        Map<Id, List<String>> chainByRecord = new Map<Id, List<String>>();
        Set<String> keys = new Set<String>();

        for (ApplicationItem__c appl : newRecords) {
            if (!isSplittable(appl, allowTails)) {
                continue;
            }
            List<String> chain = chainFor(appl.Request_Type__c);
            if (chain.size() < 2) {
                continue; // nowhere to overflow to
            }
            candidates.add(appl);
            chainByRecord.put(appl.Id, chain);
            // Every pool the request could reach, not only the one it asked for.
            for (String leaveType : chain) {
                keys.add(ApplicationItemTriggerLogic.balanceKey(
                    appl.OwnerId, leaveType, appl.Term_From__c.year()));
            }
        }
        if (candidates.isEmpty()) {
            return;
        }

        Map<String, Pool> poolByKey = poolsFor(keys);
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysForBatch(candidates);

        List<ApplicationItem__c> toUpdate = new List<ApplicationItem__c>();
        List<ApplicationItem__c> continuations = new List<ApplicationItem__c>();
        // Continuations from an earlier split of a parent being rebuilt below. Only the
        // ones whose parent actually gets replacements are collected.
        List<ApplicationItem__c> superseded = new List<ApplicationItem__c>();

        for (ApplicationItem__c appl : candidates) {
            List<Date> workingDays = ApplicationItemTriggerLogic.workingDaysFor(appl, holidays);
            if (workingDays.isEmpty()) {
                continue;
            }

            if (!poolByKey.containsKey(ApplicationItemTriggerLogic.balanceKey(
                    appl.OwnerId, appl.Request_Type__c, appl.Term_From__c.year()))) {
                continue;
            }

            List<Half> halves = halvesFor(appl, workingDays);
            List<Segment> segments =
                allocate(appl, chainByRecord.get(appl.Id), halves, poolByKey);

            if (segments.isEmpty()
                || (segments.size() == 1 && segments[0].leaveType.equals(appl.Request_Type__c))) {
                continue;
            }

            List<Piece> pieces = new List<Piece>();
            for (Segment seg : segments) {
                pieces.addAll(piecesFor(seg, halves));
            }
            if (pieces.isEmpty()) {
                continue;
            }

            Date rangeEnd = appl.Term_To__c == null ? appl.Term_From__c : appl.Term_To__c;
            if (ALL_DAY.equals(pieces[0].period)) {
                pieces[0].startsOn = appl.Term_From__c;
            }
            Piece tail = pieces[pieces.size() - 1];
            if (ALL_DAY.equals(tail.period)) {
                tail.endsOn = rangeEnd;
            }

            for (Integer i = 0; i < pieces.size(); i++) {
                Piece piece = pieces[i];
                if (i == 0) {
                    ApplicationItem__c head = new ApplicationItem__c(Id = appl.Id);

                    if (!piece.leaveType.equals(appl.Request_Type__c)) {
                        head.Request_Type__c = piece.leaveType;
                    }
                    head.Term_From__c = piece.startsOn;
                    head.Term_To__c = piece.endsOn;
                    head.Period_Leave__c = piece.period;
                    toUpdate.add(head);
                } else {
                    continuations.add(continuationOf(appl, piece));
                }
            }

            addSuperseded(superseded, supersededByParent, appl.Id);
            handled.add(appl.Id);
        }

        // Saved and restored rather than simply cleared, so a nested evaluate cannot
        // lift the guard while an outer one is still writing.
        Boolean wasRebuilding = rebuilding;
        rebuilding = true;
        try {
            // Before the replacements, so an old continuation and a new one never
            // occupy the same dates.
            if (!superseded.isEmpty()) {
                delete superseded;
            }
            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }
            if (!continuations.isEmpty()) {
                insert continuations;
            }
        } finally {
            rebuilding = wasRebuilding;
        }
    }

    private static List<Half> halvesFor(ApplicationItem__c appl, List<Date> workingDays) {
        List<Half> halves = new List<Half>();
        if (workingDays.size() == 1 && isHalfDay(appl.Period_Leave__c)) {
            halves.add(new Half(workingDays[0], AM_LEAVE.equals(appl.Period_Leave__c)));
            return halves;
        }
        for (Date day : workingDays) {
            halves.add(new Half(day, true));
            halves.add(new Half(day, false));
        }
        return halves;
    }

    private static List<Segment> allocate(ApplicationItem__c appl, List<String> chain,
                                          List<Half> halves, Map<String, Pool> poolByKey) {
        List<Segment> segments = new List<Segment>();
        Integer total = halves.size();
        Integer cursor = 0;
        Integer yr = appl.Term_From__c.year();

        for (Integer i = 0; i < chain.size() && cursor < total; i++) {
            Boolean isLast = (i == chain.size() - 1);
            Integer take = isLast
                ? total - cursor
                : capacityOf(poolByKey.get(
                      ApplicationItemTriggerLogic.balanceKey(appl.OwnerId, chain[i], yr)),
                      halves, cursor, total);
            if (take > 0) {
                segments.add(new Segment(chain[i], cursor, take));
                cursor += take;
            }
        }

        if (cursor < total && !segments.isEmpty()) {
            segments[segments.size() - 1].halfCount += total - cursor;
        }
        return segments;
    }

    private static List<Piece> piecesFor(Segment seg, List<Half> halves) {
        List<Piece> pieces = new List<Piece>();
        Integer first = seg.firstHalf;
        Integer last  = first + seg.halfCount - 1;

        if (!halves[first].isMorning) {
            pieces.add(new Piece(seg.leaveType, halves[first].day, halves[first].day, PM_LEAVE));
            first++;
        }
        // Held back rather than added here, so the whole days below stay in date order
        // between the two half days.
        Piece closing = (first <= last && halves[last].isMorning)
            ? new Piece(seg.leaveType, halves[last].day, halves[last].day, AM_LEAVE)
            : null;
        if (closing != null) {
            last--;
        }
        if (first <= last) {
            pieces.add(new Piece(seg.leaveType, halves[first].day, halves[last].day, ALL_DAY));
        }
        if (closing != null) {
            pieces.add(closing);
        }
        return pieces;
    }

    private static Integer capacityOf(Pool pool, List<Half> halves,
                                      Integer cursor, Integer total) {
        if (pool == null || pool.available == null || pool.available <= 0) {
            return 0;
        }
        /*
         * Spent half a day at a time, drawing on the carried days first and falling back
         * to the accrued ones, so a request that straddles June 30 is funded correctly on
         * both sides of it: carried days pay for the June halves and accrued days for the
         * July ones. Days arrive in date order, so the carry window is always the front of
         * the range and never has to be revisited.
         */
        Decimal carryLeft = pool.carryAvailable == null ? 0 : pool.carryAvailable;
        Decimal accruedLeft = pool.available - carryLeft;
        if (accruedLeft < 0) {
            accruedLeft = 0;
        }

        Integer usable = 0;
        Integer room = total - cursor;
        while (usable < room) {
            Date day = halves[cursor + usable].day;
            if (pool.closesOn != null && day > pool.closesOn) {
                break;
            }
            if (pool.opensOn != null && day < pool.opensOn) {
                break;
            }
            Boolean carryReaches = pool.carryClosesOn == null || day <= pool.carryClosesOn;
            if (carryReaches && carryLeft >= 0.5) {
                carryLeft -= 0.5;
            } else if (accruedLeft >= 0.5) {
                accruedLeft -= 0.5;
            } else {
                break;
            }
            usable++;
        }
        return usable;
    }

    private static Map<String, Pool> poolsFor(Set<String> keys) {
        Map<String, Pool> pools = new Map<String, Pool>();
        for (Leave_Balance__c bal : [
            SELECT External_Key__c, Accrued_To_Date__c, Carry_Over_Days__c, Used_Days__c,
                   Granted_On__c, Expiry_Date__c, Carry_Over_Expiry__c
            FROM Leave_Balance__c
            WHERE External_Key__c IN :keys
        ]) {
            Pool pool = new Pool();
            pool.available = zeroIfNull(bal.Accrued_To_Date__c) + zeroIfNull(bal.Carry_Over_Days__c)
                           - zeroIfNull(bal.Used_Days__c);
            /*
             * What is LEFT of the carry over, since it is spent before the current year:
             * MAX(0, CarriedIn - Used). Once consumption has passed the carried amount
             * there is none left to date-limit and the pool is ordinary accrued days.
             */
            Decimal carryLeft = zeroIfNull(bal.Carry_Over_Days__c) - zeroIfNull(bal.Used_Days__c);
            pool.carryAvailable = carryLeft < 0 ? 0 : carryLeft;
            pool.carryClosesOn = bal.Carry_Over_Expiry__c;
            pool.closesOn = bal.Expiry_Date__c;
            pool.opensOn = bal.Granted_On__c;
            pools.put(bal.External_Key__c, pool);
        }
        return pools;
    }

    @TestVisible
    private static List<String> chainFor(String leaveType) {
        List<String> chain = new List<String>();
        Set<String> seen = new Set<String>();
        String cursor = leaveType;
        while (String.isNotBlank(cursor) && !seen.contains(cursor)
               && chain.size() < MAX_CHAIN_HOPS) {
            Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(cursor);
            if (policy == null) {
                break;
            }
            chain.add(cursor);
            seen.add(cursor);
            cursor = policy.Overflow_To__c;
        }
        return chain;
    }

    private static ApplicationItem__c continuationOf(ApplicationItem__c parent, Piece piece) {
        return new ApplicationItem__c(
            RecordTypeId    = parent.RecordTypeId,
            Request_Type__c = piece.leaveType,
            Period_Leave__c = piece.period,
            Term_From__c    = piece.startsOn,
            Term_To__c      = piece.endsOn,
            Remark__c       = continuationRemark(parent, piece),
            Status__c       = parent.Status__c,
            OwnerId         = parent.OwnerId,
            Split_From__c   = parent.Id
        );
    }

    private static String continuationRemark(ApplicationItem__c parent, Piece piece) {
        String suffix = isHalfDay(piece.period)
            ? ' [' + piece.period.toLowerCase() + ', ' + piece.leaveType.toLowerCase()
                   + ', split from ' + parent.Request_Type__c + ']'
            : ' [' + piece.leaveType.toLowerCase() + ' continuation of '
                   + parent.Request_Type__c + ']';
        String base = parent.Remark__c == null ? '' : parent.Remark__c;
        Integer room = 255 - suffix.length();
        return (base.length() > room ? base.substring(0, room) : base) + suffix;
    }

    private static Boolean isHalfDay(String periodLeave) {
        return AM_LEAVE.equals(periodLeave) || PM_LEAVE.equals(periodLeave);
    }

    private static Boolean isSplittable(ApplicationItem__c appl, Boolean allowTails) {
        if (handled.contains(appl.Id)) {
            return false;
        }
        // A continuation of an earlier split. On insert it never splits again; after a
        // promotion it must, which is what allowTails is for.
        if (appl.Split_From__c != null && !allowTails) {
            return false;
        }
        if (appl.Term_From__c == null || zeroIfNull(appl.Leave_Days__c) <= 0) {
            return false;
        }
        if (ApplicationItemTriggerHandler.isOvertimeRequest(appl)) {
            return false;
        }
        Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(appl.Request_Type__c);
        return policy != null && String.isNotBlank(policy.Overflow_To__c);
    }

    private static void addSuperseded(List<ApplicationItem__c> collector,
                                      Map<Id, List<ApplicationItem__c>> byParent, Id parentId) {
        if (byParent != null && byParent.containsKey(parentId)) {
            collector.addAll(byParent.get(parentId));
        }
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}