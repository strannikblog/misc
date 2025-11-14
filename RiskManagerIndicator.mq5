//+------------------------------------------------------------------+
//|                                         RiskManagerIndicator.mq5  |
//|                                    Risk Management Indicator       |
//|                                                                    |
//+------------------------------------------------------------------+
#property copyright "Risk Management Indicator"
#property link      ""
#property version   "1.0"
#property description "Dynamic risk management based on consecutive losses"
#property indicator_chart_window
#property indicator_plots   0

//+------------------------------------------------------------------+
//| Includes                                                         |
//+------------------------------------------------------------------+
// Note: No external dependencies - uses built-in MQL5 string operations

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Risk Management Settings ==="
input double inpMaxRiskPercent = 2.0;           // Maximum Risk %
input double inpMinRiskPercent = 0.5;           // Minimum Risk %
input double inpRiskReductionFactor = 0.5;      // Risk reduction (0.5 = 50%)
input double inpRecoveryThreshold = 0.5;        // Recovery threshold (0.5 = 50%)
input bool inpAutoDetectTrades = true;          // Auto-detect new closed trades

input group "=== Display Settings ==="
input color inpLabelBackgroundColor = C'240,240,240';  // Label background
input color inpLabelTextColor = C'50,50,50';            // Label text color
input int inpLabelCorner = CORNER_LEFT_UPPER;            // Panel corner position (0=LeftUpper,1=LeftLower,2=RightUpper,3=RightLower)
input int inpLabelX = 20;                               // X offset from corner edge
input int inpLabelY = 30;                               // Y offset from corner edge
input bool inpShowCompactDisplay = false;               // Compact format
input int inpFontSize = 9;                              // Font size

//+------------------------------------------------------------------+
//| Risk Manager State Structure                                    |
//+------------------------------------------------------------------+
struct RiskManagerState {
    double maxRiskPercent;        // User defined (e.g., 2.0)
    double minRiskPercent;        // User defined (e.g., 0.5)
    double currentRiskPercent;    // Current active risk (e.g., 1.0)
    double previousRiskPercent;   // Risk before last reduction
    double targetRiskPercent;     // Risk we're working towards
    int consecutiveLosses;        // Current loss streak
    double peakEquity;            // Equity before current DD started

    // Tiered recovery targets
    double recoveryTargetEquity;  // Current recovery target
    double tier1RecoveryTarget;   // Recovery target to go from 0.5% to 1%
    double tier2RecoveryTarget;   // Recovery target to go from 1% to 2%

    // Track which tiers are pending recovery
    bool needTier1Recovery;       // Need to recover to go from 0.5% to 1%
    bool needTier2Recovery;       // Need to recover to go from 1% to 2%

    // Cumulative profit tracking since last risk reduction
    double cumulativeProfitSinceRiskReduction; // Profit accumulator

    datetime lastTradeCloseTime;  // For tracking new trades
    ulong lastProcessedTicket;    // Avoid reprocessing same trades
    string accountNumber;         // Account identifier
    datetime lastUpdateTime;      // Last state update
};

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
RiskManagerState g_state;
string g_labelName = "RiskManagerLabel";
string g_buttonName = "RiskManagerResetButton";
bool g_initialized = false;

//+------------------------------------------------------------------+
//| Custom functions for state serialization                        |
//+------------------------------------------------------------------+
string StateToCsv(const RiskManagerState &state) {
    return StringFormat(
        "%.6f,%.6f,%.6f,%.6f,%.6f,%d,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%.2f,%llu,%s,%d",
        state.maxRiskPercent,
        state.minRiskPercent,
        state.currentRiskPercent,
        state.previousRiskPercent,
        state.targetRiskPercent,
        state.consecutiveLosses,
        state.peakEquity,
        state.recoveryTargetEquity,
        state.tier1RecoveryTarget,
        state.tier2RecoveryTarget,
        (int)state.needTier1Recovery,
        (int)state.needTier2Recovery,
        (int)state.lastTradeCloseTime,
        state.cumulativeProfitSinceRiskReduction,
        state.lastProcessedTicket,
        state.accountNumber,
        (int)state.lastUpdateTime
    );
}

bool CsvToState(const string csvStr, RiskManagerState &state) {
    string parts[];
    int count = StringSplit(csvStr, ',', parts);

    if(count != 17) {
        Print("❌ Invalid state file format. Expected 17 fields, got ", count);
        return false;
    }

    state.maxRiskPercent = StringToDouble(parts[0]);
    state.minRiskPercent = StringToDouble(parts[1]);
    state.currentRiskPercent = StringToDouble(parts[2]);
    state.previousRiskPercent = StringToDouble(parts[3]);
    state.targetRiskPercent = StringToDouble(parts[4]);
    state.consecutiveLosses = (int)StringToInteger(parts[5]);
    state.peakEquity = StringToDouble(parts[6]);
    state.recoveryTargetEquity = StringToDouble(parts[7]);
    state.tier1RecoveryTarget = StringToDouble(parts[8]);
    state.tier2RecoveryTarget = StringToDouble(parts[9]);
    state.needTier1Recovery = (StringToInteger(parts[10]) == 1);
    state.needTier2Recovery = (StringToInteger(parts[11]) == 1);
    state.lastTradeCloseTime = (datetime)StringToInteger(parts[12]);
    state.cumulativeProfitSinceRiskReduction = StringToDouble(parts[13]);
    state.lastProcessedTicket = StringToInteger(parts[14]);
    state.accountNumber = parts[15];
    state.lastUpdateTime = (datetime)StringToInteger(parts[16]);

    return true;
}

//+------------------------------------------------------------------+
//| File Operations                                                  |
//+------------------------------------------------------------------+
string GetStateFileName() {
    string account = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
    string company = StringSubstr(AccountInfoString(ACCOUNT_COMPANY), 0, 10);
    StringReplace(company, " ", "_");
    return "RiskManager_" + account + "_" + company + ".csv";
}

void SaveStateToFile(const RiskManagerState &state) {
    string filename = GetStateFileName();
    string csvStr = StateToCsv(state);

    int fileHandle = FileOpen(filename, FILE_WRITE | FILE_TXT | FILE_ANSI);
    if(fileHandle != INVALID_HANDLE) {
        FileWriteString(fileHandle, csvStr);
        FileClose(fileHandle);
        Print("✓ Risk manager state saved to ", filename);
    } else {
        Print("❌ Failed to save risk manager state to ", filename);
    }
}

bool LoadStateFromFile(RiskManagerState &state) {
    string filename = GetStateFileName();

    int fileHandle = FileOpen(filename, FILE_READ | FILE_TXT | FILE_ANSI);
    if(fileHandle != INVALID_HANDLE) {
        string csvStr = FileReadString(fileHandle);
        FileClose(fileHandle);

        if(CsvToState(csvStr, state)) {
            Print("✓ Risk manager state loaded from ", filename);
            return true;
        }
    }

    Print("ℹ No existing risk manager state found, will initialize new");
    return false;
}

//+------------------------------------------------------------------+
//| Risk Management Logic                                           |
//+------------------------------------------------------------------+
void InitializeState(RiskManagerState &state) {
    state.maxRiskPercent = inpMaxRiskPercent;
    state.minRiskPercent = inpMinRiskPercent;
    state.currentRiskPercent = inpMaxRiskPercent;
    state.targetRiskPercent = inpMaxRiskPercent;
    state.previousRiskPercent = inpMaxRiskPercent;
    state.consecutiveLosses = 0;
    state.peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    state.recoveryTargetEquity = state.peakEquity;
    state.tier1RecoveryTarget = state.peakEquity;
    state.tier2RecoveryTarget = state.peakEquity;
    state.needTier1Recovery = false;
    state.needTier2Recovery = false;
    state.cumulativeProfitSinceRiskReduction = 0.0; // Initialize profit accumulator
    state.lastTradeCloseTime = 0;
    state.lastProcessedTicket = 0;
    state.accountNumber = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
    state.lastUpdateTime = TimeCurrent();

    SaveStateToFile(state);
    Print("🆕 Risk manager initialized at ", state.maxRiskPercent, "% risk");
}

void ProcessNewTrades(RiskManagerState &state) {
    if(!inpAutoDetectTrades) return;

    // Get trade history
    HistorySelect(0, TimeCurrent());

    // Process new closed trades (reverse order to get newest first)
    for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
        ulong ticket = HistoryDealGetTicket(i);
        if(ticket == 0) continue;

        if(!HistoryDealSelect(ticket)) continue;

        // Skip if already processed
        if(ticket <= state.lastProcessedTicket) continue;

        // Check if it's a deal for current symbol and a closing deal
        string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
        long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);

        if(symbol != _Symbol) continue;
        if(entry != DEAL_ENTRY_OUT) continue; // Skip non-closing deals

        double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
        datetime closeTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

        Print("📊 Processing closed trade #", ticket, " P/L: $", profit);

        // Process trade result
        ProcessTradeResult(state, profit, closeTime);
        state.lastProcessedTicket = ticket;
    }

    // Check for recovery progress
    CheckRecoveryProgress(state);
}

void ProcessTradeResult(RiskManagerState &state, double profit, datetime closeTime) {
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);

    // Update peak equity (new high watermark)
    if(currentEquity > state.peakEquity) {
        state.peakEquity = currentEquity;
        Print("🏈 New equity peak: $", state.peakEquity);
    }

    if(profit < 0) {
        // Loss detected - reduce risk
        HandleLoss(state, profit, closeTime);
    } else if(profit > 0 && (state.needTier1Recovery || state.needTier2Recovery)) {
        // Profit detected while in recovery - accumulate profit
        state.cumulativeProfitSinceRiskReduction += profit;
        Print("💰 Profit +$", profit, " added to accumulator. Total: $", state.cumulativeProfitSinceRiskReduction);
    }

    state.lastTradeCloseTime = closeTime;
    state.lastUpdateTime = TimeCurrent();
}

void HandleLoss(RiskManagerState &state, double lossAmount, datetime closeTime) {
    state.consecutiveLosses++;

    Print("📉 Loss #", state.consecutiveLosses, " detected: -$", MathAbs(lossAmount));

    // Update peak equity (new high watermark)
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(currentEquity > state.peakEquity) {
        state.peakEquity = currentEquity;
        Print("🏈 New equity peak: $", state.peakEquity);
    }

    // Calculate new risk (reduce by 50%, but not below minimum)
    double newRisk = state.currentRiskPercent * inpRiskReductionFactor;
    if(newRisk < state.minRiskPercent) newRisk = state.minRiskPercent;

    if(newRisk < state.currentRiskPercent) {
        state.previousRiskPercent = state.currentRiskPercent;
        state.currentRiskPercent = newRisk;

        // Reset profit accumulator when risk is reduced
        state.cumulativeProfitSinceRiskReduction = 0.0;
        Print("💰 Profit accumulator reset to $0 (risk reduced)");

        // Calculate DD caused by this specific risk level
        double tierDD = state.peakEquity - currentEquity;
        double recoveryAmount = tierDD * inpRecoveryThreshold;

        // Set recovery targets based on which risk tier we just dropped from
        if(state.previousRiskPercent == state.maxRiskPercent && state.currentRiskPercent < state.maxRiskPercent) {
            // Dropped from 2% → lower, set tier2 recovery target (for going back to 2%)
            state.tier2RecoveryTarget = currentEquity + recoveryAmount;
            state.needTier2Recovery = true;
            state.recoveryTargetEquity = state.tier2RecoveryTarget;
            state.targetRiskPercent = state.maxRiskPercent; // Target is max risk

            Print("⚠️ Risk reduced: ", state.previousRiskPercent, "% → ", state.currentRiskPercent, "%");
            Print("🎯 Tier 2 recovery: need +$", recoveryAmount, " to return to ", state.maxRiskPercent, "%");

        } else if(state.currentRiskPercent == state.minRiskPercent) {
            // Dropped to 0.5% (from 1%), set tier1 recovery target (for going back to 1%)
            state.tier1RecoveryTarget = currentEquity + recoveryAmount;
            state.needTier1Recovery = true;
            state.recoveryTargetEquity = state.tier1RecoveryTarget;

            // Calculate middle tier (1% if max is 2%, min is 0.5%)
            double middleTier = (state.maxRiskPercent + state.minRiskPercent) / 2.0;
            state.targetRiskPercent = middleTier;

            Print("⚠️ Risk reduced: ", state.previousRiskPercent, "% → ", state.currentRiskPercent, "%");
            Print("🎯 Tier 1 recovery: need +$", recoveryAmount, " to return to ", middleTier, "%");
        }

        // Multiple losses at minimum risk - just update the tier1 target
        if(state.currentRiskPercent == state.minRiskPercent && state.previousRiskPercent == state.minRiskPercent) {
            // Still at minimum, update tier1 recovery target with new DD
            state.tier1RecoveryTarget = currentEquity + recoveryAmount;
            state.recoveryTargetEquity = state.tier1RecoveryTarget;

            Print("🔄 Still at minimum risk - updated Tier 1 recovery target");
            Print("🎯 Tier 1 recovery: need +$", recoveryAmount, " to return to 1%");
        }
    }
}

void CheckRecoveryProgress(RiskManagerState &state) {
    // Check Tier 1 Recovery (0.5% → 1%)
    double middleTier = (state.maxRiskPercent + state.minRiskPercent) / 2.0;
    double tier1RecoveryAmount = state.tier1RecoveryTarget - (AccountInfoDouble(ACCOUNT_EQUITY) - state.cumulativeProfitSinceRiskReduction);

    if(state.needTier1Recovery && state.cumulativeProfitSinceRiskReduction >= tier1RecoveryAmount && state.currentRiskPercent < middleTier) {
        state.currentRiskPercent = middleTier; // Go to 1%
        state.needTier1Recovery = false;
        state.cumulativeProfitSinceRiskReduction = 0.0; // Reset accumulator for next tier

        // If still need Tier 2 recovery, set that as next target
        if(state.needTier2Recovery) {
            state.recoveryTargetEquity = state.tier2RecoveryTarget;
            state.targetRiskPercent = state.maxRiskPercent; // Target is 2%
            Print("📈 Risk increased to ", state.currentRiskPercent, "% (Tier 1 recovery complete)");
            Print("💰 Accumulator reset. Continue to Tier 2 recovery...");
        } else {
            // Fully recovered
            state.consecutiveLosses = 0;
            state.recoveryTargetEquity = state.peakEquity;
            Print("✅ Fully recovered! Risk back to ", state.currentRiskPercent, "%");
        }
    }

    // Check Tier 2 Recovery (1% → 2%)
    else if(state.needTier2Recovery) {
        double tier2RecoveryAmount = state.tier2RecoveryTarget - (AccountInfoDouble(ACCOUNT_EQUITY) - state.cumulativeProfitSinceRiskReduction);
        if(state.cumulativeProfitSinceRiskReduction >= tier2RecoveryAmount) {
            state.currentRiskPercent = state.maxRiskPercent;
            state.needTier2Recovery = false;
            state.cumulativeProfitSinceRiskReduction = 0.0; // Reset accumulator
            state.recoveryTargetEquity = state.peakEquity;

            // Fully recovered
            state.consecutiveLosses = 0;
            Print("✅ Fully recovered! Risk back to ", state.currentRiskPercent, "%");
        }
    }
}

//+------------------------------------------------------------------+
//| Display Functions                                                |
//+------------------------------------------------------------------+
void CreateDisplay() {
    // Create main panel with dynamic height based on recovery status
    int panelHeight = (g_state.needTier1Recovery || g_state.needTier2Recovery) ? 155 : 140;

    // Calculate corner-specific positions
    int panelX, panelY, textOffsetX, buttonX, buttonY;

    // Adjust positions based on corner
    switch(inpLabelCorner) {
        case CORNER_LEFT_UPPER:
            panelX = inpLabelX;
            panelY = inpLabelY;
            textOffsetX = inpLabelX + 10;
            buttonX = inpLabelX;
            buttonY = inpLabelY + ((g_state.needTier1Recovery || g_state.needTier2Recovery) ? 160 : 145);
            break;

        case CORNER_LEFT_LOWER:
            panelX = inpLabelX;
            panelY = inpLabelY + panelHeight;  // Offset upward for bottom corner
            textOffsetX = inpLabelX + 10;
            buttonX = inpLabelX;
            buttonY = inpLabelY + 25;  // Button appears below panel
            break;

        case CORNER_RIGHT_UPPER:
            panelX = inpLabelX + 200;  // Offset leftward for right corner (panel width is 200)
            panelY = inpLabelY;
            textOffsetX = inpLabelX + 10;  // Text is relative to panel left edge
            buttonX = inpLabelX + 200;
            buttonY = inpLabelY + ((g_state.needTier1Recovery || g_state.needTier2Recovery) ? 160 : 145);
            break;

        case CORNER_RIGHT_LOWER:
            panelX = inpLabelX + 200;  // Offset leftward for right corner
            panelY = inpLabelY + panelHeight;  // Offset upward for bottom corner
            textOffsetX = inpLabelX + 10;
            buttonX = inpLabelX + 200;
            buttonY = inpLabelY + 25;  // Button appears below panel
            break;

        default:
            panelX = inpLabelX;
            panelY = inpLabelY;
            textOffsetX = inpLabelX + 10;
            buttonX = inpLabelX;
            buttonY = inpLabelY + ((g_state.needTier1Recovery || g_state.needTier2Recovery) ? 160 : 145);
            break;
    }

    if(ObjectCreate(0, g_labelName, OBJ_RECTANGLE_LABEL, 0, 0, 0)) {
        ObjectSetInteger(0, g_labelName, OBJPROP_XDISTANCE, panelX);
        ObjectSetInteger(0, g_labelName, OBJPROP_YDISTANCE, panelY);
        ObjectSetInteger(0, g_labelName, OBJPROP_CORNER, inpLabelCorner);
        ObjectSetInteger(0, g_labelName, OBJPROP_XSIZE, 200);
        ObjectSetInteger(0, g_labelName, OBJPROP_YSIZE, panelHeight);
        ObjectSetInteger(0, g_labelName, OBJPROP_BGCOLOR, inpLabelBackgroundColor);
        ObjectSetInteger(0, g_labelName, OBJPROP_BORDER_COLOR, clrGray);
        ObjectSetInteger(0, g_labelName, OBJPROP_BACK, true);
        ObjectSetInteger(0, g_labelName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    }

    // Create individual text labels for each line (added _Progress for cumulative profit tracking)
    string lineNames[9] = {"_Title", "_DD", "_PrevRisk", "_CurrentRisk", "_TargetRisk", "_Goal", "_Losses", "_Separator", "_Progress"};
    for(int i = 0; i < 9; i++) {
        string labelName = g_labelName + lineNames[i];
        if(ObjectCreate(0, labelName, OBJ_LABEL, 0, 0, 0)) {
            // Calculate absolute text positions (always use LEFT_UPPER corner for text)
            int textX, textY;

            switch(inpLabelCorner) {
                case CORNER_LEFT_UPPER:
                    textX = panelX + 10;  // 10px inside panel from left
                    textY = panelY + 15 + (i * 15);  // Start 15px from top
                    break;

                case CORNER_LEFT_LOWER:
                    textX = panelX + 10;  // 10px inside panel from left
                    textY = panelY - panelHeight + 15 + (i * 15);  // Work upward from bottom
                    break;

                case CORNER_RIGHT_UPPER:
                    textX = panelX + 10;  // 10px inside panel from left edge of panel
                    textY = panelY + 15 + (i * 15);  // Start 15px from top
                    break;

                case CORNER_RIGHT_LOWER:
                    textX = panelX + 10;  // 10px inside panel from left edge of panel
                    textY = panelY - panelHeight + 15 + (i * 15);  // Work upward from bottom
                    break;

                default:
                    textX = panelX + 10;
                    textY = panelY + 15 + (i * 15);
                    break;
            }

            // Text labels should always use LEFT_UPPER corner for consistent positioning
            ObjectSetInteger(0, labelName, OBJPROP_XDISTANCE, textX);
            ObjectSetInteger(0, labelName, OBJPROP_YDISTANCE, textY);
            ObjectSetInteger(0, labelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);  // Fixed corner for text
            ObjectSetString(0, labelName, OBJPROP_FONT, "Arial");
            ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, inpFontSize);
            ObjectSetInteger(0, labelName, OBJPROP_COLOR, inpLabelTextColor);
            ObjectSetInteger(0, labelName, OBJPROP_BACK, false);
        }
    }

    if(ObjectCreate(0, g_buttonName, OBJ_BUTTON, 0, 0, 0)) {
        ObjectSetInteger(0, g_buttonName, OBJPROP_XDISTANCE, buttonX);
        ObjectSetInteger(0, g_buttonName, OBJPROP_YDISTANCE, buttonY);
        ObjectSetInteger(0, g_buttonName, OBJPROP_CORNER, inpLabelCorner);
        ObjectSetInteger(0, g_buttonName, OBJPROP_XSIZE, 200);
        ObjectSetInteger(0, g_buttonName, OBJPROP_YSIZE, 25);
        ObjectSetString(0, g_buttonName, OBJPROP_TEXT, "🔄 RESET RISK");
        ObjectSetString(0, g_buttonName, OBJPROP_FONT, "Arial Bold");
        ObjectSetInteger(0, g_buttonName, OBJPROP_FONTSIZE, 9);
        ObjectSetInteger(0, g_buttonName, OBJPROP_BGCOLOR, clrTomato);
        ObjectSetInteger(0, g_buttonName, OBJPROP_COLOR, clrWhite);
        ObjectSetInteger(0, g_buttonName, OBJPROP_BORDER_COLOR, clrRed);
    }
}

void UpdateDisplay() {
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    double currentDD = g_state.peakEquity - currentEquity;
    double ddPercent = (g_state.peakEquity > 0) ? (currentDD / g_state.peakEquity) * 100 : 0;

    string riskArrow = (g_state.currentRiskPercent < g_state.targetRiskPercent) ? "⬆️" : "✅";

      // Calculate remaining amounts based on profit accumulator
    double tier1Remaining = 0.0;
    double tier2Remaining = 0.0;
    double currentRemaining = 0.0;
    double baseEquity = AccountInfoDouble(ACCOUNT_EQUITY) - g_state.cumulativeProfitSinceRiskReduction;

    if(g_state.needTier1Recovery) {
        tier1Remaining = MathMax(0.0, g_state.tier1RecoveryTarget - baseEquity);
        currentRemaining = tier1Remaining;
    }
    if(g_state.needTier2Recovery) {
        tier2Remaining = MathMax(0.0, g_state.tier2RecoveryTarget - baseEquity);
        currentRemaining = MathMax(currentRemaining, tier2Remaining);
    }

    if(inpShowCompactDisplay) {
        // Compact format - show only 3 lines
        ObjectSetString(0, g_labelName + "_Title", OBJPROP_TEXT, "🛡️ RISK");
        ObjectSetString(0, g_labelName + "_DD", OBJPROP_TEXT, "DD: -$" + DoubleToString(MathAbs(currentDD), 0) + " (" + DoubleToString(ddPercent, 1) + "%)");
        ObjectSetString(0, g_labelName + "_PrevRisk", OBJPROP_TEXT, "Risk: " + DoubleToString(g_state.currentRiskPercent, 1) + "%→" + DoubleToString(g_state.targetRiskPercent, 1) + "% " + riskArrow);
        ObjectSetString(0, g_labelName + "_Goal", OBJPROP_TEXT, "Need +$" + DoubleToString(currentRemaining, 0));

        // Show progress if in recovery
        if(g_state.needTier1Recovery || g_state.needTier2Recovery) {
            double totalNeeded = currentRemaining;
            double progressPercent = (totalNeeded > 0) ? ((g_state.cumulativeProfitSinceRiskReduction / (totalNeeded + g_state.cumulativeProfitSinceRiskReduction)) * 100) : 100;
            ObjectSetString(0, g_labelName + "_Losses", OBJPROP_TEXT, "Progress: " + DoubleToString(progressPercent, 1) + "%");
        }

        // Hide unused labels
        ObjectSetString(0, g_labelName + "_CurrentRisk", OBJPROP_TEXT, "");
        ObjectSetString(0, g_labelName + "_TargetRisk", OBJPROP_TEXT, "");
        ObjectSetString(0, g_labelName + "_Separator", OBJPROP_TEXT, "");
        ObjectSetString(0, g_labelName + "_Progress", OBJPROP_TEXT, "");
    } else {
        // Detailed format - show all lines
        ObjectSetString(0, g_labelName + "_Title", OBJPROP_TEXT, "🛡️ RISK MANAGER");
        ObjectSetString(0, g_labelName + "_Separator", OBJPROP_TEXT, "─────────────────");
        ObjectSetString(0, g_labelName + "_DD", OBJPROP_TEXT, "DD: -$" + DoubleToString(MathAbs(currentDD), 0) + " (" + DoubleToString(ddPercent, 1) + "%)");
        ObjectSetString(0, g_labelName + "_PrevRisk", OBJPROP_TEXT, "Prev Risk: " + DoubleToString(g_state.previousRiskPercent, 1) + "%");
        ObjectSetString(0, g_labelName + "_CurrentRisk", OBJPROP_TEXT, "Current: " + DoubleToString(g_state.currentRiskPercent, 1) + "% ⬇️");
        ObjectSetString(0, g_labelName + "_TargetRisk", OBJPROP_TEXT, "Target: " + DoubleToString(g_state.targetRiskPercent, 1) + "% " + riskArrow);
        ObjectSetString(0, g_labelName + "_Goal", OBJPROP_TEXT, "Need +$" + DoubleToString(currentRemaining, 0));
        ObjectSetString(0, g_labelName + "_Losses", OBJPROP_TEXT, "Losses: " + IntegerToString(g_state.consecutiveLosses));

        // Show progress information if in recovery
        if(g_state.needTier1Recovery || g_state.needTier2Recovery) {
            string progressInfo = "";
            if(g_state.needTier1Recovery) progressInfo += "T1: $" + DoubleToString(tier1Remaining, 0) + " | ";
            if(g_state.needTier2Recovery) progressInfo += "T2: $" + DoubleToString(tier2Remaining, 0);

            ObjectSetString(0, g_labelName + "_Separator", OBJPROP_TEXT, "─ Progress ─");
            ObjectSetString(0, g_labelName + "_Progress", OBJPROP_TEXT, progressInfo);
        } else {
            // Hide Progress labels when not in recovery
            ObjectSetString(0, g_labelName + "_Progress", OBJPROP_TEXT, "");
        }
    }
}

void DeleteDisplay() {
    ObjectDelete(0, g_labelName);
    ObjectDelete(0, g_buttonName);

    // Delete all individual text labels (updated to include _Progress)
    string lineNames[9] = {"_Title", "_DD", "_PrevRisk", "_CurrentRisk", "_TargetRisk", "_Goal", "_Losses", "_Separator", "_Progress"};
    for(int i = 0; i < 9; i++) {
        ObjectDelete(0, g_labelName + lineNames[i]);
    }
}

//+------------------------------------------------------------------+
//| Manual Reset                                                     |
//+------------------------------------------------------------------+
void ManualReset() {
    Print("🔄 Manual reset requested");
    InitializeState(g_state);
    UpdateDisplay();
}

//+------------------------------------------------------------------+
//| Indicator Event Handlers                                         |
//+------------------------------------------------------------------+
int OnInit() {
    Print("🚀 Risk Manager Indicator v1.0 starting...");

    // Try to load existing state
    if(!LoadStateFromFile(g_state)) {
        // No existing state, initialize new one
        InitializeState(g_state);
    } else {
        // Validate loaded state
        if(g_state.accountNumber != IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))) {
            Print("⚠️ State mismatch - reinitializing for new account");
            InitializeState(g_state);
        } else {
            Print("✓ Existing state loaded successfully");
        }
    }

    // Create display elements
    CreateDisplay();
    UpdateDisplay();

    g_initialized = true;
    Print("✅ Risk Manager Indicator initialized");

    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    Print("🛑 Risk Manager Indicator stopping...");

    // Save current state
    if(g_initialized) {
        SaveStateToFile(g_state);
        DeleteDisplay();
    }

    Print("👋 Risk Manager Indicator stopped");
}

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &real_volume[],
                const int &spread[]) {

    // Process new trades and update display
    if(g_initialized) {
        ProcessNewTrades(g_state);
        UpdateDisplay();
        SaveStateToFile(g_state);
    }

    return(rates_total);
}

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam) {

    // Handle reset button click
    if(id == CHARTEVENT_OBJECT_CLICK && sparam == g_buttonName) {
        ManualReset();
        ObjectSetInteger(0, g_buttonName, OBJPROP_STATE, false); // Reset button state
        ChartRedraw();
    }

    // Handle chart property change (timeframe change, etc.)
    if(id == CHARTEVENT_CHART_CHANGE) {
        if(g_initialized) {
            UpdateDisplay();
        }
    }
}
