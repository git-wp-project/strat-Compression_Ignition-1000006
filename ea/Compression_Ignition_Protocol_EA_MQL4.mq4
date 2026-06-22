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
#property strict

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
   if(InpBBPeriod <= 0 || InpRSIPeriod <= 0) return INIT_PARAMETERS_INCORRECT;
   Print("Compression Ignition Protocol (MT4) initialized on ", _Symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization (MT4)                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("Compression Ignition Protocol EA deinitialized.");
  }
//+------------------------------------------------------------------+