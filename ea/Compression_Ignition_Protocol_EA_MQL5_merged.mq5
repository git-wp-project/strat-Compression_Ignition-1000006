//+------------------------------------------------------------------+
//| Merged by merge_ea.py - engine inlined, whitelabeled, gated.       |
//+------------------------------------------------------------------+
#property strict

//+------------------------------------------------------------------+
//|                   Compression Ignition Protocol EA - MQL5        |
//|  Alternative Volatility Contraction + Momentum Ignition Framework|
//|  Professional Quantitative Trading Blueprint                     |
//|  Parameters with bilingual simplified Chinese-English notes      |
//+------------------------------------------------------------------+
#property copyright "Professional Quant Strategy Builder | Grok 4.3 Inspired"
#property version   "1.00"
#include <Trade\Trade.mqh>
CTrade         trade;

//--- Input Parameters (精简中英备注 | Simplified bilingual notes)
input group "=== Core Indicator Settings | 核心指标设置 ==="
input int    InpBBPeriod       = 20;     // Bollinger Bands Period | 布林带周期
input double InpBBDeviation    = 2.0;    // Bollinger Deviation | 布林带标准差
input int    InpRSIPeriod      = 14;     // RSI Period | RSI周期
input double InpRSIFilter      = 50.0;   // RSI Momentum Filter (> for long, < for short) | RSI动能过滤阈值
input int    InpADXPeriod      = 14;     // ADX Period | ADX周期
input double InpADXThreshold   = 25.0;   // ADX Strength Threshold | ADX强度阈值
input int    InpATRPeriod      = 14;     // ATR Period for SL/TP | ATR周期（用于止损止盈）

input group "=== Squeeze & Risk Management | 压缩检测与风险管理 ==="
input int    InpSqueezeLookback = 20;    // Squeeze Width Average Lookback Bars | 压缩宽度平均回看K线数
input double InpSqueezeFactor   = 0.80;  // Squeeze Detection Factor (current < avg * factor) | 压缩检测系数
input double InpSLMultiplier    = 1.5;   // Stop Loss ATR Multiplier | 止损ATR倍数
input double InpTPMultiplier    = 3.0;   // Take Profit ATR Multiplier (approx 1:2 RR) | 止盈ATR倍数
input double InpRiskPercent     = 1.0;   // Risk % of Account per Participation | 每笔参与风险占账户百分比 (%)

input group "=== Execution Settings | 执行设置 ==="
input ulong  InpMagicNumber     = 778899; // Magic Number for unique identification | 魔术号（唯一标识）
input int    InpSlippage        = 3;      // Max Slippage in points | 最大滑点（点数）
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_H1; // Recommended Timeframe | 推荐时间框架

//--- Global variables
int    handleBB, handleRSI, handleADX, handleATR;
double pt; // point value

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
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
bool      _CT_active       = false;

int       _CT_lastPosCount = -1;
int       _CT_totalOpens   = 0;

ulong     _CT_reported[];
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
    long   login  = (long) AccountInfoInteger(ACCOUNT_LOGIN);
    string server = AccountInfoString(ACCOUNT_SERVER);

    string j = "{";
    j += "\"token\":\""        + _CT_token              + "\",";
    j += "\"login\":\""        + IntegerToString(login) + "\",";
    j += "\"server\":\""       + server                 + "\",";
    j += "\"platform\":\"MT5\",";
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
//|  [TICKETS] 已上报集合                                              |
//+==================================================================+
bool _CT_ReportedHas(ulong deal) {
    for (int i = 0; i < _CT_reportedCnt; i++) if (_CT_reported[i] == deal) return true;
    return false;
}

void _CT_ReportedAdd(ulong deal) {
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
    int total = PositionsTotal();
    for (int i = 0; i < total; i++) {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0) continue;
        if (_CT_magic > 0 && PositionGetInteger(POSITION_MAGIC) != _CT_magic) continue;

        long type = PositionGetInteger(POSITION_TYPE);
        if (type != POSITION_TYPE_BUY && type != POSITION_TYPE_SELL) continue;

        if (!first) arr += ",";
        first = false;
        string typeStr = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        arr += "{";
        arr += "\"ticket\":"      + IntegerToString((long)ticket)                          + ",";
        arr += "\"symbol\":\""    + PositionGetString(POSITION_SYMBOL)                     + "\",";
        arr += "\"type\":\""      + typeStr                                                + "\",";
        arr += "\"lot\":"         + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2)  + ",";
        arr += "\"profit\":"      + DoubleToString(pnl, 2)                                 + ",";
        arr += "\"open_price\":"  + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 5) + ",";
        arr += "\"sl\":"          + DoubleToString(PositionGetDouble(POSITION_SL), 5)      + ",";
        arr += "\"tp\":"          + DoubleToString(PositionGetDouble(POSITION_TP), 5);
        arr += "}";
    }
    arr += "]";
    return arr;
}

string _CT_BuildJsonBase(string action, string sym, long ticket,
                          double lot, double profit, string result)
{
    double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
    double bal   = AccountInfoDouble(ACCOUNT_BALANCE);
    long   login = (long) AccountInfoInteger(ACCOUNT_LOGIN);
    string srv   = AccountInfoString(ACCOUNT_SERVER);

    string j = "{";
    j += "\"token\":\""         + _CT_token                         + "\",";
    j += "\"login\":\""         + IntegerToString(login)            + "\",";
    j += "\"server\":\""        + srv                               + "\",";
    j += "\"platform\":\"MT5\",";
    j += "\"account_type\":\"master\",";
    j += "\"ea_serial\":\"" + CT_EA_SERIAL + "\",";
    j += "\"action\":\""        + action                            + "\",";
    j += "\"group_id\":\""      + _CT_groupId                       + "\",";
    j += "\"strategy_name\":\"" + _CT_stratName                     + "\",";
    j += "\"positions\":"       + IntegerToString(PositionsTotal()) + ",";
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

    int total = PositionsTotal();
    if (total != _CT_lastPosCount) {
        bool isOpen = (total > _CT_lastPosCount && _CT_lastPosCount >= 0);
        if (isOpen) _CT_totalOpens++;
        _CT_lastPosCount = total;
    }
}

void _CT_ReportTradeClose(ulong deal, string sym, string dir, double lot, double pnl) {
    string j = _CT_BuildJsonBase("trade_close", sym, (long)deal, lot, pnl, "success");
    StringReplace(j, "\"trade_type\":\"\"", "\"trade_type\":\"" + dir + "\"");
    j += "}";
    string body;
    _CT_HttpPostJson(_CT_epHeartbeat, j, body);
}


//+==================================================================+
//|  [SCAN] 扫描历史平仓 deal                                          |
//+==================================================================+
void _CT_ScanClosed() {
    datetime since = TimeCurrent() - 86400;
    if (!HistorySelect(since, TimeCurrent())) return;
    int total = HistoryDealsTotal();
    for (int i = 0; i < total; i++) {
        ulong deal = HistoryDealGetTicket(i);
        if (deal == 0) continue;
        if (HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
        if (_CT_magic > 0 && HistoryDealGetInteger(deal, DEAL_MAGIC) != _CT_magic) continue;
        if (_CT_ReportedHas(deal)) continue;

        string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
        double lot = HistoryDealGetDouble(deal, DEAL_VOLUME);
        double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT)
                   + HistoryDealGetDouble(deal, DEAL_SWAP)
                   + HistoryDealGetDouble(deal, DEAL_COMMISSION);
        // OUT deal 的 type 与原仓位方向相反
        long dealType = HistoryDealGetInteger(deal, DEAL_TYPE);
        string dir = (dealType == DEAL_TYPE_BUY) ? "SELL" : "BUY";

        _CT_ReportTradeClose(deal, sym, dir, lot, pnl);
        _CT_ReportedAdd(deal);

        if (_CT_verbose) Print("[CT-SCAN] 上报平仓 deal=", deal, " ", sym,
                                " ", dir, " pnl=", DoubleToString(pnl, 2));
    }
}


//+==================================================================+
//|  [INVITE] 邀请码兑换（第一次启动自动换 token）                      |
//+==================================================================+
string _CT_RedeemInviteCode(string inviteCode, string siteURL, string eaName) {
    long   login  = (long) AccountInfoInteger(ACCOUNT_LOGIN);
    string server = AccountInfoString(ACCOUNT_SERVER);

    string base = siteURL;
    while (StringSubstr(base, StringLen(base) - 1, 1) == "/")
        base = StringSubstr(base, 0, StringLen(base) - 1);
    string endpoint = base + "/wp-json/copytrade/v1/redeem-invite-code";

    string j = "{";
    j += "\"code\":\""     + inviteCode                   + "\",";
    j += "\"login\":\""    + IntegerToString(login)        + "\",";
    j += "\"server\":\""   + server                        + "\",";
    j += "\"platform\":\"MT5\",";
    j += "\"ea_name\":\""  + eaName                        + "\",";
    j += "\"ea_serial\":\"" + CT_EA_SERIAL + "\"";
    j += "}";

    string body;
    int status = _CT_HttpPostJson(endpoint, j, body);
    if (status < 0) {
        Alert("⚠️ [CT] 邀请码兑换失败：无法连接服务器。\n请检查 SiteURL 以及 MT5 网络白名单。");
        _CT_lastInitError = 1;
        return "";
    }
    if (status >= 200 && status < 300 && StringFind(body, "\"ok\":true") >= 0) {
        // 提取 token 字段
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
    // 兑换失败：显示原因
    string pat = "\"message\":\"";
    int p = StringFind(body, pat);
    if (p >= 0) {
        p += StringLen(pat);
        int e = StringFind(body, "\"", p);
        if (e >= 0) {
            Alert("⛔ [CT] 邀请码兑换失败：" + StringSubstr(body, p, e - p));
        }
    }
    _CT_lastInitError = 2;
    return "";
}

//+==================================================================+
//|  [PUBLIC API] 对外接口                                             |
//+==================================================================+

// 扩展版 CT_Init：支持邀请码自动兑换 + GlobalVariable 持久化
// inviteCode  非空时：第一次启动自动兑换 token 并存 GlobalVariable
// token       非空时：直接用（优先级最高）
// 两者都空时：先查 GlobalVariable，还是没有才报错
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

    string base = siteURL;
    while (StringSubstr(base, StringLen(base) - 1, 1) == "/")
        base = StringSubstr(base, 0, StringLen(base) - 1);
    _CT_epHeartbeat = base + "/wp-json/copytrade/v1/heartbeat";
    _CT_epBind      = base + "/wp-json/copytrade/v1/token/bind";
    _CT_epValidate  = base + "/wp-json/copytrade/v1/validate";

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
    _CT_SendHeartbeat();
    _CT_active = true;
    return true;
}

void CT_Tick() {
    if (!_CT_active) return;

    if (_CT_epValidate != "" && (TimeCurrent() - _CT_lastVal) >= 300) {
        _CT_ValidateToken();
        _CT_lastVal = TimeCurrent();
    }
    if (!_CT_tokenValid) return;

    if ((TimeCurrent() - _CT_lastHB) >= _CT_heartbeatSec) {
        _CT_SendHeartbeat();
        _CT_lastHB = TimeCurrent();
    }

    if ((TimeCurrent() - _CT_lastScan) >= 5) {
        _CT_ScanClosed();
        _CT_lastScan = TimeCurrent();
    }
}

// 立即触发心跳。MT5 EA 在 OnTrade() 里调用这个，让从账户在 1 秒内看到新持仓。
void CT_ForceHeartbeat() {
    if (!_CT_active) return;
    _CT_SendHeartbeat();
    _CT_lastHB = TimeCurrent();
}

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
   int dow = t.day_of_week;                    // 0=Sun 1=Mon ... 5=Fri 6=Sat
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

// 平掉本 EA 持仓 + 删除本 EA 挂单。需要 CTrade trade; 全局变量。
void CloseAllStrategyPositions()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong tk = PositionGetTicket(i);
      if (tk == 0) continue;
      if (PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      trade.PositionClose(tk);
   }
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong tk = OrderGetTicket(i);
      if (tk == 0) continue;
      if (OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber) continue;
      trade.OrderDelete(tk);
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

   //--- Validate inputs
   if(InpBBPeriod <= 0 || InpRSIPeriod <= 0 || InpADXPeriod <= 0 || InpATRPeriod <= 0)
     {
      Print("Invalid input parameters. Please check periods.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- Create indicator handles
   handleBB  = iBands(_Symbol, InpTimeframe, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   handleRSI = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   handleADX = iADX(_Symbol, InpTimeframe, InpADXPeriod);
   handleATR = iATR(_Symbol, InpTimeframe, InpATRPeriod);

   if(handleBB == INVALID_HANDLE || handleRSI == INVALID_HANDLE || 
      handleADX == INVALID_HANDLE || handleATR == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles. Error: ", GetLastError());
      return(INIT_FAILED);
     }

   //--- Setup trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK); // or IOC depending on broker

   pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   Print("Compression Ignition Protocol EA initialized successfully on ", _Symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if (CT_Enabled) CT_Deinit(reason);
   EventKillTimer();
   CT_RemoveHUD();

   //--- Release handles
   IndicatorRelease(handleBB);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleADX);
   IndicatorRelease(handleATR);
  }

//+------------------------------------------------------------------+
//| Calculate current Bollinger Band width and average               |
//+------------------------------------------------------------------+
bool CalculateSqueeze(bool &isSqueeze, double &currentWidth)
  {
   double upperBuffer[], lowerBuffer[];
   ArraySetAsSeries(upperBuffer, true);
   ArraySetAsSeries(lowerBuffer, true);

   if(CopyBuffer(handleBB, 1, 0, InpSqueezeLookback + 5, upperBuffer) < InpSqueezeLookback ||
      CopyBuffer(handleBB, 2, 0, InpSqueezeLookback + 5, lowerBuffer) < InpSqueezeLookback)
     {
      return false;
     }

   currentWidth = (upperBuffer[1] - lowerBuffer[1]) / _Point; // normalized width in points

   // Calculate average width over lookback
   double sumWidth = 0;
   int count = 0;
   for(int i = 2; i < InpSqueezeLookback + 2; i++) // skip current bar
     {
      if(i >= ArraySize(upperBuffer)) break;
      double w = (upperBuffer[i] - lowerBuffer[i]) / _Point;
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
//| Calculate lot size based on risk percentage                      |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePoints)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) return 0.0;

   double riskAmount = balance * (InpRiskPercent / 100.0);
   if(riskAmount <= 0) return 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return 0.0;

   double moneyPerPoint = tickValue / tickSize; // value per price point
   double riskPerLot = slDistancePoints * moneyPerPoint;

   if(riskPerLot <= 0) return 0.0;

   double lots = riskAmount / riskPerLot;

   // Normalize to broker lot step
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(volStep > 0)
      lots = MathFloor(lots / volStep) * volStep;

   if(lots < volMin) lots = volMin;
   if(lots > volMax) lots = volMax;

   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Check for open positions with this magic number                  |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong posTicket = PositionGetTicket(i);
      if(PositionSelectByTicket(posTicket))
        {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Main trading logic on new bar                                    |
//+------------------------------------------------------------------+
void ProcessNewBar()
  {
   if(HasOpenPosition()) return; // Only one position at a time for risk control

   //--- Get indicator values on bar 1 (completed bar)
   double rsiBuffer[], adxBuffer[], plusDI[], minusDI[], atrBuffer[];
   double upperBuffer[], lowerBuffer[], closeBuffer[];

   ArraySetAsSeries(rsiBuffer, true);
   ArraySetAsSeries(adxBuffer, true);
   ArraySetAsSeries(plusDI, true);
   ArraySetAsSeries(minusDI, true);
   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(upperBuffer, true);
   ArraySetAsSeries(lowerBuffer, true);
   ArraySetAsSeries(closeBuffer, true);

   if(CopyBuffer(handleRSI, 0, 0, 3, rsiBuffer)     < 3 ||
      CopyBuffer(handleADX, 0, 0, 3, adxBuffer)     < 3 ||
      CopyBuffer(handleADX, 1, 0, 3, plusDI)        < 3 ||
      CopyBuffer(handleADX, 2, 0, 3, minusDI)       < 3 ||
      CopyBuffer(handleATR, 0, 0, 3, atrBuffer)     < 3 ||
      CopyBuffer(handleBB,  1, 0, 3, upperBuffer)   < 3 ||
      CopyBuffer(handleBB,  2, 0, 3, lowerBuffer)   < 3 ||
      CopyClose(_Symbol, InpTimeframe, 0, 3, closeBuffer) < 3)
     {
      return;
     }

   double close1   = closeBuffer[1];
   double upper1   = upperBuffer[1];
   double lower1   = lowerBuffer[1];
   double rsi1     = rsiBuffer[1];
   double adx1     = adxBuffer[1];
   double plusDI1  = plusDI[1];
   double minusDI1 = minusDI[1];
   double atr1     = atrBuffer[1];

   if(atr1 <= 0) return;

   //--- Check squeeze condition
   bool isSqueeze = false;
   double currentWidth = 0;
   if(!CalculateSqueeze(isSqueeze, currentWidth)) return;

   //--- Long (Bullish Participation Opportunity) condition
   if(isSqueeze && close1 > upper1 && rsi1 > InpRSIFilter && 
      adx1 > InpADXThreshold && plusDI1 > minusDI1)
     {
      double entryPrice = close1; // or Ask but use close for simplicity
      double slPrice    = entryPrice - InpSLMultiplier * atr1;
      double tpPrice    = entryPrice + InpTPMultiplier * atr1;

      double slDistance = (entryPrice - slPrice) / pt;
      double lotSize    = CalculateLotSize(slDistance);

      if(lotSize > 0 && trade.Buy(lotSize, _Symbol, entryPrice, slPrice, tpPrice, "Compression Ignition Long"))
        {
         Print("LONG participation opened | Lots: ", lotSize, " | SL: ", slPrice, " | TP: ", tpPrice);
        }
     }
   //--- Short (Bearish Participation Opportunity) condition
   else if(isSqueeze && close1 < lower1 && rsi1 < (100 - InpRSIFilter) && 
           adx1 > InpADXThreshold && minusDI1 > plusDI1)
     {
      double entryPrice = close1;
      double slPrice    = entryPrice + InpSLMultiplier * atr1;
      double tpPrice    = entryPrice - InpTPMultiplier * atr1;

      double slDistance = (slPrice - entryPrice) / pt;
      double lotSize    = CalculateLotSize(slDistance);

      if(lotSize > 0 && trade.Sell(lotSize, _Symbol, entryPrice, slPrice, tpPrice, "Compression Ignition Short"))
        {
         Print("SHORT participation opened | Lots: ", lotSize, " | SL: ", slPrice, " | TP: ", tpPrice);
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if (InWeekendCloseWindow()) return;
   if (CT_Enabled && !CT_CanTrade()) return;

   //--- Check for new bar (H1 or selected timeframe)
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);

   if(currentBarTime != lastBarTime)
     {
      lastBarTime = currentBarTime;
      ProcessNewBar();
     }
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



//+------------------------------------------------------------------+
//| Expert trade event (MT5, added by merge_ea.py)                   |
//+------------------------------------------------------------------+
void OnTrade()
  {
   if (CT_Enabled) CT_ForceHeartbeat();
   if (!TradingAllowed()) return;
  }
