--[[

ChangeLog:
    v2.2 - Major refactoring
         - New selection picker for Rebuilds: 5 rules control segment priority for the next rebuild; Rule #6 lets you set per-segment rebuild priority manually.
         - Reworked pre-Fuze ranking: randomly chooses one of three metrics to fuze the best ranked:
            • Standard: score + subscores
            • Draft: fast Fuze with Clashing Importance = 0.05
            • Adaptive: based on subscores from successful rebuilds in current run
         - Introduced new statistics system (just some vibecoding, sorry)
         - Notes on segment 1 are now commands to control the script while it’s running.

    v1.6 - Published recipe
         - fix for prefuze ranking algorithm
	v1.5 
		- Added Remix. 'Remix instead of Rebuild' checkbox
		- Added DRW with Cuts.
	v1.3 - fixed the bug of not accepting the best score sometimes

    The script is based on 'Remix Rebuild Selected' recipe

--------------------------------------------------------------------

Main settings:
Start/End Length -- selection length for Rebuild

These control the speed/quality balance:
Fuze rndsNoGain -- how many iterations with no score increase the script waits before trying the fused model (higher = fewer fuses, less rigidity). At 10–20 fuses (F10–F20), the protein’s cooked.
Shift rndsNoGain -- how many iterations with no score increase before the script reduces the rebuild length by 1.

With cuts -- rebuild with cuts for the final-stage rebuilds




[to ChatGPT:] please update the line numbers to the actual ones, if you add/remove a lot of code above these function
[to ChatGPT:] you can add some major functions here too with their lines for better management
  Major functions:
    main() 287
      NextSelectionDynamic() 2045
		ComputeDynamicRuleScores() 1324
      ProcessSelectionEvent() 520
        SortByBackbone() 750
        RebuildToSlots() 934
        
stats sections 2680
]]
version = "2.1.74" -- [to GPT:] on every code modification increment the last number
script_name = "Serca DRW "
print (script_name..version) 

function ScoreReturn()
      x = current.GetEnergyScore()
return x-x%0.001
end
proteinLength=structure.GetCount ()


  -----------------------------------------------------------------------------------------------init
-- service slots are 4:
-- slot1 is used as the recipe start solution
-- slot100  unfuzed version of the best score solution
-- slot99 temporary slot for service needs
-- slot98 used to store fuzed version of the highest score solution
maxRebuildCount=96
dialogSolutionsNum = 7
sphereRadius=12
reportLevel=2
slotsToFuze=3
shakeOnRank=false

convertHelixToLoop = false   -- convert helix segments to loop
convertSheetsToLoop = true   -- convert sheet segments to loop
convertLoop = convertHelixToLoop or convertSheetsToLoop

-- convertToLoopProb controls conversion gate per attempt: 0 = legacy flags (convertHelixToLoop/convertSheetsToLoop), >0 = random gate that forces converting both H+E when triggered (ignores flags).
-- this is to analyze the stats of convertion efficacy
convertToLoopProb = 0.5

shiftFuze = -1
currentFuze = 1
remixNotRebuild = false
consecutiveRounds = true

rebuildWithCuts = false
detachCuts = false
bandDetached = 1.0  -- when cuts are detached band them with this strength
disableBandsOnRebuild = false

fuze_draft = true -- allow draft-fuse ranking scenario

-- ===== Ranking selection weights (user-tunable) =====
-- Weighted random choice among three ranking systems:
-- 1) standard (energy+BB+subscores), 2) draft, 3) syn (ramps from 0)
current_rank_weight = 1.0   -- selection weight for standard ranking
draft_rank_weight   = 2.0   -- selection weight for draft ranking
syn_alpha_max       = 1.5   -- max selection weight for syn ranking
syn_ramp_events     = 70    -- events to reach syn max selection weight
-- ================================================


-- Last chosen ranking scenario for the current event
-- Values: "standard" | "draft" | "syn" | nil (unset)
rankScenario = nil

startCI = 0.05 --probably a dead variable
endCI=behavior.GetClashImportance() --probably a dead variable
CI = endCI --probably a dead variable


-- Controls how variable the final selection length can be around L
-- Interpreted as a 95% interval half-width (≈ ±lengthVariability around L)
-- Larger values → more aggressive attempts to grow/shrink; 0 → keep length
lengthVariability = 2

OverlapSettings = true
overlap = 0
ignoredSel = 0

selectionLength=13 --its value is replaced by StartRebuild - EndRebuild vars
StartRebuild = START_REBUILD_NOCUTS
EndRebuild = END_REBUILD_NOCUTS

-- Will be set by applyDialogDefaults(); defined here for clarity
fuzeAfternoGain = nil
shiftNoGain = nil

fuzeAfternoGain_counter = 0
shiftNoGain_counter = 0
shiftFuze_counter = 0

startingAA=1

bestScore=ScoreReturn()
lastScore=-9999999
currentBBScore=-9999999
rebuildScores = {}
remixBBScores = {}, {}
rebuildScores[1]=bestScore
rebuildRetryNo=0
bestSelectNum=0
solutionsFound = 1
remixNum = #rebuildScores
undo.SetUndo(false)
freeSlot=97

selectionPresent=false
bestSlot=0
selectionEnd=0
selectionStart=0
selNum=0
roundsWithNoGain = 0
FuzeNumber = 1

fuzeConfig = {
						"{1.00, 2, 0.05,20} {0.25, 2, 0.25,7} {1.00, 2, 1.00,20} {0.05, 1, 0.25,2} {1.00, 3, 1.00,20} ", --best score
						" {0.05, 3, 0.05,2} {1.00, -7, 1.00,2} {1.00, 3, 1.00,20}",	-- short fuze 
                        "{0.05, -3, 0.05,7}", --draft
						"{0.05, 1, 0.05,7} {1.00, -2, 1.00,20} {0.25, -3, 0.05,7} {1.00, 1, 1.00,20} ", --rebuildWithCuts fuze
						"{0.25, 1, 1.00,20} {0.05, 2, 0.05,7} {0.25, 3, 0.05,7} {1.00, -2, 1.00,20} {1.00, 3, 1.00,20} ", --best score
						" {0.05, 3, 0.05,2} {1.00, -7, 1.00,2} {1.00, 3, 1.00,20}",
						"{0.05, -2, 0.05,7} {0.25, 2, 0.25,7} {1.00, 3, 1.00,20}",	
						"{0.05, -2, 0.05,7} {1.00, 3, 1.00,7} {0.05, 2, 0.05,7} {0.25, 1, 0.25,2} {1.00, 3, 1.00,20}"
						}	


------------------- Defaults to fill the dialog window rebuild parameters
-- Baseline at 100 aa: how many no-gain events before fuze switch
FUZE_BASE_100AA_NOCUTS   = 30   -- e.g., fuse every 50 Rebuilds on ProteinLength=100
FUZE_BASE_100AA_WITHCUTS = 6    -- more aggressive when rebuilding with cuts
-- How often to shift length relative to fuze: shift threshold = fuze / SHIFT_PER_FUZE
SHIFT_PER_FUZE_NOCUTS    = 2
SHIFT_PER_FUZE_WITHCUTS  = 0.45
-- Dialog Slider ranges scale with baseline; cap to avoid runaway
SLIDER_CAP_ABSOLUTE      = 2000
FUZE_SLIDER_MAX_MULT     = 20
SHIFT_SLIDER_MAX_MULT    = 20

-- start/end lengths and dialog defaults
START_REBUILD_NOCUTS = 13
END_REBUILD_NOCUTS   = 13
START_REBUILD_WITHCUTS = 12
END_REBUILD_WITHCUTS   = 6
DIALOG_SOLUTIONS_NOCUTS = 7
DIALOG_SOLUTIONS_WITHCUTS = 7

---------------------- Euristics Rules to choose the next selection for rebuild/remix
---- see function NextSelectionDynamic()
SELECTION_STRATEGY = { STATIC = "static", DYNAMIC = "dynamic" }
selectionStrategy = SELECTION_STRATEGY.DYNAMIC

-- Dynamic selection (SELECTION_STRATEGY.DYNAMIC): how we pick the next area to rebuild
-- We score every segment by five simple ideas (Rules 1–5), then slide a selection  and choose
-- the place where the average rule points are highest. Below are the rules:
--  Rule 1 — Biggest impact from the last accepted rebuild: segments whose scores changed the most
--    during that successful rebuild get priority; this priority fades with each subsequent selection.
--  Rule 2 — Hasn’t been rebuilt for a while: segments that were rebuilt long ago are pushed
--    to the front of the queue to keep coverage fair.
--  Rule 3 — Impact from the last unsuccessful rebuild: segments that changed the most during
--    the last failed attempt get priority; this priority grows with a longer no‑gain streak.
--  Rule 4 — Weak local score: segments with lower current score are prioritized to lift weak spots.
--  Rule 5 — Weak backbone score: segments with lower backbone score are also prioritized.
-- After scoring, each rule is scaled to a 0–1 range and combined with its weight. We then try
-- selection lengths around L (L−1, L, L+1) and pick the selection with the best average score. If two
-- selections tie, we prefer the one closest to L, and if still equal, the shorter one.
-- The tweakable constants below set how strong each rule is and how fast Rule 1 fades and Rule 3 grows.
--  Rule 0 — Success-rate map: segments with higher success ratio (successes/attempts)
--           get higher priority persistently.
dyn_rule0_weight = 2.0   -- weight for Rule 0 (success ratio)
dyn_rule1_weight = 1.0   -- weight for Rule 1 (aggregated impact of accepted rebuilds)
dyn_rule2_weight = 1.0   -- age since last rebuild (in events)
dyn_rule2_ageScale = 100 -- scale for typical age; used implicitly via min-max; keep for reference
dyn_rule3_weight = -0.4  -- aggregated magnitude of |Score - Score_at_last_no_gain| (default inverted)
dyn_rule4_weight = 0.3   -- low per-segment Score gets more points
dyn_rule5_weight = 0.3   -- low per-segment ScoreBB gets more points
-- Rule 6 — User map from Notes (base62 0-9,a-z,A-Z). Higher char → higher priority.
dyn_rule6_weight = 2.0   -- default weight; can be changed via Notes
rule6_lastString = nil   -- last accepted raw base62 string from Notes
rule6_mapNorm = {} -- Initialize Rule 6 normalized map with zeros (no effect) by default
for i = 1, proteinLength do rule6_mapNorm[i] = 0 end

-- Decaying aggregation for Rule 1 (success) and Rule 3 (no‑gain): always enabled.
local function _agg_decay_from_half_life(H)
    if not H or H <= 0 then return 0 end
    return 2 ^ (-1 / H)
end
-- Aggregation depth via half-life in events. H<=0 → lam=0 (memory of exactly last impulse).
R1_DECAY_EVENTS = 6
R3_DECAY_EVENTS = 6
dyn_rule1_agg_decay = _agg_decay_from_half_life(R1_DECAY_EVENTS)
dyn_rule3_agg_decay = _agg_decay_from_half_life(R3_DECAY_EVENTS)

-- Policy: inside current rebuild window we do not add new impulse (avoid self-bias); we still apply decay.

-- Optional reset of R3 memory after success. If enabled, multiply fail-aggregator by this factor on success.
R3_SUCCESS_RESET_ENABLED = true
R3_SUCCESS_RESET_FACTOR  = 0.0  -- 0.0 = full reset; 0.5 = halve memory; 1.0 = no extra reset

local function _recalc_agg_decays()
    dyn_rule1_agg_decay = _agg_decay_from_half_life(R1_DECAY_EVENTS)
    dyn_rule3_agg_decay = _agg_decay_from_half_life(R3_DECAY_EVENTS)
end


-- Dynamic selection tracking state (filled at runtime)
segLastRebuildEventIx = {}
segScoreAtLastSuccess = {}
segScoreAtLastNoGain  = {}
lastSuccessEventIndex = 0
eventsProcessedCounter = 0
consecutiveNoGainEvents = 0
 -- Per-segment counter: how many times a segment was sent to rebuild (any event)
 segRebuildCount = {}
-- Per-segment impact of the last accepted rebuild (absolute delta of per-segment score at success time)
segImpactLastSuccess = {}
-- Per-segment impact of the last unsuccessful rebuild attempt (absolute delta at failure time)
segImpactLastNoGain = {}
-- Decaying aggregators (EMA-like) for R1/R3
segImpactSuccAgg = {}
segImpactFailAgg = {}
---------------------------------

selDialog=selNum
selectionStartArr={}
selectionEndArr={}
solutionIDs = {}
action="Rebuild"

rebuiltResidues = {} 	--array to monitor changes in residues in all the solutions in slots

startScore=ScoreReturn()
startRoundScore = ScoreReturn()
initScore=ScoreReturn()  --the real start score that doesn't changes

print ("+++Starting score "..startScore.." saved to slot 1")

save.Quicksave(1)
save.Quicksave(100)

timer1, timer2, timer3, timer4, timer5  = 0,0,0,0,0 -- timers for srcipt functions to check execution. 

selection.DeselectAll() --Clear All The Selections On The Start for DRW!
save.SaveSecondaryStructure()
-----------------------------------------------------------------------------------------------main
function main()
    resetRebuiltResidues()

    -- Prepare initial user selections (only used to seed defaults; static selections are built later)
    FindSelection()
    tempSelNum=selNum
    if selNum==0 then selNum=1 end
    selDialog=selNum

    -- Dialog with options
    while requestResult~=1 do
      requestResult = RequestOptions()
      if requestResult == 0 then return end
      if requestResult == 2 then selDialog=selDialog+1 end
      if selDialog>5 then selDialog=5 end
    end

    selNum=math.max(tempSelNum, selDialog, selNum)

    -- seed slot98 with fuzed start if requested
    if Stats and Stats.init then Stats.init() end
    if (useSlot98) then 
        if reportLevel>2 then print ("Making Fuze for this unfuzed start", startScore) end
        Fuze2(fuzeConfig[1])
        if reportLevel>1 then print ("Fuzed to", ScoreReturn()) end
        if ScoreReturn() > startScore then
            save.Quicksave(98)
            save.Quicksave(100)
            startScore=ScoreReturn()
            startRoundScore = ScoreReturn()
            initScore=ScoreReturn() 
        end
    else
        save.Quicksave(98)
    end
    save.Quickload(1)

-- ===== Summary output for dialog parameters =====
	do
	  local parts = {
		(action or "Run")..": "
		..tostring(maxRebuildCount)
		.." : "..tostring(slotsToFuze)
		..". Length "..tostring(StartRebuild).." - "..tostring(EndRebuild).."\n"
	  }

	  local kvs = {
		{"fuzeNoGain",            fuzeAfternoGain},
		{"shiftNoGain",           shiftNoGain},
		{"consecutiveEvents",     consecutiveRounds},
		{"selectionStrategy",     selectionStrategy},
		{"rebuildWithCuts",       rebuildWithCuts},
		{"convertHelixToLoop",    convertHelixToLoop},
		{"convertSheetsToLoop",   convertSheetsToLoop},
		{"detachCuts",            detachCuts},
		{"disableBandsOnRebuild", disableBandsOnRebuild},
		{"bandDetached",          bandDetached},
		{"stopAfter",             stopAfter},
		{"ignoredSel",            ignoredSel},
		{"ReportLevel",           reportLevel},
		{"shake",                 shakeOnRank},
		{"useSlot98",             useSlot98},
	  }
	  --print only true values
	  for _, kv in ipairs(kvs) do
		local k, v = kv[1], kv[2]
		if v ~= false and v ~= nil then
		  parts[#parts+1] = ", "..k..(v == true and "" or "="..tostring(v))
		end
	  end

	  if (reportLevel or 0) > 1 then		print(table.concat(parts).."\n")	  end
	end
-- ===== /Summary output =====

    -- Initialize dynamic tracking arrays with current per-segment scores
    for i = 1, proteinLength do
        segLastRebuildEventIx[i] = 0
        local s = current.GetSegmentEnergyScore(i)
        segScoreAtLastSuccess[i] = s
        segScoreAtLastNoGain[i]  = s
        segRebuildCount[i] = 0
        segImpactLastSuccess[i] = 0
        segImpactLastNoGain[i] = 0
        segImpactSuccAgg[i] = 0
        segImpactFailAgg[i] = 0
    end

    -- Prepare selections for static strategy
    local sortedStartArr, sortedEndArr
    local staticIndex = 1
    if selectionStrategy == SELECTION_STRATEGY.STATIC then
        if OverlapSettings then overlap=SetOverlap(selectionLength) end
        SplitProteinBySelections()
        sortedStartArr, sortedEndArr = SortSelections(selectionStartArr, selectionEndArr)
        staticIndex = 1
        if (reportLevel>1) and (selNum>0) then printSelections() end
    end

    eventsProcessedCounter = 0
    consecutiveNoGainEvents = 0

    while (stopAfter==0) or (eventsProcessedCounter < stopAfter) do
        ReadNotes() -- catching the Notes commands

        -- choose next selection
        if selectionStrategy == SELECTION_STRATEGY.STATIC then
            if staticIndex > selNum or selNum == 0 then
                -- shift starting position a bit to avoid repeating same chunks
                startingAA = startingAA - 1
                if OverlapSettings then overlap=SetOverlap(selectionLength) end
                SplitProteinBySelections()
                sortedStartArr, sortedEndArr = SortSelections(selectionStartArr, selectionEndArr)
                staticIndex = 1
            end
            selectionStart = sortedStartArr[staticIndex] or 1
            selectionEnd   = sortedEndArr[staticIndex] or math.min(selectionStart + selectionLength - 1, proteinLength)
        else
            selectionStart, selectionEnd = NextSelectionDynamic()
        end

        -- Report upcoming selection (use actual selection length)
        if reportLevel>1 then
            local lenActual = (selectionEnd or 0) - (selectionStart or 1) + 1
            if lenActual < 1 then lenActual = 1 end
            print("#"..(eventsProcessedCounter+1).." len "..lenActual.." segs: "..selectionStart.."-"..selectionEnd..". F"..FuzeNumber..". Score "..startScore)
        end

        -- ====Rebuilds start in this section====
        eventDelta = 0
        if ignoredSel > 0 then
            ignoredSel = ignoredSel - 1
            if reportLevel>2 then print("Skipped by 'SkipFirst X'. Remaining:", ignoredSel) end
        else
            -----MAJOR REBUILDING FUNCTION--------------------------------------------------------------------------------------------
            eventDelta = ProcessSelectionEvent() 
        end
        -- ====

        -- Update counters per event
        eventsProcessedCounter = eventsProcessedCounter + 1
        if eventDelta > 0.5 then --0.5 is just a small gap to prevent reset of the counters on 0.001 pts gains
            consecutiveNoGainEvents = 0
            if consecutiveRounds then
                fuzeAfternoGain_counter = 0
                shiftNoGain_counter = 0
                shiftFuze_counter = 0
            end
            -- Update baseline for Rule 1 (after success): capture current per-segment scores
            lastSuccessEventIndex = eventsProcessedCounter
            for i = 1, proteinLength do
                segScoreAtLastSuccess[i] = current.GetSegmentEnergyScore(i)
            end
        else
            consecutiveNoGainEvents = consecutiveNoGainEvents + 1
            fuzeAfternoGain_counter = fuzeAfternoGain_counter + 1
            shiftNoGain_counter = shiftNoGain_counter + 1
            shiftFuze_counter = shiftFuze_counter + 1
            -- Update baseline for Rule 3 (after an unsuccessful event)
            for i = 1, proteinLength do
                segScoreAtLastNoGain[i] = current.GetSegmentEnergyScore(i)
            end
        end

        -- Adjust after event if thresholds reached
        -- Switch to fuzed version
        if (fuzeAfternoGain == 0) or ((fuzeAfternoGain_counter >= fuzeAfternoGain) and (fuzeAfternoGain>0)) then
            if reportLevel>1 then 
                print ("No-gain:"..consecutiveNoGainEvents,
                       "/ counters: fuze ".. fuzeAfternoGain_counter,
                       "/ length("..selectionLength..") ".. shiftNoGain_counter)
            end
            fuzeAfternoGain_counter = 0
            local lastScore = ScoreReturn()
            save.Quickload(98)
            save.Quicksave(100)
            startScore = ScoreReturn()
            FuzeNumber = FuzeNumber + 1
            if reportLevel>1 then print ("Switched to fuzed version ".. ScoreReturn().." (was "..lastScore..")") end
            if reportLevel>2 then ShowRebuildFrequency() end
        end

        -- Change fuze type periodically (disabled)
        if (shiftFuze_counter >= shiftFuze) and (shiftFuze>0) then
            shiftFuze_counter = 0
            if currentFuze == 2 then 
                currentFuze = 1
                if reportLevel>1 then print ("Switched to Fuze1. (events with no gain="..shiftFuze..")") end
            else
                if reportLevel>1 then print ("Switched to Fuze2. (events with no gain="..shiftFuze..")") end
                currentFuze = 2
            end
            if reportLevel>2 then ShowRebuildFrequency() end
        end

        -- Decrease selection length after X no-gain events
        if (shiftNoGain > 0) and (shiftNoGain_counter >= shiftNoGain) then
            if StartRebuild ~= EndRebuild then
                shiftNoGain_counter = 0
                selectionLength = selectionLength - 1
                if selectionLength < EndRebuild then selectionLength = EndRebuild end
                if reportLevel>1 then print ("No-gain events hit. New length "..selectionLength) end
                if OverlapSettings then overlap=SetOverlap(selectionLength) end
                if selectionStrategy == SELECTION_STRATEGY.STATIC then
                    SplitProteinBySelections()
                    sortedStartArr, sortedEndArr = SortSelections(selectionStartArr, selectionEndArr)
                    staticIndex = 1
                end
                if reportLevel>2 then ShowRebuildFrequency() end
            end
        end

        if selectionStrategy == SELECTION_STRATEGY.STATIC then
            staticIndex = staticIndex + 1
        end

        -- Mark last rebuilt event index and increment per-segment rebuild counters
        for k = selectionStart, selectionEnd do
            if k>=1 and k<=proteinLength then
                segLastRebuildEventIx[k] = eventsProcessedCounter
                segRebuildCount[k] = (segRebuildCount[k] or 0) + 1
            end
        end
    end -- while events

    Cleanup()
    
end -- function main()


------------------------------------------------------------------------------General Fuze/Rebuild Management------------------------------------------------------------------------------

-- One rebuild event for the current selectionStart/selectionEnd
function ProcessSelectionEvent()
    local improved = false
    -- ensure we always return a numeric delta (0 if no candidates)
    local eventDelta = 0
    local preTopSlotId = nil

    solutionsFound = 1
    solutionSubscoresArray = {}
    bestScore=-9999999
    bestSlot=100 -- placeholder
    -- Reset candidate store to avoid carrying over tail from previous events
    rankScenario = nil
    remixBBScores = {}
    rebuildScores = {}
    remixNum = 0

    SetSelection()
    -- Convert to Helices/Sheets to loop. This influences the rebuild solutions.
    -- Converting H/S to loop with probability p
    local p = convertToLoopProb
    local forced = math.random() < p)
    local convHCnt, convECnt = 0, 0
    if forced or (p == 0 and convertLoop) then
      save.LoadSecondaryStructure()  -- restore original secondary structure только если будет конверсия
      for i = selectionStart, selectionEnd do
        local ss = structure.GetSecondaryStructure(i)
        if ss == "H" and (forced or convertHelixToLoop) then structure.SetSecondaryStructure(i, "l"); convHCnt = convHCnt + 1 end
        if ss == "E" and (forced or convertSheetsToLoop) then structure.SetSecondaryStructure(i, "l"); convECnt = convECnt + 1 end
      end
    end

    -- Snapshot per-segment scores before tht rebuild attempt (for Rule 1 impact measurement)
    local segScoreBeforeEvent = {}
    for i = 1, proteinLength do
        segScoreBeforeEvent[i] = current.GetSegmentEnergyScore(i)
    end
    save.Quicksave(100)

    RebuildRemixSelected() --Rebuilding and getting the remixNum

    bestSelectNum = math.min(remixNum, slotsToFuze)

    if reportLevel>2 then print(remixNum, "solutions found on "..action..". Ranking best "..bestSelectNum) end

    if Stats and Stats.enabled and remixNum > 0 then
        local t0 = os.clock()
        local evIx = (eventsProcessedCounter or 0) + 1
        Stats.logCandidates(action, evIx, selectionStart, selectionEnd, startScore, remixBBScores)
        -- Check score dispersion
        if Stats.checkSubscoreVariability then
            pcall(Stats.checkSubscoreVariability, evIx, solutionSubscoresArray)
        end
        timer4 = os.clock() - t0 + timer4
    end

    ----------------------------------- Short fuze

    if remixNum > 0 then 
        -- Local function: short-fuse pass
        local function RunShortFuses(max2fuze, fuzeIdx, logStats, logDraft, report)
            max2fuze = math.min(max2fuze, remixNum)

            for i, rec in ipairs(remixBBScores) do
                if i <= max2fuze then

                    save.Quickload(rec.id)

                    if max2fuze > 1 or rebuildWithCuts then --no need for short fuze when just 1 candidate is available, but fuze cuts anyway (to close them)

                      Fuze2(fuzeConfig[fuzeIdx]) --fuzeIdx = 2 short fuze; fuzeIdx = 3 draft fuze (ci=0.05)

                      if logDraft then -- draft fuze: store draft scores instead of logging
                        rec.draft_score = ScoreReturn()
                        rec.draft_bb    = ScoreBBReturn()
                      end
                    end

                    if logStats then
                        local t0 = os.clock()
                        if Stats and Stats.enabled then
                          local pre_s = rec.score
                          local pre_bb = rec.scoreBB
                          local subs_total_arr = nil
                          for _, srec in ipairs(solutionSubscoresArray) do
                              if srec["SolutionID"] == rec.id then
                                  local parts = Stats.scoreParts or {}
                                  subs_total_arr = {}
                                  for idx, name in ipairs(parts) do subs_total_arr[idx] = srec[name] or 0 end
                                  break
                              end
                          end
                          local short_s = ScoreReturn(); local short_bb = ScoreBBReturn()
                          Stats.logShortFuzeCand(action, (eventsProcessedCounter or 0)+1, selectionStart, selectionEnd,
                            i, rec.id, short_s, short_bb, pre_s, subs_total_arr, (short_s - pre_s), pre_bb,
                            rec.draft_score, rec.draft_bb, rec.rank_std or rec.rank)
                          if i == 1 then
                              preTopSlotId = rec.id
                              Stats.logShortFuzeTop(action, (eventsProcessedCounter or 0)+1, selectionStart, selectionEnd, rec.id, rec.rank_std or rec.rank, short_s, short_bb)
                          end
                        end
                        timer4 = os.clock() - t0 + timer4
                    end

                    local textBest=""
                    if (ScoreReturn() > bestScore) then
                        save.Quicksave(99) --save to compare with the Final Fuze score
                        bestScore=ScoreReturn()
                        bestSlot=rec.id
                        textBest="*"
                    end
                    if (report) and (reportLevel>1) and (max2fuze>1) then print(("%-5s \t %3d from bb %6.0f score: %6.3f /%.1f %s"):format(rankScenario, rec.id, rec.scoreBB, ScoreReturn(), (rec.rank or 0), textBest)) end
                end --if i <= max2fuze
            end --for
        end --local function RunShortFuseCandidates

        --------- Short fuze execution
        local t0 = os.clock()
        SortByBackbone()
        timer1 = os.clock() - t0 + timer1

        if rankScenario == "draft" then
            local t0 = os.clock()
            SortByBackbone(3) --no draft score yet, so solution list is not sorted. lets standard sort it for some aesthetics
            timer1 = os.clock() - t0 + timer1
            if slotsToFuze == 1 then
				if not rebuildWithCuts then
					temp = math.floor(math.sqrt(remixNum)) --lets still fuze draft a few solutions
					RunShortFuses(temp, 3, true, true, false) 
				end
            else
                RunShortFuses(remixNum, 3, false, true, true) --draft fuze all the candidates
                local t0 = os.clock()
                SortByBackbone(4) --sort by draft score
                timer1 = os.clock() - t0 + timer1
                rankScenario = "ShortFuzed"
                RunShortFuses(bestSelectNum, 2, true, false, true)
            end
        else 
            RunShortFuses(bestSelectNum, 2, true, false, true) -- regular short fuze
        end

        -----------------------------------Final Fuze for the best selection-----------------------------------
        save.Quickload(bestSlot)
        if reportLevel>2 then print("Fuzing best solution from slot", bestSlot) end

        Fuze2(fuzeConfig[1])
        if reportLevel>3  then print ( "Fuzed to", ScoreReturn() ) end

        -- check if this Final Fuze was more effective than the short one above
        if bestScore > ScoreReturn() then 
            save.Quickload(99) 
            if reportLevel>2 then print ( "Short fuze was better. Restoring", ScoreReturn()) end
        end 

        local currentScore = ScoreReturn()
        eventDelta = currentScore - startScore
        -- success flag duplicates 'improved'; keep a single source of truth
        if  currentScore > startScore then -- accept Fuze results if the score is better for this selection
            -- Save current fused best/unfuzed best, then apply deferred ops uniformly to both slots
            ReadNotes()
            save.Quicksave(98)
            save.Quickload(bestSlot)
            ReadNotes()
            save.Quicksave(100)

            -- Report gain using pre-update baseline (eventDelta), then update baseline
            local prevBest = currentScore - eventDelta
            print ("Gained "..roundX(eventDelta).." points. New best score: "..currentScore.." / "..ScoreReturn())
            if reportLevel>1  then print ("Total gain:", roundX(currentScore-initScore)) end
            startScore = currentScore

            -- Capture per-segment impact of this successful rebuild (Rule 1)
            UpdateImpactSuccess(segScoreBeforeEvent, selectionStart, selectionEnd)

            local currentRow = getRow(1)
            currentRow = changeRowValues(currentRow, selectionStart, selectionEnd)
            setRow(currentRow, 1)
            if reportLevel>0 then ShowRebuildFrequency() end
            improved = true
            -- segment-level success counters and delta distributions
            if Stats and Stats.logSuccessWindow then
                Stats.logSuccessWindow(selectionStart, selectionEnd, segScoreBeforeEvent)
            end
        else
            -- Capture per-segment impact of this unsuccessful rebuild (Rule 3)
            UpdateImpactNoGain(segScoreBeforeEvent, selectionStart, selectionEnd)
            if reportLevel>2 then print("No improve ("..currentScore.."). Restored to "..startScore, "/", currentScore) end
        end

        ApplyDeferredToSlots()-- if user asked to unfreeze/unband, apply these to slots 98 and 100 now (deferred)

        -- Load initial state
        save.Quickload(100)

        if Stats and Stats.enabled then
                local t0 = os.clock()
                Stats.logFinalFuze(
                  action,
                  (eventsProcessedCounter or 0)+1,
                  selectionStart,
                  selectionEnd,
                  bestSlot,
                  bestScore,
                  currentScore,
                  improved,
                  (convHCnt > 0),
                  (convECnt > 0),
                  convHCnt,
                  convECnt,
                  eventDelta
                )
                if improved and Stats.markFinalCandidate then
                    Stats.markFinalCandidate((eventsProcessedCounter or 0)+1, bestSlot)
                end
                -- After evaluating short-fuse for top-K candidates, record per-segment rank inefficiency for this event
                if preTopSlotId and bestSlot and bestSelectNum and bestSelectNum >= 1 then
                    if bestSlot ~= preTopSlotId then
                        for i = selectionStart, selectionEnd do
                            Stats.segmentIneffCount[i] = (Stats.segmentIneffCount[i] or 0) + 1
                        end
                    end
                end
                timer4 = os.clock() - t0 + timer4
        end

        if slotsToFuze > 1 then print ("-------------------------------------------------") end
    end -- if remixNum>0

    return eventDelta
end
--------------------------------------------------------------Rebuild/Remix--------------------------------------------------------------------

function SortByBackbone(rankType)
  -- Helper: build and return a position->id map for current order
  local function posMap()
      local m = {}
      for i, rec in ipairs(remixBBScores) do m[i] = rec.id end
      return m
  end

  N = #remixBBScores

  local function scoreRank(accumulate) 
      table.sort(remixBBScores, function(a,b) return (a.score or -1e18) > (b.score or -1e18) end)
      if accumulate ~= false then
        for i, rec in ipairs(remixBBScores) do
            rec.rank = (rec.rank or 0) + (N + 1 - i)  -- add rank points to all candidates (energy)
        end
      end
  end
  local function bbRank(accumulate) 
    table.sort(remixBBScores, function(a,b) return (a.scoreBB or -1e18) > (b.scoreBB or -1e18) end)
    if accumulate ~= false then
      for i, rec in ipairs(remixBBScores) do
          rec.rank = (rec.rank or 0) + (N + 1 - i)  -- add rank points to all candidates (backbone)
      end
    end
  end
  local function draftRank(accumulate) 
    table.sort(remixBBScores, function(a,b) return (a.draft_score or -1e18) > (b.draft_score or -1e18) end)
    if accumulate ~= false then
      for i, rec in ipairs(remixBBScores) do
          rec.rank = (rec.rank or 0) + (N + 1 - i)  -- add rank points to all candidates (draft)
      end
    end
  end

  -- Standard ranking procedure (energy + BB + subscores tweaks), then sort by rec.rank desc
  local function standardRank()
      scoreRank(true) 
      bbRank(true)

      highestSolutionIDs = GetHighestSolutionIDs(solutionSubscoresArray)
      for scorePart, solutionIDs in pairs(highestSolutionIDs) do
          if reportLevel>4 then print(" Solution ID with highest",scorePart," subscore:", table.concat(solutionIDs, ", ")) end
      end

      -- sort by rank to inspect interim results
      table.sort(remixBBScores, function(a,b) return (a.rank or 0) > (b.rank or 0) end)
      for i, rec in ipairs(remixBBScores) do
          if (i<=N) then
              if reportLevel>2 then print("Backbone score", rec.scoreBB, "from slot", rec.id, "score: "..rec.score, "/"..rec.rank) end
          end
      end

      -- add 0.5 to every highest subscore solution (round first decimal "#remixBBScores / 12". 10 is used as the first decimal floor basis)
      otherSubscoresAddRank = math.floor(N / 12 * 10 + 0.5) / 10
      -- increase the rank for solutions found in highest subscore IDs
      for _, rec in ipairs(remixBBScores) do
          local solutionID = rec.id
          for _, solutionIDs in pairs(highestSolutionIDs) do
              for _, id in ipairs(solutionIDs) do
                  if id == solutionID then
                      rec.rank = rec.rank + otherSubscoresAddRank
                  end
              end
          end
      end
      table.sort(remixBBScores, function(a,b) return (a.rank or 0) > (b.rank or 0) end)
      -- Copying rank for statistics analyzis the efficacy of this rank
      for _, rec in ipairs(remixBBScores) do
          rec.rank_std = rec.rank
      end
  end

  ------------------------------ranking starts here----------------------------------
  -- Default scenario: Choosing method to rank the Rebuild solutions
  if not rankType then
        local evCur = (eventsProcessedCounter or 0) + 1
        if syn_ramp_events > 0 then
            wSyn = math.min(syn_alpha_max, syn_alpha_max * evCur / syn_ramp_events)
        else
            wSyn = syn_alpha_max
        end

        -- apply more draft weight to windows aligned with a hardness map (min-max scaled)
        local wDraftEff = draft_rank_weight
        draft_scale_source = "inefficiency"   -- "dispersion": Avg ScoreBB dispersion map; "inefficiency": Rank inefficiency map; "within_std": Per-seg BB std within window
            local map = nil
            if Stats then
                if draft_scale_source == "inefficiency" and Stats._segmentRankInefficiencyMap then
                    map = Stats._segmentRankInefficiencyMap()
                elseif draft_scale_source == "dispersion" and Stats._segmentDispersionAveragesLenNorm then
                    map = Stats._segmentDispersionAveragesLenNorm()
                elseif draft_scale_source == "within_std" and Stats._segmentBBStdWithinLcorrMap then
                    map = Stats._segmentBBStdWithinLcorrMap()
                end
            end
            if map then
                local sumSel, minAll, maxAll = 0, math.huge, -math.huge
                for i = 1, proteinLength do
                    local v = map[i] or 0
                    if i >= selectionStart and i <= selectionEnd then sumSel = sumSel + v end
                    if v > maxAll then maxAll = v end
                    if v < minAll then minAll = v end
                end
                if maxAll > minAll then
                    local avgSel = sumSel / math.max(1, (selectionEnd - selectionStart + 1))
                    local draftScale = math.max(0.2, (avgSel - minAll) / (maxAll - minAll))
                    wDraftEff = draft_rank_weight * draftScale
                end
            end

        local total = math.max(0, current_rank_weight) + math.max(0, wSyn) + math.max(0, wDraftEff)
        local r = (total > 0) and (math.random() * total) or 0

        if r < math.max(0, current_rank_weight) then
            rankType = 3
            rankScenario = "standard"
        elseif r < (math.max(0, current_rank_weight) + math.max(0, wSyn)) then
            rankType = 5
            rankScenario  = "adaptive" --syn sort
        else
            rankScenario = "draft"
            rankType = 4
        end

        if reportLevel > 2 and slotsToFuze > 1 then
            print(string.format("[Rank] scenario=%s (w: std=%.2f syn=%.2f draft=%.2f)", rankScenario, current_rank_weight, wSyn, wDraftEff))
        end
  end

  -- reset rank accumulator to avoid double-counting on repeated calls
  for _, rec in ipairs(remixBBScores) do rec.rank = 0 end
  -- Always compute 'standard' rank into rec.rank so Stats can use it regardless
  -- of the chosen scenario. This will temporarily sort by rank; scenario-specific
  -- sorts below will set the final order for the event.
  do
    standardRank()
  end

  -- Numeric rankType: 1=score, 2=BB, 3=standard rank, 4=draft_score, 5=syn
  if rankType == 1 then
      scoreRank(false) 
      return posMap()
  elseif rankType == 2 then
      bbRank(false) 
      return posMap()
  elseif rankType == 3 then
      -- already computed above
      return posMap()
  elseif rankType == 4 then
      draftRank(false) 
      return posMap()

  --Adaptive method calculations
  elseif rankType == 5 then
    local evCur = (eventsProcessedCounter or 0) + 1
    local usedSyn = false
    if Stats and Stats.Syn and Stats.Syn.order then
        if Stats.checkSubscoreVariability and solutionSubscoresArray then
            pcall(Stats.checkSubscoreVariability, evCur, solutionSubscoresArray)
        end
        local res = Stats.Syn.order(evCur, remixBBScores, solutionSubscoresArray)
        local order = res and res.order or nil
        if order and #order > 0 then
            local pos = {}; for i,slot in ipairs(order) do pos[slot] = i end
            local N = #remixBBScores
            table.sort(remixBBScores, function(a,b)
                local pa = pos[a.id] or (N + a.id)
                local pb = pos[b.id] or (N + b.id)
                if pa == pb then return a.id < b.id end
                return pa < pb
            end)
            usedSyn = true
            return posMap()
        end
    end
    if not usedSyn then
        standardRank()
        return posMap()
    end
  end

end

function RebuildToSlots()
	  j=0
	  rebuildIter=1
	  undo.SetUndo(false)
	  
	  while (j<maxRebuildCount) and (rebuildIter<7) do
		j=j+1
		
		local newBandCount = 0  -- Count of added bands
		
		--- make cuts
		local function CutAndBand(cutIdx, a, b)
		  structure.InsertCut(cutIdx)
		  if detachCuts and bandDetached > 0 then
			local id = band.AddBetweenSegments(a, b)
			if id and id > 0 then
			  band.SetStrength(id, bandDetached)
			  band.SetGoalLength(id, structure.GetDistance(a, b))
			  newBandCount = newBandCount + 1
			end
		  end
		end
		if rebuildWithCuts then 
		  if selectionStart > 1          then CutAndBand(selectionStart - 1, selectionStart - 1, selectionStart) end
		  if selectionEnd   < proteinLength - 1 then CutAndBand(selectionEnd,         selectionEnd,     selectionEnd + 1) end
		end
		---
	  
		if disableBandsOnRebuild then  disabledBands = DisableAllBands()	end
		if rebuildWithCuts and detachCuts then 
		  behavior.UseCutBands(false) --return cuts attachment before the fuze
		end
	  
		-------REBUILD------
        local t0 = os.clock()
		structure.RebuildSelected(rebuildIter)
        timer2 = os.clock() - t0 + timer2
	  
		if disableBandsOnRebuild then
		  EnableBands(disabledBands)
		end
	  
		if CheckRepeats() then 
			j=j-1
			rebuildIter = rebuildIter+1
		else -- okay, we have a new original solution we are going to save
			  if rebuildWithCuts then
					if bandDetached > 0 and detachCuts then -- delete temporary bands after rebuild
						  TinyFuze2()
						  totalBands = band.GetCount()
						  if newBandCount > 0 then
							for i = totalBands, totalBands - newBandCount + 1, -1 do
							  band.Delete(i)
							end
						  end
					end
					behavior.UseCutBands(true)
					
					Fuze2(fuzeConfig[4])
					
					  -- Delete cuts
					if selectionStart > 1 then structure.DeleteCut(selectionStart-1) end
					if selectionEnd < proteinLength-1 then structure.DeleteCut(selectionEnd) end
					
					-- brief wiggle after cuts delete
					recentbest.Save()
					behavior.SetClashImportance(1)
					structure.WiggleAll(15)
					recentbest.Restore()
			  end
		  
			  local temp = GetSolutionSubscores(j+1)
			  table.insert(solutionSubscoresArray, temp) -- subscores are used to rank best solutions to fuze
			  remixBBScores[solutionsFound-1] = {id = solutionsFound, scoreBB=ScoreBBReturn(), score=ScoreReturn(), rank=0, draft_score=nil, draft_bb=nil} 

			  save.LoadSecondaryStructure()
			  ReadNotes()
			  save.Quicksave(j+1)
			  rebuildIter=1
		 
		end
		save.Quickload(100)
	  
	  end
	  undo.SetUndo(true) 
	  return j
end
  
function remixBBscoreList()
	  for i=1, remixNum do
		save.Quickload(i+1)
		if shakeOnRank then  --makes a small shake before ranking energy score of rebuild (if checkbox was selected).
		  makeShake()
		end
		
		local temp = GetSolutionSubscores(i+1)
		table.insert(solutionSubscoresArray, temp)
		remixBBScores[solutionsFound-1] = {id = solutionsFound, scoreBB=ScoreBBReturn(), score=ScoreReturn(), rank=0, draft_score=nil, draft_bb=nil} 
		if reportLevel>2 then print ( "Slot", i+1, "score", ScoreReturn(), "BB", ScoreBBReturn()) end

		save.LoadSecondaryStructure()
		ReadNotes()
		save.Quicksave(i+1)

	  end
end
  
function RebuildRemixSelected()
	  if remixNotRebuild then
		remixNum = structure.RemixSelected(2, maxRebuildCount)
		if (remixNum>0) then remixBBscoreList() end
	  else
		remixNum = RebuildToSlots()
		--remixNum=#rebuildScores-1
	  end
end

function CheckRepeats()
  currentScore=ScoreReturn()
  isDuplicate=false
  remixNum= #rebuildScores
    
  for k=1, remixNum do
    if rebuildScores[k] == currentScore then isDuplicate=true end
  end
  if not isDuplicate then 
    solutionsFound = solutionsFound+1
    rebuildScores[solutionsFound] = currentScore
    save.Quicksave(solutionsFound)
    if shakeOnRank then makeShake() end --makes a small shake before ranking energy score of rebuild (if checkbox was selected).
    currentScore=ScoreReturn()
  remixBBScores[solutionsFound-1] = {
    id = solutionsFound,
    scoreBB = ScoreBBReturn(),
    score = currentScore,
    rank = 0,
    draft_score = nil,
    draft_bb = nil
  }
    
    if reportLevel>2 then print ( "Slot", solutionsFound, "backbone", ScoreBBReturn(), "score", currentScore) end
    --if reportLevel==2 then io.write(".") end
  else 
    if reportLevel>2 then print (currentScore, "is duplicated to already found.") end
  end

  return isDuplicate
end

function DisableAllBands()
  local bandCount = band.GetCount()
  local disabledBands = {}
  for i = 1, bandCount do
      if band.IsEnabled(i) then
          table.insert(disabledBands, i)
          band.Disable(i)
      end
  end
  return disabledBands
end

function EnableBands(bandsList)
  for _, bandId in ipairs(bandsList) do
      band.Enable(bandId)
  end
end


------------------------------------------
-- Function to get the list of SolutionIDs with the highest subscore for each score part
function GetHighestSolutionIDs(solutionSubscoresArray)
  local highestSolutionIDs = {}
  if not solutionSubscoresArray or #solutionSubscoresArray == 0 then
      return highestSolutionIDs
  end
  if reportLevel > 3 then print("Length of the solutionSubscoresArray:", #solutionSubscoresArray) end

  -- Iterate over each score part (skip the SolutionID field)
  for scorePart, _ in pairs(solutionSubscoresArray[1]) do
    if scorePart ~= "SolutionID" then
      local maxSubscore = -9999999
      local minSubscore =  9999999
      local maxSolutionIDs = {}
      -- Iterate over each solution subscores
      for _, subscores in ipairs(solutionSubscoresArray) do
          local subscore = subscores[scorePart]
          local solutionID = subscores["SolutionID"]
      -- find the max value between all the solutions for secific subscore
      if subscore > maxSubscore then
        maxSubscore = subscore
        maxSolutionIDs = {solutionID}
      elseif subscore == maxSubscore then
        table.insert(maxSolutionIDs, solutionID)
      end

      -- Track the minimum subscore to prevent including in highestSolutionIDs array subscores with the same values for all the solutions
      if subscore < minSubscore then
        minSubscore = subscore
      end
    end

    if maxSubscore ~= minSubscore then
        highestSolutionIDs[scorePart] = maxSolutionIDs
    end
  end
end

-- Return the list of SolutionIDs with the highest subscore for each score part
return highestSolutionIDs
end



-------------------------------------------------------------Dialog-------------------------------------------------------------
--Switch between Rebuild with Cuts and No Cuts mode

local DIALOG_MODE = { NO_CUTS = "no_cuts", WITH_CUTS = "with_cuts" }
local currentDialogMode = DIALOG_MODE.NO_CUTS

local function applyDialogDefaults(mode)
    if mode == DIALOG_MODE.WITH_CUTS then
        StartRebuild = START_REBUILD_WITHCUTS
        slotsToFuze = 1
        EndRebuild = END_REBUILD_WITHCUTS
        fuzeAfternoGain = math.floor(FUZE_BASE_100AA_WITHCUTS * 100 / proteinLength + 0.5)
        if fuzeAfternoGain < 1 then fuzeAfternoGain = 1 end
        shiftNoGain = math.floor(fuzeAfternoGain / SHIFT_PER_FUZE_WITHCUTS + 0.5)
        if shiftNoGain < 1 then shiftNoGain = 1 end
        rebuildWithCuts = true
        dialogSolutionsNum = DIALOG_SOLUTIONS_WITHCUTS
    else
        StartRebuild = START_REBUILD_NOCUTS
        EndRebuild = END_REBUILD_NOCUTS
        slotsToFuze = 3
        -- Scale thresholds with protein length using intuitive 100aa baseline
        fuzeAfternoGain = math.floor(FUZE_BASE_100AA_NOCUTS * 100 / proteinLength + 0.5)
        if fuzeAfternoGain < 1 then fuzeAfternoGain = 1 end
        shiftNoGain = math.floor(fuzeAfternoGain / SHIFT_PER_FUZE_NOCUTS + 0.5)
        if shiftNoGain < 1 then shiftNoGain = 1 end
        rebuildWithCuts = false
        dialogSolutionsNum = DIALOG_SOLUTIONS_NOCUTS
    end
    detachCuts = false
    bandDetached = 1.0
    selectionLength = StartRebuild
end

applyDialogDefaults(currentDialogMode)

function RequestOptions()
    ask=dialog.CreateDialog(script_name..version)

    ask.maxRebuildCount = dialog.AddSlider("Solutions Num",dialogSolutionsNum,1,maxRebuildCount,0) 
    ask.slotsToFuze = dialog.AddSlider("Slots to fuze",slotsToFuze,1,36,0) 
    -- slots to fuze: math.ceil(x^(5/14))) --3) = 2  --3=2 4=2 5=2 7=3 8=3  10=3 11=4 14=4  15=5 16=5 20=5  21=6  22=6 25=6  26=7 30=7

    ask.remixNotRebuild=dialog.AddCheckbox("Remix instead of Rebuild", remixNotRebuild)
    --ask.remixNotRebuild.value=false

    --selections
    --ask.s1 = dialog.AddLabel("Selections")
    ask.StartRebuild = dialog.AddSlider("Start Length",StartRebuild,2,proteinLength,0)
    ask.EndRebuild = dialog.AddSlider("End Length",EndRebuild,2,proteinLength,0)
    ask.selectionStrategyDynamic = dialog.AddCheckbox("Dynamic selections", selectionStrategy == SELECTION_STRATEGY.DYNAMIC)
    --ask.selectionStart1 = dialog.AddSlider("Overlap",selectionStartArr[1],0,proteinLength,0)
    ask.disableBandsOnRebuild=dialog.AddCheckbox("Disable bands on rebuild", disableBandsOnRebuild)
    
    --fuze options
    local showCutOptions = currentDialogMode == DIALOG_MODE.WITH_CUTS
    if showCutOptions then
        ask.l1 = dialog.AddLabel("With Cuts:")
        ask.rebuildWithCuts=dialog.AddCheckbox("Rebuild with cuts", rebuildWithCuts)
        ask.detachCuts=dialog.AddCheckbox("Detach cuts on rebuild (Disable Cut Bands)", detachCuts)
        ask.bandDetached=dialog.AddSlider("Band Detached strength", bandDetached, 0, 3, 2)
    end

    ask.l2 = dialog.AddLabel("Other:")
    ask.convertHelixToLoop = dialog.AddCheckbox("Convert helix to loop", convertHelixToLoop)
    ask.convertSheetsToLoop = dialog.AddCheckbox("Convert sheets to loop", convertSheetsToLoop)
    ask.shakeOnRank=dialog.AddCheckbox("Shake solution on Rank stage", shakeOnRank)

    ask.l3 = dialog.AddLabel("Do after X rebuilds with NoGain:")
    ask.consecutiveRounds=dialog.AddCheckbox("Consecutive Events", consecutiveRounds)
    local fuzeMaxCap = math.min(SLIDER_CAP_ABSOLUTE, math.max(1, math.floor((fuzeAfternoGain > 0 and fuzeAfternoGain or 1) * FUZE_SLIDER_MAX_MULT + 0.5)))
    local shiftMaxCap = math.min(SLIDER_CAP_ABSOLUTE, math.max(1, math.floor((shiftNoGain > 0 and shiftNoGain or 1) * SHIFT_SLIDER_MAX_MULT + 0.5)))
    ask.fuzeAfternoGain = dialog.AddSlider("Fuze events NoGain",fuzeAfternoGain,-1,fuzeMaxCap,0)  -- -1: accept fuzed solution on highscore; 0: switch every event; >0: after N no-gain events
    ask.shiftNoGain = dialog.AddSlider("Shift events NoGain",shiftNoGain,-1,shiftMaxCap,0)
    ask.stopAfter = dialog.AddSlider("Stop After (rebuilds)",0,0,1000,0)

    ask.l4 = dialog.AddLabel("Service:")
    ask.ignoredSel = dialog.AddSlider("SkipFirst X", 0,0, math.floor(proteinLength/2), 0)
    ask.reportLevel = dialog.AddSlider("Report detalization", reportLevel,1,4,0)
    ask.useSlot98=dialog.AddCheckbox("Unfuzed version", false)

    ask.Cancel = dialog.AddButton("Cancel",0)
    local toggleLabel = showCutOptions and "No Cuts" or "With Cuts"
    ask.toggleCuts = dialog.AddButton(toggleLabel,3)
    ask.OK = dialog.AddButton("OK",1)
    --ask.addSelections = dialog.AddButton("AddSelection",2)

    returnVal=dialog.Show(ask)
    if returnVal == 3 then
        if showCutOptions then
            currentDialogMode = DIALOG_MODE.NO_CUTS
        else
            currentDialogMode = DIALOG_MODE.WITH_CUTS
        end
        applyDialogDefaults(currentDialogMode)
        return RequestOptions()
    end

    if returnVal > 0 then

        if returnVal==1 then
            maxRebuildCount=ask.maxRebuildCount.value
            dialogSolutionsNum = maxRebuildCount
        end

    	remixNotRebuild=ask.remixNotRebuild.value
    	shakeOnRank=ask.shakeOnRank.value
    	reportLevel=ask.reportLevel.value
    	convertHelixToLoop = ask.convertHelixToLoop.value
    	convertSheetsToLoop = ask.convertSheetsToLoop.value
    	convertLoop = convertHelixToLoop or convertSheetsToLoop
    	slotsToFuze=ask.slotsToFuze.value
    	stopAfter=ask.stopAfter.value
    	startCI=1 --ask.startCI.value
    	useSlot98 =ask.useSlot98.value
    	consecutiveRounds =ask.consecutiveRounds.value
    	--shiftFuze=ask.shiftFuze.value

    	fuzeAfternoGain=ask.fuzeAfternoGain.value
    	shiftNoGain=ask.shiftNoGain.value
    	ignoredSel=ask.ignoredSel.value

    	StartRebuild=ask.StartRebuild.value
    	EndRebuild=ask.EndRebuild.value
        if ask.selectionStrategyDynamic.value then selectionStrategy = SELECTION_STRATEGY.DYNAMIC else selectionStrategy = SELECTION_STRATEGY.STATIC end

        if showCutOptions then
    	    rebuildWithCuts = ask.rebuildWithCuts.value
        end
    	disableBandsOnRebuild = ask.disableBandsOnRebuild.value
    	if ask.detachCuts then
    		detachCuts = ask.detachCuts.value
    	end
    	if ask.bandDetached then
    		bandDetached = ask.bandDetached.value
    	end

    	----fix some vars if needed
    	if remixNotRebuild then
    		action="Remix"
    		if StartRebuild > 9  then
    			StartRebuild = 9
    			print ("StartRebuild more than 9 not available for Remix. Setting at 9")
    		end
    		if EndRebuild > 9  then
    			EndRebuild = 9
    			print ("EndRebuild more than 9 not available for Remix. Setting at 9")
    		end
    	end

    	if StartRebuild < EndRebuild then
    		temp = StartRebuild
    		StartRebuild = EndRebuild
    		EndRebuild = temp
    	end
    	selectionLength=StartRebuild

    	if OverlapSettings then overlap=SetOverlap(selectionLength) end

    	if slotsToFuze > maxRebuildCount then slotsToFuze = maxRebuildCount end
    	--if slotsToFuze==1 then shakeOnRank=false end

    	SplitProteinBySelections() --create the selections



    else
    	print ("Canceled")
    end

    return returnVal
end



--------------------------------------------------------------------------------- Rules ---------------------------------------------------------------------------------
-- On-demand dynamic rule scoring (replicates the scoring used by NextSelectionDynamic)
function ComputeDynamicRuleScores()
    local r0Raw, r1Raw, r2Raw, r3Raw, r4Raw, r5Raw = {}, {}, {}, {}, {}, {}
    local r0min, r0max = math.huge, -math.huge
    local r1min, r1max = math.huge, -math.huge
    local r2min, r2max = math.huge, -math.huge
    local r3min, r3max = math.huge, -math.huge
    local sMin, sMax = math.huge, -math.huge
    local bbMin, bbMax = math.huge, -math.huge

    -- Aggregated rules R1/R3 use EMA memories; no additional per-event decay/amplification needed here.

    for i = 1, proteinLength do
        local segScore = current.GetSegmentEnergyScore(i)
        local segBB    = GetSegmentBBScore(i)
        sMin = math.min(sMin, segScore); sMax = math.max(sMax, segScore)
        bbMin = math.min(bbMin, segBB);  bbMax = math.max(bbMax, segBB)

        -- Rule 0 raw: success ratio per segment (successes / attempts), from Stats
        local at = (Stats and Stats.segmentAttemptCount and Stats.segmentAttemptCount[i]) or 0
        local sc = (Stats and Stats.segmentSuccessCount and Stats.segmentSuccessCount[i]) or 0
        local r0 = (at > 0) and (sc / at) or 0
        r0Raw[i] = r0; r0min = math.min(r0min, r0); r0max = math.max(r0max, r0)

        local d1 = (segImpactSuccAgg[i] or 0)
        r1Raw[i] = d1; r1min = math.min(r1min, d1); r1max = math.max(r1max, d1)

        local age = math.max(0, (eventsProcessedCounter or 0) - (segLastRebuildEventIx[i] or 0))
        r2Raw[i] = age; r2min = math.min(r2min, age); r2max = math.max(r2max, age)

        local d3 = (segImpactFailAgg[i] or 0)
        r3Raw[i] = d3; r3min = math.min(r3min, d3); r3max = math.max(r3max, d3)

        r4Raw[i] = segScore
        r5Raw[i] = segBB
    end

    -- Remix edge age fix (same as in NextSelectionDynamic): ends never rebuild,
    -- which overinflates Rule 2 near edges. Mirror neighbors' age to edges.
    if remixNotRebuild and proteinLength >= 2 then
        r2Raw[1] = r2Raw[2]
        r2Raw[proteinLength] = r2Raw[proteinLength-1]
        r2min, r2max = math.huge, -math.huge
        for i = 1, proteinLength do
            local v = r2Raw[i]
            if v < r2min then r2min = v end
            if v > r2max then r2max = v end
        end
    end

    local function norm(val, vmin, vmax)
        if val ~= val then return 0 end -- NaN guard
        if vmax <= vmin then return 0 end
        return (val - vmin) / (vmax - vmin)
    end

    local cont0, cont1, cont2, cont3, cont4, cont5, cont6, points = {}, {}, {}, {}, {}, {}, {}, {}
    for i = 1, proteinLength do
        local r0 = dyn_rule0_weight * norm(r0Raw[i], r0min, r0max)
        local r1 = dyn_rule1_weight * norm(r1Raw[i], r1min, r1max)
        local r2 = dyn_rule2_weight * norm(r2Raw[i], r2min, r2max)
        local r3 = dyn_rule3_weight * norm(r3Raw[i], r3min, r3max)
        -- For r4/r5 lower values should get higher points → invert
        local r4 = 0
        if sMax > sMin then r4 = dyn_rule4_weight * ((sMax - r4Raw[i]) / (sMax - sMin)) end
        local r5 = 0
        if bbMax > bbMin then r5 = dyn_rule5_weight * ((bbMax - r5Raw[i]) / (bbMax - bbMin)) end

        -- Rule 6: user map (normalized [0..1]) scaled by dyn_rule6_weight
        local r6 = 0
        if rule6_mapNorm then r6 = (rule6_mapNorm[i] or 0) * (dyn_rule6_weight or 0) end

        cont0[i], cont1[i], cont2[i], cont3[i], cont4[i], cont5[i], cont6[i] = r0, r1, r2, r3, r4, r5, r6
        points[i] = (r0 + r1 + r2 + r3 + r4 + r5 + r6)
    end

    return cont1, cont2, cont3, cont4, cont5, cont6, cont0, points
end

-- Print the dynamic rule bars R1..R5 (+R6 if present), computed on-demand
function PrintRuleBarsFrom(cont1, cont2, cont3, cont4, cont5, cont6, cont0)
    local pal = getBarPalette(BAR_STYLE.BASE10)
    if cont0 then print("R0 "..encodeScalarArrayToBar(cont0, pal)) end
    print("R1 "..encodeScalarArrayToBar(cont1, pal))
    print("R2 "..encodeScalarArrayToBar(cont2, pal))
    print("R3 "..encodeScalarArrayToBar(cont3, pal))
    print("R4 "..encodeScalarArrayToBar(cont4, pal))
    print("R5 "..encodeScalarArrayToBar(cont5, pal))
    if cont6 then print("R6 "..encodeScalarArrayToBar(cont6, pal)) end
end

function PrintRuleBars()
    local cont1, cont2, cont3, cont4, cont5, cont6, cont0 = ComputeDynamicRuleScores()
    PrintRuleBarsFrom(cont1, cont2, cont3, cont4, cont5, cont6, cont0)
end

-- Update per-segment impact arrays used by dynamic selection rules
-- Success: updates segImpactLastSuccess (Rule 1 baseline), zeroing inside [selStart..selEnd]
function UpdateImpactSuccess(segScoreBeforeEvent, selStart, selEnd)
    for i = 1, proteinLength do
        local after = current.GetSegmentEnergyScore(i)
        local before = segScoreBeforeEvent[i] or after
        local delta = math.abs(after - before)
        local inside = (i >= (selStart or 1)) and (i <= (selEnd or 0))
        -- Legacy "last" snapshot for R1
        if inside then segImpactLastSuccess[i] = 0 else segImpactLastSuccess[i] = delta end

        -- Aggregated R1: decay each event, then add new impulse outside current window
        segImpactSuccAgg[i] = (segImpactSuccAgg[i] or 0) * (dyn_rule1_agg_decay or 0)
        if not inside then
            segImpactSuccAgg[i] = (segImpactSuccAgg[i] or 0) + delta
        end

        -- On success optionally reset/decay R3 memory additionally
        local f = (dyn_rule3_agg_decay or 0) * ((R3_SUCCESS_RESET_ENABLED and (R3_SUCCESS_RESET_FACTOR or 1)) or 1)
        segImpactFailAgg[i] = (segImpactFailAgg[i] or 0) * f
    end
end

-- No-gain: updates segImpactLastNoGain (Rule 3 baseline), zeroing inside [selStart..selEnd]
function UpdateImpactNoGain(segScoreBeforeEvent, selStart, selEnd)
    for i = 1, proteinLength do
        local after = current.GetSegmentEnergyScore(i)
        local before = segScoreBeforeEvent[i] or after
        local delta = math.abs(after - before)
        local inside = (i >= (selStart or 1)) and (i <= (selEnd or 0))

        -- Legacy "last" snapshot for R3
        if inside then segImpactLastNoGain[i] = 0 else segImpactLastNoGain[i] = delta end

        -- Decay both aggregators every event; add new impulse for R3 outside current window
        segImpactSuccAgg[i] = (segImpactSuccAgg[i] or 0) * (dyn_rule1_agg_decay or 0)
        segImpactFailAgg[i] = (segImpactFailAgg[i] or 0) * (dyn_rule3_agg_decay or 0)
        if not inside then
            segImpactFailAgg[i] = (segImpactFailAgg[i] or 0) + delta
        end
    end
end

-- Print the same normalized rebuild-events map that we show at the end
function PrintRebuildEventsPerSegment()
    local pal = getBarPalette(BAR_STYLE.BASE10)
    local bar = encodeScalarArrayToBar(segRebuildCount, pal)
    print("Rebuild events per segment (normalized):")
    print(bar)
end

-- Base62 helpers for Rule 6 (map from Notes)
local function base62Index(ch)
    local byte = string.byte(ch)
    if not byte then return nil end
    -- '0'..'9' → 0..9
    if byte >= 48 and byte <= 57 then return byte - 48 end
    -- 'a'..'z' → 10..35
    if byte >= 97 and byte <= 122 then return 10 + (byte - 97) end
    -- 'A'..'Z' → 36..61
    if byte >= 65 and byte <= 90 then return 36 + (byte - 65) end
    return nil
end

local function parseBase62StringToArray(s)
    local arr = {}
    if not s or s == "" then return arr end
    for i = 1, #s do
        local c = string.sub(s, i, i)
        local v = base62Index(c)
        if v then arr[#arr+1] = v end
    end
    return arr
end

local function resampleLinear(values, targetLen)
    local n = #values
    local out = {}
    if targetLen <= 0 then return out end
    if n == 0 then
        for i = 1, targetLen do out[i] = 0 end
        return out
    end
    if n == 1 then
        local v = values[1]
        for i = 1, targetLen do out[i] = v end
        return out
    end
    for t = 0, targetLen - 1 do
        -- Nearest-neighbor by proportional position
        local pos = (t) * (n - 1) / (targetLen - 1)
        local idx = math.floor(pos + 0.5) + 1
        if idx < 1 then idx = 1 end
        if idx > n then idx = n end
        out[t + 1] = values[idx]
    end
    return out
end

local function UpdateRule6MapFromString(rawStr)
    rule6_lastString = rawStr
    local arr = parseBase62StringToArray(rawStr)
    local res = resampleLinear(arr, proteinLength)
    -- Normalize to [0..1] by the present range of values.
    -- If all values are equal and >0, map becomes all 1s; if all zeros, remains zeros.
    local norm = {}
    local rmin, rmax = math.huge, -math.huge
    for i = 1, proteinLength do
        local v = res[i] or 0
        if v < rmin then rmin = v end
        if v > rmax then rmax = v end
    end
    if rmax > rmin then
        local span = rmax - rmin
        for i = 1, proteinLength do
            norm[i] = ((res[i] or 0) - rmin) / span
        end
    else
        local denom = (rmax > 0) and rmax or 1
        for i = 1, proteinLength do
            norm[i] = (res[i] or 0) / denom
        end
    end
    rule6_mapNorm = norm
end

local function PrintRule6Bar()
    local pal = getBarPalette(BAR_STYLE.BASE10)
    local cont6 = {}
    for i = 1, proteinLength do
        cont6[i] = (rule6_mapNorm and rule6_mapNorm[i] or 0) * (dyn_rule6_weight or 0)
    end
    print("R6 "..encodeScalarArrayToBar(cont6, pal))
end

---------------------
-- Read a Note text to control script execution
function ReadNotes()
    did=nil
    res = structure.GetNote(1)
    if res and res~= "" then
        did = ProcessNoteCommands(res)
    end
    if did then structure.SetNote(1,"") end
    return res
end

-- Parse ad-hoc commands from a note and run them. Returns true if any command recognized.
function ProcessNoteCommands(noteText)
    local text = tostring(noteText or "")
    local lower = string.lower(text)
    local did = false

    local function has(tok)
        return string.find(lower, tok, 1, true) ~= nil
    end

    -- Deferred quick actions
    if has("unfreeze") or has("unfr") then
        Deferred.unfreeze = true
        print("[note] Unfreeze at round end")
        did = true
    end
    if has("bands") or has("band") then
        Deferred.unband = true
        print("[note] Disable bands at round end")
        did = true
    end

    -- Rules bar
    if has("rules") then
        if PrintRuleBars then PrintRuleBars() end
        did = true
    end

    -- Simple stats shortcuts
    if has("maps") and Stats and Stats.printAllMaps then
        Stats.printAllMaps()
        did = true
    end
    if has("candidates") and Stats and Stats.printData then
        Stats.printData("candidates")
        did = true
    end

    -- Stats on/off
    if has("disable") and Stats and Stats.setEnabled then
        Stats.setEnabled(true)
        did = true
    end
    if has("enable") and Stats and Stats.setEnabled then
        Stats.setEnabled(false)
        did = true
    end

    -- 'stat' == full analysis (equivalent to former 'stats all')
    -- avoid triggering on 'stats on/off'
    if has("stat") and Stats then
        if Stats.printSummary then Stats.printSummary() end
        if Stats.printAllCorrelations then Stats.printAllCorrelations() end
        if Stats.printAllMaps then Stats.printAllMaps() end
        did = true
    end

    -- Maps (Rule 6): clear and set string
    if has("map clear") then
        rule6_lastString = nil
        rule6_mapNorm = {}
        for i = 1, proteinLength do rule6_mapNorm[i] = 0 end
        if PrintRule6Bar then PrintRule6Bar() end
        did = true
    end
    do
        -- find "map " position case-insensitively via 'lower', but capture from original 'text'
        local sidx, eidx = lower:find("map%s+")
        if sidx then
            local rest = text:sub(eidx + 1)
            local mapStr = rest:match("([0-9A-Za-z]+)")
            if mapStr and #mapStr > 0 then
                if UpdateRule6MapFromString then UpdateRule6MapFromString(mapStr) end
                if PrintRule6Bar then PrintRule6Bar() end
                did = true
            end
        end
    end
    if has("mapw") then
        local wnum = tonumber(lower:match("mapw%s*=?%s*([%+%-%d%.]+)") or "")
        if wnum then
            dyn_rule6_weight = wnum
            if PrintRule6Bar then PrintRule6Bar() end
            did = true
        end
    end

    -- Rule weights r1w..r6w
    do
        for i = 1, 6 do
            if has("r"..tostring(i).."w") then
                local valstr = lower:match("r"..tostring(i).."w%s*=?%s*([%+%-%d%.]+)")
                local v = tonumber(valstr or "")
                if v then
                    if i == 1 then dyn_rule1_weight = v
                    elseif i == 2 then dyn_rule2_weight = v
                    elseif i == 3 then dyn_rule3_weight = v
                    elseif i == 4 then dyn_rule4_weight = v
                    elseif i == 5 then dyn_rule5_weight = v
                    else dyn_rule6_weight = v end
                    print(string.format("Rule R%d weight set to %s", i, tostring(v)))
                    did = true
                end
            end
        end
    end

    -- Start/End rebuild
    local changedSE = false
    if has("startrebuild") then
        local s = lower:match("startrebuild%s*=?%s*(%d+)")
        local newStart = tonumber(s or "")
        if newStart then
            if remixNotRebuild then
                local cap = math.min(9, math.max(3, math.floor(newStart)))
                if cap > proteinLength - 1 then cap = math.max(3, proteinLength - 1) end
                StartRebuild = cap
            else
                local cap = math.min(proteinLength, math.max(2, math.floor(newStart)))
                StartRebuild = cap
            end
            changedSE = true
            did = true
        end
    end
    if has("endrebuild") then
        local s = lower:match("endrebuild%s*=?%s*(%d+)")
        local newEnd = tonumber(s or "")
        if newEnd then
            if remixNotRebuild then
                local cap = math.min(9, math.max(3, math.floor(newEnd)))
                if cap > proteinLength - 1 then cap = math.max(3, proteinLength - 1) end
                EndRebuild = cap
            else
                local cap = math.min(proteinLength, math.max(2, math.floor(newEnd)))
                EndRebuild = cap
            end
            changedSE = true
            did = true
        end
    end
    if changedSE then
        if StartRebuild < EndRebuild then StartRebuild, EndRebuild = EndRebuild, StartRebuild end
        if selectionLength < EndRebuild then selectionLength = EndRebuild end
        if selectionLength > StartRebuild then selectionLength = StartRebuild end
        if selectionStrategy == SELECTION_STRATEGY.STATIC then selNum = 0 end
    end

    -- fuze*/shift* thresholds
    if has("fuze") then
        -- accepts 'fuze', 'fuzenogain', 'fuze nogain', with optional '='
        local n = tonumber(lower:match("fuze%w*%s*=?%s*([+-]?%d+)") or "")
        if n ~= nil then
            fuzeAfternoGain = n
            did = true
        end
    end
    if has("shift") then
        -- accepts 'shift', 'shiftnogain', 'shift nogain', with optional '='
        local n = tonumber(lower:match("shift%w*%s*=?%s*([+-]?%d+)") or "")
        if n ~= nil then
            shiftNoGain = n
            did = true
        end
    end

    -- Timers summary
    if has("time") then
        print("--------------Timers--------------")
        print ("Sorting "..roundX(timer1), "Subscoring "..roundX(timer5), "Rebuild "..roundX(timer2), "Fuze "..roundX(timer3), "Logging "..roundX(timer4))
        did = true
    end

    return did
end

-------- Deferred actions requested via Notes (applied at end of event on slots 98/100)
Deferred = Deferred or { unfreeze = false, unband = false }

-- Apply deferred operations to storage slots 98 (fuzed best) and 100 (unfuzed best).
-- Returns true if anything was applied.
function ApplyDeferredToSlots()
    if not _anyDeferred() then return false end
    local function applyTo(slot)
      save.Quickload(slot)
      structure.SetNote(1,"")
      _applyDeferredOnCurrent()
      save.Quicksave(slot)
    end
    applyTo(98)
    applyTo(100)
    _clearDeferred()
    return true
  end

function _anyDeferred()
  return (Deferred and (Deferred.unfreeze or Deferred.unband)) or false
end
function _clearDeferred()
  if Deferred then Deferred.unfreeze = false; Deferred.unband = false end
end
function _applyDeferredOnCurrent()
  -- Apply requested operations to the currently loaded solution
  if not Deferred then return end
  if Deferred.unfreeze then freeze.UnfreezeAll()
    if reportLevel > 1 then print("Unfreeze is done") end
  end
  if Deferred.unband then band.DisableAll() 
    if reportLevel > 1 then print("Bands disabled") end
  end
end


--------------------------------------------------Set of service functions to monitor what parts of the protein in the accepted solution where actually rebuilt
--Using 2d array. Number of rows = number of occupied slots
--Number of columns = number of the residues. Each row contain zero value for the residues that werent changed and 1 if they were rebuild in this solution

-- Function to add a new row with 1 between startIndex and endIndex and 0 elsewhere
function addRow(startIndex, endIndex)
    local newRow = {}
    for j = 1, rebuiltResidues.numColumns do
        if j >= startIndex and j <= endIndex then
            newRow[j] = 1
        else
            newRow[j] = 0
        end
    end
    table.insert(rebuiltResidues, newRow)
end

-- Function to modify the row and increase values between selectionStart and selectionEnd by 1
-- If 9 is reached, continue with 'a', 'b', ..., 'z', then 'A', 'B', ..., 'Z'
function changeRowValues(row, selectionStart, selectionEnd)
    for j = selectionStart, selectionEnd do
        if j >= 1 and j <= #row then
            if row[j] == 9 then
                row[j] = 'a'
            elseif type(row[j]) == 'string' then
                if row[j] >= 'a' and row[j] < 'z' then
                    row[j] = string.char(string.byte(row[j]) + 1)
                elseif row[j] == 'z' then
                    row[j] = 'A'
                elseif row[j] >= 'A' and row[j] < 'Z' then
                    row[j] = string.char(string.byte(row[j]) + 1)
                elseif row[j] == 'Z' then
                    row[j] = 'Z'
                end
            elseif type(row[j]) == 'number' and row[j] >= 0 and row[j] < 9 then
                row[j] = row[j] + 1
            end
        end
    end
    return row
end
function getRow(rowNumber)
    if rebuiltResidues[rowNumber] then
        return rebuiltResidues[rowNumber]
    end
end
function setRow(sourceRow, destRowNumber)
    if rebuiltResidues[destRowNumber] then
        for j = 1, #sourceRow do
            rebuiltResidues[destRowNumber][j] = sourceRow[j]
        end
    end
end
-- Function to print the values of the specified row compactly
function printRow(rowNumber)
    if rebuiltResidues[rowNumber] then
        print(table.concat(rebuiltResidues[rowNumber], ""))
    end
end

-- Wrapper to show rebuild frequency map; currently uses legacy printRow.
-- To switch to normalized visualization, replace implementation here.
function ShowRebuildFrequency()
    printRow(1)
end

function resetRebuiltResidues(rowNumber)
	if rowNumber~=nil and rowNumber~=0 then
		currentrow = getRow(rowNumber)	--save the row before reseting the table
	end
	rebuiltResidues = {} 
	rebuiltResidues.numColumns = proteinLength
	addRow(0, 0) --add and empty row for 'slot1'

	if rowNumber~=nil  and rowNumber~=0 then
		setRow(currentrow, 1)
		print (table.concat(rebuiltResidues[1], ""))
	end
end

-------------------------------------------------------------------------Selection functions--------------------------------------------------------------------


-- Selects the next selection  based on per-segment scores and recent rebuild history.
--[[
How the next selection window is chosen:

1) Score a per-segment priority map ("points")
   - We build five simple Rules per segment and then combine them with weights:
     R1: How much that segment moved on the last successful rebuild (impact),
         faded with time since the last success (exponential decay).
     R2: How long it’s been since we last rebuilt that segment (age in events).
     R3: How much that segment moved on the last unsuccessful rebuild (impact),
         amplified by the number of consecutive no‑gain events.
     R4: Lower per‑segment energy Score gets more points (we invert min‑max).
     R5: Lower per‑segment backbone Score (BB) gets more points (we invert min‑max).
   - Each Rk is min‑max normalized to [0..1] and multiplied by its weight.
   - points[i] = w1*R1 + w2*R2 + w3*R3 + w4*R4 + w5*R5.
   - For visibility: if reportLevel >= 3 we print bars for R1..R5, and if >= 2 we print a bar for PTS (= points sum) using 0–9a–zA–Z.

2) Anchor on strict length L
   - Find the best window of exactly L by average points per segment (sum/len), honoring engine constraints.
   - If no strict‑L window exists, fall back to a global valid search (any allowed length) and pick the best by average points.

3) Edge‑aware stochastic adjustment (per side)
   - For each side independently sample one of [expand 1, shrink 1, keep] with base weights 1:1:1.
   - Bias toward shrinking at the ends, primarily from the side that is not at the boundary.
   - Apply only if local condition passes: expand if neighbor > protein average; shrink if boundary segment < protein average.

4) Return the final [start, end] window; if a modification yields an invalid window, rollback to the anchor. If no anchor existed, run the global valid search to ensure a valid window is returned.

Notes about the signals used:
   • R1 uses per‑segment impact captured right after a successful rebuild (absolute delta from the pre‑event snapshot), then decayed by time since that success.
   • R3 uses per‑segment impact captured right after an unsuccessful rebuild, amplified by the current streak of no‑gain events.
   • R2 is simply the number of events since we last touched that segment.
   • All three (R1,R2,R3) help escape stagnation while R4/R5 gently pull us toward weak areas.
]]

-- Validate selection window against engine constraints (mode-aware)
function IsSelectionValid(ss, ee)
  if not ss or not ee then return false end
  if ss ~= ss or ee ~= ee then return false end -- NaN guard
  if ss > ee then return false end
  if ss < 1 or ee > proteinLength then return false end
  local wlen = ee - ss + 1
  if remixNotRebuild then
      -- Remix constraints: length 3..9 and cannot include first/last segment
      if wlen < 3 or wlen > 9 then return false end
      if ss <= 1 or ee >= proteinLength then return false end
  else
      -- Rebuild constraints: minimal length 2
      if wlen < 2 then return false end
  end
  return true
end

-- Modify selection length around L using a single variability parameter.
-- Behavior:
--  - Choose action with equal probability: expand, shrink, or keep.
--  - If expand/shrink chosen: perform at least one step if valid, then
--    continue with a decaying probability controlled by `var95` (95% range ≈ ±var95).
--  - Probabilities are modulated by per-segment points so that low-point edges
--    shrink more readily and high-point neighbors expand more readily, but a
--    small floor probability always remains.
--  - At protein ends, prefer shrinking from the opposite (non-edge) side.
function ModifySelectionLength(s, e, L, points, avgPts, var95)
  local minStartAllowed = remixNotRebuild and 2 or 1
  local maxEndAllowed   = remixNotRebuild and (proteinLength - 1) or proteinLength
  local minLen          = remixNotRebuild and 3 or 2

  local function canShrinkLeft(ss, ee)  return IsSelectionValid(ss + 1, ee) end
  local function canShrinkRight(ss, ee) return IsSelectionValid(ss, ee - 1) end
  local function canExpandLeft(ss, ee)  return IsSelectionValid(ss - 1, ee) end
  local function canExpandRight(ss, ee) return IsSelectionValid(ss, ee + 1) end

  local function pickShrinkSide(ss, ee)
      local leftEdge  = (ss <= minStartAllowed)
      local rightEdge = (ee >= maxEndAllowed)
      local leftOK  = canShrinkLeft(ss, ee)  and (not leftEdge)
      local rightOK = canShrinkRight(ss, ee) and (not rightEdge)
      if leftOK and not rightOK then return 'left' end
      if rightOK and not leftOK then return 'right' end
      if not leftOK and not rightOK then return nil end
      -- Prefer shrinking from the non-edge side
      if leftEdge then return 'right' end
      if rightEdge then return 'left' end
      local pl = points[ss] or avgPts
      local pr = points[ee] or avgPts
      if pl < pr then return 'left' end
      if pr < pl then return 'right' end
      return (math.random() < 0.5) and 'left' or 'right'
  end

  local function pickExpandSide(ss, ee)
      local leftEdge  = (ss <= minStartAllowed)
      local rightEdge = (ee >= maxEndAllowed)
      local leftOK  = canExpandLeft(ss, ee)  and (not leftEdge)
      local rightOK = canExpandRight(ss, ee) and (not rightEdge)
      if leftOK and not rightOK then return 'left' end
      if rightOK and not leftOK then return 'right' end
      if not leftOK and not rightOK then return nil end
      -- Prefer side with stronger neighbor points
      local nl = ((ss - 1) >= 1) and points[ss - 1] or -math.huge
      local nr = ((ee + 1) <= proteinLength) and points[ee + 1] or -math.huge
      if nl > nr then return 'left' end
      if nr > nl then return 'right' end
      return (math.random() < 0.5) and 'left' or 'right'
  end

  local function contProb(baseQ, qualityBias)
      local floorMin = 0.05
      local q = baseQ * (1 + 0.5 * qualityBias) -- gamma=0.5 tilt by quality
      if q < floorMin then q = floorMin end
      if q > 0.95 then q = 0.95 end
      return q
  end

  local function baseQFromVar(v)
      v = v or 0
      if v <= 0 then return 0 end
      -- Ensure about 95% of lengths stay within ±v around L (approximately)
      -- P(|Δ|<=v) ≈ 1 - (2/3)*q^v  →  q ≈ (0.075)^(1/v)
      return math.pow(0.075, 1 / math.max(1, v))
  end

  local baseQ = baseQFromVar(var95)

  local r = math.random()
  local action = (r < (1/3)) and 'expand' or ((r < (2/3)) and 'shrink' or 'keep')

  if action == 'keep' then return s, e end

  if action == 'shrink' then
      -- First mandatory step (if possible)
      local side = pickShrinkSide(s, e)
      if not side then return s, e end
      if side == 'left' then
          if IsSelectionValid(s + 1, e) then s = s + 1 end
      else
          if IsSelectionValid(s, e - 1) then e = e - 1 end
      end
      -- Subsequent steps with decaying probability modulated by edge quality
      while true do
          local side2 = pickShrinkSide(s, e)
          if not side2 then break end
          local edgePts = (side2 == 'left') and (points[s] or avgPts) or (points[e] or avgPts)
          local bias = 0
          if avgPts and avgPts == avgPts and edgePts then
              bias = (avgPts - edgePts) / math.max(1e-9, avgPts)
              if bias > 1 then bias = 1 elseif bias < -1 then bias = -1 end
          end
          local q = contProb(baseQ, bias)
          if math.random() >= q then break end
          if side2 == 'left' then
              if IsSelectionValid(s + 1, e) then s = s + 1 else break end
          else
              if IsSelectionValid(s, e - 1) then e = e - 1 else break end
          end
      end
      return s, e
  end

  -- action == 'expand'
  do
      -- First mandatory step (if possible)
      local side = pickExpandSide(s, e)
      if not side then return s, e end
      if side == 'left' then
          if IsSelectionValid(s - 1, e) then s = s - 1 end
      else
          if IsSelectionValid(s, e + 1) then e = e + 1 end
      end
      -- Subsequent steps: continue with probability tilted by neighbor quality
      while true do
          local side2 = pickExpandSide(s, e)
          if not side2 then break end
          local neighborPts = (side2 == 'left') and (((s - 1) >= 1) and points[s - 1] or avgPts)
                            or (((e + 1) <= proteinLength) and points[e + 1] or avgPts)
          local bias = 0
          if avgPts and avgPts == avgPts and neighborPts then
              bias = (neighborPts - avgPts) / math.max(1e-9, avgPts)
              if bias > 1 then bias = 1 elseif bias < -1 then bias = -1 end
          end
          local q = contProb(baseQ, bias)
          if math.random() >= q then break end
          if side2 == 'left' then
              if IsSelectionValid(s - 1, e) then s = s - 1 else break end
          else
              if IsSelectionValid(s, e + 1) then e = e + 1 else break end
          end
      end
      return s, e
  end
end

function NextSelectionDynamic()
  local L = selectionLength or 5
  if remixNotRebuild and L > 9 then L = 9 end
  if remixNotRebuild and L < 3 then L = 3 end
  if (not remixNotRebuild) and L < 2 then L = 2 end
  if L > proteinLength then L = proteinLength end

  ------RULES-------
  -- Collect raw components per segment
  local r0Raw, r1Raw, r2Raw, r3Raw, r4Raw, r5Raw = {}, {}, {}, {}, {}, {}
  local r0min, r0max = math.huge, -math.huge
  local r1min, r1max = math.huge, -math.huge
  local r2min, r2max = math.huge, -math.huge
  local r3min, r3max = math.huge, -math.huge
  local sMin, sMax = math.huge, -math.huge
  local bbMin, bbMax = math.huge, -math.huge

  -- Aggregated rules R1/R3 use EMA memories; no additional per-event decay/amplification needed here.

  for i = 1, proteinLength do
      local segScore = current.GetSegmentEnergyScore(i)
      local segBB    = GetSegmentBBScore(i)
      sMin = math.min(sMin, segScore); sMax = math.max(sMax, segScore)
      bbMin = math.min(bbMin, segBB);  bbMax = math.max(bbMax, segBB)

      -- Rule 0 raw: success ratio per segment (successes / attempts), from Stats
      local at = (Stats and Stats.segmentAttemptCount and Stats.segmentAttemptCount[i]) or 0
      local sc = (Stats and Stats.segmentSuccessCount and Stats.segmentSuccessCount[i]) or 0
      local r0 = (at > 0) and (sc / at) or 0
      r0Raw[i] = r0; r0min = math.min(r0min, r0); r0max = math.max(r0max, r0)

      local d1 = (segImpactSuccAgg[i] or 0)
      r1Raw[i] = d1; r1min = math.min(r1min, d1); r1max = math.max(r1max, d1)

      local age = math.max(0, (eventsProcessedCounter or 0) - (segLastRebuildEventIx[i] or 0))
      r2Raw[i] = age; r2min = math.min(r2min, age); r2max = math.max(r2max, age)

      local d3 = (segImpactFailAgg[i] or 0)
      r3Raw[i] = d3; r3min = math.min(r3min, d3); r3max = math.max(r3max, d3)

      r4Raw[i] = segScore
      r5Raw[i] = segBB
  end

  -- Remix edge age fix: ends never rebuild, so Rule 2 (age) is artificially high there.
  -- To avoid edge inflation, copy neighbors' age for the first/last segments.
  if remixNotRebuild and proteinLength >= 2 then
      r2Raw[1] = r2Raw[2]
      r2Raw[proteinLength] = r2Raw[proteinLength-1]
      -- Recompute R2 min/max after adjustment
      r2min, r2max = math.huge, -math.huge
      for i = 1, proteinLength do
          local v = r2Raw[i]
          if v < r2min then r2min = v end
          if v > r2max then r2max = v end
      end
  end

  local function norm(val, vmin, vmax)
      if val ~= val then return 0 end -- NaN guard
      if vmax <= vmin then return 0 end
      return (val - vmin) / (vmax - vmin)
  end

  local points = {}
  local cont1, cont2, cont3, cont4, cont5, cont6 = {}, {}, {}, {}, {}, {}
  for i = 1, proteinLength do
      local r0 = dyn_rule0_weight * norm(r0Raw[i], r0min, r0max)
      local r1 = dyn_rule1_weight * norm(r1Raw[i], r1min, r1max)
      local r2 = dyn_rule2_weight * norm(r2Raw[i], r2min, r2max)
      local r3 = dyn_rule3_weight * norm(r3Raw[i], r3min, r3max)
      -- For r4/r5 lower values should get higher points → invert
      local r4 = 0
      if sMax > sMin then r4 = dyn_rule4_weight * ((sMax - r4Raw[i]) / (sMax - sMin)) end
      local r5 = 0
      if bbMax > bbMin then r5 = dyn_rule5_weight * ((bbMax - r5Raw[i]) / (bbMax - bbMin)) end

      -- Rule 6: user map (normalized [0..1]) scaled by weight
      local r6 = 0
      if rule6_mapNorm then r6 = (rule6_mapNorm[i] or 0) * (dyn_rule6_weight or 0) end

      cont1[i], cont2[i], cont3[i], cont4[i], cont5[i], cont6[i] = r1, r2, r3, r4, r5, r6
      points[i] = (r0 + r1 + r2 + r3 + r4 + r5 + r6)
  end

  -- Print selections
  if reportLevel > 3 then
      PrintRuleBarsFrom(cont1, cont2, cont3, cont4, cont5, cont6)
  end
  if reportLevel > 2 then
      local pal = getBarPalette(BAR_STYLE.BASE10)
      print("PTS "..encodeScalarArrayToBar(points, pal))
  end
  ------RULES-------

  -- Find best selection window according to the rules points with the length L
  -- Anchor to exactly L using extended (virtual) indices with mirrored padding
  -- We scan starts from -floor(L/2) to proteinLength - floor(L/2),
  -- compute window average on the extended axis, then trim to real indices
  -- (and for Remix drop ends so the window stays in [2..N-1]).
  local baseStart, baseEnd, baseScore = nil, nil, -math.huge
  do
      local wlen = L
      local h = math.floor(wlen / 2)
      local scanStart = -h
      local scanStop  = proteinLength - h

      -- Reflective padding mapping to avoid edge inflation (no edge duplication):
      --   left: 0->2, -1->3, -2->4, ... ; right: N+1->N-1, N+2->N-2, ...
      local function mapIndex(idx)
          local m
          if idx < 1 then
              m = 2 - idx
          elseif idx > proteinLength then
              m = 2 * proteinLength - idx
          else
              m = idx
          end
          if m < 1 then m = 1 end
          if m > proteinLength then m = proteinLength end
          return m
      end
      local function extPoint(idx)
          local ri = mapIndex(idx)
          return points[ri] or 0
      end

      local function consider(extS, sumVal)
          local extE = extS + wlen - 1
          local sReal, eReal
          if remixNotRebuild then
              sReal = math.max(2, extS)
              eReal = math.min(proteinLength - 1, extE)
          else
              sReal = math.max(1, extS)
              eReal = math.min(proteinLength, extE)
          end
          if IsSelectionValid(sReal, eReal) then
              local sc = sumVal / wlen
              if sc > baseScore then baseScore = sc; baseStart = sReal; baseEnd = eReal end
          end
      end

      -- prime window at scanStart
      local windowSum = 0
      for k = 0, wlen - 1 do windowSum = windowSum + extPoint(scanStart + k) end
      consider(scanStart, windowSum)
      -- slide
      for extS = scanStart + 1, scanStop do
          windowSum = windowSum - extPoint(extS - 1) + extPoint(extS + wlen - 1)
          consider(extS, windowSum)
      end
  end

  -- Helper: global valid search (any allowed length), pick best average points; tie-break by closeness to L, then shorter
  local function FindBestAnyValidWindow()
      local bestSS, bestEE = nil, nil
      local bestSc, bestLen = -math.huge, 0
      -- prefix sums for O(1) window sums
      -- prefix sums with a true 0-index guard for ss=1
      local ps = {[0] = 0}
      for i = 1, proteinLength do ps[i] = ps[i-1] + points[i] end
      local function betterAny(sc, wlen, currSc, currLen)
          local eps = 1e-12
          if sc > currSc + eps then return true end
          if math.abs(sc - currSc) <= eps then
              local d1 = math.abs(wlen - L)
              local d2 = math.abs(currLen - L)
              if d1 < d2 then return true end
              if d1 == d2 and wlen < currLen then return true end
          end
          return false
      end
      local minLen = remixNotRebuild and 3 or 2
      local maxLen = remixNotRebuild and math.min(9, proteinLength-1) or proteinLength
      for wlen = minLen, maxLen do
          for ss = 1, proteinLength - wlen + 1 do
              local ee = ss + wlen - 1
              if IsSelectionValid(ss, ee) then
                  local sum = ps[ee] - ps[ss-1]
                  local sc = sum / wlen
                  if betterAny(sc, wlen, bestSc, bestLen) then bestSc = sc; bestLen = wlen; bestSS = ss; bestEE = ee end
              end
          end
      end
      return bestSS, bestEE
  end

  -- If a strict-L window exists, use it as base. Otherwise, run global valid search
  local retStart, retEnd
  if baseStart and baseEnd then
      retStart, retEnd = baseStart, baseEnd
  else
      local ss, ee = FindBestAnyValidWindow()
      retStart, retEnd = ss, ee
  end

  -- Compute average points across the protein for thresholding
  local sumPts = 0
  for i = 1, proteinLength do sumPts = sumPts + points[i] end
  local avgPts = (proteinLength > 0) and (sumPts / proteinLength) or 0

  -- Apply length modification: 1/3 expand, 1/3 shrink, 1/3 keep.
  -- Uses decaying continuation probability controlled by lengthVariability,
  -- with edge-aware side preference and score-aware modulation.
  local origStart, origEnd = retStart, retEnd
  local s, e = retStart, retEnd
  s, e = ModifySelectionLength(s, e, L, points, avgPts, lengthVariability)

  -- Validate final selection; rollback if invalid or degenerate
  if IsSelectionValid(s, e) then
      retStart, retEnd = s, e
  else
      -- Do not re-search: first restore the original selection pick
      if IsSelectionValid(origStart, origEnd) then
          retStart, retEnd = origStart, origEnd
      elseif baseStart and baseEnd and IsSelectionValid(baseStart, baseEnd) then
          -- fallback to strict-L anchor if it existed
          retStart, retEnd = baseStart, baseEnd
      else
          -- as a safety net, run global valid search once
          local ss, ee = FindBestAnyValidWindow()
          if ss and ee then
              retStart, retEnd = ss, ee
          else
              -- last resort: clamp to minimal valid window
              local ss2 = remixNotRebuild and 2 or 1
              local minLen = remixNotRebuild and 3 or 2
              local ee2 = math.min(ss2 + minLen - 1, remixNotRebuild and (proteinLength-1) or proteinLength)
              retStart, retEnd = ss2, ee2
          end
      end
  end

  -- Optional trace
  if reportLevel > 3 then
      local lenActual = (retEnd or 0) - (retStart or 1) + 1
      print(string.format("Dynamic pick L=%d : %d-%d (len=%d)", L, retStart or -1, retEnd or -1, lenActual))
  end

  return retStart, retEnd
end


------------------------------------------------------------------------------------------------------------

-- Generic bar-encoding utilities for visualizing per-segment arrays
BAR_STYLE = { ASCII = "ascii", BASE62 = "base62", BASE10 = "base10" }
local function getBarPalette(style)
    -- Provide BASE62 and BASE10 palettes; ASCII falls back to BASE62.
    local s
    if style == BAR_STYLE.BASE10 then
        s = "0123456789"
    else
        -- Default/BASE62: 0-9, a-z, A-Z 
        s = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    end
    local t = {}
    for i=1,#s do t[i] = s:sub(i,i) end
    return t
end
function encodeScalarArrayToBar(vals, palette, vmin, vmax, invert)
    local pal = palette or getBarPalette(BAR_STYLE.BASE62)
    local n = #pal
    local useDirectDigits = false
    -- If using base10 palette, and no explicit min/max provided, and all values are integers in [0..9],
    -- then map digits directly without stretching amplitude.
    if (pal == getBarPalette(BAR_STYLE.BASE10)) and (vmin == nil and vmax == nil) then
        useDirectDigits = true
        for i=1, proteinLength do
            local v = vals[i]
            if v ~= nil then
                if type(v) ~= "number" or v < 0 or v > 9 or math.floor(v) ~= v then
                    useDirectDigits = false
                    break
                end
            end
        end
    end

    local out = {}
    if useDirectDigits then
        for i=1, proteinLength do
            local v = vals[i] or 0
            if invert then v = 9 - v end
            local idx = math.floor(v + 0.5) + 1
            if idx < 1 then idx = 1 elseif idx > n then idx = n end
            out[i] = pal[idx]
        end
        return table.concat(out, "")
    end

    local mn = vmin; local mx = vmax
    if mn == nil or mx == nil then
        mn = math.huge; mx = -math.huge
        for i=1, proteinLength do
            local v = vals[i] or 0
            if v < mn then mn = v end
            if v > mx then mx = v end
        end
    end
    for i=1, proteinLength do
        local v = vals[i] or 0
        local t = 0
        if mx > mn then t = (v - mn) / (mx - mn) end
        if invert then t = 1 - t end
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local idx = math.floor(t*(n-1) + 0.5) + 1
        if idx < 1 then idx = 1 elseif idx > n then idx = n end
        out[i] = pal[idx]
    end
    return table.concat(out, "")
end

--selections
function FindSelection()
	selNum=0
	for k=1, proteinLength do
	  if selection.IsSelected(k) then 
		--find for selection start
		if k==1 then 
		  selNum=selNum+1
		  selectionStartArr[selNum]=k
		else  
		  if not selection.IsSelected(k-1) then 
			selNum=selNum+1
			selectionStartArr[selNum]=k 
		  end
		end
		
		--find the selection end
		if k==proteinLength then
		  selectionEndArr[selNum]=k
		else
		  if not selection.IsSelected(k+1) then selectionEndArr[selNum]=k end
		end
	   
	  end
	end

	--if no selection, select residues 3-6
	if selNum==0 then
	  selectionStartArr[1]=math.min(5,proteinLength)
	  selectionEndArr[1]=math.min(13,proteinLength)
	end
end

function SetSelection()
	selection.DeselectAll()
	for k=1, proteinLength do
		if (k>=selectionStart) and (k<=selectionEnd) then
			selection.Select (k)
		end
	end
end

function SelectLoops()
	selection.DeselectAll()
	looplength=0

	--select all loops with length >= 3
	for k=1, proteinLength do
	  --print (structure.GetSecondaryStructure(k))
	  if structure.GetSecondaryStructure(k) == 'L' then 
		looplength=looplength+1
		selection.Select (k) 
	  else
		if (looplength>0)  and (looplength<3) then  --deselect if loop is too short
		  for j=1, looplength do
			selection.Deselect (k-j)
		  end
		end
		looplength=0
	  end
	  
	  if (k==proteinLength) and (looplength==1) then selection.Deselect (k) end
	end
end
  
--markup selection of the full protein with some overlap
function SplitProteinBySelections ()
	selectionStartArr={}
	selectionEndArr={}
    k=0 -- used here as selection number 
    if (overlap>=selectionLength) or (overlap<0) then overlap=selectionLength-1 end
    if (startingAA+selectionLength-1 <= 1) then startingAA=1 end -- reset selection markup position counter (startingAA) to 1st protein residue if it is too low
    activeAA=startingAA --startingAA is set in main when running this function. activeAA used as the current pointer of the selection end
        
    --make first selections
    while (activeAA<1) do
      if (activeAA+selectionLength-1>=2) then --if next selection length is >=2
        k=k+1 
        selectionStartArr[k]=1
        selectionEndArr[k]=activeAA+selectionLength-1
      end
      activeAA=activeAA+selectionLength-overlap
    end
    
    --make further selections
    while activeAA+selectionLength-1 < proteinLength do
      k=k+1
      selectionStartArr[k]=activeAA
      selectionEndArr[k]=activeAA+selectionLength-1
      activeAA=selectionEndArr[k]-overlap+1
    end
        
    --make last selections
    while (proteinLength-activeAA+1>=2) do --if next selection length is >=2
      k=k+1
      selectionStartArr[k]=activeAA
      selectionEndArr[k]=proteinLength
      activeAA=activeAA+selectionLength-overlap
    end
    
    selNum=k
 end

function SetAllSelections()
	selection.DeselectAll()
	for j=1, selNum do
	  selectionStart=selectionStartArr[j]
	  selectionEnd=selectionEndArr[j]
	  if (selectionEnd-selectionStart < 0) then
		temp = selectionStart
		selectionStart = selectionEnd
		selectionEnd = temp
	  end
	  if (reportLevel>3) then print ("Setting selection"..j.."/"..selNum..": ", selectionStart.."-"..selectionEnd) end
	  for k=1, proteinLength do
		if (k>=selectionStart) and (k<=selectionEnd) then
		  selection.Select (k)
		end
	  end
	end
end



---------------------------------------------------------------- 
function printSelections()
	strOutput2=""
	print ("Found "..selNum.." selections")
	for j=1, selNum do
	  if (selNum>5) then 
		strOutput2=strOutput2.."   "..selectionStartArr[j].."-"..selectionEndArr[j]
		if (math.fmod(j, 7)==6) then strOutput2=strOutput2.."\n" end
	  else
		print (selectionStartArr[j].."-"..selectionEndArr[j])
	  end
	end
	if (selNum>5) then print(strOutput2) end
end



-- Select everything in radius sphereRadius(=8) near any selected segment.
function SelectionSphere()
	--dump selection to array
	selectedSegs={}
	for k=1, proteinLength do
	  if selection.IsSelected(k) then  
		selectedSegs[k]=1
	  else
		selectedSegs[k]=0
	  end
	end

	for k=1, proteinLength do
	  for j=1, proteinLength do
		dist_str = structure.GetDistance(k, j)
		if (selectedSegs[j] == 1) and (dist_str < sphereRadius) then
		   selection.Select(k)
		end
	  end
	end
end
--------------------------------------------------------------FUZE
function makeShake()
    behavior.SetClashImportance(1)
    structure.ShakeSidechainsAll (2)
end
function TinyFuze()
    SelectionSphere()
    behavior.SetClashImportance(0.05)
    structure.ShakeSidechainsSelected(1)
    behavior.SetClashImportance(1)
    SetSelection()
end
function TinyFuze2()
	recentbest.Save()
	SelectionSphere()
	behavior.SetClashImportance(0.05)
	structure.ShakeSidechainsSelected(1) 
	structure.WiggleSelected(20)
	behavior.SetClashImportance(1)
	structure.ShakeSidechainsSelected(1)
	structure.WiggleAll(20)
	SetSelection()
	recentbest.Restore()
end
-- Function to parse the input string into a 2D array
function parseInput(input)
    local result = {}
    for quadruplet in input:gmatch("{([^}]+)}") do
        local values = {}
        for value in quadruplet:gmatch("[^,%s]+") do
            table.insert(values, tonumber(value))
        end
        table.insert(result, {
            clashImportance = values[1],
            shakeIter = values[2],
            clashImportance2= values[3],
            wiggleIter = values[4]
        })
    end
    return result
end
-- Universal function that runs the logic on parsed input
function Fuze2(inputString, slotx)
    local t0 = os.clock()

	recentbest.Save()
    local fuzeConfig = parseInput(inputString)
    local score = ScoreReturn()

    for idx, triplet in ipairs(fuzeConfig) do
        behavior.SetClashImportance(triplet.clashImportance)
        if triplet.shakeIter and triplet.shakeIter > 0 then
            structure.ShakeSidechainsAll(triplet.shakeIter)
        elseif triplet.shakeIter and triplet.shakeIter < 0 then
            structure.WiggleAll(-triplet.shakeIter, false, true)
        end
        
        behavior.SetClashImportance(triplet.clashImportance2)
        if triplet.wiggleIter and triplet.wiggleIter > 0 then
            structure.WiggleAll(triplet.wiggleIter)
        elseif triplet.wiggleIter and triplet.wiggleIter < 0 then
            structure.WiggleAll(-triplet.wiggleIter, true, false)
        end
    end
    ReadNotes()
	recentbest.Restore()		

    timer3 = os.clock() - t0 + timer3
  return score -- Return the score
end



-----------------------------------------------------------------------------------------------
--Classic selection algorithm
-- calculate BB score persegments for a selection
function CalculateSelectionScorePerSegment(start, finish)
	local segmentCount = finish - start + 1
	local segScore = 0
	for i = start, finish do
    segScore = segScore + current.GetSegmentEnergyScore(i)
		--segScore = segScore + GetSegmentBBScore(i)
	end
	return segScore / segmentCount
end

-- sort selections based on energy score per number of segments
function SortSelections(selectionStartArr, selectionEndArr)
	local sortedSelections = {}

	-- Calculate and store energy scores per segment for each selection
	for i = 1, #selectionStartArr do
		local start = selectionStartArr[i]
		local finish = selectionEndArr[i]
		local energyScorePerSegment = CalculateSelectionScorePerSegment(start, finish)
		table.insert(sortedSelections, {index = i, start = start, finish = finish, scorePerSegment = energyScorePerSegment})
	end

	-- Sort the sortedSelections table based on energy scores per segment in ascending order
	table.sort(sortedSelections, function(a, b) return a.scorePerSegment < b.scorePerSegment end)

	-- Print the start index, end index, energy score per segment of each selection, and the sorted start and end indices
	for _, selection in ipairs(sortedSelections) do
		if reportLevel>3 then print("Start index:", selection.start, "- End index:", selection.finish, "- Energy/seg", selection.scorePerSegment) end
	end

	-- Return the sorted arrays
	local sortedStartArr = {}
	local sortedEndArr = {}
	for _, selection in ipairs(sortedSelections) do
		table.insert(sortedStartArr, selection.start)
		table.insert(sortedEndArr, selection.finish)
	end

	return sortedStartArr, sortedEndArr
end

function SetOverlap(selectionLength)
	overlap = math.ceil(selectionLength^(6/11)) -- math.floor(math.sqrt(selectionLength)) + 1 --decrease overlap basing on selectionLength: 5=2 6=2 7=3 8=3 9=3 10=4 11=4 12=4 13=5 14=5
	if selectionLength < 7 then overlap = overlap - 1 end --with a bit of correction for small rebuild values
	return overlap
end
---------------------------------------------------------------service functions
function roundX(x)--cut all afer 3-rd place
return x-x%0.01
end

--[[ function returning the max between two numbers --]]
function max(num1, num2)
   if (num1 > num2) then  result = num1
   else result = num2    end
   return result
end

--	BackBone-Score is just the general score without clashing. Clashing is usefull to ignore when there is need to rank a lot of the Rebuild solutions very fast without the Fuze.
function ScoreBBReturn()
    x = 0
    for i=1, proteinLength do
      x = x + current.GetSegmentEnergySubscore(i, "Clashing")
    end
    x = current.GetEnergyScore() - x
	return x-x%1
end

-- Create array of the Scores for every Subscore of the puzzle
function GetSolutionSubscores(SolutionID)
    local t0 = os.clock()
    -- Reuse cached score part names when available to avoid repeated API calls
    local scoreParts = (Stats and Stats.scoreParts) or puzzle.GetPuzzleSubscoreNames() or {}
    if Stats and not Stats.scoreParts and #scoreParts > 0 then Stats.scoreParts = scoreParts end
    local solutionSubscores = {}

    for _, scorePart in ipairs(scoreParts) do
        local sum = 0
        for segmentIndex = 1, proteinLength do
            sum = sum + (current.GetSegmentEnergySubscore(segmentIndex, scorePart) or 0)
        end
        solutionSubscores[scorePart] = sum
    end

    solutionSubscores["SolutionID"] = SolutionID
    timer5 = os.clock() - t0 + timer5
    return solutionSubscores
end

function GetSegmentBBScore(i)
	return current.GetSegmentEnergyScore(i) - current.GetSegmentEnergySubscore(i, "Clashing")
end

---------------------------------------------------- Stats --------------------------------------------------------------------
Stats = Stats or {}
Stats.enabled = true -- default ON 
Stats._cleanup_ran = false
Stats.candidates = Stats.candidates or {}
Stats.short = Stats.short or {}
Stats.final = Stats.final or {}
Stats.shortCandidates = Stats.shortCandidates or {} -- per-candidate short-fuze logs
Stats.subscoreRecords = Stats.subscoreRecords or {}  -- per-event window subscores vs success label (filled when available)
Stats.aaRecords = Stats.aaRecords or {}             -- per-event AA composition (total/edge/interior)
-- parts constant across candidates per event: constSubscoreParts[event_ix][part_index]=true
Stats.constSubscoreParts = Stats.constSubscoreParts or {}
-- segment-level aggregates
Stats.segmentAttemptCount = Stats.segmentAttemptCount or {}
Stats.segmentSuccessCount = Stats.segmentSuccessCount or {}
-- per-segment relative inefficiency counter: increment when short-fuse winner ≠ pre-rank #1
Stats.segmentIneffCount = Stats.segmentIneffCount or {}
Stats.maxRows = 5000 -- soft cap to avoid runaway memory; oldest trimmed

-- lightweight version counters and caches for optimization
Stats._candidatesVer = Stats._candidatesVer or 0
Stats._shortVer = Stats._shortVer or 0
Stats._cache = Stats._cache or { lenDisp = nil, segDispLN = nil, synByEvent = nil, synWeights = nil, winAgg = nil }

function Stats._trim(tbl)
  local n = #tbl
  if n > Stats.maxRows then
    local drop = n - Stats.maxRows
    local keep = n - drop
    for i=1,keep do tbl[i] = tbl[i + drop] end
    for i=keep+1,n do tbl[i] = nil end
  end
  return tbl
end

-- cache invalidators
local function _invalidate_syn_caches()
  if Stats and Stats._cache then
    Stats._cache.synByEvent = nil
    Stats._cache.synWeights = nil
  end
end
local function _invalidate_dispersion_caches()
  if Stats and Stats._cache then
    Stats._cache.lenDisp = nil
    Stats._cache.segDispLN = nil
  end
end
function Stats.init()
  Stats.proteinLength = proteinLength
  -- capture references to existing dynamic-tracking arrays (for inspection)
  if segRebuildCount then Stats.segRebuildCount = segRebuildCount end
  -- capture subscore names once
  local ok, names = pcall(puzzle.GetPuzzleSubscoreNames)
  if ok and type(names)=="table" then Stats.scoreParts = names end
  _invalidate_syn_caches(); _invalidate_dispersion_caches()
end
function Stats.setEnabled(on)
  Stats.enabled = (on and true) or false
  print("[Stats] "..(Stats.enabled and "enabled" or "disabled"))
end
local function _mean_std(vals)
  local n = #vals; if n==0 then return 0,0 end
  local s=0; for i=1,n do s = s + (vals[i] or 0) end
  local m = s / n
  local v=0; for i=1,n do local d=(vals[i] or 0)-m; v=v+d*d end
  v = v / math.max(1, n-1)
  return m, math.sqrt(v)
end


local function _syn_sorted_event_keys(map)
  local ks = {}
  for k,_ in pairs(map) do ks[#ks+1] = k end
  table.sort(ks, function(a,b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
  return ks
end

local function _syn_event_feature_stats(arr, nparts)
  local mu, sd, cnt = {}, {}, {}
  for j=1,nparts do mu[j]=0; sd[j]=0; cnt[j]=0 end
  for _,c in ipairs(arr) do
    local a = c.subs_total
    if a then
      for j=1,nparts do
        local v = a[j]
        if type(v)=="number" then mu[j] = mu[j] + v; cnt[j] = cnt[j] + 1 end
      end
    end
  end
  for j=1,nparts do if cnt[j]>0 then mu[j] = mu[j] / cnt[j] else mu[j]=0 end end
  for _,c in ipairs(arr) do
    local a = c.subs_total
    if a then
      for j=1,nparts do
        local v = a[j]
        if type(v)=="number" then local d=v-mu[j]; sd[j]=sd[j]+d*d end
      end
    end
  end
  for j=1,nparts do if cnt[j]>1 then sd[j] = math.sqrt(sd[j]/(cnt[j]-1)) else sd[j]=0 end end
  return mu, sd
end

local function _syn_event_scalar_stats(arr, field)
  local mu, cnt = 0, 0
  for _,c in ipairs(arr) do
    local v = c[field]
    if type(v) == "number" then mu = mu + v; cnt = cnt + 1 end
  end
  if cnt > 0 then mu = mu / cnt else mu = 0 end
  local var = 0
  for _,c in ipairs(arr) do
    local v = c[field]
    if type(v) == "number" then local d = v - mu; var = var + d*d end
  end
  local sd = (cnt > 1) and math.sqrt(var / (cnt - 1)) or 0
  return mu, sd
end

function Stats._syn_build_by_event()
  -- cache by short-candidate version to avoid repeated regrouping
  local c = Stats._cache and Stats._cache.synByEvent
  if c and c.ver == Stats._shortVer and c.map then return c.map end
  local byEvent = {}
  for _,r in ipairs(Stats.shortCandidates or {}) do
    local t = byEvent[r.event_ix] or {}; byEvent[r.event_ix] = t
    t[#t+1] = r
  end
  if Stats and Stats._cache then Stats._cache.synByEvent = { ver = Stats._shortVer, map = byEvent } end
  return byEvent
end

-- Forward declaration so earlier functions (e.g. syn_compute_weights) can call it
local _pearson

function Stats.syn_compute_weights(limitEv)
  if not (Stats.scoreParts and #Stats.scoreParts>0) then return nil, 0, 0 end
  -- cache lookup
  do
    local wc = Stats._cache and Stats._cache.synWeights
    if wc and wc.ver == Stats._shortVer and wc.map and wc.map[limitEv] then
      local hit = wc.map[limitEv]
      return hit.w, hit.used, hit.eventsUsed
    end
  end
  local parts = Stats.scoreParts
  local np = #parts
  local xs, ys = {}, {}
  for j=1,np do xs[j] = {}; ys[j] = {} end
  local xsDraft, ysDraft = {}, {}
  local includeDraft = (fuze_draft == true)
  local byEvent = Stats._syn_build_by_event()
  local evs = _syn_sorted_event_keys(byEvent)
  local eventsUsed = 0
  for _,ev in ipairs(evs) do
    local iev = tonumber(ev) or 0
    if iev < (tonumber(limitEv) or 0) then
      local arr = byEvent[ev]
      if arr and #arr >= 2 then
        eventsUsed = eventsUsed + 1
        local copy = {}
        for i=1,#arr do copy[i] = arr[i] end
        table.sort(copy, function(a,b) return (a.short_score or -1e18) > (b.short_score or -1e18) end)
        local wslot = copy[1] and copy[1].slot or nil
        local mu, sd = _syn_event_feature_stats(arr, np)
        local muD, sdD = 0, 0
        if includeDraft then muD, sdD = _syn_event_scalar_stats(arr, "draft_score") end
        local constMap = Stats.constSubscoreParts and Stats.constSubscoreParts[ev] or {}
        for _,c in ipairs(arr) do
          local y = (c.slot == wslot) and 1 or 0
          local a = c.subs_total
          if a then
            for j=1,np do
              if not (constMap and constMap[j]) then
                local v = a[j]
                if type(v)=="number" and (sd[j] or 0) > 0 then
                  local z = (v - (mu[j] or 0)) / (sd[j] or 1)
                  xs[j][#xs[j]+1] = z; ys[j][#ys[j]+1] = y
                end
              end
            end
          end
          if includeDraft and (sdD or 0) > 0 then
            local dv = c.draft_score
            if type(dv) == "number" then
              local dz = (dv - (muD or 0)) / (sdD or 1)
              xsDraft[#xsDraft+1] = dz; ysDraft[#ysDraft+1] = y
            end
          end
        end
      end
    end
  end
  local w = {}; local used = 0
  for j=1,np do
    local r = _pearson(xs[j], ys[j])
    if r ~= 0 and r == r then used = used + 1 end
    w[j] = r or 0
  end
  if includeDraft then
    local rd = _pearson(xsDraft, ysDraft)
    if rd ~= 0 and rd == rd then used = used + 1 end
    w._draft = rd or 0
  end
  -- store in cache
  do
    local wc = Stats._cache and Stats._cache.synWeights
    if not wc or wc.ver ~= Stats._shortVer then wc = { ver = Stats._shortVer, map = {} } end
    wc.map[limitEv] = { w = w, used = used, eventsUsed = eventsUsed }
    Stats._cache.synWeights = wc
  end
  return w, used, eventsUsed
end

local function _syn_rank_for_event(arr, weights)
  local np = (Stats.scoreParts and #Stats.scoreParts) or 0
  if np == 0 then return nil, nil end
  local mu, sd = _syn_event_feature_stats(arr, np)
  local useDraft = (fuze_draft == true) and (weights and (weights._draft or 0) ~= 0)
  local muD, sdD = 0, 0
  if useDraft then muD, sdD = _syn_event_scalar_stats(arr, "draft_score") end
  local scored = {}
  for _,c in ipairs(arr) do
    local s = 0
    local a = c.subs_total
    if a then
      for j=1,np do
        local denom = sd[j] or 0
        if denom and denom > 0 then
          local v = a[j]
          if type(v)=="number" then
            local z = (v - (mu[j] or 0)) / denom
            s = s + (weights[j] or 0) * z
          end
        end
      end
    end
    if useDraft and (sdD or 0) > 0 then
      local v = c.draft_score
      if type(v) == "number" then
        local z = (v - (muD or 0)) / (sdD or 1)
        s = s + (weights._draft or 0) * z
      end
    end
    scored[#scored+1] = {slot=c.slot, score=s}
  end
  table.sort(scored, function(a,b)
    if (a.score or 0) == (b.score or 0) then return (a.slot or 0) < (b.slot or 0) end
    return (a.score or 0) > (b.score or 0)
  end)
  local order = {}
  for i=1,#scored do order[i] = scored[i].slot end
  local top = scored[1] and scored[1].slot or nil
  return top, order
end

-- Syn black-box: return order (slot ids, desc) and dynamic weight for blending
Stats.Syn = Stats.Syn or {}
function Stats.Syn.order(evCur, remixBBScores, solutionSubscoresArray)
  if not (Stats and Stats.enabled) then return nil end
  local parts = Stats.scoreParts
  if not (parts and #parts > 0) then return nil end
  if type(remixBBScores) ~= 'table' or #remixBBScores < 2 then return nil end

  -- Train from events strictly before evCur
  local wts, used, eventsUsed = Stats.syn_compute_weights(evCur)
  if not (wts and used and used > 0 and eventsUsed and eventsUsed > 0) then return nil end

  -- Build current-event features
  local byId = {}
  if type(solutionSubscoresArray)=="table" then
    for _, rec in ipairs(solutionSubscoresArray) do
      if type(rec)=="table" and rec["SolutionID"] then byId[rec["SolutionID"]] = rec end
    end
  end
  local arrNow = {}
  for _, r in ipairs(remixBBScores) do
    local id = r.id
    local subrec = byId[id]
    local a = nil
    if subrec then
      a = {}
      for idx, name in ipairs(parts) do a[idx] = subrec[name] or 0 end
    end
    arrNow[#arrNow+1] = {slot=id, subs_total=a, draft_score=r.draft_score}
  end

  local _, order = _syn_rank_for_event(arrNow, wts)
  if not order or #order < 1 then return nil end

  -- Dynamic syn weight: ramp from 0 to syn_max across syn_ramp_events
  local synMax = syn_alpha_max or 1.5
  local rampN  = syn_ramp_events or 50
  local frac = (rampN > 0) and (eventsUsed / rampN) or 1
  if frac < 0 then frac = 0 end; if frac > 1 then frac = 1 end
  local weight = synMax * frac

  return { order = order, weight = weight, eventsUsed = eventsUsed }
end
-- Print all available per-segment maps (normalized 0-9)
-- Compute per-segment rank inefficiency: fraction of events where pre-rank #1
-- did not win short-fuse (non-top1 short-win / attempts).
function Stats._segmentRankInefficiencyMap()
  local n = proteinLength or 0
  local vals = {}
  for i = 1, n do
    local a = Stats.segmentAttemptCount[i] or 0
    local b = Stats.segmentIneffCount[i] or 0
    vals[i] = (a > 0) and (b / a) or 0
  end
  return vals
end

-- Per-segment BB std within window (mean-centered, L-corrected), aggregated across events
function Stats._segmentBBStdWithinLcorrMap()
  local n = proteinLength or 0
  local vals = {}
  for i = 1, n do
    local s = (Stats.segmentBBVarSum and Stats.segmentBBVarSum[i]) or 0
    local c = (Stats.segmentBBVarCount and Stats.segmentBBVarCount[i]) or 0
    vals[i] = (c > 0 and s >= 0) and math.sqrt(s / c) or 0
  end
  return vals
end

function Stats.printAllMaps()
  if not (getBarPalette and encodeScalarArrayToBar) then return end
  local pal10 = getBarPalette(BAR_STYLE.BASE10)

  -- Helper to test if an array has any non-nil/non-zero entries
  local function hasData(arr)
    if not arr then return false end
    for i=1,(proteinLength or 0) do
      local v = arr[i]
      if v and v ~= 0 then return true end
    end
    return false
  end

  -- 1) Rebuild events per segment
  local reb = segRebuildCount or (Stats and Stats.segRebuildCount)
  if hasData(reb) then
    print("[Maps] Rebuild events per segment:")
    print(encodeScalarArrayToBar(reb, pal10))
  end

  -- 2) Segment success rate (success/attempts)
  local n = proteinLength or 0
  local rate = {}
  local hasRate = false
  for i=1,n do
    local a = Stats.segmentAttemptCount[i] or 0
    local s = Stats.segmentSuccessCount[i] or 0
    if a > 0 then rate[i] = s / a; if rate[i] ~= 0 then hasRate = true end else rate[i] = 0 end
  end
  if hasRate then
    print("[Maps] Success rate per segment:")
    print(encodeScalarArrayToBar(rate, pal10))
  end

  -- 3) Rule6 user priority map (if present)
  if rule6_mapNorm and hasData(rule6_mapNorm) then
    local r6 = {}
    for i=1,(proteinLength or 0) do r6[i] = (rule6_mapNorm[i] or 0) * (dyn_rule6_weight or 0) end
    print("[Maps] Rule6 priority map:")
    print(encodeScalarArrayToBar(r6, pal10))
  end

  
  -- 4) Length-normalized segment average bb_std (dispersion)
  if Stats and Stats.candidates and #Stats.candidates > 0 then
    local disp_ln = Stats._segmentDispersionAveragesLenNorm and Stats._segmentDispersionAveragesLenNorm()
    if hasData(disp_ln) then
      print("[Maps] Avg BB dispersion per segment (len-normalized):")
      print(encodeScalarArrayToBar(disp_ln, pal10))
    end
  end

  -- 4b) Within-window per-segment BB std (mean-centered within each event window)
  do
    local n = proteinLength or 0
    local vals = {}
    local hasVal = false
    for i=1,n do
      local s = (Stats.segmentBBVarSum and Stats.segmentBBVarSum[i]) or 0
      local c = (Stats.segmentBBVarCount and Stats.segmentBBVarCount[i]) or 0
      local v = (c > 0 and s > 0) and math.sqrt(s / c) or 0
      vals[i] = v
      if v ~= 0 then hasVal = true end
    end
    if hasVal then
      print("[Maps] Per-segment BB std within window (mean-centered, L-corrected):")
      print(encodeScalarArrayToBar(vals, pal10))
    end
  end

  -- 5) Relative inefficiency map: fraction of events where pre-rank top1 did not win after short-fuse
  do
    local vals = Stats._segmentRankInefficiencyMap and Stats._segmentRankInefficiencyMap() or {}
    if hasData(vals) then
      print("[Maps] Rank inefficiency per segment (non-top1 short-win / attempts):")
      print(encodeScalarArrayToBar(vals, pal10))
    end
  end
end

-- Compute per-segment average dispersion (avg bb_std seen when segment was in a selection)
function Stats._segmentDispersionAverages() -- legacy (unused for maps; kept for compatibility)
  if Stats and Stats._segmentDispersionAveragesLenNorm then
    return Stats._segmentDispersionAveragesLenNorm() or {}
  end
  return {}
end

-- Build baseline bb_std statistics per window length from candidate events
function Stats._lenDispersionStats()
  -- memoize by candidates version
  local c = Stats._cache and Stats._cache.lenDisp
  if c and c.ver == Stats._candidatesVer then return c.mu, c.sd end
  local byLen = {}
  for _,row in ipairs(Stats.candidates or {}) do
    local L = tonumber(row.len or 0) or 0
    local v = tonumber(row.bb_std or 0) or 0
    if L > 0 then
      local t = byLen[L] or {s=0, s2=0, n=0}
      t.s = t.s + v
      t.s2 = t.s2 + v*v
      t.n = t.n + 1
      byLen[L] = t
    end
  end
  local mu = {}
  local sd = {}
  for L, t in pairs(byLen) do
    if t.n > 0 then
      local m = t.s / t.n
      local var = 0
      if t.n > 1 then
        local ex2 = t.s2 / t.n
        local ex = m
        var = math.max(0, (ex2 - ex*ex)) * (t.n / math.max(1, t.n-1))
      end
      mu[L] = m
      sd[L] = (var > 0) and math.sqrt(var) or 0
    end
  end
  if Stats and Stats._cache then Stats._cache.lenDisp = { ver = Stats._candidatesVer, mu = mu, sd = sd } end
  return mu, sd
end

-- Map event -> length-normalized bb_std (ratio to mean for its window length)
function Stats._eventLenNormBBStdMap()
  local mu, _ = Stats._lenDispersionStats()
  local m = {}
  for _,row in ipairs(Stats.candidates or {}) do
    if row and row.event_ix then
      local L = tonumber(row.len or 0) or 0
      local v = tonumber(row.bb_std or 0) or 0
      local base = (L>0) and (mu[L] or 0) or 0
      local norm = (base and base>1e-9) and (v/base) or 1
      m[row.event_ix] = norm
    end
  end
  return m
end

-- Compute per-segment average of length-normalized dispersion.
-- Normalization: ratio to mean bb_std for this window length (mu[L]).
function Stats._segmentDispersionAveragesLenNorm()
  -- memoize by candidates version
  local c = Stats._cache and Stats._cache.segDispLN
  if c and c.ver == Stats._candidatesVer and c.avg then return c.avg end
  local n = proteinLength or 0
  if n <= 0 then return {} end
  local mu, _ = Stats._lenDispersionStats()
  local sums = {}
  local cnts = {}
  for i=1,n do sums[i]=0; cnts[i]=0 end
  for _,row in ipairs(Stats.candidates or {}) do
    local L = tonumber(row.len or 0) or 0
    local v = tonumber(row.bb_std or 0) or 0
    local m = (L>0) and (mu[L] or 0) or 0
    local norm
    if m and m > 1e-9 then norm = v / m else norm = 1 end
    local s = tonumber(row.start or 0) or 0
    local e = tonumber(row.finish or 0) or 0
    if s > 0 and e >= s and e <= n then
      for i = s, e do
        sums[i] = (sums[i] or 0) + norm
        cnts[i] = (cnts[i] or 0) + 1
      end
    end
  end
  local avg = {}
  for i=1,n do
    if (cnts[i] or 0) > 0 then avg[i] = (sums[i] or 0) / (cnts[i] or 1) else avg[i] = 0 end
  end
  if Stats and Stats._cache then Stats._cache.segDispLN = { ver = Stats._candidatesVer, avg = avg } end
  return avg
end

-- Print per-segment dispersion map and top-K segments by average dispersion
function Stats.printSegDispersion(topK)
  local vals = (Stats._segmentDispersionAveragesLenNorm and Stats._segmentDispersionAveragesLenNorm()) or {}
  if getBarPalette and encodeScalarArrayToBar then
    local pal10 = getBarPalette(BAR_STYLE.BASE10)
    print("[Stats] Segment avg bb_std (dispersion) map (len-normalized):")
    print(encodeScalarArrayToBar(vals, pal10))
  end
  -- collect top-K indices
  local items = {}
  for i=1,(proteinLength or 0) do items[#items+1] = {i=i, v=vals[i] or 0} end
  table.sort(items, function(a,b) return (a.v or 0) > (b.v or 0) end)
  local K = tonumber(topK or 10) or 10
  if #items > 0 then
    print(string.format("[Stats] Top %d segments by avg bb_std (len-norm):", math.min(K, #items)))
    for j=1,math.min(K,#items) do
      print(string.format("  #%d  seg=%d  avg=%.3f", j, items[j].i or 0, items[j].v or 0))
    end
  else
    print("[Stats] No segment dispersion data yet")
  end
end
local function _win_agg(startIdx, endIdx)
  local s, bb, clash = 0, 0, 0
  local n = 0
  local ssH, ssE, ssL = 0,0,0
  local bb_arr = {}
  for i = startIdx, endIdx do
    local si = current.GetSegmentEnergyScore(i)
    local ci = current.GetSegmentEnergySubscore(i, "Clashing")
    local bbi = si - ci
    local ss = structure.GetSecondaryStructure(i)
    s = s + si; bb = bb + bbi; clash = clash + ci; n = n + 1
    bb_arr[i] = bbi
    if ss == "H" then ssH = ssH + 1 elseif ss == "E" then ssE = ssE + 1 else ssL = ssL + 1 end
  end
  if n<1 then n=1 end
  return {
    len = endIdx - startIdx + 1,
    score_mean = s/n,
    bb_mean = bb/n,
    clash_mean = clash/n,
    frac_H = ssH/n, frac_E = ssE/n, frac_L = ssL/n,
    bb_arr = bb_arr,
  }
end
-- Amino-acid mapping and helpers
local aa3_map = {
    g = "Gly", a = "Ala", v = "Val", l = "Leu", i = "Ile",
    m = "Met", f = "Phe", w = "Trp", p = "Pro", s = "Ser",
    t = "Thr", c = "Cys", y = "Tyr", n = "Asn", q = "Gln",
    d = "Asp", e = "Glu", k = "Lys", r = "Arg", h = "His",
}
-- Build and cache 3-letter AA names for all positions (sequence is static during run)
local function _build_aa3_cache()
    local n = (Stats and Stats.proteinLength) or proteinLength or 0
    local cache = {}
    if not structure or not structure.GetAminoAcid then
        for i=1,n do cache[i] = "Unk" end
        Stats._aa3_cache = cache
        return cache
    end
    for i=1,n do
        local aa = "Unk"
        local ok, k = pcall(structure.GetAminoAcid, i)
        if ok and k then
            k = string.lower(tostring(k))
            aa = aa3_map[k] or "Unk"
        end
        cache[i] = aa
    end
    Stats._aa3_cache = cache
    return cache
end

local function _get_aa3(i)
    if not i or i <= 0 then return "Unk" end
    local cache = Stats and Stats._aa3_cache
    if not cache then cache = _build_aa3_cache() end
    local v = cache and cache[i]
    if v ~= nil then return v end
    -- Fallback for out-of-range or late calls; also fill cache slot
    local aa = "Unk"
    if structure and structure.GetAminoAcid then
        local ok, k = pcall(structure.GetAminoAcid, i)
        if ok and k then
            k = string.lower(tostring(k))
            aa = aa3_map[k] or "Unk"
        end
    end
    if cache then cache[i] = aa else Stats._aa3_cache = {[i]=aa} end
    return aa
end
local function _aa_comp(startIdx, endIdx)
  local counts = {}
  local n = 0
  for i=startIdx, endIdx do
    local aa = _get_aa3(i)
    counts[aa] = (counts[aa] or 0) + 1
    n = n + 1
  end
  local fr = {}
  if n < 1 then return fr end
  for k,v in pairs(counts) do fr[k] = v / n end
  return fr
end
local function _edge_int_ranges(startIdx, endIdx)
  local len = endIdx - startIdx + 1
  if len <= 0 then return nil,nil end
  if len == 1 then return {startIdx,startIdx}, nil end
  if len == 2 then return {startIdx, endIdx}, nil end
  return {startIdx, endIdx}, {startIdx+1, endIdx-1}
end
local function _subscores_window(startIdx, endIdx)
  local parts = Stats.scoreParts or {}
  local out = {}
  for pi=1,#parts do out[pi]=0 end
  for i=startIdx, endIdx do
    for pi, name in ipairs(parts) do
      out[pi] = out[pi] + (current.GetSegmentEnergySubscore(i, name) or 0)
    end
  end
  return out
end
-- Sum subscores only at true edges (start and end positions)
local function _subscores_edges(startIdx, endIdx)
  local parts = Stats.scoreParts or {}
  local out = {}
  for pi=1,#parts do out[pi]=0 end
  if not startIdx or not endIdx or endIdx < startIdx then return out end
  local function addAt(i)
    for pi, name in ipairs(parts) do
      out[pi] = out[pi] + (current.GetSegmentEnergySubscore(i, name) or 0)
    end
  end
  addAt(startIdx)
  if endIdx ~= startIdx then addAt(endIdx) end
  return out
end
_pearson = function(xs, ys)
  local n = 0; local sx, sy, sxx, syy, sxy = 0,0,0,0,0
  local m = math.min(#xs, #ys)
  for i=1,m do
    local x, y = xs[i], ys[i]
    if type(x)=="number" and type(y)=="number" then
      n = n + 1; sx = sx + x; sy = sy + y; sxx = sxx + x*x; syy = syy + y*y; sxy = sxy + x*y
    end
  end
  if n<2 then return 0 end
  local cov = sxy - sx*sy/n
  local vx = sxx - sx*sx/n
  local vy = syy - sy*sy/n
  if vx <= 0 or vy <= 0 then return 0 end
  return cov / math.sqrt(vx*vy)
end
local function _rule_window_means(startIdx, endIdx)
  local ok, c1,c2,c3,c4,c5,c6 = pcall(function()
    local a,b,c,d,e,f = ComputeDynamicRuleScores()
    return a,b,c,d,e,f
  end)
  if not ok or not c1 then return 0,0,0,0,0,0 end
  local function avg(arr)
    local s=0; local n=0
    for i=startIdx, endIdx do s=s+(arr[i] or 0); n=n+1 end
    if n<1 then return 0 end
    return s/n
  end
  return avg(c1), avg(c2), avg(c3), avg(c4), avg(c5), avg(c6)
end
local function _fmt(x)
  if x == nil then return "" end
  if type(x) ~= "number" then return tostring(x) end
  local rint = math.floor(x + 0.5)
  if math.abs(x - rint) < 1e-9 then return string.format("%d", rint) end
  local ax = math.abs(x)
  local fmt
  if ax > 100 then fmt = "%.0f"
  elseif ax > 10 then fmt = "%.1f"
  elseif ax > 1 then fmt = "%.2f"
  else fmt = "%.3f" end
  local s = string.format(fmt, x)
  if string.match(s, "^%-?0%.0+$") then s = "0" end
  return s
end
function Stats.logCandidates(action, eventIx, selStart, selEnd, startScore, remixBBScores)
  if not Stats.enabled then return end
  local n = 0; local scores = {}; local bbs = {}
  if type(remixBBScores)=="table" then
    for _, it in ipairs(remixBBScores) do
      n = n + 1
      scores[n] = it.score or 0
      bbs[n] = it.scoreBB or 0
    end
  end
  local sm, ssd = _mean_std(scores)
  local bm, bsd = _mean_std(bbs)
  -- compute and cache per-event window aggregates to avoid repeat API calls
  local w = _win_agg(selStart, selEnd)
  do
    Stats._cache = Stats._cache or {}
    Stats._cache.winAgg = Stats._cache.winAgg or {}
    Stats._cache.winAgg[eventIx] = w
  end
  -- Accumulate per-segment within-window BB variance (centered at window mean) without extra API calls
  do
    local bb_arr = w.bb_arr or {}
    local mean = w.bb_mean or 0
    local L = tonumber(w.len or 0) or 0
    local norm = 1.0
    if L and L > 1 then
      local f = 1 - (1 / L)
      if f > 1e-9 then norm = math.sqrt(f) else norm = 1.0 end
    end
    Stats.segmentBBVarSum = Stats.segmentBBVarSum or {}
    Stats.segmentBBVarCount = Stats.segmentBBVarCount or {}
    for i = selStart, selEnd do
      local di = (bb_arr[i] or 0) - mean
      local din = (norm ~= 0) and (di / norm) or di
      Stats.segmentBBVarSum[i] = (Stats.segmentBBVarSum[i] or 0) + din*din
      Stats.segmentBBVarCount[i] = (Stats.segmentBBVarCount[i] or 0) + 1
    end
  end
  local r1,r2,r3,r4,r5,r6 = _rule_window_means(selStart, selEnd)
  -- segment-level aggregates for variability vs success later
  for i = selStart, selEnd do
    Stats.segmentAttemptCount[i] = (Stats.segmentAttemptCount[i] or 0) + 1
  end
  -- AA composition (total/edge/interior)
  local edgeR, intR = _edge_int_ranges(selStart, selEnd)
  local aa_total = _aa_comp(selStart, selEnd)
  -- true-edge AA composition (start/end only)
  local aa_edge = {}
  do
    local s, e = selStart, selEnd
    if s and e and e >= s then
      local denom = (e == s) and 1 or 2
      if denom == 1 then
        aa_edge = _aa_comp(s, s)
      else
        local c1 = _aa_comp(s, s)
        local c2 = _aa_comp(e, e)
        -- combine single-segment fractions into 2-segment average
        local keys = {}
        for k,_ in pairs(c1) do keys[k]=true end
        for k,_ in pairs(c2) do keys[k]=true end
        for k,_ in pairs(keys) do aa_edge[k] = ((c1[k] or 0) + (c2[k] or 0)) / 2 end
      end
    end
  end
  local aa_int  = intR and _aa_comp(intR[1], intR[2]) or {}
  table.insert(Stats.aaRecords, {
    event_ix=eventIx, action=action, start=selStart, finish=selEnd, len=w.len,
    aa_total=aa_total, aa_edge=aa_edge, aa_int=aa_int,
    frac_H=w.frac_H, frac_E=w.frac_E, frac_L=w.frac_L,
  })
  -- Subscores per window (pre-event snapshot)
  if Stats.scoreParts and #Stats.scoreParts>0 then
    local subs_win = _subscores_window(selStart, selEnd)
    local subs_edge, subs_int
    subs_edge = _subscores_edges(selStart, selEnd)
    if intR  then subs_int  = _subscores_window(intR[1], intR[2])  end
    table.insert(Stats.subscoreRecords, {
      event_ix=eventIx, action=action, start=selStart, finish=selEnd, len=w.len,
      subs_win=subs_win, subs_edge=subs_edge, subs_int=subs_int,
    })
  end
  local row = {
    event_ix = eventIx or 0,
    action = action or "",
    start = selStart or 0, finish = selEnd or 0, len = w.len or 0,
    pre_score = startScore or 0,
    cand_n = n,
    score_mean = sm, score_std = ssd, bb_mean = bm, bb_std = bsd,
    win_score_mean = w.score_mean, win_bb_mean = w.bb_mean, win_clash_mean = w.clash_mean,
    frac_H = w.frac_H, frac_E = w.frac_E, frac_L = w.frac_L,
    R1 = r1, R2 = r2, R3 = r3, R4 = r4, R5 = r5, R6 = r6,
  }
  table.insert(Stats.candidates, row)
  Stats.candidates = Stats._trim(Stats.candidates)
  -- bump candidates version and invalidate related caches
  Stats._candidatesVer = (Stats._candidatesVer or 0) + 1
  _invalidate_dispersion_caches()
end
function Stats.logShortFuzeTop(action, eventIx, selStart, selEnd, slotId, rank, shortScore, shortBB)
  if not Stats.enabled then return end
  -- reuse cached window aggregates for this event when available
  local w = (Stats._cache and Stats._cache.winAgg and Stats._cache.winAgg[eventIx])
  if not w then
    w = _win_agg(selStart, selEnd)
    Stats._cache = Stats._cache or {}
    Stats._cache.winAgg = Stats._cache.winAgg or {}
    Stats._cache.winAgg[eventIx] = w
  end
  local row = {
    event_ix = eventIx or 0, action = action or "",
    start = selStart or 0, finish = selEnd or 0, len = w.len or 0,
    slot = slotId or 0, rank = rank or 0,
    short_score = shortScore or 0, short_bb = shortBB or 0,
    win_score_mean = w.score_mean, win_bb_mean = w.bb_mean, win_clash_mean = w.clash_mean,
    frac_H = w.frac_H, frac_E = w.frac_E, frac_L = w.frac_L,
  }
  table.insert(Stats.short, row)
  Stats.short = Stats._trim(Stats.short)
end
function Stats.logShortFuzeCand(action, eventIx, selStart, selEnd, preRank, slotId, shortScore, shortBB, preScore, subsTotal, shortDelta, preBB, draftScore, draftBB, stdRankSum)
  if not Stats.enabled then return end
  local row = {
    event_ix=eventIx, action=action, start=selStart, finish=selEnd, len=(selEnd-selStart+1),
    pre_rank=preRank, slot=slotId, short_score=shortScore, short_bb=shortBB,
  }
  if preScore ~= nil then row.pre_score = preScore end
  if subsTotal ~= nil then row.subs_total = subsTotal end
  if shortDelta ~= nil then row.short_delta = shortDelta else
    if preScore ~= nil and shortScore ~= nil then row.short_delta = (shortScore or 0) - (preScore or 0) end
  end
  if preBB ~= nil then row.pre_bb = preBB end
  if draftScore ~= nil then row.draft_score = draftScore end
  if draftBB ~= nil then row.draft_bb = draftBB end
  if stdRankSum ~= nil then row.std_rank_sum = stdRankSum end
  table.insert(Stats.shortCandidates, row)
  Stats.shortCandidates = Stats._trim(Stats.shortCandidates)
  -- bump short-candidate version and invalidate syn caches
  Stats._shortVer = (Stats._shortVer or 0) + 1
  _invalidate_syn_caches()
end
function Stats.logFinalFuze(action, eventIx, selStart, selEnd, bestSlot, shortBest, finalScore, success, conv_h, conv_e, conv_h_cnt, conv_e_cnt, event_delta)
  if not Stats.enabled then return end
  local row = {
    event_ix = eventIx or 0, action = action or "",
    start = selStart or 0, finish = selEnd or 0, len = (selEnd or 0) - (selStart or 0) + 1,
    best_slot = bestSlot or 0, short_best = shortBest or 0, final_score = finalScore or 0,
    success = success and 1 or 0,
    conv_h = (conv_h and 1) or 0,
    conv_e = (conv_e and 1) or 0,
    conv_h_cnt = conv_h_cnt or 0,
    conv_e_cnt = conv_e_cnt or 0,
    event_delta = event_delta or 0,
  }
  table.insert(Stats.final, row)
  Stats.final = Stats._trim(Stats.final)
end

-- Log per-event success window stats: per-segment success counts and edge/interior delta sums
function Stats.logSuccessWindow(selStart, selEnd, segBefore)
  if not Stats.enabled then return end
  for i = selStart, selEnd do
    Stats.segmentSuccessCount[i] = (Stats.segmentSuccessCount[i] or 0) + 1
  end
end
function Stats.clear()
  Stats.candidates = {}
  Stats.short = {}
  Stats.final = {}
  Stats.shortCandidates = {}
  Stats.subscoreRecords = {}
  Stats.aaRecords = {}
  -- reset per-segment aggregates
  Stats.segmentAttemptCount = {}
  Stats.segmentSuccessCount = {}
  Stats.segmentIneffCount = {}
  Stats.segmentBBVarSum = {}
  Stats.segmentBBVarCount = {}
  Stats.constSubscoreParts = {}
  -- reset AA cache (in case of reloads)
  Stats._aa3_cache = nil
  -- reset versions and caches
  Stats._candidatesVer = 0
  Stats._shortVer = 0
  Stats._cache = { lenDisp = nil, segDispLN = nil, synByEvent = nil, synWeights = nil, winAgg = nil }
  print("[Stats] cleared")
end
local function _printRows(rows, header, fields, limit)
  limit = limit or #rows
  if limit > #rows then limit = #rows end
  print(header)
  for i = math.max(1, #rows - limit + 1), #rows do
    local r = rows[i]
    local parts = {}
    for _, f in ipairs(fields) do parts[#parts+1] = _fmt(r[f]) end
    print(table.concat(parts, ", "))
  end
  if #rows == 0 then print("<empty>") end
end
function Stats.printData(kind, limit)
  if kind == "candidates" then
    _printRows(Stats.candidates,
      "event,action,start,end,len,pre,cn,score_m,score_s,bb_m,bb_s,win_s,win_bb,win_clash,H,E,L,R1,R2,R3,R4,R5,R6",
      {"event_ix","action","start","finish","len","pre_score","cand_n","score_mean","score_std","bb_mean","bb_std","win_score_mean","win_bb_mean","win_clash_mean","frac_H","frac_E","frac_L","R1","R2","R3","R4","R5","R6"},
      limit)
  elseif kind == "short" then
    _printRows(Stats.short,
      "event,action,start,end,len,slot,rank,short_score,short_bb,win_s,win_bb,win_clash,H,E,L",
      {"event_ix","action","start","finish","len","slot","rank","short_score","short_bb","win_score_mean","win_bb_mean","win_clash_mean","frac_H","frac_E","frac_L"},
      limit)
  elseif kind == "final" then
    _printRows(Stats.final,
      "event,action,start,end,len,best_slot,short_best,final,success",
      {"event_ix","action","start","finish","len","best_slot","short_best","final_score","success"},
      limit)
  else
    print("[Stats] unknown kind: "..tostring(kind))
  end
end
local function _avg(rows, field)
  local s=0; local n=0
  for i=1,#rows do local v=rows[i][field]; if type(v)=="number" then s=s+v; n=n+1 end end
  if n==0 then return 0 end
  return s/n
end
local function _avgAAFractions()
  local sums = {}; local cnt = 0
  for _,r in ipairs(Stats.aaRecords or {}) do
    if r.aa_total then
      for k,v in pairs(r.aa_total) do sums[k] = (sums[k] or 0) + (v or 0) end
      cnt = cnt + 1
    end
  end
  local items = {}
  if cnt > 0 then
    for k,v in pairs(sums) do table.insert(items, {k, v/cnt}) end
    table.sort(items, function(a,b) return (a[2] or 0) > (b[2] or 0) end)
  end
  return items
end
function Stats.printSummary()
  print("[Stats] summary:")
  local cAvg = _avg(Stats.candidates, "score_std")
  local bAvg = _avg(Stats.candidates, "bb_std")
  print(string.format(" candidates: %d (score_std avg=%s, bb_std avg=%s)", #Stats.candidates, _fmt(cAvg), _fmt(bAvg)))
  local shortAvg = _avg(Stats.short, "short_score")
  print(string.format(" short:      %d (short_score avg=%s)", #Stats.short, _fmt(shortAvg)))
  local succPct = 100 * _avg(Stats.final, "success")
  print(string.format(" final:      %d (success rate=%s%%)", #Stats.final, _fmt(succPct)))
  -- Segment-weighted success and effect size (Δ per segment | success) by SS type (H/E)
  do
    -- Build quick map: event_ix -> estimated total H/E segments in the window (pre-event)
    local evHE = {}
    for _,c in ipairs(Stats.candidates or {}) do
      if c and c.event_ix then
        local h = 0; local e = 0
        local len = c.len or 0
        if c.frac_H then h = len * c.frac_H end
        if c.frac_E then e = len * c.frac_E end
        -- round to nearest int for counts
        local function rint(x) return math.floor((x or 0) + 0.5) end
        evHE[c.event_ix] = {h = rint(h), e = rint(e), len = len}
      end
    end

    local Hseg, Hsucc = 0, 0
    local Eseg, Esucc = 0, 0
    local HnSeg, HnSucc = 0, 0 -- non-converted H segments
    local EnSeg, EnSucc = 0, 0 -- non-converted E segments
    -- conditional deltas per segment
    local HsegSuccCnt, HsegSuccDelta = 0, 0
    local HsegFailCnt, HsegFailDelta = 0, 0
    local EsegSuccCnt, EsegSuccDelta = 0, 0
    local EsegFailCnt, EsegFailDelta = 0, 0
    local HnSegSuccCnt, HnSegSuccDelta = 0, 0
    local HnSegFailCnt, HnSegFailDelta = 0, 0
    local EnSegSuccCnt, EnSegSuccDelta = 0, 0
    local EnSegFailCnt, EnSegFailDelta = 0, 0
    for _,r in ipairs(Stats.final or {}) do
      local s = (r.success or 0)
      local hc = r.conv_h_cnt or 0
      local ec = r.conv_e_cnt or 0
      local d = r.event_delta or 0
      Hseg = Hseg + hc; Hsucc = Hsucc + hc * s
      Eseg = Eseg + ec; Esucc = Esucc + ec * s
      if s == 1 then
        HsegSuccCnt = HsegSuccCnt + hc; HsegSuccDelta = HsegSuccDelta + hc * d
        EsegSuccCnt = EsegSuccCnt + ec; EsegSuccDelta = EsegSuccDelta + ec * d
      else
        HsegFailCnt = HsegFailCnt + hc; HsegFailDelta = HsegFailDelta + hc * d
        EsegFailCnt = EsegFailCnt + ec; EsegFailDelta = EsegFailDelta + ec * d
      end
      local he = evHE[r.event_ix]
      if he then
        local htot = math.max(0, (he.h or 0))
        local etot = math.max(0, (he.e or 0))
        local hnc = math.max(0, htot - hc)
        local enc = math.max(0, etot - ec)
        HnSeg = HnSeg + hnc; HnSucc = HnSucc + hnc * s
        EnSeg = EnSeg + enc; EnSucc = EnSucc + enc * s
        if s == 1 then
          HnSegSuccCnt = HnSegSuccCnt + hnc; HnSegSuccDelta = HnSegSuccDelta + hnc * d
          EnSegSuccCnt = EnSegSuccCnt + enc; EnSegSuccDelta = EnSegSuccDelta + enc * d
        else
          HnSegFailCnt = HnSegFailCnt + hnc; HnSegFailDelta = HnSegFailDelta + hnc * d
          EnSegFailCnt = EnSegFailCnt + enc; EnSegFailDelta = EnSegFailDelta + enc * d
        end
      end
    end
    -- Duplicate convert/no-conv summary removed; detailed version remains in Stats.analyzeLoopSeg().
  end
  local aa = _avgAAFractions()
  if #aa > 0 then
    local n = math.min(3, #aa)
    local parts = {}
    for i=1,n do parts[#parts+1] = tostring(aa[i][1]).."=".._fmt(aa[i][2]) end
    print(" top AA: "..table.concat(parts, ", "))
  end
end
-- Analyses
local function _event_success_map()
  local m = {}
  for _,r in ipairs(Stats.final) do m[r.event_ix] = r.success end
  return m
end
function Stats.analyzeSubscores()
  if not (Stats.scoreParts and #Stats.scoreParts>0) then print("[Stats] no scoreParts"); return end
  local evSuc = _event_success_map()
  local xs = {}; local ys = {}
  local acc = {}
  for j,name in ipairs(Stats.scoreParts) do
    local function corrOf(getarr)
      xs, ys = {}, {}
      for _, rec in ipairs(Stats.subscoreRecords) do
        local arr = getarr(rec)
        local s = arr and arr[j] or nil
        local y = evSuc[rec.event_ix]
        -- skip events where this part is constant across candidates
        local skip = false
        local ev = rec.event_ix
        if Stats.constSubscoreParts and Stats.constSubscoreParts[ev] and Stats.constSubscoreParts[ev][j] then skip = true end
        if (not skip) and s and y~=nil then table.insert(xs, s); table.insert(ys, y) end
      end
      return _pearson(xs, ys)
    end
    local rW = corrOf(function(r) return r.subs_win end)
    local rE = corrOf(function(r) return r.subs_edge end)
    local rI = corrOf(function(r) return r.subs_int end)
    local mr = math.max(math.abs(rW or 0), math.abs(rE or 0), math.abs(rI or 0))
    acc[#acc+1] = {name=tostring(name), rW=rW, rE=rE, rI=rI, mr=mr}
  end
  table.sort(acc, function(a,b) return (a.mr or 0) > (b.mr or 0) end)
  print("[Stats] Pearson corr for subscores vs success (win / edge / interior):")
  for _,it in ipairs(acc) do
    print(string.format("  %-20s %.3f / %.3f / %.3f", it.name, it.rW or 0, it.rE or 0, it.rI or 0))
  end
end
function Stats.analyzeAA()
  local evSuc = _event_success_map(); local aas = {}
  -- collect set of AAs observed
  for _,r in ipairs(Stats.aaRecords) do
    for k,_ in pairs(r.aa_total or {}) do aas[k]=true end
  end
  -- total fractions
  do
    local acc = {}
    for aa,_ in pairs(aas) do
      local xs, ys = {}, {}
      for _,rec in ipairs(Stats.aaRecords) do
        local x = (rec.aa_total and rec.aa_total[aa]) or 0
        local y = evSuc[rec.event_ix]
        if y~=nil then table.insert(xs, x); table.insert(ys, y) end
      end
      local r = _pearson(xs, ys)
      acc[#acc+1] = {aa=aa, r=r, ar=math.abs(r or 0)}
    end
    table.sort(acc, function(a,b) return (a.ar or 0) > (b.ar or 0) end)
    print("[Stats] Pearson corr AA fraction (total) vs success:")
    for _,it in ipairs(acc) do
      print(string.format("  %-4s r=%.3f", it.aa, it.r or 0))
    end
  end
  -- edge fractions
  do
    local acc = {}
    for aa,_ in pairs(aas) do
      local xs_int, ys_int = {}, {}
      local xs_border, ys_border = {}, {}
      local xs_b1, ys_b1 = {}, {}
      for _,rec in ipairs(Stats.aaRecords) do
        local y = evSuc[rec.event_ix]
        if y ~= nil then
          local s = tonumber(rec.start or 0) or 0
          local e = tonumber(rec.finish or 0) or 0
          local len = tonumber(rec.len or ((e>=s) and (e-s+1) or 0)) or 0

          -- interior fraction: use precomputed aa_int, only if len>=3
          if len >= 3 then
            local xi = (rec.aa_int and rec.aa_int[aa]) or 0
            table.insert(xs_int, xi); table.insert(ys_int, y)
          end

          -- border fraction: reuse precomputed true-edge composition
          if len >= 1 and s > 0 and e >= s then
            local xb = (rec.aa_edge and rec.aa_edge[aa]) or 0
            table.insert(xs_border, xb); table.insert(ys_border, y)
          end

          -- border+1 fraction: positions start+1 and end-1, only if len>4 (uses cached _get_aa3)
          if len > 4 then
            local p1 = s + 1
            local p2 = e - 1
            local cnt2 = 0
            if _get_aa3(p1) == aa then cnt2 = cnt2 + 1 end
            if _get_aa3(p2) == aa then cnt2 = cnt2 + 1 end
            local xb1 = cnt2 / 2
            table.insert(xs_b1, xb1); table.insert(ys_b1, y)
          end
        end
      end

      local rI = _pearson(xs_int, ys_int)
      local rB = _pearson(xs_border, ys_border)
      local rB1 = _pearson(xs_b1, ys_b1)
      -- sort by decreasing correlation (take the best among the three)
      local key = math.max(rI or -1e18, rB or -1e18, rB1 or -1e18)
      acc[#acc+1] = {aa=aa, rI=rI, rB=rB, rB1=rB1, key=key}
    end
    table.sort(acc, function(a,b) return (a.key or -1e18) > (b.key or -1e18) end)
    print("[Stats] AA position in selection vs success (interior / border / border+1):")
    for _,it in ipairs(acc) do
      print(string.format("  %-4s %.3f / %.3f / %.3f", it.aa, it.rI or 0, it.rB or 0, it.rB1 or 0))
    end
  end
end
function Stats.analyzeSS()
  local evSuc = _event_success_map()
  local function corr(getx)
    local xs, ys = {}, {}
    for _,rec in ipairs(Stats.aaRecords) do
      local x = getx(rec)
      local y = evSuc[rec.event_ix]
      if x~=nil and y~=nil then table.insert(xs, x); table.insert(ys, y) end
    end
    return _pearson(xs, ys)
  end
  print(string.format("[Stats] SS corr: H=%.3f E=%.3f L=%.3f",
    corr(function(r) return r.frac_H end),
    corr(function(r) return r.frac_E end),
    corr(function(r) return r.frac_L end)))
end
function Stats.analyzeVariability()
  local evSuc = _event_success_map(); local xs, ys = {}, {}
  for _,row in ipairs(Stats.candidates) do
    local y = evSuc[row.event_ix]
    if y~=nil then table.insert(xs, row.bb_std or 0); table.insert(ys, y) end
  end
  print(string.format("[Stats] Corr(bb_std across candidates, success) = %.3f", _pearson(xs, ys)))
end
function Stats.analyzeSegVarVsSuccess()
  local xs, ys = {}, {}
  local disp_ln = Stats._segmentDispersionAveragesLenNorm and Stats._segmentDispersionAveragesLenNorm() or {}
  for i=1,(Stats.proteinLength or 0) do
    local a = Stats.segmentAttemptCount[i] or 0
    local s = Stats.segmentSuccessCount[i] or 0
    local v = disp_ln[i] or 0
    if a>0 and v~=0 then
      table.insert(xs, v)            -- length-normalized avg dispersion
      table.insert(ys, s / a)        -- segment success rate
    end
  end
  if #xs==0 then print("[Stats] No segment data"); return end
  print(string.format("[Stats] Corr(len-norm bb_disp per seg, seg success rate) = %.3f", _pearson(xs, ys)))
end

-- Correlate within-window per-segment BB std (mean-centered) with segment success rate
function Stats.analyzeSegVarWithinVsSuccess()
  local xs, ys = {}, {}
  local n = Stats.proteinLength or proteinLength or 0
  for i=1,n do
    local a = Stats.segmentAttemptCount[i] or 0
    local s = Stats.segmentSuccessCount[i] or 0
    local sum = (Stats.segmentBBVarSum and Stats.segmentBBVarSum[i]) or 0
    local cnt = (Stats.segmentBBVarCount and Stats.segmentBBVarCount[i]) or 0
    local v = (cnt > 0 and sum > 0) and math.sqrt(sum / cnt) or 0
    if a>0 and v~=0 then
      table.insert(xs, v)            -- per-segment within-window std
      table.insert(ys, s / a)        -- segment success rate
    end
  end
  if #xs==0 then print("[Stats] No per-segment within-window BB data"); return end
  print(string.format("[Stats] Corr(per-seg BB std within window, seg success rate) [L-corrected] = %.3f", _pearson(xs, ys)))
end

-- Correlate per-segment rank inefficiency with per-segment dispersion metrics
-- Rank inefficiency map: fraction of events where pre-rank #1 did NOT win short-fuse (non-top1 short-win / attempts)
-- Dispersion metrics:
--   (1) Length-normalized avg dispersion per segment (across events): Stats._segmentDispersionAveragesLenNorm()
--   (2) Within-window per-seg BB std (mean-centered, L-corrected): Stats._segmentBBStdWithinLcorrMap()
function Stats.analyzeInefficiencyCorr(minAttempts)
  local N = Stats.proteinLength or proteinLength or 0
  if N <= 0 then print("[Stats] IneffCorr: no protein length"); return end
  local minA = tonumber(minAttempts) or 1

  local ineff = (Stats._segmentRankInefficiencyMap and Stats._segmentRankInefficiencyMap()) or {}
  local disp_ln = (Stats._segmentDispersionAveragesLenNorm and Stats._segmentDispersionAveragesLenNorm()) or {}
  local within  = (Stats._segmentBBStdWithinLcorrMap and Stats._segmentBBStdWithinLcorrMap()) or {}

  local xs0, ys0 = {}, {}  -- ineff vs seg success rate
  local xs1, ys1 = {}, {}  -- ineff vs len-norm seg dispersion
  local xs2, ys2 = {}, {}  -- ineff vs within-window seg std

  for i=1,N do
    local a = (Stats.segmentAttemptCount and Stats.segmentAttemptCount[i]) or 0
    if a >= minA then
      local r = ineff[i] or 0
      local s = (Stats.segmentSuccessCount and Stats.segmentSuccessCount[i]) or 0
      xs0[#xs0+1], ys0[#ys0+1] = r, ((a>0) and (s/a) or 0)
      local d = disp_ln[i] or 0
      if d ~= 0 then xs1[#xs1+1], ys1[#ys1+1] = r, d end
      local w = within[i] or 0
      if w ~= 0 then xs2[#xs2+1], ys2[#ys2+1] = r, w end
    end
  end

  if #xs0>0 then 
    print(string.format("[Stats] Corr(rank inefficiency per seg, seg success rate) [minA=%d] = %.3f  (segs=%d)", minA, _pearson(xs0, ys0), #xs0))
  else
    print("[Stats] IneffCorr: no segments for success-rate corr")
  end
  if #xs1>0 then
    print(string.format("[Stats] Corr(rank inefficiency per seg, len-norm bb_disp per seg) [minA=%d] = %.3f  (segs=%d)", minA, _pearson(xs1, ys1), #xs1))
  else
    print("[Stats] IneffCorr: no segments for len-norm dispersion")
  end
  if #xs2>0 then
    print(string.format("[Stats] Corr(rank inefficiency per seg, per-seg BB std within window) [L-corrected, minA=%d] = %.3f  (segs=%d)", minA, _pearson(xs2, ys2), #xs2))
  else
    print("[Stats] IneffCorr: no segments for within-window BB std")
  end
end
function Stats.analyzeRank()
  -- Evaluate how often pre-rank (SortByBackbone) top1 and pure BB top1 match the short-fuse winner
  local byEvent = Stats._syn_build_by_event()
  local tot, hitsPre, hitsBB = 0, 0, 0
  local hitsScore, hitsStd = 0, 0
  local mrrPre, mrrBB, mrrScore, mrrStd = 0, 0, 0, 0
  local totDraft, hitsDraft, mrrDraft = 0, 0, 0
  local totDraftBB, hitsDraftBB, mrrDraftBB = 0, 0, 0
  -- Final-fuse correlation prep: success map and per-metric arrays of 1/rank(final)
  local evSuccess = {}
  for _,fr in ipairs(Stats.final or {}) do evSuccess[fr.event_ix] = fr.success end
  local corrData = {
    pre = {xs={}, ys={}}, bb = {xs={}, ys={}}, score = {xs={}, ys={}},
    draft = {xs={}, ys={}}, draft_bb = {xs={}, ys={}}, std = {xs={}, ys={}}, syn = {xs={}, ys={}}
  }
  for ev, arr in pairs(byEvent) do
    if #arr >= 2 then -- meaningful only if >1
      tot = tot + 1
      -- find short-fuse winner slot without sorting
      local bestSlot, bestShort = nil, -1e18
      for _,x in ipairs(arr) do
        local s = tonumber(x.short_score or -1e18) or -1e18
        if s > bestShort then bestShort = s; bestSlot = x.slot end
      end
      local minPre, bestBB = 1e9, -1e18
      local preSlot, bbSlot = nil, nil
      local scoreSlot, scoreBest = nil, -1e18
      local stdSlot, stdBest = nil, -1e18
      local draftSlot, draftBest = nil, -1e18
      local draftBBSlo, draftBBBest = nil, -1e18
      for _,x in ipairs(arr) do
        local pr = x.pre_rank or 1e9
        if pr < minPre then minPre = pr; preSlot = x.slot end
        local pb = tonumber(x.pre_bb or -1e18) or -1e18
        if pb > bestBB then bestBB = pb; bbSlot = x.slot end
        local ps = tonumber(x.pre_score or -1e18) or -1e18
        if ps > scoreBest then scoreBest = ps; scoreSlot = x.slot end
        local st = tonumber(x.std_rank_sum or -1e18) or -1e18
        if st > stdBest then stdBest = st; stdSlot = x.slot end
        local ds = x.draft_score
        if type(ds) == "number" and ds > draftBest then draftBest = ds; draftSlot = x.slot end
        local dbb = x.draft_bb
        if type(dbb) == "number" and dbb > draftBBBest then draftBBBest = dbb; draftBBSlo = x.slot end
      end
      if preSlot ~= nil and bestSlot ~= nil and preSlot == bestSlot then hitsPre = hitsPre + 1 end
      if bbSlot  ~= nil and bestSlot ~= nil and bbSlot  == bestSlot then hitsBB  = hitsBB  + 1 end
      if scoreSlot ~= nil and bestSlot ~= nil and scoreSlot == bestSlot then hitsScore = hitsScore + 1 end
      if stdSlot ~= nil and bestSlot ~= nil and stdSlot == bestSlot then hitsStd = hitsStd + 1 end
      if draftSlot ~= nil then
        totDraft = totDraft + 1
        if bestSlot ~= nil and draftSlot == bestSlot then hitsDraft = hitsDraft + 1 end
      end
      if draftBBSlo ~= nil then
        totDraftBB = totDraftBB + 1
        if bestSlot ~= nil and draftBBSlo == bestSlot then hitsDraftBB = hitsDraftBB + 1 end
      end

  -- MRR: reciprocal rank of the true winner under each ranking
  local function shallow_copy(a)
        local b = {}
        for i=1,#a do b[i] = a[i] end
        return b
      end
      local function find_rank_by(arr2, keyfn, desc)
        table.sort(arr2, function(a,b)
          local ka = keyfn(a) or 0; local kb = keyfn(b) or 0
          if desc then return ka > kb else return ka < kb end
        end)
        for i,x in ipairs(arr2) do if x.slot == bestSlot then return i end end
        return nil
      end
      do
        local copy = shallow_copy(arr)
        local r = find_rank_by(copy, function(x) return x.pre_rank end, false)
        if r and r>0 then mrrPre = mrrPre + 1/r end
      end
      do
        local copy = shallow_copy(arr)
        local r = find_rank_by(copy, function(x)
          local v = x.pre_bb
          if type(v) ~= "number" then return -1e18 end
          return v
        end, true)
        if r and r>0 then mrrBB = mrrBB + 1/r end
      end
      do
        local copy = shallow_copy(arr)
        local r = find_rank_by(copy, function(x) return tonumber(x.pre_score or -1e18) end, true)
        if r and r>0 then mrrScore = mrrScore + 1/r end
      end
      do
        local copy = shallow_copy(arr)
        local r = find_rank_by(copy, function(x)
          local v = x.std_rank_sum
          if type(v) ~= "number" then return -1e18 end
          return v
        end, true)
        if r and r>0 then mrrStd = mrrStd + 1/r end
      end
      do
        if draftSlot ~= nil then
          local copy = shallow_copy(arr)
          local r = find_rank_by(copy, function(x)
            local v = x.draft_score
            if type(v) ~= "number" then return -1e18 end
            return v
          end, true)
          if r and r>0 then mrrDraft = mrrDraft + 1/r end
        end
      end
      do
        if draftBBSlo ~= nil then
          local copy = shallow_copy(arr)
          local r = find_rank_by(copy, function(x)
            local v = x.draft_bb
            if type(v) ~= "number" then return -1e18 end
            return v
          end, true)
          if r and r>0 then mrrDraftBB = mrrDraftBB + 1/r end
        end
      end

      -- Correlation vs final success: use reciprocal rank of final winner under each ranking
      local success = evSuccess[ev]
      if success ~= nil then
        local function rank_of(arr2, keyfn, desc, targetSlot)
          table.sort(arr2, function(a,b)
            local ka = keyfn(a) or 0; local kb = keyfn(b) or 0
            if desc then return ka > kb else return ka < kb end
          end)
          for i,x in ipairs(arr2) do if x.slot == targetSlot then return i end end
          return nil
        end
        local finalSlot = nil
        -- find final winner slot from Stats.final
        -- (Stats.final has one row per event)
        for _,fr in ipairs(Stats.final or {}) do if fr.event_ix == ev then finalSlot = fr.best_slot; break end end
        if finalSlot ~= nil then
          -- pre
          do local copy = shallow_copy(arr); local r = rank_of(copy, function(x) return x.pre_rank end, false, finalSlot); if r and r>0 then table.insert(corrData.pre.xs, 1/r); table.insert(corrData.pre.ys, success) end end
          -- bb
          do local copy = shallow_copy(arr); local r = rank_of(copy, function(x) return tonumber(x.pre_bb or -1e18) end, true, finalSlot); if r and r>0 then table.insert(corrData.bb.xs, 1/r); table.insert(corrData.bb.ys, success) end end
          -- score
          do local copy = shallow_copy(arr); local r = rank_of(copy, function(x) return tonumber(x.pre_score or -1e18) end, true, finalSlot); if r and r>0 then table.insert(corrData.score.xs, 1/r); table.insert(corrData.score.ys, success) end end
          -- std
          do local copy = shallow_copy(arr); local r = rank_of(copy, function(x) return tonumber(x.std_rank_sum or -1e18) end, true, finalSlot); if r and r>0 then table.insert(corrData.std.xs, 1/r); table.insert(corrData.std.ys, success) end end
          -- draft (only if present)
          if draftSlot ~= nil then
            local copy = shallow_copy(arr)
            local r = rank_of(copy, function(x) return tonumber(x.draft_score or -1e18) end, true, finalSlot)
            if r and r>0 then table.insert(corrData.draft.xs, 1/r); table.insert(corrData.draft.ys, success) end
          end
          -- draft_bb (only if present)
          if draftBBSlo ~= nil then
            local copy = shallow_copy(arr)
            local r = rank_of(copy, function(x) return tonumber(x.draft_bb or -1e18) end, true, finalSlot)
            if r and r>0 then table.insert(corrData.draft_bb.xs, 1/r); table.insert(corrData.draft_bb.ys, success) end
          end
        end
      end
    end
  end
  -- Synthetic ranking based on subscore correlations (incremental training on past events)
  local totSyn, hitsSyn, mrrSyn = 0, 0, 0
  do
    local evs = _syn_sorted_event_keys(byEvent)
    for _,ev in ipairs(evs) do
      local arr = byEvent[ev]
      if arr and #arr >= 2 then
        local wts, used = Stats.syn_compute_weights(ev)
        if wts and used and used > 0 then
          -- find short-fuse winner without sorting
          local wslot, wbest = nil, -1e18
          for _,x in ipairs(arr) do
            local s = tonumber(x.short_score or -1e18) or -1e18
            if s > wbest then wbest = s; wslot = x.slot end
          end
          local top, order = _syn_rank_for_event(arr, wts)
          if top ~= nil then
            totSyn = totSyn + 1
            if wslot ~= nil and top == wslot then hitsSyn = hitsSyn + 1 end
            if order and wslot ~= nil then
              local rk = nil
              for i=1,#order do if order[i] == wslot then rk = i; break end end
              if rk and rk > 0 then mrrSyn = mrrSyn + 1/rk end
            end
            -- correlation with final success
            if order then
              local finalSlot = nil; for _,fr in ipairs(Stats.final or {}) do if fr.event_ix == ev then finalSlot = fr.best_slot; break end end
              local success = evSuccess[ev]
              if finalSlot ~= nil and success ~= nil then
                local rkf = nil; for i=1,#order do if order[i] == finalSlot then rkf = i; break end end
                if rkf and rkf > 0 then table.insert(corrData.syn.xs, 1/rkf); table.insert(corrData.syn.ys, success) end
              end
            end
          end
        end
      end
    end
  end
  local accPre = (tot>0) and (hitsPre/tot*100) or 0
  local accBB  = (tot>0) and (hitsBB /tot*100) or 0
  local accScore = (tot>0) and (hitsScore/tot*100) or 0
  local accStd = (tot>0) and (hitsStd/tot*100) or 0
  local mrrPreV = (tot>0) and (mrrPre/tot) or 0
  local mrrBBV = (tot>0) and (mrrBB/tot) or 0
  local mrrScoreV = (tot>0) and (mrrScore/tot) or 0
  local mrrStdV = (tot>0) and (mrrStd/tot) or 0
  local accDraft = (totDraft>0) and (hitsDraft/totDraft*100) or 0
  local mrrDraftV = (totDraft>0) and (mrrDraft/totDraft) or 0
  local accDraftBB = (totDraftBB>0) and (hitsDraftBB/totDraftBB*100) or 0
  local mrrDraftBBV = (totDraftBB>0) and (mrrDraftBB/totDraftBB) or 0
  local accSyn = (totSyn>0) and (hitsSyn/totSyn*100) or 0
  local mrrSynV = (totSyn>0) and (mrrSyn/totSyn) or 0
  print(string.format("[Stats] Short-fuze Top1 accuracy by ranking: pre=%.1f%%, bb=%.1f%%, score=%.1f%%, standard=%.1f%%, draft=%.1f%%, draft_bb=%.1f%%, syn=%.1f%%  (events=%d)", accPre, accBB, accScore, accStd, accDraft, accDraftBB, accSyn, tot))
  print(string.format("[Stats] Short-fuze MRR (1/position) by rank type: pre=%.3f, bb=%.3f, score=%.3f, standard=%.3f, draft=%.3f, draft_bb=%.3f, syn=%.3f", mrrPreV, mrrBBV, mrrScoreV, mrrStdV, mrrDraftV, mrrDraftBBV, mrrSynV))

  -- Correlation of each ranking’s reciprocal rank of the final winner with final success
  local rPre    = _pearson(corrData.pre.xs,      corrData.pre.ys)
  local rBB     = _pearson(corrData.bb.xs,       corrData.bb.ys)
  local rScore  = _pearson(corrData.score.xs,    corrData.score.ys)
  local rStd    = _pearson(corrData.std.xs,      corrData.std.ys)
  local rDraft  = _pearson(corrData.draft.xs,    corrData.draft.ys)
  local rDraftB = _pearson(corrData.draft_bb.xs, corrData.draft_bb.ys)
  local rSyn    = _pearson(corrData.syn.xs,     corrData.syn.ys)
  print(string.format("[Stats] Corr(1/rank_final, success): pre=%.3f, bb=%.3f, score=%.3f, standard=%.3f, draft=%.3f, draft_bb=%.3f, syn=%.3f", rPre or 0, rBB or 0, rScore or 0, rStd or 0, rDraft or 0, rDraftB or 0, rSyn or 0))

  -- Subscore leaders list moved to combined output (Stats.analyzeSubsCombined).
end

-- BB dispersion vs probability of final success (binary)
function Stats.analyzeVarFinalBins()
  local evX = Stats._eventLenNormBBStdMap()
  local xs, ys, idx = {}, {}, {}
  for _,r in ipairs(Stats.final or {}) do
    local x = evX[r.event_ix]
    if x ~= nil then
      xs[#xs+1] = x; ys[#ys+1] = (tonumber(r.success) or 0)
      idx[#idx+1] = #xs
    end
  end
  if #xs == 0 then
    print("[Stats] Var→Final: no data (need candidates+final)")
    return
  end
  print(string.format("[Stats] Corr(bb_std_norm, final success) = %.3f", _pearson(xs, ys)))
  -- Quantile bins (equal count)
  local nb = 4
  table.sort(idx, function(a,b) return xs[a] < xs[b] end)
  local function bin_bounds(b)
    local lo_i = math.floor((b-1) * #idx / nb) + 1
    local hi_i = (b == nb) and #idx or math.floor(b * #idx / nb)
    local lo = xs[idx[lo_i]]; local hi = xs[idx[hi_i]]
    return lo, hi, lo_i, hi_i
  end
  print("[Stats] P(final success) by bb_std_norm quantiles:")
  for b=1,nb do
    local lo, hi, lo_i, hi_i = bin_bounds(b)
    local n, s = 0, 0
    for k=lo_i,hi_i do local i = idx[k]; n = n + 1; s = s + (ys[i] or 0) end
    local p = (n>0) and (100*s/n) or 0
    print(string.format("  [%-6s .. %-6s]  P=%.1f%%  (n=%d)", _fmt(lo), _fmt(hi), p, n))
  end
end

-- Split event-level dispersion into directional (PC1) vs residual, and relate to success
function Stats.analyzeDispersionSplit()
  -- Build candidates by event
  local byEvent = {}
  for _,r in ipairs(Stats.shortCandidates or {}) do
    local t = byEvent[r.event_ix] or {}; byEvent[r.event_ix] = t; table.insert(t, r)
  end
  -- Map event -> success
  local evSuc = {}
  for _,r in ipairs(Stats.final or {}) do evSuc[r.event_ix] = r.success end
  -- Event -> window (start,finish)
  local evWin = {}
  for _,c in ipairs(Stats.candidates or {}) do evWin[c.event_ix] = {c.start or 1, c.finish or 0} end
  -- Hardness map and threshold (80th percentile)
  local disp_ln = Stats._segmentDispersionAveragesLenNorm and Stats._segmentDispersionAveragesLenNorm() or {}
  local vals = {}
  for i=1,(proteinLength or 0) do vals[#vals+1] = disp_ln[i] or 0 end
  table.sort(vals)
  local function perc(p)
    if #vals==0 then return 0 end
    local k = math.max(1, math.min(#vals, math.floor(p*#vals+0.5)))
    return vals[k]
  end
  local thr80 = perc(0.8)

  local function mean_std(vec)
    local n=#vec; if n==0 then return 0,0 end
    local s=0; for i=1,n do s=s+(vec[i] or 0) end
    local m=s/n; local v=0; for i=1,n do local d=(vec[i] or 0)-m; v=v+d*d end
    v=v/math.max(1,n-1); return m, math.sqrt(v)
  end
  local function corr(xs, ys)
    local n = math.min(#xs,#ys); if n<2 then return 0 end
    local mx, sx = mean_std(xs); local my, sy = mean_std(ys)
    if sx<=0 or sy<=0 then return 0 end
    local s=0; for i=1,n do s = s + ((xs[i]-mx)/sx)*((ys[i]-my)/sy) end
    return s/(n-1)
  end
  -- Power iteration for top eigen (EVR_PC1)
  local function top_evr(cov)
    local d = #cov; if d==0 then return 0, nil end
    local v={}; for i=1,d do v[i]=1/math.sqrt(d) end
    for it=1,20 do
      local nv={}; for i=1,d do local s=0; for j=1,d do s=s+(cov[i][j] or 0)*(v[j] or 0) end; nv[i]=s end
      local norm=0; for i=1,d do norm=norm+nv[i]*nv[i] end; norm=math.sqrt(math.max(1e-12,norm))
      for i=1,d do v[i]=nv[i]/norm end
    end
    local num=0; for i=1,d do local si=0; for j=1,d do si=si+(cov[i][j] or 0)*(v[j] or 0) end; num=num+v[i]*si end
    local tr=0; for i=1,d do tr=tr+(cov[i][i] or 0) end
    local evr = (tr>1e-12) and (num/tr) or 0
    return evr, v
  end

  local ySuc = {}
  local anis, vperp, gaps, frhard = {}, {}, {}, {}
  -- hotspot concentration per event (count above 80th percentile and share of top-2 among hotspot intensities)
  local hotcnt, top2share = {}, {}

  local parts = Stats.scoreParts or {}
  for ev, arr in pairs(byEvent) do
    if (arr and #arr>=2) and (evSuc[ev]~=nil) then
      local np = #parts; if np==0 then break end
      -- per-part mean/std in this event
      local mu, sd = {}, {}
      for j=1,np do mu[j]=0; sd[j]=0 end
      local n = #arr
      -- first pass: mean
      for _,c in ipairs(arr) do
        local a = c.subs_total
        if a then for j=1,np do mu[j] = mu[j] + (a[j] or 0) end end
      end
      for j=1,np do mu[j] = mu[j]/math.max(1,n) end
      -- second pass: std
      for _,c in ipairs(arr) do
        local a=c.subs_total
        if a then for j=1,np do local d=(a[j] or 0)-mu[j]; sd[j]=sd[j]+d*d end end
      end
      for j=1,np do sd[j] = (n>1) and math.sqrt(sd[j]/(n-1)) or 0 end
      -- Build covariance of z (skip parts with sd==0)
      local idxMap, d= {}, 0
      for j=1,np do if sd[j] and sd[j]>0 then d=d+1; idxMap[d]=j end end
      if d>=1 then
        local cov = {}; for i=1,d do cov[i]={}; for j=1,d do cov[i][j]=0 end end
        local zlist = {}
        for _,c in ipairs(arr) do
          local a=c.subs_total; local z={}
          if a then
            for p=1,d do local j=idxMap[p]; z[p] = ((a[j] or 0) - mu[j]) / sd[j] end
            table.insert(zlist, z)
            for p=1,d do for q=1,d do cov[p][q] = cov[p][q] + z[p]*z[q] end end
          end
        end
        local denom = math.max(1, (#zlist-1))
        for p=1,d do for q=1,d do cov[p][q] = cov[p][q] / denom end end
        local evr, v = top_evr(cov)
        -- anisotropy = EVR_PC1; var_perp = 1 - EVR
        local an = evr or 0; local vp = (evr and (1-evr)) or 0
        -- gap_top along PC1
        local proj = {}
        for k=1,#zlist do
          local s=0; for p=1,d do s = s + (zlist[k][p] or 0) * (v[p] or 0) end
          proj[#proj+1] = s
        end
        table.sort(proj)
        local function median(t)
          local m=#t; if m==0 then return 0 end
          if (m%2)==1 then return t[(m+1)/2] else return 0.5*(t[m/2]+t[m/2+1]) end
        end
        local gap = 0
        if #proj>0 then gap = proj[#proj] - median(proj) end
        -- frac_hard in window and hotspot concentration
        local fh = 0
        do
          local w = evWin[ev]
          if w and (w[2] or 0) >= (w[1] or 1) then
            local s = math.max(1, w[1] or 1); local e = math.min(proteinLength or 0, w[2] or 0)
            local L = math.max(1, e - s + 1)
            local hc = 0
            local hv = {}
            for i=s,e do
              local v = disp_ln[i] or 0
              if v >= thr80 then hc = hc + 1; hv[#hv+1] = v end
            end
            fh = hc / L
            -- hotspot concentration: share of top-2 hotspot intensities among all hotspots in the window
            local t2s = 0
            if #hv > 0 then
              table.sort(hv, function(a,b) return (a or 0) > (b or 0) end)
              local tot = 0; for _,vv in ipairs(hv) do tot = tot + (vv or 0) end
              local top2 = (hv[1] or 0) + (hv[2] or 0)
              t2s = (tot > 0) and (top2 / tot) or 1
            else
              t2s = 0
            end
            hotcnt[#hotcnt+1] = hc
            top2share[#top2share+1] = t2s
          end
        end
        -- collect
        ySuc[#ySuc+1] = evSuc[ev] or 0
        anis[#anis+1] = an
        vperp[#vperp+1] = vp
        gaps[#gaps+1] = gap
        frhard[#frhard+1] = fh
      end
    end
  end
  local nE = #ySuc
  if nE == 0 then print("[Stats] Dispersion split: no data"); return end
  -- Correlations
  print(string.format("[Stats] Dispersion split (events=%d):", nE))
  print(string.format("  Corr(anisotropy, success) = %.3f", corr(anis, ySuc)))
  print(string.format("  Corr(var_perp, success)  = %.3f", corr(vperp, ySuc)))
  print(string.format("  Corr(gap_top, success)   = %.3f", corr(gaps, ySuc)))
  -- Quantiles by anisotropy
  local xs, ys = {}, {}
  for i=1,nE do xs[i]=anis[i] or 0; ys[i]=ySuc[i] or 0 end
  local idx = {}; for i=1,nE do idx[i]=i end
  table.sort(idx, function(a,b) return xs[a] < xs[b] end)
  local nb = 4
  print("[Stats] P(final success) by anisotropy quantiles:")
  for b=1,nb do
    local lo_i = math.floor((b-1) * nE / nb) + 1
    local hi_i = (b == nb) and nE or math.floor(b * nE / nb)
    local lo = xs[idx[lo_i]]; local hi = xs[idx[hi_i]]
    local cnt, sum = 0, 0
    for k=lo_i,hi_i do local i0 = idx[k]; cnt = cnt + 1; sum = sum + (ys[i0] or 0) end
    local p = (cnt>0) and (100*sum/cnt) or 0
    print(string.format("  [%-6s .. %-6s]  P=%.1f%%  (n=%d)", _fmt(lo), _fmt(hi), p, cnt))
  end
  -- 2x2: anisotropy (median) x frac_hard (median)
  local function median_of(t)
    local a={}; for i=1,#t do a[i]=t[i] or 0 end
    table.sort(a); local m=#a; if m==0 then return 0 end
    if (m%2)==1 then return a[(m+1)/2] else return 0.5*(a[m/2]+a[m/2+1]) end
  end
  local an_med = median_of(anis)
  local fh_med = median_of(frhard)
  local bins = {ll={n=0,s=0}, lh={n=0,s=0}, hl={n=0,s=0}, hh={n=0,s=0}}
  for i=1,nE do
    local a = (anis[i] or 0) >= an_med
    local f = (frhard[i] or 0) > fh_med
    local key = (a and f) and 'hh' or (a and not f) and 'hl' or (not a and f) and 'lh' or 'll'
    bins[key].n = bins[key].n + 1
    bins[key].s = bins[key].s + (ySuc[i] or 0)
  end
  local function pr(b) local n=b.n; local s=b.s; return (n>0) and (100*s/n) or 0 end
  print("[Stats] P(success) 2x2 (anisotropy×frac_hard):")
  print(string.format("  low aniso, low hard:  P=%.1f%% (n=%d)", pr(bins.ll), bins.ll.n))
  print(string.format("  high aniso, low hard: P=%.1f%% (n=%d)", pr(bins.hl), bins.hl.n))
  print(string.format("  low aniso, high hard: P=%.1f%% (n=%d)", pr(bins.lh), bins.lh.n))
  print(string.format("  high aniso, high hard: P=%.1f%% (n=%d)", pr(bins.hh), bins.hh.n))
  -- Hotspot concentration summary
  do
    local function avg_of(t)
      local s=0; for i=1,#t do s=s+(t[i] or 0) end; return (#t>0) and (s/#t) or 0
    end
    local function median_of(t)
      local a={}; for i=1,#t do a[i]=t[i] or 0 end
      table.sort(a); local m=#a; if m==0 then return 0 end
      if (m%2)==1 then return a[(m+1)/2] else return 0.5*(a[m/2]+a[m/2+1]) end
    end
    local hc_avg, hc_med = avg_of(hotcnt), median_of(hotcnt)
    local t2_avg, t2_med = avg_of(top2share), median_of(top2share)
    print("[Stats] Hotspot concentration (80p threshold):")
    print(string.format("  hot_count: avg=%s, median=%s", _fmt(hc_avg), _fmt(hc_med)))
    print(string.format("  top2_share among hotspots: avg=%s, median=%s", _fmt(t2_avg), _fmt(t2_med)))
  end
end

-- Segment-weighted success for convert-to-loop by SS type
function Stats.analyzeLoopSeg()
  -- Build event -> H/E total counts map from candidates
  local evHE = {}
  for _,c in ipairs(Stats.candidates or {}) do
    if c and c.event_ix then
      local len = c.len or 0
      local function rint(x) return math.floor((x or 0) + 0.5) end
      evHE[c.event_ix] = {
        h = rint(len * (c.frac_H or 0)),
        e = rint(len * (c.frac_E or 0)),
        len = len,
      }
    end
  end

  local Hseg, Hsucc = 0, 0
  local Eseg, Esucc = 0, 0
  local HnSeg, HnSucc = 0, 0
  local EnSeg, EnSucc = 0, 0
  -- conditional deltas per segment
  local HsegSuccCnt, HsegSuccDelta = 0, 0
  local HsegFailCnt, HsegFailDelta = 0, 0
  local EsegSuccCnt, EsegSuccDelta = 0, 0
  local EsegFailCnt, EsegFailDelta = 0, 0
  local HnSegSuccCnt, HnSegSuccDelta = 0, 0
  local HnSegFailCnt, HnSegFailDelta = 0, 0
  local EnSegSuccCnt, EnSegSuccDelta = 0, 0
  local EnSegFailCnt, EnSegFailDelta = 0, 0
  for _, r in ipairs(Stats.final or {}) do
    local s  = (r.success or 0)
    local hc = r.conv_h_cnt or 0
    local ec = r.conv_e_cnt or 0
    local d  = r.event_delta or 0
    Hseg = Hseg + hc; Hsucc = Hsucc + hc * s
    Eseg = Eseg + ec; Esucc = Esucc + ec * s
    if s == 1 then
      HsegSuccCnt = HsegSuccCnt + hc; HsegSuccDelta = HsegSuccDelta + hc * d
      EsegSuccCnt = EsegSuccCnt + ec; EsegSuccDelta = EsegSuccDelta + ec * d
    else
      HsegFailCnt = HsegFailCnt + hc; HsegFailDelta = HsegFailDelta + hc * d
      EsegFailCnt = EsegFailCnt + ec; EsegFailDelta = EsegFailDelta + ec * d
    end
    local he = evHE[r.event_ix]
    if he then
      local htot = math.max(0, (he.h or 0))
      local etot = math.max(0, (he.e or 0))
      local hnc = math.max(0, htot - hc)
      local enc = math.max(0, etot - ec)
      HnSeg = HnSeg + hnc; HnSucc = HnSucc + hnc * s
      EnSeg = EnSeg + enc; EnSucc = EnSucc + enc * s
      if s == 1 then
        HnSegSuccCnt = HnSegSuccCnt + hnc; HnSegSuccDelta = HnSegSuccDelta + hnc * d
        EnSegSuccCnt = EnSegSuccCnt + enc; EnSegSuccDelta = EnSegSuccDelta + enc * d
      else
        HnSegFailCnt = HnSegFailCnt + hnc; HnSegFailDelta = HnSegFailDelta + hnc * d
        EnSegFailCnt = EnSegFailCnt + enc; EnSegFailDelta = EnSegFailDelta + enc * d
      end
    end
  end
  print("[Stats] Convert-to-Loop (segment-weighted):")
  if Hseg > 0 then
    local pH = 100 * Hsucc / Hseg
    local eH  = (HsegSuccCnt > 0) and (HsegSuccDelta / HsegSuccCnt) or "n/a"
    local eHf = (HsegFailCnt > 0) and (HsegFailDelta / HsegFailCnt) or "n/a"
    print(string.format("  H convert:   %d seg (succ=%s%%, Δ/seg|succ=%s, Δ/seg|unsucc=%s)", Hseg, _fmt(pH), _fmt(eH), _fmt(eHf)))
  else
    print("  H convert:   0 seg")
  end
  if HnSeg > 0 then
    local pHn = 100 * HnSucc / HnSeg
    local eHn  = (HnSegSuccCnt > 0) and (HnSegSuccDelta / HnSegSuccCnt) or "n/a"
    local eHnf = (HnSegFailCnt > 0) and (HnSegFailDelta / HnSegFailCnt) or "n/a"
    print(string.format("  H no-conv:   %d seg (succ=%s%%, Δ/seg|succ=%s, Δ/seg|unsucc=%s)", HnSeg, _fmt(pHn), _fmt(eHn), _fmt(eHnf)))
  else
    print("  H no-conv:   0 seg")
  end
  if Eseg > 0 then
    local pE = 100 * Esucc / Eseg
    local eE  = (EsegSuccCnt > 0) and (EsegSuccDelta / EsegSuccCnt) or "n/a"
    local eEf = (EsegFailCnt > 0) and (EsegFailDelta / EsegFailCnt) or "n/a"
    print(string.format("  E convert:   %d seg (succ=%s%%, Δ/seg|succ=%s, Δ/seg|unsucc=%s)", Eseg, _fmt(pE), _fmt(eE), _fmt(eEf)))
  else
    print("  E convert:   0 seg")
  end
  if EnSeg > 0 then
    local pEn = 100 * EnSucc / EnSeg
    local eEn  = (EnSegSuccCnt > 0) and (EnSegSuccDelta / EnSegSuccCnt) or "n/a"
    local eEnf = (EnSegFailCnt > 0) and (EnSegFailDelta / EnSegFailCnt) or "n/a"
    print(string.format("  E no-conv:   %d seg (succ=%s%%, Δ/seg|succ=%s, Δ/seg|unsucc=%s)", EnSeg, _fmt(pEn), _fmt(eEn), _fmt(eEnf)))
  else
    print("  E no-conv:   0 seg")
  end
end
-- Print full set of correlation analyses (same as 'corr' note)
function Stats.printAllCorrelations()
  local function run(name, fn)
    local ok, err = pcall(fn)
    if not ok then print("[Stats] "..name.." failed: "..tostring(err)) end
  end
  if PrintRuleBars then pcall(PrintRuleBars) end
  if Stats.analyzeSubscores then run("analyzeSubscores", Stats.analyzeSubscores) end
  if Stats.analyzeRules then run("analyzeRules", Stats.analyzeRules) end
  if Stats.analyzeRank then run("analyzeRank", Stats.analyzeRank) end
  if Stats.analyzeAA then run("analyzeAA", Stats.analyzeAA) end
  if Stats.analyzeSubsCombined then run("analyzeSubsCombined", Stats.analyzeSubsCombined) end
  if Stats.analyzeSS then run("analyzeSS", Stats.analyzeSS) end
  if Stats.analyzeVariability then run("analyzeVariability", Stats.analyzeVariability) end
  if Stats.analyzeSegVarVsSuccess then run("analyzeSegVarVsSuccess", Stats.analyzeSegVarVsSuccess) end
  if Stats.analyzeSegVarWithinVsSuccess then run("analyzeSegVarWithinVsSuccess", Stats.analyzeSegVarWithinVsSuccess) end
  if Stats.analyzeInefficiencyCorr then run("analyzeInefficiencyCorr", Stats.analyzeInefficiencyCorr) end
  if Stats.analyzeDispersionSplit then run("analyzeDispersionSplit", Stats.analyzeDispersionSplit) end
  if Stats.analyzeLoopSeg then run("analyzeLoopSeg", Stats.analyzeLoopSeg) end
  if Stats.analyzeVarFinalBins then run("analyzeVarFinalBins", Stats.analyzeVarFinalBins) end
end

-- Unified output: per-subscore short-fuze Top1 accuracy (leaders) + correlation with final (is_final)
function Stats.analyzeSubsCombined()
  if not (Stats.scoreParts and #Stats.scoreParts>0) then print("[Stats] no scoreParts"); return end
  local parts = Stats.scoreParts
  -- Group candidates by event for accuracy metric
  local byEvent = {}
  for _,r in ipairs(Stats.shortCandidates or {}) do
    local t = byEvent[r.event_ix] or {}; byEvent[r.event_ix] = t; table.insert(t, r)
  end
  -- Accuracy by leaders per part
  local hits, tots = {}, {}
  local eventsUsed = 0
  for ev, arr in pairs(byEvent) do
    if #arr >= 2 then
      eventsUsed = eventsUsed + 1
      table.sort(arr, function(a,b) return (a.short_score or -1e9) > (b.short_score or -1e9) end)
      local bestSlot = arr[1] and arr[1].slot or nil
      for j=1,#parts do
        if not (Stats.constSubscoreParts and Stats.constSubscoreParts[ev] and Stats.constSubscoreParts[ev][j]) then
          local bestV = -1e18
          for _,x in ipairs(arr) do
            local a = x.subs_total; local v = (a and a[j]) or -1e18
            if v > bestV then bestV = v end
          end
          local win = false
          for _,x in ipairs(arr) do
            local a = x.subs_total; local v = (a and a[j]) or -1e18
            if math.abs(v - bestV) < 1e-12 and x.slot == bestSlot then win = true; break end
          end
          tots[j] = (tots[j] or 0) + 1; if win then hits[j] = (hits[j] or 0) + 1 end
        end
      end
    end
  end
  -- Correlation per part vs final selection (is_final)
  local corr = {}
  for j=1,#parts do
    local xs, ys = {}, {}
    for _,r in ipairs(Stats.shortCandidates or {}) do
      local a = r.subs_total; local y = (tonumber(r.is_final) or 0)
      local ev = r.event_ix
      local const = Stats.constSubscoreParts and Stats.constSubscoreParts[ev] and Stats.constSubscoreParts[ev][j]
      if (not const) and a and type(a[j])=="number" then
        xs[#xs+1] = a[j]; ys[#ys+1] = y
      end
    end
    local rv = _pearson(xs, ys)
    corr[j] = rv
  end
  -- Build and filter items (non-zero correlation only)
  local items = {}
  for j=1,#parts do
    local r = corr[j] or 0
    if r ~= 0 and r == r then
      local acc = 0
      if (tots[j] or 0) > 0 then acc = 100 * (hits[j] or 0) / (tots[j] or 1) end
      items[#items+1] = {name=tostring(parts[j]), acc=acc, r=r}
    end
  end
  table.sort(items, function(a,b)
    if (a.acc or 0) ~= (b.acc or 0) then return (a.acc or 0) > (b.acc or 0) end
    local ar = math.abs(a.r or 0); local br = math.abs(b.r or 0)
    if ar ~= br then return ar > br end
    return tostring(a.name) < tostring(b.name)
  end)
  print(string.format("[Stats] Short-fuze subscore metrics (events=%d):", eventsUsed))
  for _,it in ipairs(items) do
    print(string.format("  %-20s acc=%.1f%%  r=% .3f", it.name, it.acc or 0, it.r or 0))
  end
end

-- Analyze Rule contributions (R1..R6 window means) vs final success
function Stats.analyzeRules()
  local evSuc = _event_success_map()
  local rows = Stats.candidates or {}
  local rules = {"R1","R2","R3","R4","R5","R6"}
  local acc = {}
  local function mean_of(field, cond)
    local s, n = 0, 0
    for _,r in ipairs(rows) do
      local y = evSuc[r.event_ix]
      if y ~= nil and (cond==nil or cond(y)) then
        local v = tonumber(r[field] or 0) or 0
        s = s + v; n = n + 1
      end
    end
    if n==0 then return 0 end
    return s/n
  end
  for _,rk in ipairs(rules) do
    local xs, ys = {}, {}
    for _,r in ipairs(rows) do
      local y = evSuc[r.event_ix]
      if y ~= nil then
        xs[#xs+1] = tonumber(r[rk] or 0) or 0
        ys[#ys+1] = y
      end
    end
    local r = _pearson(xs, ys)
    local m1 = mean_of(rk, function(y) return y==1 end)
    local m0 = mean_of(rk, function(y) return y==0 end)
    acc[#acc+1] = {name=rk, r=r, ar=math.abs(r or 0), d=m1-m0}
  end
  table.sort(acc, function(a,b) return (a.ar or 0)>(b.ar or 0) end)
  print("[Stats] Rule window means vs final success (sorted by |r|):")
  for _,it in ipairs(acc) do
    print(string.format("  %-2s  r=% .3f  Δ=%.3f", it.name, it.r or 0, it.d or 0))
  end
end
-- Check that per-candidate total subscores vary across candidates for each part (flag constants)
function Stats.checkSubscoreVariability(eventIx, solutionSubscoresArray)
  if not solutionSubscoresArray or #solutionSubscoresArray == 0 then return end
  local parts = Stats.scoreParts or puzzle.GetPuzzleSubscoreNames() or {}
  if #parts == 0 then return end
  local ev = tonumber(eventIx) or 0
  if ev <= 0 then return end
  local map = {}
  for j, name in ipairs(parts) do
    local mn, mx = math.huge, -math.huge
    local seen = false
    for _, row in ipairs(solutionSubscoresArray) do
      local v = row and row[name]
      if type(v) == 'number' then
        seen = true
        if v < mn then mn = v end
        if v > mx then mx = v end
      end
    end
    if seen and not (mx > mn) then
      map[j] = true -- constant across candidates for this event
    end
  end
  Stats.constSubscoreParts[ev] = map
end
-- Mark short-candidate row as final for a given event and slot
function Stats.markFinalCandidate(eventIx, slotId)
  for _,r in ipairs(Stats.shortCandidates) do
    if r.event_ix == eventIx and r.slot == slotId then r.is_final = 1 end
  end
end
function Stats.onCleanup()
  if not Stats.enabled then return end
  if Stats._cleanup_ran then return end
  Stats._cleanup_ran = true
  -- Protect each section to avoid reentry if one fails
  local ok
  ok = pcall(Stats.printSummary); if not ok then print("[Stats] summary failed") end
  ok = pcall(Stats.printAllCorrelations); if not ok then print("[Stats] correlations failed") end
  ok = pcall(Stats.printAllMaps); if not ok then print("[Stats] maps failed") end
end
------------- End Stats -------------

----------------------------------------------------------
function Cleanup(err)
    print (err)
    currentScore=ScoreReturn()
	  behavior.SetClashImportance(endCI)
    undo.SetUndo(true) 

    if (currentScore > startScore) then save.Quicksave(98) 
    else save.Quickload(98)  end

	if (fuzeAfternoGain>=0) then  save.Quickload(98) end
    currentScore=ScoreReturn()
    
    if (currentScore > initScore) then
      print ("Total gain:", roundX(currentScore-initScore))
    else
      save.Quickload(1)
      print("No improve. Restored to "..ScoreReturn())
    end
      
	save.Quickload(1)
	save.Quickload(100)
	save.Quickload(98)

    -- Print stats snapshot on cleanup (once)
  if Stats and Stats.enabled and not Stats._cleanup_ran then Stats.onCleanup() end
    
  print (err)

    
  end

-------------------------------------------------------------

xpcall ( main , Cleanup )
