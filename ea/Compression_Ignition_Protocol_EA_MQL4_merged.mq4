//+------------------------------------------------------------------+
//| Merged by merge_ea.py - engine inlined, whitelabeled, gated.       |
//+------------------------------------------------------------------+
#property strict

//+------------------------------------------------------------------+
//|                   Compression Ignition Protocol EA - MQL4        |
//|  Alternative Volatility Contraction + Momentum Ignition Framework|
//|  Professional Quantitative Trading Blueprint                     |
//|  Parameters with bilingual simplified Chinese-English notes      |
//|                                                                  |
//|  FIXED VERSION (v1.01): Corrected iBands() parameter count by    |
//|  adding the required 'applied_price' (PRICE_CLOSE) parameter.    |
//|  All 6 iBands calls have been updated to resolve compilation     |
//|  errors: 'iBands' - wrong parameters count.                      |
//+------------------------------------------------------------------+
#property copyright "Professional Quant Strategy Builder | Grok 4.3 Inspired"
#property version   "1.01"
//--- Input Parameters (精简中英备注 | Simplified bilingual notes)
input int    InpBBPeriod       = 20;     // Bollinger Bands Period | 布林带周期
input double InpBBDeviation    = 2.0;    // Bollinger Deviation | 布林带标准差
input int    InpRSIPeriod      = 14;     // RSI Period | RSI周期
input double InpRSIFilter      = 50.0;   // RSI Momentum Filter | RSI动能过滤阈值
input int    InpADXPeriod      = 14;     // ADX Period | ADX周期
input double InpADXThreshold   = 25.0;   // ADX Strength Threshold | ADX强度阈值
input int    InpATRPeriod      = 14;     // ATR Period for SL/TP | ATR周期（用于止损止盈）

input int    InpSqueezeLookback = 20;    // Squeeze Width Average Lookback Bars | 压缩宽度平均回看K线数
input double InpSqueezeFactor   = 0.80;  // Squeeze Detection Factor | 压缩检测系数
input double InpSLMultiplier    = 1.5;   // Stop Loss ATR Multiplier | 止损ATR倍数
input double InpTPMultiplier    = 3.0;   // Take Profit ATR Multiplier | 止盈ATR倍数
input double InpRiskPercent     = 1.0;   // Risk % of Account per Participation | 每笔参与风险占账户百分比 (%)

input int    InpMagicNumber     = 778899; // Magic Number | 魔术号
input int    InpSlippage        = 3;      // Max Slippage | 最大滑点
input int    InpTimeframe       = PERIOD_H1; // Recommended Timeframe | 推荐时间框架

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percentage (MT4 version)        |
//+------------------------------------------------------------------+


// ==================== EA 唯一序号 + 面板地址 (编译期常量) ====================
#define CT_EA_SERIAL "C007"
#define CT_SITE_URL  "https://jybj.org"

// ==================== CT 参数 (仅 CT_InviteCode 可见; 已取消 Token) ====================
input  string CT_InviteCode   = "";                    // 授权码 (XXXX-XXXX-XXXX)
sinput bool   CT_Enabled      = true;                  // 总开关(隐藏)
sinput int    CT_HeartbeatSec = 5;                     // 心跳间隔(隐藏)
sinput int    CT_MagicFilter  = 0;                     // 0=自动用 InpMagicNumber; 非零=自定义过滤(隐藏)
sinput bool   CT_ShowHUD      = true;                  // 图表显示授权到期 HUD(隐藏)

//+==================================================================+
//|  [ENGINE - inlined from .mqh, whitelabeled]                       |
//+==================================================================+


//+==================================================================+
//|  [STATE] 模块内部状态                                              |
//+==================================================================+
string    _CT_token        = "";
string    _CT_siteURL      = "";
int       _CT_heartbeatSec = 5;
int       _CT_magic        = 0;
bool      _CT_verbose      = false;

string    _CT_epHeartbeat  = "";
string    _CT_epBind       = "";
string    _CT_epValidate   = "";

string    _CT_groupId      = "";
string    _CT_stratName    = "";
string    _CT_expiry       = "";  // 授权到期日 YYYY-MM-DD (空=永久/未知)

datetime  _CT_lastHB       = 0;
datetime  _CT_lastVal      = 0;
datetime  _CT_lastScan     = 0;
bool      _CT_tokenValid   = true;
bool      _CT_active       = false;   // 是否处于已绑定 + 工作状态

int       _CT_lastPosCount = -1;
int       _CT_totalOpens   = 0;

long      _CT_reported[];
int       _CT_reportedCnt  = 0;
int       _CT_lastInitError = 0;  // 0=ok, 1=transient (network), 2=permanent (rejected)


//+==================================================================+
//|  [HTTP] HTTP 请求封装                                              |
//+==================================================================+
int _CT_HttpPostJson(string url, string json, string &outBody, int timeout = 5000) {
    char post[], resp[]; string respHeaders;
    int bytes = StringToCharArray(json, post, 0, WHOLE_ARRAY, CP_UTF8);
    if (bytes > 0 && post[bytes-1] == 0) ArrayResize(post, bytes-1);
    ResetLastError();
    int status = WebRequest("POST", url, "Content-Type: application/json\r\n",
                             timeout, post, resp, respHeaders);
    if (status < 0) {
        Print("[CT] POST 失败 err=", GetLastError(),
              "（请在 工具→选项→智能交易系统 中加入 ", _CT_siteURL, "）");
        outBody = "";
        return -1;
    }
    outBody = CharArrayToString(resp);
    return status;
}

string _CT_HttpGet(string url, int timeout = 5000) {
    char post[], resp[]; string respHeaders;
    ResetLastError();
    int status = WebRequest("GET", url, "", timeout, post, resp, respHeaders);
    if (status < 0) return "";
    return CharArrayToString(resp);
}

string _CT_JsonStr(string body, string key) {
    string pat = "\"" + key + "\":\"";
    int p = StringFind(body, pat);
    if (p < 0) return "";
    p += StringLen(pat);
    int e = StringFind(body, "\"", p);
    return e < 0 ? "" : StringSubstr(body, p, e - p);
}

bool _CT_JsonBool(string body, string key) {
    string pat = "\"" + key + "\":";
    int p = StringFind(body, pat);
    if (p < 0) return false;
    p += StringLen(pat);
    return StringSubstr(body, p, 4) == "true";
}


//+==================================================================+
//|  [BIND] 服务端绑定                                                 |
//+==================================================================+
bool _CT_Bind() {
    long   login  = AccountNumber();
    string server = AccountServer();

    string j = "{";
    j += "\"token\":\""        + _CT_token              + "\",";
    j += "\"login\":\""        + IntegerToString(login) + "\",";
    j += "\"server\":\""       + server                 + "\",";
    j += "\"platform\":\"MT4\",";
    j += "\"account_type\":\"master\",";
    j += "\"ea_serial\":\"" + CT_EA_SERIAL + "\"";
    j += "}";

    string body;
    int status = _CT_HttpPostJson(_CT_epBind, j, body);
    if (status < 0) {
        Alert("⚠️ [EA] 无法连接面板：" + _CT_siteURL +
              "\n请检查 SiteURL 是否正确，以及是否在 工具→选项→智能交易系统 中加入了允许的 URL 列表。");
        _CT_lastInitError = 1;
        return false;
    }

    if (status >= 200 && status < 300 && _CT_JsonBool(body, "ok")) {
        _CT_groupId   = _CT_JsonStr(body, "group_id");
        _CT_stratName = _CT_JsonStr(body, "strategy_name");
        _CT_expiry    = _CT_JsonStr(body, "expiry");
        Print("[CT] ✅ 绑定成功 group_id=", _CT_groupId, " strategy=", _CT_stratName);
        return true;
    }

    string errCode = _CT_JsonStr(body, "code");
    string errMsg  = _CT_JsonStr(body, "message");
    Alert("⛔ [EA] 绑定失败：" + errCode + " - " + errMsg);
    Print("[CT] 失败 status=", status, " code=", errCode, " msg=", errMsg);
    _CT_lastInitError = 2;
    return false;
}

bool _CT_ValidateToken() {
    if (_CT_epValidate == "" || _CT_token == "") return true;
    string body = _CT_HttpGet(_CT_epValidate + "?token=" + _CT_token);
    if (body == "") return _CT_tokenValid;
    bool valid = (StringFind(body, "\"valid\":true") >= 0);
    { string _ex = _CT_JsonStr(body, "expiry"); if (_ex != "") _CT_expiry = _ex; }
    if (_CT_tokenValid && !valid) {
        Print("[CT] ⛔ Token 已失效，停止上报，策略暂停开仓");
        Alert("⛔ Token 已失效，策略将暂停开新仓（持仓保留），请联系管理员");
    } else if (!_CT_tokenValid && valid) {
        Print("[CT] ✅ Token 已恢复，策略恢复");
        Alert("✅ Token 已恢复，策略恢复正常");
    }
    _CT_tokenValid = valid;
    return _CT_tokenValid;
}


//+==================================================================+
//|  [TICKETS] 已上报集合（防重复）                                    |
//+==================================================================+
bool _CT_ReportedHas(long deal) {
    for (int i = 0; i < _CT_reportedCnt; i++) if (_CT_reported[i] == deal) return true;
    return false;
}

void _CT_ReportedAdd(long deal) {
    ArrayResize(_CT_reported, _CT_reportedCnt + 1);
    _CT_reported[_CT_reportedCnt++] = deal;
    if (_CT_reportedCnt > 1000) {
        for (int k = 0; k < 500; k++) _CT_reported[k] = _CT_reported[k + 500];
        _CT_reportedCnt = 500;
        ArrayResize(_CT_reported, _CT_reportedCnt);
    }
}


//+==================================================================+
//|  [REPORT] 心跳 / 事件上报                                          |
//+==================================================================+
string _CT_BuildPositionsArray() {
    string arr = "[";
    bool first = true;
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (_CT_magic > 0 && OrderMagicNumber() != _CT_magic) continue;
        if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

        if (!first) arr += ",";
        first = false;
        string typeStr = (OrderType() == OP_BUY) ? "BUY" : "SELL";
        double pnl = OrderProfit() + OrderSwap() + OrderCommission();
        arr += "{";
        arr += "\"ticket\":"      + IntegerToString(OrderTicket())             + ",";
        arr += "\"symbol\":\""    + OrderSymbol()                              + "\",";
        arr += "\"type\":\""      + typeStr                                    + "\",";
        arr += "\"lot\":"         + DoubleToString(OrderLots(), 2)             + ",";
        arr += "\"profit\":"      + DoubleToString(pnl, 2)                     + ",";
        arr += "\"open_price\":"  + DoubleToString(OrderOpenPrice(), 5)        + ",";
        arr += "\"sl\":"          + DoubleToString(OrderStopLoss(), 5)         + ",";
        arr += "\"tp\":"          + DoubleToString(OrderTakeProfit(), 5);
        arr += "}";
    }
    arr += "]";
    return arr;
}

string _CT_BuildJsonBase(string action, string sym, long ticket,
                          double lot, double profit, string result)
{
    double eq  = AccountEquity();
    double bal = AccountBalance();
    string j = "{";
    j += "\"token\":\""         + _CT_token                         + "\",";
    j += "\"login\":\""         + IntegerToString(AccountNumber())  + "\",";
    j += "\"server\":\""        + AccountServer()                   + "\",";
    j += "\"platform\":\"MT4\",";
    j += "\"account_type\":\"master\",";
    j += "\"ea_serial\":\"" + CT_EA_SERIAL + "\",";
    j += "\"action\":\""        + action                            + "\",";
    j += "\"group_id\":\""      + _CT_groupId                       + "\",";
    j += "\"strategy_name\":\"" + _CT_stratName                     + "\",";
    j += "\"positions\":"       + IntegerToString(OrdersTotal())    + ",";
    j += "\"equity\":"          + DoubleToString(eq, 2)             + ",";
    j += "\"balance\":"         + DoubleToString(bal, 2)            + ",";
    j += "\"total_opens\":"     + IntegerToString(_CT_totalOpens)   + ",";
    j += "\"master_symbol\":\"" + sym                              + "\",";
    j += "\"slave_symbol\":\"\",\"trade_type\":\"\",";
    j += "\"master_ticket\":"   + IntegerToString(ticket)          + ",";
    j += "\"slave_ticket\":0,";
    j += "\"lot\":"             + DoubleToString(lot, 2)           + ",";
    j += "\"profit\":"          + DoubleToString(profit, 2)        + ",";
    j += "\"result\":\""        + result                           + "\",";
    j += "\"error_code\":0,\"error_msg\":\"\",";
    j += "\"timestamp\":"       + IntegerToString((long)TimeCurrent());
    return j;
}

void _CT_SendHeartbeat() {
    string j = _CT_BuildJsonBase("heartbeat", "", 0, 0, 0, "success");
    string positions = _CT_BuildPositionsArray();
    StringReplace(j, "\"timestamp\":",
                     "\"positions_detail\":" + positions + ",\"timestamp\":");
    j += "}";
    string body;
    _CT_HttpPostJson(_CT_epHeartbeat, j, body);

    int total = OrdersTotal();
    if (total != _CT_lastPosCount) {
        bool isOpen = (total > _CT_lastPosCount && _CT_lastPosCount >= 0);
        if (isOpen) _CT_totalOpens++;
        _CT_lastPosCount = total;
    }
}

void _CT_ReportTradeClose(long ticket, string sym, string dir, double lot, double pnl) {
    string j = _CT_BuildJsonBase("trade_close", sym, ticket, lot, pnl, "success");
    StringReplace(j, "\"trade_type\":\"\"", "\"trade_type\":\"" + dir + "\"");
    j += "}";
    string body;
    _CT_HttpPostJson(_CT_epHeartbeat, j, body);
}


//+==================================================================+
//|  [SCAN] 扫描历史平仓                                               |
//+==================================================================+
void _CT_ScanClosed() {
    datetime since = TimeCurrent() - 86400;
    int total = OrdersHistoryTotal();
    for (int i = total - 1; i >= 0; i--) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
        if (OrderCloseTime() < since) break;
        if (_CT_magic > 0 && OrderMagicNumber() != _CT_magic) continue;
        if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
        long tk = OrderTicket();
        if (_CT_ReportedHas(tk)) continue;

        string sym = OrderSymbol();
        string dir = (OrderType() == OP_BUY) ? "BUY" : "SELL";
        double lot = OrderLots();
        double pnl = OrderProfit() + OrderSwap() + OrderCommission();
        _CT_ReportTradeClose(tk, sym, dir, lot, pnl);
        _CT_ReportedAdd(tk);

        if (_CT_verbose) Print("[CT-SCAN] 上报平仓 ticket=", tk, " ", sym,
                                " ", dir, " pnl=", DoubleToString(pnl, 2));
    }
}


//+==================================================================+
//|  [INVITE] 邀请码兑换（第一次启动自动换 token）                      |
//+==================================================================+
string _CT_RedeemInviteCode(string inviteCode, string siteURL, string eaName) {
    long   login  = (long) AccountNumber();
    string server = AccountServer();

    string base = siteURL;
    while (StringSubstr(base, StringLen(base) - 1, 1) == "/")
        base = StringSubstr(base, 0, StringLen(base) - 1);
    string endpoint = base + "/wp-json/copytrade/v1/redeem-invite-code";

    string j = "{";
    j += "\"code\":\""     + inviteCode                   + "\",";
    j += "\"login\":\""    + IntegerToString(login)        + "\",";
    j += "\"server\":\""   + server                        + "\",";
    j += "\"platform\":\"MT4\",";
    j += "\"ea_name\":\""  + eaName                        + "\",";
    j += "\"ea_serial\":\"" + CT_EA_SERIAL + "\"";
    j += "}";

    string body;
    int status = _CT_HttpPostJson(endpoint, j, body);
    if (status < 0) {
        Alert("⚠️ [CT] 邀请码兑换失败：无法连接服务器。\n请检查 SiteURL 以及 MT4 网络白名单。");
        _CT_lastInitError = 1;
        return "";
    }
    if (status >= 200 && status < 300 && StringFind(body, "\"ok\":true") >= 0) {
        string pat = "\"token\":\"";
        int p = StringFind(body, pat);
        if (p < 0) return "";
        p += StringLen(pat);
        int e = StringFind(body, "\"", p);
        if (e < 0) return "";
        string token = StringSubstr(body, p, e - p);
        Print("[CT] ✅ 邀请码兑换成功，Token 已获取");
        return token;
    }
    string pat = "\"message\":\"";
    int p = StringFind(body, pat);
    if (p >= 0) {
        p += StringLen(pat);
        int e = StringFind(body, "\"", p);
        if (e >= 0) Alert("⛔ [CT] 邀请码兑换失败：" + StringSubstr(body, p, e - p));
    }
    _CT_lastInitError = 2;
    return "";
}

//+==================================================================+
//|  [PUBLIC API] 对外接口（你在 EA 里调用这些）                       |
//+==================================================================+

// 初始化引擎。在 EA 的 OnInit 里调用一次。
// 支持邀请码自动兑换 + Token 本地持久化。
bool CT_Init(string token, string siteURL,
             int heartbeatSec = 5, int magic = 0, bool verbose = false,
             string inviteCode = "")
{
    _CT_lastInitError = 0;
    if (siteURL == "") {
        Print("[CT] ⚠️ 面板地址为空, 引擎未启动");
        _CT_lastInitError = 2;
        _CT_active = false;
        return false;
    }

    string useToken = token;

    // [invite-only] 仅用授权码: 不读 GlobalVariable / 不读写本地缓存
    //               每次启动向服务器兑换 (服务端幂等: 同账号同序号返回同一 token)
    if (useToken == "" && inviteCode != "") {
        Print("[CT] 检测到授权码, 正在向服务器验证...");
        useToken = _CT_RedeemInviteCode(inviteCode, siteURL, "MasterEA");
    }

    if (useToken == "") {
        _CT_active = false;
        return false;
    }

    _CT_token        = useToken;
    _CT_siteURL      = siteURL;
    _CT_heartbeatSec = MathMax(3, heartbeatSec);
    _CT_magic        = magic;
    _CT_verbose      = verbose;

    // 拼接端点 URL（去掉末尾斜杠）
    string base = siteURL;
    while (StringSubstr(base, StringLen(base) - 1, 1) == "/")
        base = StringSubstr(base, 0, StringLen(base) - 1);
    _CT_epHeartbeat = base + "/wp-json/copytrade/v1/heartbeat";
    _CT_epBind      = base + "/wp-json/copytrade/v1/token/bind";
    _CT_epValidate  = base + "/wp-json/copytrade/v1/validate";

    // 合规：在日志中清楚告知用户引擎已启用
    string tokenHint = "";
    if (StringLen(useToken) > 6)
        tokenHint = StringSubstr(useToken, 0, 4) + "..." + StringSubstr(useToken, StringLen(useToken) - 2, 2);
    Print("════════════════════════════════════════════");
    Print("[EA] 引擎已启用");
    Print("[EA]   面板: ", siteURL);
    Print("[EA]   Token: ", tokenHint);
    Print("[EA]   Magic 过滤: ", magic == 0 ? "无（上报全部持仓）" : IntegerToString(magic));
    Print("[EA] 上报内容: 当前持仓、账户权益/余额、平仓盈亏");
    Print("[EA] 如需关闭, 把 CT_Enabled 改为 false");
    Print("════════════════════════════════════════════");

    if (!_CT_Bind()) {
        _CT_active = false;
        return false;
    }
    _CT_SendHeartbeat();   // 立刻发一次
    _CT_active = true;
    return true;
}

// 周期任务。在 OnTimer 里调用（建议 EventSetTimer(1) 即每秒）。
void CT_Tick() {
    if (!_CT_active) return;

    // Token 周期重验证（每 5 分钟）
    if (_CT_epValidate != "" && (TimeCurrent() - _CT_lastVal) >= 300) {
        _CT_ValidateToken();
        _CT_lastVal = TimeCurrent();
    }
    if (!_CT_tokenValid) return;

    // 心跳
    if ((TimeCurrent() - _CT_lastHB) >= _CT_heartbeatSec) {
        _CT_SendHeartbeat();
        _CT_lastHB = TimeCurrent();
    }

    // 扫描平仓（每 5 秒）
    if ((TimeCurrent() - _CT_lastScan) >= 5) {
        _CT_ScanClosed();
        _CT_lastScan = TimeCurrent();
    }
}

// （可选）立即触发一次心跳。可以在 EA 检测到开/平仓时调用以降低延迟。
// MT4 没有 OnTrade 回调，因此此函数主要给手动触发用。
void CT_ForceHeartbeat() {
    if (!_CT_active) return;
    _CT_SendHeartbeat();
    _CT_lastHB = TimeCurrent();
}

// 在 OnDeinit 里调用。
void CT_Deinit(int reason) {
    bool realStop = (reason == REASON_REMOVE     ||
                     reason == REASON_CHARTCLOSE ||
                     reason == REASON_CLOSE);
    if (realStop && _CT_active) {
        string j = _CT_BuildJsonBase("offline", "", 0, 0, 0, "success");
        j += "}";
        string body;
        _CT_HttpPostJson(_CT_epHeartbeat, j, body);
    }
    _CT_active = false;
}

// 查询当前是否正常工作（已绑定 + Token 有效）。
bool CT_IsActive() {
    return _CT_active && _CT_tokenValid;
}

//+------------------------------------------------------------------+
//|  CT_CanTrade - 策略代码可调用此函数判断是否允许交易                |
//|  返回 false 时：Token 已失效，应跳过开仓逻辑（持仓保留）          |
//+------------------------------------------------------------------+
bool CT_CanTrade() {
    return _CT_tokenValid;
}

// 0=ok, 1=transient (network unreachable), 2=permanent (server rejected)
int CT_GetLastInitError() { return _CT_lastInitError; }

// 授权到期日字符串 YYYY-MM-DD (空 = 永久 / 尚未绑定)
string CT_GetExpiry() { return _CT_expiry; }
//+------------------------------------------------------------------+

//+==================================================================+
//|  [HELPERS] 周末时段 + 全平 + 综合放行                              |
//+==================================================================+

// 北京时间 = GMT + 8 (无夏令时)。周五 23:30 - 周一 08:00 禁止交易。
bool InWeekendCloseWindow()
{
   datetime nowBJ = TimeGMT() + 8 * 3600;
   MqlDateTime t;
   TimeToStruct(nowBJ, t);
   int dow = t.day_of_week;
   int hm  = t.hour * 60 + t.min;
   if (dow == 5 && hm >= 23 * 60 + 30) return true;
   if (dow == 6)                       return true;
   if (dow == 0)                       return true;
   if (dow == 1 && hm <  8 * 60)       return true;
   return false;
}

bool TradingAllowed()
{
   if (CT_Enabled && !CT_CanTrade()) return false;
   if (InWeekendCloseWindow())       return false;
   return true;
}

void CloseAllStrategyPositions()
{
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderMagicNumber() != InpMagicNumber) continue;
      string s  = OrderSymbol();
      int    tk = OrderTicket();
      if (OrderType() == OP_BUY) {
         if (!OrderClose(tk, OrderLots(), MarketInfo(s, MODE_BID), 3, CLR_NONE))
            Print("CloseAllStrategyPositions: OrderClose BUY failed #", tk, " ", s, " err=", GetLastError());
      } else if (OrderType() == OP_SELL) {
         if (!OrderClose(tk, OrderLots(), MarketInfo(s, MODE_ASK), 3, CLR_NONE))
            Print("CloseAllStrategyPositions: OrderClose SELL failed #", tk, " ", s, " err=", GetLastError());
      } else {
         if (!OrderDelete(tk))
            Print("CloseAllStrategyPositions: OrderDelete failed #", tk, " ", s, " err=", GetLastError());
      }
   }
}


//+==================================================================+
//|  [HUD] 授权到期日图表显示 (MT4/MT5 通用)                           |
//+==================================================================+

// 在图表右上角画一行 label。MT4(build 600+)/MT5 通用 API。
void CT_HudLabel(string name, string text, int ydist, color col)
{
   if (ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  ydist);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      col);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   9);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   ObjectSetString (0, name, OBJPROP_FONT,       "Consolas");
   ObjectSetString (0, name, OBJPROP_TEXT,       text);
}

// 根据 CT_GetExpiry() 渲染授权到期 HUD。
void CT_DrawHUD()
{
   if (!CT_Enabled || !CT_ShowHUD) return;

   string exp = CT_GetExpiry();
   string l1, l2;
   color  col;

   if (exp == "") {
      l1  = "[" + CT_EA_SERIAL + "] 授权: 有效";
      l2  = "到期: 长期有效";
      col = clrLime;
   } else {
      string dotted = exp;
      StringReplace(dotted, "-", ".");
      datetime et   = StringToTime(dotted);
      long     secs = (long)et + 86399 - (long)TimeCurrent();
      if (secs <= 0) {
         l1  = "[" + CT_EA_SERIAL + "] 授权已过期";
         l2  = "到期: " + exp;
         col = clrRed;
      } else {
         long days = secs / 86400;
         l1  = "[" + CT_EA_SERIAL + "] 授权到期: " + exp;
         l2  = "剩余: " + IntegerToString((int)days) + " 天";
         col = (days <= 7) ? clrOrange : clrLime;
      }
   }
   CT_HudLabel("CTHUD_l1", l1, 20, col);
   CT_HudLabel("CTHUD_l2", l2, 36, col);
   ChartRedraw(0);
}

void CT_RemoveHUD()
{
   ObjectDelete(0, "CTHUD_l1");
   ObjectDelete(0, "CTHUD_l2");
}

//+==================================================================+
//|  [STRATEGY EVENT HANDLERS - wrapped]                              |
//+==================================================================+
double CalculateLotSize(double slDistancePoints)
  {
   double balance = AccountBalance();
   if(balance <= 0) return 0.0;

   double riskAmount = balance * (InpRiskPercent / 100.0);
   if(riskAmount <= 0) return 0.0;

   double tickValue = MarketInfo(_Symbol, MODE_TICKVALUE);
   double tickSize  = MarketInfo(_Symbol, MODE_TICKSIZE);
   if(tickValue <= 0 || tickSize <= 0) return 0.0;

   double moneyPerPoint = tickValue / tickSize;
   double riskPerLot = slDistancePoints * moneyPerPoint;

   if(riskPerLot <= 0) return 0.0;

   double lots = riskAmount / riskPerLot;

   double volStep = MarketInfo(_Symbol, MODE_LOTSTEP);
   double volMin  = MarketInfo(_Symbol, MODE_MINLOT);
   double volMax  = MarketInfo(_Symbol, MODE_MAXLOT);

   if(volStep > 0)
      lots = MathFloor(lots / volStep) * volStep;

   if(lots < volMin) lots = volMin;
   if(lots > volMax) lots = volMax;

   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Check if position with magic exists (MT4)                        |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = 0; i < OrdersTotal(); i++)
     {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if(OrderMagicNumber() == InpMagicNumber && OrderSymbol() == _Symbol)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Calculate squeeze on completed bar                               |
//+------------------------------------------------------------------+
bool CalculateSqueeze(bool &isSqueeze, double &currentWidth)
  {
   int tf = InpTimeframe;
   currentWidth = (iBands(_Symbol, tf, InpBBPeriod, InpBBDeviation, 0, PRICE_CLOSE, MODE_UPPER, 1) - 
                   iBands(_Symbol, tf, InpBBPeriod, InpBBDeviation, 0, PRICE_CLOSE, MODE_LOWER, 1)) / Point;

   double sumWidth = 0;
   int count = 0;
   for(int i = 2; i <= InpSqueezeLookback + 1; i++)
     {
      double w = (iBands(_Symbol, tf, InpBBPeriod, InpBBDeviation, 0, PRICE_CLOSE, MODE_UPPER, i) - 
                  iBands(_Symbol, tf, InpBBPeriod, InpBBDeviation, 0, PRICE_CLOSE, MODE_LOWER, i)) / Point;
      if(w > 0)
        {
         sumWidth += w;
         count++;
        }
     }

   if(count < InpSqueezeLookback / 2) return false;

   double avgWidth = sumWidth / count;
   isSqueeze = (currentWidth < avgWidth * InpSqueezeFactor) && (currentWidth > 0);
   return true;
  }

//+------------------------------------------------------------------+
//| Process trading logic on new bar (MT4)                           |
//+------------------------------------------------------------------+
void ProcessNewBar()
  {
   if(HasOpenPosition()) return;

   int tf = InpTimeframe;
   double close1   = iClose(_Symbol, tf, 1);
   double upper1   = iBands(_Symbol, tf, InpBBPeriod, InpBBDeviation, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double lower1   = iBands(_Symbol, tf, InpBBPeriod, InpBBDeviation, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double rsi1     = iRSI(_Symbol, tf, InpRSIPeriod, PRICE_CLOSE, 1);
   double adx1     = iADX(_Symbol, tf, InpADXPeriod, PRICE_CLOSE, MODE_MAIN, 1);
   double plusDI1  = iADX(_Symbol, tf, InpADXPeriod, PRICE_CLOSE, MODE_PLUSDI, 1);
   double minusDI1 = iADX(_Symbol, tf, InpADXPeriod, PRICE_CLOSE, MODE_MINUSDI, 1);
   double atr1     = iATR(_Symbol, tf, InpATRPeriod, 1);

   if(atr1 <= 0) return;

   bool isSqueeze = false;
   double currentWidth = 0;
   if(!CalculateSqueeze(isSqueeze, currentWidth)) return;

   // Long condition
   if(isSqueeze && close1 > upper1 && rsi1 > InpRSIFilter && adx1 > InpADXThreshold && plusDI1 > minusDI1)
     {
      double entry = close1;
      double sl = entry - InpSLMultiplier * atr1;
      double tp = entry + InpTPMultiplier * atr1;

      double slDist = (entry - sl) / Point;
      double lots = CalculateLotSize(slDist);

      if(lots > 0)
        {
         int ticket = OrderSend(_Symbol, OP_BUY, lots, entry, InpSlippage, sl, tp, "Compression Ignition Long", InpMagicNumber, 0, clrGreen);
         if(ticket > 0) Print("LONG participation opened | Lots: ", lots);
        }
     }
   // Short condition
   else if(isSqueeze && close1 < lower1 && rsi1 < (100 - InpRSIFilter) && adx1 > InpADXThreshold && minusDI1 > plusDI1)
     {
      double entry = close1;
      double sl = entry + InpSLMultiplier * atr1;
      double tp = entry - InpTPMultiplier * atr1;

      double slDist = (sl - entry) / Point;
      double lots = CalculateLotSize(slDist);

      if(lots > 0)
        {
         int ticket = OrderSend(_Symbol, OP_SELL, lots, entry, InpSlippage, sl, tp, "Compression Ignition Short", InpMagicNumber, 0, clrRed);
         if(ticket > 0) Print("SHORT participation opened | Lots: ", lots);
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function (MT4)                                       |
//+------------------------------------------------------------------+
void OnTick()
  {
   if (InWeekendCloseWindow()) return;
   if (CT_Enabled && !CT_CanTrade()) return;

   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);

   if(currentBarTime != lastBarTime)
     {
      lastBarTime = currentBarTime;
      ProcessNewBar();
     }
  }

//+------------------------------------------------------------------+
//| Expert initialization (MT4)                                      |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- [LICENSE] 未填授权码则禁止运行 (invite-only: 无 Token 回退)
   if (CT_Enabled && CT_InviteCode == "")
     {
      Alert("请填写授权码后再运行 (格式 XXXX-XXXX-XXXX)");
      Print("[EA] 未填写授权码, EA 不运行");
      return(INIT_FAILED);
     }

   //--- 魔术号过滤
   int ctMagic = (CT_MagicFilter != 0) ? CT_MagicFilter : (int)InpMagicNumber;

   //--- 启动引擎 (根据失败类型决定是否阻止运行)
   if (CT_Enabled)
     {
      if (!CT_Init("", CT_SITE_URL, CT_HeartbeatSec, ctMagic, false, CT_InviteCode))
        {
         if (CT_GetLastInitError() == 2)
           {
            Alert("授权码无效或已过期, EA 不运行。请检查授权码后重新加载。");
            Print("[EA] 授权码被拒绝, EA 不运行");
            return(INIT_FAILED);
           }
         Print("[EA] 服务暂时不可用 (网络问题?), 策略照常运行");
        }
     }
   EventSetTimer(1);

   if(InpBBPeriod <= 0 || InpRSIPeriod <= 0) return INIT_PARAMETERS_INCORRECT;
   Print("Compression Ignition Protocol (MT4) initialized on ", _Symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization (MT4)                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if (CT_Enabled) CT_Deinit(reason);
   EventKillTimer();
   CT_RemoveHUD();

   Print("Compression Ignition Protocol EA deinitialized.");
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Expert timer function (added by merge_ea.py)                     |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if (CT_Enabled) CT_Tick();
   CT_DrawHUD();
   if (InWeekendCloseWindow())
     {
      CloseAllStrategyPositions();
      return;
     }
   if (CT_Enabled && !CT_CanTrade()) return;
  }
