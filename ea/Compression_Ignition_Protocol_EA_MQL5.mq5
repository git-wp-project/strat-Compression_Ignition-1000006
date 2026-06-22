//+------------------------------------------------------------------+
//|                   Compression Ignition Protocol EA - MQL5        |
//|  Alternative Volatility Contraction + Momentum Ignition Framework|
//|  Professional Quantitative Trading Blueprint                     |
//|  Parameters with bilingual simplified Chinese-English notes      |
//+------------------------------------------------------------------+
#property copyright "Professional Quant Strategy Builder | Grok 4.3 Inspired"
#property version   "1.00"
#property strict

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
int OnInit()
  {
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