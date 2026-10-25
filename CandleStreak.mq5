//+------------------------------------------------------------------+
//|                                               CandleStreak.mq5   |
//|   Candle Streak  v1.00（TradingView 版インジケーターの MT5 移植）  |
//|   ・陽線／陰線が指定本数連続したらマーク（本数ラベル or 矢印）を表示 |
//|   ・マークの付け方：到達した足だけ／連続中は毎足                    |
//|   ・連続区間を枠で囲む（連続が伸びる間は枠も伸びる）                |
//|   ・連続中の足に色を付ける（初期値オフ）                            |
//|   ・確定足で連続本数以上ならアラート（ポップアップ／プッシュ通知）   |
//|                                                                  |
//|   原作：Candle Streak ©suzumetacos                                |
//|   Mozilla Public License 2.0（https://mozilla.org/MPL/2.0/）       |
//+------------------------------------------------------------------+
#property copyright "©suzumetacos (MPL 2.0) / MT5移植"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 9
#property indicator_plots   3

#property indicator_label1  "連続中の足"
#property indicator_type1   DRAW_COLOR_CANDLES
#property indicator_color1  C'8,153,129',C'242,54,69'

#property indicator_label2  "陽線連続"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  C'8,153,129'

#property indicator_label3  "陰線連続"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  C'242,54,69'

//+------------------------------------------------------------------+
//| 列挙型                                                           |
//+------------------------------------------------------------------+
enum ENUM_MARK_MODE
  {
   MARK_REACH = 0,          // 到達した足だけ
   MARK_EVERY = 1           // 連続中は毎足
  };

//+------------------------------------------------------------------+
//| 入力                                                             |
//+------------------------------------------------------------------+
input group "基本"
input int            InpLen        = 8;             // 連続本数（2〜100）
input ENUM_MARK_MODE InpMarkMode   = MARK_REACH;    // マークの付け方

input group "表示"
input bool           InpShowBull   = true;          // 陽線の連続を表示
input bool           InpShowBear   = true;          // 陰線の連続を表示
input bool           InpShowLabel  = true;          // 本数ラベルを表示（オフで矢印）
input bool           InpShowBox    = true;          // 連続区間を枠で囲む
input bool           InpPaint      = false;         // 連続中の足に色を付ける
input int            InpLabelSize  = 9;             // ラベルの文字サイズ
input int            InpMaxBars    = 5000;          // ラベル・枠を描く過去の本数（0=全て）

input group "色"
input color          InpBullCol    = C'8,153,129';  // 陽線の色
input color          InpBearCol    = C'242,54,69';  // 陰線の色

input group "アラート"
input bool           InpAlertBull  = true;          // 陽線の連続を通知
input bool           InpAlertBear  = true;          // 陰線の連続を通知
input bool           InpAlertPopup = true;          // ポップアップで通知
input bool           InpAlertPush  = false;         // スマホにプッシュ通知

//+------------------------------------------------------------------+
//| バッファ・グローバル                                             |
//+------------------------------------------------------------------+
double   g_candleO[], g_candleH[], g_candleL[], g_candleC[], g_candleClr[];
double   g_upArrow[], g_dnArrow[];
double   g_bullCnt[], g_bearCnt[];

int      g_len;
string   g_prefix;
color    g_bullFill, g_bearFill;
datetime g_lastAlertBar = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_len    = MathMax(2, MathMin(100, InpLen));
   g_prefix = "CandleStreak" + IntegerToString(g_len) + "_";

   SetIndexBuffer(0, g_candleO,   INDICATOR_DATA);
   SetIndexBuffer(1, g_candleH,   INDICATOR_DATA);
   SetIndexBuffer(2, g_candleL,   INDICATOR_DATA);
   SetIndexBuffer(3, g_candleC,   INDICATOR_DATA);
   SetIndexBuffer(4, g_candleClr, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(5, g_upArrow,   INDICATOR_DATA);
   SetIndexBuffer(6, g_dnArrow,   INDICATOR_DATA);
   SetIndexBuffer(7, g_bullCnt,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, g_bearCnt,   INDICATOR_CALCULATIONS);

   for(int p = 0; p < 3; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

//--- 連続中の足（0=陽線の色、1=陰線の色）
   PlotIndexSetInteger(0, PLOT_COLOR_INDEXES, 2);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, InpBullCol);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 1, InpBearCol);
   PlotIndexSetInteger(0, PLOT_SHOW_DATA, false);

//--- 矢印（本数ラベルを出さない時のマーク）
   PlotIndexSetInteger(1, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT, 12);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, InpBullCol);
   PlotIndexSetInteger(2, PLOT_ARROW, 234);
   PlotIndexSetInteger(2, PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, InpBearCol);

//--- 枠の塗りは背景色と混ぜて薄くする（TradingView の透過 88% 相当）
   color bg   = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   g_bullFill = BlendColor(InpBullCol, bg, 0.12);
   g_bearFill = BlendColor(InpBearCol, bg, 0.12);

   IndicatorSetString(INDICATOR_SHORTNAME, "Candle Streak(" + IntegerToString(g_len) + ")");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| 終了                                                             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| 計算                                                             |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < 2)
      return(0);

//--- live=false は全本の再計算。この時は古いオブジェクトを消してから描き直す
   bool live  = (prev_calculated > 0);
   int  start = live ? prev_calculated - 1 : 0;
   if(!live)
      ObjectsDeleteAll(0, g_prefix);

   int  drawFrom = (InpMaxBars > 0) ? MathMax(0, rates_total - InpMaxBars) : 0;
   bool every    = (InpMarkMode == MARK_EVERY);

   for(int i = start; i < rates_total; i++)
     {
      int prevBull = (i > 0) ? (int)g_bullCnt[i - 1] : 0;
      int prevBear = (i > 0) ? (int)g_bearCnt[i - 1] : 0;
      int bull     = (close[i] > open[i]) ? prevBull + 1 : 0;
      int bear     = (close[i] < open[i]) ? prevBear + 1 : 0;
      g_bullCnt[i] = bull;
      g_bearCnt[i] = bear;

      bool bullHit = InpShowBull && (every ? bull >= g_len : bull == g_len);
      bool bearHit = InpShowBear && (every ? bear >= g_len : bear == g_len);

      //--- 矢印（ラベル非表示の時だけ）
      g_upArrow[i] = (bullHit && !InpShowLabel) ? low[i]  : EMPTY_VALUE;
      g_dnArrow[i] = (bearHit && !InpShowLabel) ? high[i] : EMPTY_VALUE;

      //--- 連続中の足の色
      int clr = -1;
      if(InpPaint)
        {
         if(InpShowBull && bull >= g_len)
            clr = 0;
         else if(InpShowBear && bear >= g_len)
            clr = 1;
        }
      if(clr >= 0)
        {
         g_candleO[i]   = open[i];
         g_candleH[i]   = high[i];
         g_candleL[i]   = low[i];
         g_candleC[i]   = close[i];
         g_candleClr[i] = clr;
        }
      else
        {
         g_candleO[i]   = EMPTY_VALUE;
         g_candleH[i]   = EMPTY_VALUE;
         g_candleL[i]   = EMPTY_VALUE;
         g_candleC[i]   = EMPTY_VALUE;
         g_candleClr[i] = 0;
        }

      if(i < drawFrom)
         continue;

      //--- 本数ラベル（未確定足で条件が消えたら削除）
      string ulName = g_prefix + "UL" + TimeKey(time[i]);
      string dlName = g_prefix + "DL" + TimeKey(time[i]);
      if(bullHit && InpShowLabel)
         SetText(ulName, time[i], low[i] - LabelOffset(i, high, low), IntegerToString(bull), InpBullCol, ANCHOR_UPPER);
      else if(live)
         ObjectDelete(0, ulName);
      if(bearHit && InpShowLabel)
         SetText(dlName, time[i], high[i] + LabelOffset(i, high, low), IntegerToString(bear), InpBearCol, ANCHOR_LOWER);
      else if(live)
         ObjectDelete(0, dlName);

      //--- 連続区間の枠
      if(InpShowBox && InpShowBull)
         UpdateBox("UB", i, bull, prevBull, live, time, high, low, InpBullCol, g_bullFill);
      if(InpShowBox && InpShowBear)
         UpdateBox("DB", i, bear, prevBear, live, time, high, low, InpBearCol, g_bearFill);
     }

//--- アラート：新しい足が出たら、1本前の確定足で判定（足の確定時に1回）
   int closed = rates_total - 2;
   if(time[closed] != g_lastAlertBar)
     {
      if(g_lastAlertBar != 0)
        {
         string pre = _Symbol + " (" + TimeframeText() + "): ";
         if(InpAlertBull && (int)g_bullCnt[closed] >= g_len)
            Notify(pre + IntegerToString((int)g_bullCnt[closed]) + "本連続で陽線が連続しました");
         if(InpAlertBear && (int)g_bearCnt[closed] >= g_len)
            Notify(pre + IntegerToString((int)g_bearCnt[closed]) + "本連続で陰線が連続しました");
        }
      g_lastAlertBar = time[closed];
     }

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| 連続区間の枠を更新                                               |
//|   cnt>=本数：連続の始まり〜現在足まで枠を伸ばす                   |
//|   未確定足で連続が途切れた：枠を1本前までに戻す（本数未満なら削除）|
//+------------------------------------------------------------------+
void UpdateBox(const string tag, const int i, const int cnt, const int prevCnt, const bool live,
               const datetime &time[], const double &high[], const double &low[],
               const color border, const color fill)
  {
   if(cnt >= g_len)
      DrawBox(tag, i - cnt + 1, i, time, high, low, border, fill);
   else if(live && cnt == 0 && prevCnt > 0)
     {
      int s = i - prevCnt;
      if(prevCnt >= g_len)
         DrawBox(tag, s, i - 1, time, high, low, border, fill);
      else
        {
         string name = g_prefix + tag + TimeKey(time[s]);
         ObjectDelete(0, name + "F");
         ObjectDelete(0, name + "E");
        }
     }
  }

//+------------------------------------------------------------------+
//| 枠を描く（s〜e の高値・安値で囲む。塗り＋縁取りの2つの長方形）    |
//+------------------------------------------------------------------+
void DrawBox(const string tag, const int s, const int e,
             const datetime &time[], const double &high[], const double &low[],
             const color border, const color fill)
  {
   int    n      = e - s + 1;
   double top    = high[ArrayMaximum(high, s, n)];
   double bottom = low[ArrayMinimum(low, s, n)];
   string name   = g_prefix + tag + TimeKey(time[s]);
   SetRect(name + "F", time[s], top, time[e], bottom, fill, true);
   SetRect(name + "E", time[s], top, time[e], bottom, border, false);
  }

//+------------------------------------------------------------------+
//| 長方形オブジェクトの作成・移動                                   |
//+------------------------------------------------------------------+
void SetRect(const string name, const datetime t1, const double p1,
             const datetime t2, const double p2, const color clr, const bool fill)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, name, OBJPROP_FILL, fill);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
//| テキストオブジェクトの作成・移動                                 |
//+------------------------------------------------------------------+
void SetText(const string name, const datetime t, const double price,
             const string text, const color clr, const ENUM_ANCHOR_POINT anchor)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
      ObjectMove(0, name, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpLabelSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
//| ラベルと足の間隔（直近10本の平均値幅の20%）                       |
//+------------------------------------------------------------------+
double LabelOffset(const int i, const double &high[], const double &low[])
  {
   int    n   = MathMin(10, i + 1);
   double sum = 0.0;
   for(int k = 0; k < n; k++)
      sum += high[i - k] - low[i - k];
   return(sum / n * 0.2);
  }

//+------------------------------------------------------------------+
//| 色を背景色と混ぜる（a=前景の割合）                                |
//+------------------------------------------------------------------+
color BlendColor(const color fg, const color bg, const double a)
  {
   int r = (int)MathRound(((fg      ) & 0xFF) * a + ((bg      ) & 0xFF) * (1.0 - a));
   int g = (int)MathRound(((fg >>  8) & 0xFF) * a + ((bg >>  8) & 0xFF) * (1.0 - a));
   int b = (int)MathRound(((fg >> 16) & 0xFF) * a + ((bg >> 16) & 0xFF) * (1.0 - a));
   return((color)(r | (g << 8) | (b << 16)));
  }

//+------------------------------------------------------------------+
//| 通知                                                             |
//+------------------------------------------------------------------+
void Notify(const string msg)
  {
   if(InpAlertPopup)
      Alert(msg);
   if(InpAlertPush)
      SendNotification(msg);
  }

//+------------------------------------------------------------------+
//| 補助                                                             |
//+------------------------------------------------------------------+
string TimeKey(const datetime t)
  {
   return(IntegerToString((long)t));
  }

string TimeframeText()
  {
   return(StringSubstr(EnumToString((ENUM_TIMEFRAMES)_Period), 7));   // "PERIOD_M15" → "M15"
  }
//+------------------------------------------------------------------+
