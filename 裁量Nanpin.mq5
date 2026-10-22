//+------------------------------------------------------------------+
//|                                                 裁量Nanpin.mq5   |
//|   裁量Nanpin  v4.72                                               |
//|   ・レート予約：SELL／BUY 各3つの入力ボックス。到達で成行＋指値     |
//|                                                                  |
//|   【エントリー】                                                  |
//|   ・順張り（初期値）：上位足の方向に、下位足の±2σ到達→±1.3σ戻りで |
//|     エントリー（例：下落中は−2σ到達後、−1.3σまで戻したら売り）    |
//|   ・逆張り（選択可）：確定足がバンドの外でエントリー                |
//|   ・再ブレイク（選択可）：直近N本の高値（安値）をブレイク→走る→     |
//|     内側へ戻る→高値（安値）を現在値で再ブレイクしたらエントリー      |
//|     決済：終値で損切りライン割れ／第1目標で建値＋トレール／時間切れ |
//|   ・自動化：しない／自動エントリー（パネルで切替）・通知機能なし    |
//|   ・上位足フィルター：上位足の方向に逆らわない（押し目買い・戻り売り）|
//|   ・ATR：上限・下限で新規停止／間隔・利確幅を可変（チャートには非表示）|
//|   ・7th HEAVEN風グリッド：成行1本＋一定間隔の指値を複数本           |
//|   ・裁量ボタン：SELL／BUY の成行グリッド、自EAポジの決済（確認なし）|
//|   【決済】                                                        |
//|   ・不利な位置のポジションは微益利確、最有利の1本は伸ばす           |
//|     （BBミドル到達で決済 or 裁量、建値ストップ＋トレール）          |
//|   ・目標利益：自EAの合計損益が目標額に達したら全決済＋指値削除      |
//|   ・一括決済・指値削除は非同期で一斉送信（高速化）                  |
//|   【損切り監視】                                                  |
//|   ・本EAのポジションを SELL群／BUY群 別に集計                      |
//|   ・個別ポジ（指値約定分を含む）には損切りを置かない                |
//|   ・各群の含み損合計が強制決済額（初期30万円）に達した時だけ全決済  |
//|   ・発動時に未約定注文を削除、発動方向は解除ボタンまでロック        |
//|   ・円口座は円、ドル口座はドルを自動判定                            |
//|   ・銘柄のサフィックス有無（XAUUSD／XAUUSDx／XAUUSD-m 等）を同一視  |
//+------------------------------------------------------------------+
#property copyright "KOHI"
#property version   "4.72"
//--- 説明文（#property description）は MetaEditor のプロジェクト（.mqproj）側の設定と
//--- 重複して警告が出るため記載していません。使い方は設定ガイドを参照してください。

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 列挙型                                                           |
//+------------------------------------------------------------------+
enum ENUM_AUTO_MODE
  {
   AUTO_OFF   = 0,          // 自動化しない（裁量ボタンのみ）
   AUTO_TRADE = 1           // 自動エントリー
  };

enum ENUM_ENTRY_MODE
  {
   ENTRY_TREND    = 0,      // 順張り（上位足の方向＋下位足の±2σ到達→±1.3σへの戻り）
   ENTRY_REVERSAL = 1,      // 逆張り（確定足がバンドの外）
   ENTRY_REBREAK  = 2       // 再ブレイク（直近高値・安値をブレイク→走る→戻る→再ブレイク）
  };

enum ENUM_RB_TRAIL
  {
   RB_TRAIL_OFF  = 0,       // トレールしない
   RB_TRAIL_ATR  = 1,       // 最も有利な価格からATR×倍率
   RB_TRAIL_BARS = 2        // 直近N本の安値（SELLは高値）
  };

enum ENUM_SIGNAL_MODE
  {
   SIG_CLOSE  = 0,          // 確定足の終値がバンドの外
   SIG_TOUCH  = 1,          // 確定足の高値／安値がバンドにタッチ
   SIG_REVERT = 2           // バンドの外から内側に戻った（反転確認）
  };

enum ENUM_HTF_NEUTRAL
  {
   HTF_NEUTRAL_BOTH = 0,    // 両方向を許可
   HTF_NEUTRAL_NONE = 1     // エントリーしない
  };

enum ENUM_BEST_EXIT
  {
   BEST_MIDDLE = 0,         // BBミドル到達で決済（利益が出ている時のみ）
   BEST_MANUAL = 1          // 自動では決済しない（裁量）
  };

enum ENUM_DEL_ORDERS
  {
   DEL_ALL  = 0,            // 全ての未約定注文を削除（SELL・BUY両方）
   DEL_SAME = 1,            // 発動した方向の未約定注文のみ削除
   DEL_NONE = 2             // 削除しない
  };

//+------------------------------------------------------------------+
//| 入力パラメータ                                                   |
//+------------------------------------------------------------------+
input group "■ 自動化"
input ENUM_AUTO_MODE   InpAutoMode          = AUTO_OFF;           // 自動化（パネルのボタンでも切替可）
input bool             InpAllowBuy          = true;               // 買いエントリーを許可
input bool             InpAllowSell         = true;               // 売りエントリーを許可
input long             InpMagic             = 202310001;          // このEAのマジックナンバー

input group "■ エントリー方式"
input ENUM_ENTRY_MODE  InpEntryMode         = ENTRY_TREND;        // エントリー方式
input double           InpTrendEntryDev     = 1.3;                // 順張り：戻りでエントリーするσ（下落なら−2σ到達後に−1.3σで売り）
input int              InpTrendLookback     = 10;                 // 順張り：±2σ到達を有効とする本数（エントリー足）
input ENUM_SIGNAL_MODE InpSignalMode        = SIG_CLOSE;          // 逆張り：シグナル条件

input group "■ 再ブレイク（ブレイク→走る→戻る→再ブレイクでエントリー）"
input int              InpRbLookback        = 20;                 // 基準ライン：直近何本の高値・安値か（エントリー足・確定足）
input double           InpRbRunATR          = 1.0;                // 「走った」とみなす幅：ブレイク後、基準ラインからATR×この倍率以上
input double           InpRbPullATR         = 0.2;                // 「戻った」とみなす幅：基準ラインの内側へATR×この倍率以上
input double           InpRbFailATR         = 1.5;                // 無効：基準ラインの内側へATR×この倍率以上戻ったら（戻りが深すぎ）
input int              InpRbMaxBars         = 30;                 // 無効：ブレイクからこの本数以内に再ブレイクしなければ（0＝無制限）

input group "■ 再ブレイクの決済（再ブレイクで建てたグリッドごと）"
input double           InpRbStopATR         = 1.5;                // 1)損切り：確定足の終値が基準ラインの内側へATR×この倍率を超えたら全決済（0＝OFF）
input bool             InpRbBEAtExt         = true;               // 2)第1目標（ブレイク後の高値・安値）到達で建値ストップ＋残りの指値を削除
input ENUM_RB_TRAIL    InpRbTrailMode       = RB_TRAIL_ATR;       // 3)第1目標到達後のトレール
input double           InpRbTrailATR        = 1.0;                // 3)トレール幅：最も有利な価格からATR×この倍率
input int              InpRbTrailBars       = 5;                  // 3)トレール：直近この本数の安値（SELLは高値）
input int              InpRbTimeBars        = 20;                 // 4)時間切れ：エントリーからこの本数以内に第1目標へ届かなければ全決済（0＝OFF）
input bool             InpRbFitGrid         = true;               // ナンピンの指値を損切りラインの内側に収める（間隔を自動調整・最小は指値の間隔）

input group "■ エントリー足・ボリンジャーバンド"
input ENUM_TIMEFRAMES  InpEntryTF           = PERIOD_CURRENT;     // エントリー足（PERIOD_CURRENT＝チャートの時間足）
input int              InpBBPeriod          = 20;                 // BBの移動平均（ミドル）の期間 ※±σもこの期間で計算
input double           InpBBDev             = 2.0;                // BB偏差（σ）※順張りの到達確認・逆張りの判定に使用
input double           InpMaxSpread         = 0.50;               // 自動エントリー時の最大スプレッド（価格差・0＝無制限）

input group "■ 上位足フィルター（マルチタイムフレーム）"
input bool             InpUseHTF            = true;               // 上位足フィルターを使う（全方式共通：上位足の方向にだけエントリー）
input ENUM_TIMEFRAMES  InpHTF               = PERIOD_H4;          // 上位足
input int              InpHTFBBPeriod       = 20;                 // 上位足BBの移動平均（ミドル）の期間（ミドルラインで方向判定）
input double           InpHTFBBDev          = 2.0;                // 上位足BB偏差（σ）
input int              InpHTFSlopeBars      = 3;                  // ミドルの傾き判定本数（0＝傾きを見ない）
input ENUM_HTF_NEUTRAL InpHTFNeutral        = HTF_NEUTRAL_BOTH;   // 上位足の方向が定まらない時

input group "■ ATR"
input int              InpATRPeriod         = 14;                 // ATR期間
input double           InpATRMax            = 0;                  // ATR上限（価格差・超えたら新規停止・0＝OFF）
input double           InpATRMin            = 0;                  // ATR下限（価格差・下回ったら新規停止・0＝OFF）
input double           InpPipSize           = 0;                  // 1pipsの価格（0＝自動：GOLDは0.1）
input bool             InpShowIndicators    = true;               // BBをチャートに表示

input group "■ グリッド（7th HEAVEN風）"
input double           InpLot               = 0.01;               // 1本あたりのロット
input int              InpGridCount         = 10;                 // 指値の本数（成行1本＋指値○本）
input double           InpGridStep          = 1.0;                // 指値の間隔（価格差・GOLDなら1.0＝1ドル）※ATR可変時は最小値
input double           InpMicroTP           = 2.0;                // 微益利確幅（価格差）※ATR可変時は最小値
input bool             InpUseATRWidth       = false;              // 間隔・利確幅をATRで可変にする
input double           InpStepATRMult       = 0.3;                // 指値間隔＝ATR×この倍率
input double           InpTPATRMult         = 0.6;                // 微益利確幅＝ATR×この倍率
input double           InpGridExpireHours   = 0;                  // 全ポジ決済後に残った指値を削除するまでの時間（0＝時間では削除しない）
input int              InpMaxGridsPerSide   = 5;                  // 自動エントリーの同方向グリッド上限（裁量は無制限）
input bool             InpAutoAddGrid       = false;              // 自動：同方向のグリッド稼働中でも追加エントリーする

input group "■ 最有利ポジション（伸ばす1本）"
input ENUM_BEST_EXIT   InpBestExit          = BEST_MANUAL;        // 決済方法
input double           InpBestBE            = 0.0;                // 建値ストップ発動幅（価格差・0＝OFF）
input double           InpBestTrail         = 0.0;                // 建値移動後のトレール幅（価格差・0＝OFF）

input group "■ 損切り監視：強制決済額の初期値（口座通貨を自動判定・パネルで随時変更可）"
input double           InpSL_JPY            = 300000;             // 円口座：SELL群・BUY群それぞれの強制決済額（含み損合計・円）
input double           InpSL_USD            = 2000;               // ドル口座：SELL群・BUY群それぞれの強制決済額（含み損合計・USD）
input double           InpSL_Other          = 0;                  // その他通貨の口座：強制決済額（口座通貨）
input bool             InpIncludeSwap       = false;              // スワップを含めて判定
input bool             InpIncludeCommission = false;              // 手数料（新規約定分）を含めて判定

input group "■ 目標利益"
input double           InpTargetProfit      = 0;                  // 目標利益の初期値（自EAの合計損益がこの額に達したら全決済・口座通貨・0＝OFF・パネルで随時変更可）

input group "■ 損切り監視：発動時の動作"
input ENUM_DEL_ORDERS  InpDeleteOrders      = DEL_ALL;            // 未約定の指値・逆指値の扱い
input bool             InpLockAfterSL       = true;               // 発動した方向をロック（解除ボタンまで新規注文削除・新規ポジ即決済）
input int              InpDeviationPoints   = 100;                // 許容スリッページ（ポイント）※GOLD 2桁なら100＝1ドル
input int              InpMaxRetry          = 5;                  // 決済が残った時に警告を出すまでの再送回数（1秒間隔で再送し続ける）
input bool             InpDryRun            = false;              // 損切りのテストモード（判定のみ・決済しない）

input group "■ レート予約（7th HEAVEN風の入力ボックス）"
input double           InpTempWidth         = 5.0;                // 「+50」ボタンの仮レート幅（価格差・GOLDなら5.0＝50pips）
input color            InpSellLineColor     = clrRed;             // SELL予約ラインの色
input color            InpBuyLineColor      = clrBlue;            // BUY予約ラインの色

input group "■ パネル表示"
input int              InpPanelX            = 0;                  // パネル位置 X（左端から）
input int              InpPanelY            = 20;                 // パネル位置 Y（上端から）
input int              InpFontSize          = 10;                 // 文字サイズ（9〜14推奨）

//+------------------------------------------------------------------+
//| 定数・構造体・グローバル変数                                      |
//+------------------------------------------------------------------+
#define SIDE_SELL    0
#define SIDE_BUY     1
#define OBJ_PREFIX   "7HA3_"
#define LOG_TAG      "[裁量Nanpin] "

struct SideStat
  {
   int               count;      // 本EAのポジ数
   double            lots;
   double            profit;     // 合計損益（口座通貨）
   int               orders;     // 監視対象の未約定注文数
   int               ownCount;   // うち自EAのポジ数
   int               ownOrders;  // うち自EAの注文数
  };

CTrade            g_trade;
CTrade            g_fast;      // 一括決済・指値削除用（非同期：応答を待たずに一斉送信）

//--- 監視対象（本EAのみ）
string            g_targetCore     = "";
string            g_scName[];
string            g_scCore[];

//--- 口座・状態
string            g_currency       = "";
double            g_initAmount     = 0.0;
string            g_gvBase         = "";
ENUM_AUTO_MODE    g_autoMode       = AUTO_OFF;

double            g_slAmt[2];
bool              g_enabled[2];
bool              g_locked[2];
bool              g_closing[2];
bool              g_warned[2];
bool              g_dryNotified[2];
bool              g_stuckNotified[2];
bool              g_lockNotified[2];
double            g_balanceBefore[2];
double            g_triggerProfit[2];
int               g_closedCount[2];
int               g_closeTries[2];
int               g_deletedCount[2];
ulong             g_lastTryMs[2];
ulong             g_lastLockMs[2];

//--- グリッド
double            g_gridTP[2];
double            g_gridStep[2];
datetime          g_gridTime[2];
datetime          g_lastBarTime    = 0;
ulong             g_lastManageMs   = 0;

//--- インジケーター
ENUM_TIMEFRAMES   g_entryTF        = PERIOD_CURRENT;
int               g_hBB            = INVALID_HANDLE;
int               g_hATR           = INVALID_HANDLE;
int               g_hBBH           = INVALID_HANDLE;
int               g_hBBE           = INVALID_HANDLE;   // 順張りのエントリー用（±1.3σ）
datetime          g_armUsed[2];                        // 順張り：使用済みの±2σ到達足
#define RES_SLOTS    3
double            g_resRate[2][RES_SLOTS];             // レート予約（0＝未設定）
int               g_resDir[2][RES_SLOTS];              // 1＝上昇して到達、-1＝下落して到達
ulong             g_lastTrendMs    = 0;

//--- 再ブレイク
struct RebreakState
  {
   int               stage;      // 0＝ブレイク待ち 1＝走り待ち 2＝戻り待ち 3＝再ブレイク待ち
   double            level;      // ブレイクした基準ライン（直近N本の高値・安値）
   double            ext;        // ブレイク後の最も外側の価格（BUYは最高値・SELLは最安値）
   double            atr;        // ブレイク時のATR（確定足）
   datetime          breakTime;  // ブレイクした足
  };
RebreakState      g_rb[2];
double            g_rbLevel[2];                        // 待機中の基準ライン（新しい足で更新）
double            g_rbUsed[2];                         // エントリー済みの基準ライン
datetime          g_rbBarTime      = 0;
struct RbTrade                                         // 再ブレイクで建てたグリッドの決済管理
  {
   int               gid;        // グリッド番号
   int               side;
   double            level;      // 基準ライン
   double            ext;        // 第1目標（ブレイク後の高値・安値）
   double            atr;        // エントリー時のATR
   double            peak;       // エントリー後の最も有利な価格（トレール用）
   datetime          entryTime;  // エントリーした足
   bool              beDone;     // 第1目標に到達済み
   bool              closing;    // 全決済の送信済み
   ulong             sendMs;
  };
RbTrade           g_rbt[];
datetime          g_rbtBarTime     = 0;
ulong             g_lastRbtMs      = 0;
bool              g_rbtWarned      = false;
int               g_hATRH          = INVALID_HANDLE;
double            g_pip            = 0.1;
string            g_bbName         = "";
int               g_bbWin          = -1;

//--- 実行環境（バックテストの軽量化）
bool              g_tester         = false;            // ストラテジーテスター
bool              g_noPanel        = false;            // パネルを描かない（ビジュアルモードでないテスター）
ulong             g_lastPanelMs    = 0;

//--- 一括決済（決済ボタン・目標利益）
bool              g_flatActive     = false;
int               g_flatSide       = -1;               // -1＝SELL・BUY両方
string            g_flatReason     = "";
int               g_flatPos        = 0;                // 開始時のポジ数
int               g_flatOrd        = 0;                // 開始時の指値数
int               g_flatTries      = 0;
ulong             g_flatStartMs    = 0;
ulong             g_flatSendMs     = 0;
double            g_targetAmt      = 0.0;              // 目標利益（0＝OFF）

int               g_failPrintCount = 0;
string            g_lastEvent      = "";
string            g_lastSignal     = "";
string            g_lastAction     = "";
bool              g_actionErr      = false;
bool              g_collapsed      = false;   // パネルを折りたたみ中
int               g_gridSeq        = 0;

ulong             g_commId[];
double            g_commVal[];

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_tester  = (bool)MQLInfoInteger(MQL_TESTER);
   g_noPanel = g_tester && !(bool)MQLInfoInteger(MQL_VISUAL_MODE);

   if(InpLot <= 0 || InpGridCount < 0 || InpGridStep <= 0 || InpMicroTP <= 0 || InpBBPeriod < 2 || InpATRPeriod < 1 || InpMaxGridsPerSide < 1 ||
      InpTrendEntryDev <= 0 || InpTrendEntryDev >= InpBBDev || InpTrendLookback < 0 ||
      InpRbLookback < 1 || InpRbRunATR <= 0 || InpRbPullATR < 0 || InpRbFailATR <= InpRbPullATR || InpRbMaxBars < 0 ||
      InpRbStopATR < 0 || InpRbTrailATR <= 0 || InpRbTrailBars < 1 || InpRbTimeBars < 0)
     {
      Print(LOG_TAG + "ロット・本数・間隔・利確幅・期間の設定を確認してください。");
      return(INIT_PARAMETERS_INCORRECT);
     }

//--- 銘柄の基本名（サフィックス有無を同一視：状態保存のキーに使用）
   ArrayResize(g_scName, 0);
   ArrayResize(g_scCore, 0);
   ArrayResize(g_rbt, 0);
   g_targetCore = SymbolCore(_Symbol);
   if(StringLen(g_targetCore) < 3)
      g_targetCore = _Symbol;

//--- 口座通貨
   g_currency = AccountInfoString(ACCOUNT_CURRENCY);
   if(g_currency == "JPY")
      g_initAmount = InpSL_JPY;
   else
      if(g_currency == "USD")
         g_initAmount = InpSL_USD;
      else
         g_initAmount = InpSL_Other;
   g_initAmount = MathAbs(g_initAmount);

//--- インジケーター（使う方式・機能の分だけ作成：バックテストの軽量化）
   g_entryTF = (InpEntryTF == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpEntryTF;
   bool needE  = (InpEntryMode == ENTRY_TREND);
   bool needH  = InpUseHTF;
   bool needAH = !g_noPanel;   // 上位足ATRはパネル表示のみで使用
   g_hBB   = iBands(_Symbol, g_entryTF, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   g_hATR  = iATR(_Symbol, g_entryTF, InpATRPeriod);
   g_hBBH  = needH  ? iBands(_Symbol, InpHTF, InpHTFBBPeriod, 0, InpHTFBBDev, PRICE_CLOSE) : INVALID_HANDLE;
   g_hATRH = needAH ? iATR(_Symbol, InpHTF, InpATRPeriod) : INVALID_HANDLE;
   g_hBBE  = needE  ? iBands(_Symbol, g_entryTF, InpBBPeriod, 0, InpTrendEntryDev, PRICE_CLOSE) : INVALID_HANDLE;
   if(g_hBB == INVALID_HANDLE || g_hATR == INVALID_HANDLE || (needH && g_hBBH == INVALID_HANDLE) ||
      (needAH && g_hATRH == INVALID_HANDLE) || (needE && g_hBBE == INVALID_HANDLE))
     {
      Print(LOG_TAG + "インジケーターを作成できませんでした。");
      return(INIT_FAILED);
     }
   g_pip = CalcPip();

   g_bbName  = "";
   if(InpShowIndicators && g_entryTF == (ENUM_TIMEFRAMES)_Period && !MQLInfoInteger(MQL_TESTER))
     {
      //--- BBをメインウィンドウに表示（終了時に自分が追加した分だけ削除）。ATRは計算のみで表示しない
      if(ChartIndicatorAdd(0, 0, g_hBB))
        {
         g_bbWin  = 0;
         g_bbName = ChartIndicatorName(0, 0, ChartIndicatorsTotal(0, 0) - 1);
        }
     }

//--- 取引設定
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)MathMax(0, InpDeviationPoints));
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   g_fast.SetExpertMagicNumber((ulong)InpMagic);
   g_fast.SetDeviationInPoints((ulong)MathMax(0, InpDeviationPoints));
   g_fast.SetAsyncMode(true);
   g_fast.LogLevel(LOG_LEVEL_ERRORS);

//--- 状態初期化
   for(int s = 0; s < 2; s++)
     {
      g_slAmt[s]         = g_initAmount;
      g_enabled[s]       = true;
      g_locked[s]        = false;
      g_closing[s]       = false;
      g_warned[s]        = false;
      g_dryNotified[s]   = false;
      g_stuckNotified[s] = false;
      g_lockNotified[s]  = false;
      g_balanceBefore[s] = 0.0;
      g_triggerProfit[s] = 0.0;
      g_closedCount[s]   = 0;
      g_closeTries[s]    = 0;
      g_deletedCount[s]  = 0;
      g_lastTryMs[s]     = 0;
      g_lastLockMs[s]    = 0;
      g_gridTP[s]        = 0.0;
      g_gridStep[s]      = 0.0;
      g_gridTime[s]      = 0;
      g_armUsed[s]       = 0;
      g_rb[s].stage      = 0;
      g_rb[s].level      = 0.0;
      g_rb[s].ext        = 0.0;
      g_rb[s].atr        = 0.0;
      g_rb[s].breakTime  = 0;
      g_rbLevel[s]       = 0.0;
      g_rbUsed[s]        = 0.0;
      for(int r = 0; r < RES_SLOTS; r++)
        {
         g_resRate[s][r] = 0.0;
         g_resDir[s][r]  = 0;
        }
     }
   g_autoMode = InpAutoMode;
   g_targetAmt   = MathAbs(InpTargetProfit);
   g_flatActive  = false;

   g_gvBase = "7HA_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" +
              g_targetCore + "_" + IntegerToString(InpMagic);
   if(!g_tester)
      LoadState();   // テスターでは毎回まっさらな状態から始める

//--- 起動直後の足ではエントリーしない
   g_lastBarTime = iTime(_Symbol, g_entryTF, 0);

   PrintFormat("%s起動 v4.72：口座通貨=%s／自動化=%s／方式=%s／エントリー足=%s／上位足=%s／SELL損切り=%s／BUY損切り=%s／監視Magic=%s／銘柄=%s",
               LOG_TAG, g_currency, AutoModeText(g_autoMode), EntryModeText(), TFName(g_entryTF),
               (InpUseHTF ? TFName(InpHTF) : "OFF"),
               FormatMoney(g_slAmt[SIDE_SELL]), FormatMoney(g_slAmt[SIDE_BUY]),
               MagicListText(), ScopeText());
   for(int s = 0; s < 2; s++)
      if(g_locked[s])
         Print(LOG_TAG + SideName(s) + "はロック中です（前回の損切り後、未解除）。");

   if(!g_noPanel)
      CreatePanel();
   if(!g_tester)
      EventSetMillisecondTimer(500);   // テスターではティックだけで十分（タイマー分の処理を省く）
   MainLoop();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| 終了                                                             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   SaveState();
   RemoveOurIndicators();
   ObjectsDeleteAll(0, OBJ_PREFIX);
   if(g_hBB != INVALID_HANDLE)
      IndicatorRelease(g_hBB);
   if(g_hATR != INVALID_HANDLE)
      IndicatorRelease(g_hATR);
   if(g_hBBH != INVALID_HANDLE)
      IndicatorRelease(g_hBBH);
   if(g_hATRH != INVALID_HANDLE)
      IndicatorRelease(g_hATRH);
   if(g_hBBE != INVALID_HANDLE)
      IndicatorRelease(g_hBBE);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   MainLoop();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   MainLoop();
  }

//+------------------------------------------------------------------+
//| メインループ                                                     |
//+------------------------------------------------------------------+
void MainLoop()
  {
   GuardCheck();     // 1) 損切り監視（最優先）
   ProcessFlatten(); // 1') 一括決済（決済ボタン・目標利益）の完了確認・再送
   CheckTarget();    // 1'') 目標利益の到達チェック
   CheckNewBar();    // 2) 逆張り：新しい足でシグナル判定
   CheckTrendEntry();// 2') 順張り：±2σ到達→±1.3σ戻りを監視
   CheckRebreak();   // 2'') 再ブレイク：ブレイク→走る→戻る→再ブレイクを監視
   CheckReservations(); // 2'') レート予約の到達チェック
   ManageOwn();      // 3) 自EAポジションの微益利確・最有利ポジ管理
   ManageRebreakTrades(); // 3') 再ブレイクのグリッドの損切り・建値・トレール・時間切れ
   RefreshPanel(false);
  }

//+------------------------------------------------------------------+
//| 判定の間引き用の時刻（ミリ秒）                                    |
//|   テスターではシミュレーション上のティック時刻を使う                |
//|   （実時間を使うと、高速なテストで判定が何時間分も飛ばされるため）   |
//+------------------------------------------------------------------+
ulong NowMs()
  {
   if(g_tester)
     {
      MqlTick tk;
      if(SymbolInfoTick(_Symbol, tk))
         return((ulong)tk.time_msc);
      return((ulong)TimeCurrent() * 1000);
     }
   return(GetTickCount64());
  }

//+------------------------------------------------------------------+
//| チャートイベント（パネル操作）                                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_ENDEDIT)
     {
      for(int s = 0; s < 2; s++)
         if(sparam == ObjName("edit", s))
            ApplyEdit(s);
      if(sparam == OBJ_PREFIX + "tgt")
         ApplyTarget();
     }

   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(StringFind(sparam, OBJ_PREFIX) == 0)
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

      //--- 自動化モードの切替
      if(sparam == OBJ_PREFIX + "auto")
        {
         g_autoMode = (g_autoMode == AUTO_TRADE) ? AUTO_OFF : AUTO_TRADE;
         SaveState();
         SetAction("自動化を「" + AutoModeText(g_autoMode) + "」に切り替えました");
        }

      //--- パネルの折りたたみ／展開
      if(sparam == OBJ_PREFIX + "collapse")
        {
         g_collapsed = !g_collapsed;
         SaveState();
         ObjectsDeleteAll(0, OBJ_PREFIX);
         CreatePanel();
        }

      //--- レート予約ボタン
      if(sparam == OBJ_PREFIX + "rsset")
         ApplyReservations();
      if(sparam == OBJ_PREFIX + "rsclear")
         ClearReservations(-1);
      if(sparam == OBJ_PREFIX + "rsplus")
         FillTempRates();
      if(sparam == ObjName("rsdel", SIDE_SELL))
         ClearReservations(SIDE_SELL);
      if(sparam == ObjName("rsdel", SIDE_BUY))
         ClearReservations(SIDE_BUY);

      for(int s = 0; s < 2; s++)
        {
         if(sparam == ObjName("onoff", s))
           {
            g_enabled[s] = !g_enabled[s];
            g_warned[s]  = false;
            SaveState();
            Print(LOG_TAG + SideName(s) + "群の損切りを" + (g_enabled[s] ? "ON" : "OFF") + "にしました。");
           }

         if(sparam == ObjName("release", s) && g_locked[s])
           {
            string q = SideName(s) + "のロックを解除して、監視・エントリーを再開しますか？\n\n" +
                       "※相場を分析し直してから解除してください。";
            if(MessageBox(q, "裁量Nanpin", MB_YESNO | MB_ICONQUESTION) == IDYES)
              {
               g_locked[s]       = false;
               g_lockNotified[s] = false;
               g_warned[s]       = false;
               SaveState();
               SetAction(SideName(s) + "のロックを解除しました");
              }
           }

         if(sparam == ObjName("manual", s))
            ManualEntry(s);

         if(sparam == ObjName("closeown", s))
            ManualCloseOwn(s);
        }
     }

   RefreshPanel(true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|   ■ エントリー                                                   |
//|                                                                  |
//+------------------------------------------------------------------+
void CheckNewBar()
  {
   datetime t = iTime(_Symbol, g_entryTF, 0);
   if(t == 0 || t == g_lastBarTime)
      return;
   if(g_lastBarTime == 0)
     {
      g_lastBarTime = t;   // 起動直後（データ未取得だった場合）は判定しない
      return;
     }
   g_lastBarTime = t;
   if(InpEntryMode != ENTRY_REVERSAL)
      return;

   for(int s = 0; s < 2; s++)
     {
      if(!CheckSignal(s))
         continue;

      string reason = "";
      bool   ok     = EntryAllowed(s, false, reason);
      double up1    = Buf(g_hBB, 1, 1);
      double lo1    = Buf(g_hBB, 2, 1);
      double c1     = iClose(_Symbol, g_entryTF, 1);

      g_lastSignal = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + " " + SideName(s) +
                     (ok ? "" : "（見送り：" + reason + "）");

      string msg = StringFormat("%sシグナル（%s）：終値 %s ／ BB上 %s ／ 下 %s",
                                SideName(s), TFName(g_entryTF), PriceText(c1), PriceText(up1), PriceText(lo1));

      if(g_autoMode == AUTO_TRADE)
        {
         if(ok)
            PlaceGrid(s, false);
         else
            Print(LOG_TAG + msg + "　→ 見送り：" + reason);
        }
     }
  }

//+------------------------------------------------------------------+
//| 順張りエントリー                                                  |
//|   SELL：上位足が下降 → 下位足で−2σに到達 → −1.3σまで戻したら売り   |
//|   BUY ：上位足が上昇 → 下位足で＋2σに到達 → ＋1.3σまで押したら買い |
//+------------------------------------------------------------------+
void CheckTrendEntry()
  {
   if(InpEntryMode != ENTRY_TREND)
      return;
   ulong now = NowMs();
   if(g_lastTrendMs != 0 && (now - g_lastTrendMs) < 250)
      return;
   g_lastTrendMs = now;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = Buf(g_hBB, 0, 0);
   if(bid <= 0 || ask <= 0 || mid == EMPTY_VALUE)
      return;

   for(int side = 0; side < 2; side++)
     {
      if(!TrendSideAllowed(side))
         continue;

      datetime arm = LastExtremeTouch(side);
      if(arm == 0 || arm <= g_armUsed[side])
         continue;

      //--- 戻りの判定（±1.3σ に届き、まだミドルの手前）
      double e = Buf(g_hBBE, (side == SIDE_SELL) ? 2 : 1, 0);
      if(e == EMPTY_VALUE)
         continue;
      bool trigger = (side == SIDE_SELL) ? (bid >= e && bid < mid) : (ask <= e && ask > mid);
      if(!trigger)
         continue;

      g_armUsed[side] = arm;   // この到達では1回だけ
      SaveState();

      string reason = "";
      bool   ok     = EntryAllowed(side, false, reason);
      string msg    = StringFormat("順張り%sシグナル（%s）：%s%.1fσ到達後、%s%.1fσ（%s）まで戻り",
                                   SideName(side), TFName(g_entryTF),
                                   (side == SIDE_SELL ? "−" : "＋"), InpBBDev,
                                   (side == SIDE_SELL ? "−" : "＋"), InpTrendEntryDev, PriceText(e));
      g_lastSignal = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + " " + SideName(side) +
                     (g_autoMode == AUTO_TRADE ? (ok ? "" : "（見送り：" + reason + "）") : "（自動化OFF）");

      if(g_autoMode == AUTO_TRADE)
        {
         if(ok)
            PlaceGrid(side, false);
         else
            Print(LOG_TAG + msg + "　→ 見送り：" + reason);
        }
      else
         Print(LOG_TAG + msg + "　→ 自動化OFFのため発注なし");
     }
  }

//+------------------------------------------------------------------+
//| 上位足の方向から、順張りで狙える方向か                              |
//+------------------------------------------------------------------+
bool TrendSideAllowed(const int side)
  {
   if(side == SIDE_SELL && !InpAllowSell)
      return(false);
   if(side == SIDE_BUY && !InpAllowBuy)
      return(false);
   if(!InpUseHTF)
      return(true);
   int tr = HTFTrend();
   if(tr == 0)
      return(InpHTFNeutral == HTF_NEUTRAL_BOTH);
   return(side == SIDE_SELL ? tr == -1 : tr == 1);
  }

//+------------------------------------------------------------------+
//| 直近の±2σ到達足の時刻（SELL＝安値が−2σ以下、BUY＝高値が＋2σ以上）  |
//+------------------------------------------------------------------+
datetime LastExtremeTouch(const int side)
  {
   int cnt = InpTrendLookback + 1;
   double band[];
   double px[];
   ArraySetAsSeries(band, true);
   ArraySetAsSeries(px, true);
   if(CopyBuffer(g_hBB, (side == SIDE_SELL) ? 2 : 1, 0, cnt, band) != cnt)
      return(0);
   int got = (side == SIDE_SELL) ? CopyLow(_Symbol, g_entryTF, 0, cnt, px) : CopyHigh(_Symbol, g_entryTF, 0, cnt, px);
   if(got != cnt)
      return(0);
   for(int i = 0; i < cnt; i++)
     {
      bool touched = (side == SIDE_SELL) ? (px[i] <= band[i]) : (px[i] >= band[i]);
      if(touched)
        {
         //--- 到達後に確定足がミドルを越えて戻っていたら、その到達は無効（戻りが深すぎる）
         if(i >= 2)
           {
            double mid[];
            double cl[];
            ArraySetAsSeries(mid, true);
            ArraySetAsSeries(cl, true);
            if(CopyBuffer(g_hBB, 0, 0, i, mid) != i || CopyClose(_Symbol, g_entryTF, 0, i, cl) != i)
               return(0);
            for(int k = 1; k < i; k++)
               if(side == SIDE_SELL ? cl[k] > mid[k] : cl[k] < mid[k])
                  return(0);
           }
         return(iTime(_Symbol, g_entryTF, i));
        }
     }
   return(0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|   ■ 再ブレイク                                                    |
//|     BUY ：直近N本の高値を上抜け → ATR×倍率以上走る → 高値の内側へ   |
//|           ATR×倍率以上戻る → 高値を再び上抜けたら買い              |
//|     SELL：上記の逆（直近N本の安値）                                 |
//|     判定は現在値（Bid）でリアルタイム。基準ラインは新しい足で更新    |
//|                                                                  |
//+------------------------------------------------------------------+
void CheckRebreak()
  {
   if(InpEntryMode != ENTRY_REBREAK)
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0)
      return;

//--- 新しい足：待機中の基準ライン（直近N本の高値・安値）を更新し、期限切れを確認
   datetime t0 = iTime(_Symbol, g_entryTF, 0);
   if(t0 == 0)
      return;
   if(t0 != g_rbBarTime)
     {
      int hi = iHighest(_Symbol, g_entryTF, MODE_HIGH, InpRbLookback, 1);
      int lo = iLowest(_Symbol, g_entryTF, MODE_LOW, InpRbLookback, 1);
      if(hi < 0 || lo < 0)
         return;   // データ未取得：次回やり直す
      g_rbLevel[SIDE_BUY]  = iHigh(_Symbol, g_entryTF, hi);
      g_rbLevel[SIDE_SELL] = iLow(_Symbol, g_entryTF, lo);
      g_rbBarTime = t0;
      for(int s = 0; s < 2; s++)
         if(g_rb[s].stage > 0 && InpRbMaxBars > 0 && iBarShift(_Symbol, g_entryTF, g_rb[s].breakTime) > InpRbMaxBars)
            RebreakReset(s, "期限切れ（ブレイクから" + IntegerToString(InpRbMaxBars) + "本経過）");
     }

   for(int side = 0; side < 2; side++)
     {
      if((side == SIDE_BUY && !InpAllowBuy) || (side == SIDE_SELL && !InpAllowSell))
         continue;
      RebreakSide(side, bid);
     }
  }

//+------------------------------------------------------------------+
//| 1方向分の状態遷移                                                 |
//|   stage 0：ブレイク待ち → 1：走り待ち → 2：戻り待ち → 3：再ブレイク待ち |
//+------------------------------------------------------------------+
void RebreakSide(const int side, const double bid)
  {
   bool buy = (side == SIDE_BUY);

//--- 0：ブレイク待ち
   if(g_rb[side].stage == 0)
     {
      double wl = g_rbLevel[side];
      if(wl <= 0 || wl == g_rbUsed[side])
         return;   // エントリー済みのラインでは繰り返さない（新しい足でラインが更新されるまで）
      if(!(buy ? bid > wl : bid < wl))
         return;
      double wa = Buf(g_hATR, 0, 1);
      if(wa == EMPTY_VALUE || wa <= 0)
         return;
      g_rb[side].stage     = 1;
      g_rb[side].level     = wl;
      g_rb[side].ext       = bid;
      g_rb[side].atr       = wa;
      g_rb[side].breakTime = iTime(_Symbol, g_entryTF, 0);
      return;
     }

   double lvl = g_rb[side].level;
   double atr = g_rb[side].atr;
   double out = buy ? bid - lvl : lvl - bid;   // 基準ラインより外側への距離（内側はマイナス）
   if(buy ? bid > g_rb[side].ext : bid < g_rb[side].ext)
      g_rb[side].ext = bid;

//--- 1：走り待ち（走る前に内側へ戻ったらブレイク失敗。同じラインで判定し直す）
   if(g_rb[side].stage == 1)
     {
      if(out < 0)
        {
         g_rb[side].stage = 0;
         return;
        }
      if(out >= atr * InpRbRunATR)
        {
         g_rb[side].stage = 2;
         PrintFormat("%s再ブレイク%s：%s %s をブレイクし %s まで走った（ATR×%.1f）→ 戻り待ち", LOG_TAG, SideName(side),
                     (buy ? "高値" : "安値"), PriceText(lvl), PriceText(bid), InpRbRunATR);
        }
      return;
     }

//--- 2・3：内側へ深く戻りすぎたら無効
   if(out <= -atr * InpRbFailATR)
     {
      RebreakReset(side, StringFormat("戻りが深すぎ（%s が%s %s からATR×%.1f以上内側）", PriceText(bid),
                                      (buy ? "高値" : "安値"), PriceText(lvl), InpRbFailATR));
      return;
     }

//--- 2：戻り待ち
   if(g_rb[side].stage == 2)
     {
      if(out <= -atr * InpRbPullATR)
        {
         g_rb[side].stage = 3;
         PrintFormat("%s再ブレイク%s：%s まで戻り（%s %s の内側）→ 再ブレイク待ち", LOG_TAG, SideName(side),
                     PriceText(bid), (buy ? "高値" : "安値"), PriceText(lvl));
        }
      return;
     }

//--- 3：再ブレイク待ち
   if(out <= 0)
      return;

   g_rbUsed[side]   = lvl;
   g_rb[side].stage = 0;

   string reason = "";
   bool   ok     = EntryAllowed(side, false, reason);
   string msg    = StringFormat("再ブレイク%sシグナル（%s）：%s %s をブレイク→%s まで走り→戻り→現在値 %s で再ブレイク",
                                SideName(side), TFName(g_entryTF), (buy ? "高値" : "安値"), PriceText(lvl),
                                PriceText(g_rb[side].ext), PriceText(bid));
   g_lastSignal = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + " " + SideName(side) +
                  (g_autoMode == AUTO_TRADE ? (ok ? "" : "（見送り：" + reason + "）") : "（自動化OFF）");

   if(g_autoMode == AUTO_TRADE)
     {
      if(ok)
        {
         Print(LOG_TAG + msg);
         double line = RbLimitLine(side, lvl, atr);
         if(PlaceGrid(side, false, InpRbFitGrid ? line : 0.0))
            RbTradeAdd(g_gridSeq, side, lvl, g_rb[side].ext, atr, bid);
        }
      else
         Print(LOG_TAG + msg + "　→ 見送り：" + reason);
     }
   else
      Print(LOG_TAG + msg + "　→ 自動化OFFのため発注なし");
  }

//+------------------------------------------------------------------+
void RebreakReset(const int side, const string why)
  {
   if(g_rb[side].stage >= 2)
      Print(LOG_TAG + "再ブレイク" + SideName(side) + "：パターン無効 → " + why);
   g_rb[side].stage = 0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|   ■ 再ブレイクの決済（再ブレイクで建てたグリッドごとに管理）        |
//|     1) 損切り　：確定足の終値が 基準ライン∓ATR×倍率 を超えたら全決済 |
//|     2) 第1目標 ：ブレイク後の高値（安値）到達で建値ストップ          |
//|                  ＋残りの指値を削除                                |
//|     3) トレール：第1目標到達後、ATR幅 または 直近N本の安値（高値）   |
//|     4) 時間切れ：一定本数以内に第1目標へ届かなければ全決済           |
//|                                                                  |
//+------------------------------------------------------------------+
void RbTradeAdd(const int gid, const int side, const double level, const double ext, const double atr, const double px)
  {
   int n = ArraySize(g_rbt);
   ArrayResize(g_rbt, n + 1);
   g_rbt[n].gid       = gid;
   g_rbt[n].side      = side;
   g_rbt[n].level     = level;
   g_rbt[n].ext       = ext;
   g_rbt[n].atr       = atr;
   g_rbt[n].peak      = px;
   g_rbt[n].entryTime = iTime(_Symbol, g_entryTF, 0);
   g_rbt[n].beDone    = false;
   g_rbt[n].closing   = false;
   g_rbt[n].sendMs    = 0;
   SaveState();
   PrintFormat("%s再ブレイク%s #%d の決済管理：第1目標 %s／損切りライン %s（終値）／時間切れ %s", LOG_TAG, SideName(side), gid,
               PriceText(ext), (InpRbStopATR > 0 ? PriceText(RbStopLine(n)) : "OFF"),
               (InpRbTimeBars > 0 ? IntegerToString(InpRbTimeBars) + "本" : "OFF"));
  }

//+------------------------------------------------------------------+
void RbTradeRemove(const int i)
  {
   int n = ArraySize(g_rbt);
   for(int k = i; k < n - 1; k++)
      g_rbt[k] = g_rbt[k + 1];
   ArrayResize(g_rbt, n - 1);
   SaveState();
  }

//+------------------------------------------------------------------+
double RbStopLine(const int i)
  {
   double d = g_rbt[i].atr * InpRbStopATR;
   return(NormPrice(g_rbt[i].side == SIDE_BUY ? g_rbt[i].level - d : g_rbt[i].level + d));
  }

//+------------------------------------------------------------------+
//| ナンピンを収めるライン：損切りライン（OFFなら無効ライン）            |
//+------------------------------------------------------------------+
double RbLimitLine(const int side, const double level, const double atr)
  {
   double d = atr * (InpRbStopATR > 0 ? InpRbStopATR : InpRbFailATR);
   return(NormPrice(side == SIDE_BUY ? level - d : level + d));
  }

//+------------------------------------------------------------------+
//| グリッド番号の自EAポジション・指値の数                             |
//+------------------------------------------------------------------+
int GridPositions(const int gid)
  {
   int cnt   = 0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOwnPositionSelected())
         continue;
      int    g = 0;
      double w = 0.0;
      if(ParseGridComment(PositionGetString(POSITION_COMMENT), g, w) && g == gid)
         cnt++;
     }
   return(cnt);
  }

//+------------------------------------------------------------------+
int GridPositionsUnknown(const int side)
  {
   int cnt   = 0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOwnPositionSelected() || PositionSideSelected() != side)
         continue;
      int    g = 0;
      double w = 0.0;
      if(!ParseGridComment(PositionGetString(POSITION_COMMENT), g, w))
         cnt++;
     }
   return(cnt);
  }

//+------------------------------------------------------------------+
int GridOrders(const int gid)
  {
   int cnt   = 0;
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOwnOrderSelected())
         continue;
      int    g = 0;
      double w = 0.0;
      if(ParseGridComment(OrderGetString(ORDER_COMMENT), g, w) && g == gid)
         cnt++;
     }
   return(cnt);
  }

//+------------------------------------------------------------------+
//| グリッド番号の指値を削除（非同期）                                 |
//+------------------------------------------------------------------+
int DeleteGridOrders(const int gid)
  {
   int deleted = 0;
   int total   = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOwnOrderSelected())
         continue;
      int    g = 0;
      double w = 0.0;
      if(ParseGridComment(OrderGetString(ORDER_COMMENT), g, w) && g == gid && DeleteOrderTicket(ticket, true))
         deleted++;
     }
   return(deleted);
  }

//+------------------------------------------------------------------+
//| グリッドの全決済：指値削除＋ポジション決済を一斉送信（非同期）       |
//+------------------------------------------------------------------+
void SendGridClose(const int i)
  {
   int gid = g_rbt[i].gid;
   DeleteGridOrders(gid);
   int total = PositionsTotal();
   for(int k = total - 1; k >= 0; k--)
     {
      ulong ticket = PositionGetTicket(k);
      if(ticket == 0 || !IsOwnPositionSelected())
         continue;
      int    g = 0;
      double w = 0.0;
      if(ParseGridComment(PositionGetString(POSITION_COMMENT), g, w) && g == gid)
         ClosePositionTicket(ticket, true);
     }
   g_rbt[i].sendMs = NowMs();
  }

//+------------------------------------------------------------------+
void StartGridClose(const int i, const string why)
  {
   g_rbt[i].closing = true;
   g_failPrintCount = 0;
   SetAction(StringFormat("【%s】再ブレイク #%d を全決済：%s", SideName(g_rbt[i].side), g_rbt[i].gid, why));
   SendGridClose(i);
  }

//+------------------------------------------------------------------+
//| 毎ティック（0.3秒間隔）：再ブレイクのグリッドの決済管理             |
//+------------------------------------------------------------------+
void ManageRebreakTrades()
  {
//--- 足の切替は間引かずに検出（損切り・時間切れは確定足で判定）
//--- 管理中のグリッドがない間も追跡し、エントリー直後に古い足の確定と取り違えないようにする
   bool     newBar = false;
   datetime t0     = iTime(_Symbol, g_entryTF, 0);
   if(t0 != 0 && t0 != g_rbtBarTime)
     {
      newBar       = (g_rbtBarTime != 0);
      g_rbtBarTime = t0;
     }
   if(ArraySize(g_rbt) == 0)
      return;
   ulong now = NowMs();
   if(!newBar && g_lastRbtMs != 0 && (now - g_lastRbtMs) < 300)
      return;
   g_lastRbtMs = now;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
      return;

   for(int i = ArraySize(g_rbt) - 1; i >= 0; i--)
     {
      int  side = g_rbt[i].side;
      bool buy  = (side == SIDE_BUY);
      if(g_closing[side] || (g_flatActive && FlatSide(side)))
         continue;   // 損切り監視・一括決済の処理に任せる

      int gid = g_rbt[i].gid;
      int pos = GridPositions(gid);

//--- ポジションがなくなった：このグリッドは終了（残った指値も片付ける）
//--- ※グリッド番号を読めないポジション（ブローカーがコメントを書き換えた等）がある時は、誤判定を避けて何もしない
      if(pos == 0 && GridPositionsUnknown(side) > 0)
        {
         if(!g_rbtWarned)
           {
            Print(LOG_TAG + "ポジションのコメントからグリッド番号を読めないため、再ブレイクの決済管理を停止しています");
            g_rbtWarned = true;
           }
         continue;
        }
      if(pos == 0)
        {
         if(GridOrders(gid) > 0)
           {
            if(now - g_rbt[i].sendMs >= 1000)
              {
               DeleteGridOrders(gid);
               g_rbt[i].sendMs = now;
              }
            continue;
           }
         if(g_rbt[i].closing)
            SetAction(StringFormat("【%s】再ブレイク #%d の全決済が完了しました", SideName(side), gid));
         RbTradeRemove(i);
         continue;
        }

//--- 全決済の送信済み：1秒ごとに残りを再送
      if(g_rbt[i].closing)
        {
         if(now - g_rbt[i].sendMs >= 1000)
            SendGridClose(i);
         continue;
        }

      double px = buy ? bid : ask;   // 決済側の価格
      if(buy ? px > g_rbt[i].peak : px < g_rbt[i].peak)
         g_rbt[i].peak = px;

//--- 1) 損切り・4) 時間切れ（確定足）
      if(newBar)
        {
         double c1 = iClose(_Symbol, g_entryTF, 1);
         if(InpRbStopATR > 0 && c1 > 0)
           {
            double sl = RbStopLine(i);
            if(buy ? c1 < sl : c1 > sl)
              {
               StartGridClose(i, StringFormat("損切り（終値 %s が損切りライン %s を%s）", PriceText(c1), PriceText(sl),
                                              (buy ? "下抜け" : "上抜け")));
               continue;
              }
           }
         if(InpRbTimeBars > 0 && !g_rbt[i].beDone && iBarShift(_Symbol, g_entryTF, g_rbt[i].entryTime) >= InpRbTimeBars)
           {
            StartGridClose(i, StringFormat("時間切れ（%d本以内に第1目標 %s へ届かず）", InpRbTimeBars, PriceText(g_rbt[i].ext)));
            continue;
           }
        }

//--- 2) 第1目標：ブレイク後の高値（安値）に到達
      if(!g_rbt[i].beDone && (buy ? px >= g_rbt[i].ext : px <= g_rbt[i].ext))
        {
         g_rbt[i].beDone = true;
         int d = InpRbBEAtExt ? DeleteGridOrders(gid) : 0;
         SaveState();
         SetAction(StringFormat("【%s】再ブレイク #%d 第1目標 %s に到達%s", SideName(side), gid, PriceText(g_rbt[i].ext),
                                (InpRbBEAtExt ? StringFormat("：建値ストップ・指値%d件削除", d) : "")));
        }
      if(g_rbt[i].beDone)
         RbApplyStops(i, bid, ask);
     }
  }

//+------------------------------------------------------------------+
//| 2) 建値ストップ・3) トレールのSLを、グリッドの各ポジションに設定     |
//|    SLは有利な方向にだけ動かす                                      |
//+------------------------------------------------------------------+
void RbApplyStops(const int i, const double bid, const double ask)
  {
   int  side = g_rbt[i].side;
   bool buy  = (side == SIDE_BUY);
   int  gid  = g_rbt[i].gid;

//--- トレールの位置
   bool   useTrail = false;
   double trail    = 0.0;
   if(InpRbTrailMode == RB_TRAIL_ATR)
     {
      double d = g_rbt[i].atr * InpRbTrailATR;
      trail    = buy ? g_rbt[i].peak - d : g_rbt[i].peak + d;
      useTrail = true;
     }
   else
      if(InpRbTrailMode == RB_TRAIL_BARS)
        {
         int k = buy ? iLowest(_Symbol, g_entryTF, MODE_LOW, InpRbTrailBars, 1)
                 : iHighest(_Symbol, g_entryTF, MODE_HIGH, InpRbTrailBars, 1);
         if(k >= 0)
           {
            trail    = buy ? iLow(_Symbol, g_entryTF, k) : iHigh(_Symbol, g_entryTF, k);
            useTrail = (trail > 0);
           }
        }
   if(!InpRbBEAtExt && !useTrail)
      return;

   double tick = TickSize();
   double step = MathMax(tick, g_rbt[i].atr * 0.05);   // 細かすぎる変更は送らない
   double minD = MinStopDistance();

   int total = PositionsTotal();
   for(int k = total - 1; k >= 0; k--)
     {
      ulong ticket = PositionGetTicket(k);
      if(ticket == 0 || !IsOwnPositionSelected())
         continue;
      int    g = 0;
      double w = 0.0;
      if(!ParseGridComment(PositionGetString(POSITION_COMMENT), g, w) || g != gid)
         continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      bool   has    = false;
      double target = 0.0;
      if(InpRbBEAtExt)
        {
         target = open;
         has    = true;
        }
      if(useTrail)
        {
         target = has ? (buy ? MathMax(target, trail) : MathMin(target, trail)) : trail;
         has    = true;
        }
      target = NormPrice(target);

      bool better = (sl == 0.0) || (buy ? target >= sl + step : target <= sl - step);
      double dist = buy ? bid - target : target - ask;
      if(better && dist >= minD && dist > 0)
         g_trade.PositionModify(ticket, target, tp);
     }
  }

//+------------------------------------------------------------------+
//| パネル表示用：再ブレイクの待機状態                                 |
//+------------------------------------------------------------------+
string RebreakStatusText(color &clr)
  {
   clr = clrSilver;
   string out = "方式：再ブレイク　";
   for(int side = 0; side < 2; side++)
     {
      if((side == SIDE_BUY && !InpAllowBuy) || (side == SIDE_SELL && !InpAllowSell))
         continue;
      bool   buy = (side == SIDE_BUY);
      string hl  = buy ? "高値" : "安値";
      int    st  = g_rb[side].stage;
      if(st == 0)
         out += StringFormat("%s：%s%sブレイク待ち", SideName(side), hl, PriceText(g_rbLevel[side]));
      else
         if(st == 1)
            out += StringFormat("%s：%s%sブレイク→走り待ち", SideName(side), hl, PriceText(g_rb[side].level));
         else
            if(st == 2)
               out += StringFormat("%s：走った→戻り待ち", SideName(side));
            else
              {
               out += StringFormat("%s：%s%s再ブレイク待ち", SideName(side), hl, PriceText(g_rb[side].level));
               clr = buy ? clrDeepSkyBlue : clrTomato;
              }
      if(InpUseHTF && !TrendSideAllowed(side))
         out += "（上位足で見送り）";
      out += "　";
     }
   for(int i = 0; i < ArraySize(g_rbt); i++)
     {
      out += StringFormat("\n保有%s #%d：", SideName(g_rbt[i].side), g_rbt[i].gid);
      if(g_rbt[i].closing)
         out += "全決済中";
      else
         if(g_rbt[i].beDone)
            out += "第1目標到達済（建値・トレール中）";
         else
            out += "第1目標 " + PriceText(g_rbt[i].ext) + (InpRbStopATR > 0 ? "／損切りライン " + PriceText(RbStopLine(i)) : "");
     }
   return(out);
  }

//+------------------------------------------------------------------+
//| チャートに基準ラインを表示（ブレイク後〜再ブレイク待ちの間）         |
//+------------------------------------------------------------------+
void DrawRebreakLines()
  {
   for(int side = 0; side < 2; side++)
     {
      string name = OBJ_PREFIX + "rb" + IntegerToString(side);
      if(InpEntryMode != ENTRY_REBREAK || g_rb[side].stage == 0)
        {
         if(ObjectFind(0, name) >= 0)
            ObjectDelete(0, name);
         continue;
        }
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_HLINE, 0, 0, g_rb[side].level);
      ObjectSetDouble(0, name, OBJPROP_PRICE, g_rb[side].level);
      ObjectSetInteger(0, name, OBJPROP_COLOR, side == SIDE_SELL ? clrTomato : clrDeepSkyBlue);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, StringFormat("再ブレイク%sの基準ライン %s（%s）", SideName(side),
                      PriceText(g_rb[side].level), (g_rb[side].stage == 1 ? "走り待ち" : (g_rb[side].stage == 2 ? "戻り待ち" : "再ブレイク待ち"))));
     }

//--- 保有中のグリッド：第1目標（金色）と損切りライン（橙）
   ObjectsDeleteAll(0, OBJ_PREFIX + "rbt");
   for(int i = 0; i < ArraySize(g_rbt); i++)
     {
      if(g_rbt[i].closing)
         continue;
      string base = OBJ_PREFIX + "rbt" + IntegerToString(g_rbt[i].gid);
      if(!g_rbt[i].beDone)
         RbHLine(base + "t", g_rbt[i].ext, clrGold, StringFormat("再ブレイク%s #%d 第1目標 %s", SideName(g_rbt[i].side), g_rbt[i].gid, PriceText(g_rbt[i].ext)));
      if(InpRbStopATR > 0)
         RbHLine(base + "s", RbStopLine(i), clrDarkOrange, StringFormat("再ブレイク%s #%d 損切りライン %s（終値で判定）", SideName(g_rbt[i].side), g_rbt[i].gid, PriceText(RbStopLine(i))));
     }
  }

//+------------------------------------------------------------------+
void RbHLine(const string name, const double price, const color clr, const string tip)
  {
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASHDOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip);
  }

//+------------------------------------------------------------------+
//| パネル表示用：順張りの待機状態                                     |
//+------------------------------------------------------------------+
string TrendStatusText(color &clr)
  {
   clr = clrSilver;
   if(InpEntryMode == ENTRY_REBREAK)
      return(RebreakStatusText(clr));
   if(InpEntryMode != ENTRY_TREND)
      return(StringFormat("方式：逆張り（確定足の終値が±%.1fσの外でシグナル）", InpBBDev));

   string out = "方式：順張り　";
   bool any = false;
   for(int side = 0; side < 2; side++)
     {
      if(!TrendSideAllowed(side))
         continue;
      any = true;
      string sg  = (side == SIDE_SELL) ? "−" : "＋";
      double e   = Buf(g_hBBE, (side == SIDE_SELL) ? 2 : 1, 0);
      datetime a = LastExtremeTouch(side);
      if(a != 0 && a > g_armUsed[side])
        {
         out += StringFormat("%s：%s%.1fσ到達済 → %s%.1fσ（%s）で%s　", SideName(side), sg, InpBBDev, sg,
                             InpTrendEntryDev, PriceText(e), (side == SIDE_SELL ? "売り" : "買い"));
         clr = (side == SIDE_SELL) ? clrTomato : clrDeepSkyBlue;
        }
      else
         out += StringFormat("%s：%s%.1fσ到達待ち　", SideName(side), sg, InpBBDev);
     }
   if(!any)
      out += "上位足の方向待ち（エントリー対象なし）";
   return(out);
  }

//+------------------------------------------------------------------+
//| BB逆張りシグナル（確定足）                                        |
//+------------------------------------------------------------------+
bool CheckSignal(const int side)
  {
   double up1 = Buf(g_hBB, 1, 1);
   double lo1 = Buf(g_hBB, 2, 1);
   if(up1 == EMPTY_VALUE || lo1 == EMPTY_VALUE)
      return(false);

   double c1 = iClose(_Symbol, g_entryTF, 1);
   double h1 = iHigh(_Symbol, g_entryTF, 1);
   double l1 = iLow(_Symbol, g_entryTF, 1);
   if(c1 <= 0)
      return(false);

   if(InpSignalMode == SIG_CLOSE)
      return(side == SIDE_SELL ? (c1 > up1) : (c1 < lo1));

   if(InpSignalMode == SIG_TOUCH)
      return(side == SIDE_SELL ? (h1 >= up1) : (l1 <= lo1));

//--- SIG_REVERT：2本前の終値がバンド外 → 1本前の終値がバンド内
   double up2 = Buf(g_hBB, 1, 2);
   double lo2 = Buf(g_hBB, 2, 2);
   double c2  = iClose(_Symbol, g_entryTF, 2);
   if(up2 == EMPTY_VALUE || lo2 == EMPTY_VALUE || c2 <= 0)
      return(false);
   return(side == SIDE_SELL ? (c2 > up2 && c1 <= up1) : (c2 < lo2 && c1 >= lo1));
  }

//+------------------------------------------------------------------+
//| 上位足の方向（1＝上昇、-1＝下降、0＝不明確）                      |
//+------------------------------------------------------------------+
int HTFTrend()
  {
   double mid1 = Buf(g_hBBH, 0, 1);
   double cl1  = iClose(_Symbol, InpHTF, 1);
   if(mid1 == EMPTY_VALUE || cl1 <= 0)
      return(0);

   int dir = 0;
   if(cl1 > mid1)
      dir = 1;
   else
      if(cl1 < mid1)
         dir = -1;

   if(InpHTFSlopeBars > 0 && dir != 0)
     {
      double midN = Buf(g_hBBH, 0, 1 + InpHTFSlopeBars);
      if(midN == EMPTY_VALUE)
         return(0);
      if(dir == 1 && !(mid1 > midN))
         dir = 0;
      if(dir == -1 && !(mid1 < midN))
         dir = 0;
     }
   return(dir);
  }

//+------------------------------------------------------------------+
//| エントリー可否                                                    |
//+------------------------------------------------------------------+
bool EntryAllowed(const int side, const bool manual, string &reason)
  {
   reason = "";
   if(g_locked[side])
     {
      reason = "損切り後のロック中";
      return(false);
     }
   if(g_closing[side])
     {
      reason = "損切り決済中";
      return(false);
     }
   if(g_flatActive && FlatSide(side))
     {
      reason = "一括決済の処理中";
      return(false);
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      reason = "自動売買が無効（MT5の「アルゴリズム取引」ボタンとEAの設定を確認）";
      return(false);
     }
   if(manual)
      return(true);   // 裁量（ボタン・レート予約）は稼働中でも何度でも追加できる。フィルター・上限なし

   int grids = CountActiveGrids(side);
   if(grids >= InpMaxGridsPerSide)
     {
      reason = "自動エントリーの同方向グリッド上限（" + IntegerToString(InpMaxGridsPerSide) + "）";
      return(false);
     }

   if(grids > 0 && !InpAutoAddGrid)
     {
      reason = "同方向のグリッドが稼働中";
      return(false);
     }

   if(side == SIDE_SELL && !InpAllowSell)
     {
      reason = "売りは許可されていません";
      return(false);
     }
   if(side == SIDE_BUY && !InpAllowBuy)
     {
      reason = "買いは許可されていません";
      return(false);
     }

   if(InpUseHTF)
     {
      int tr = HTFTrend();
      if(tr == 1 && side == SIDE_SELL)
        {
         reason = "上位足" + TFName(InpHTF) + "が上昇中（売り不可）";
         return(false);
        }
      if(tr == -1 && side == SIDE_BUY)
        {
         reason = "上位足" + TFName(InpHTF) + "が下降中（買い不可）";
         return(false);
        }
      if(tr == 0 && InpHTFNeutral == HTF_NEUTRAL_NONE)
        {
         reason = "上位足の方向が不明確";
         return(false);
        }
     }

   double atr1 = Buf(g_hATR, 0, 1);
   if(atr1 != EMPTY_VALUE)
     {
      if(InpATRMax > 0 && atr1 > InpATRMax)
        {
         reason = "ATRが上限超え（" + PriceText2(atr1) + "）";
         return(false);
        }
      if(InpATRMin > 0 && atr1 < InpATRMin)
        {
         reason = "ATRが下限未満（" + PriceText2(atr1) + "）";
         return(false);
        }
     }

   if(InpMaxSpread > 0 && CurrentSpread() > InpMaxSpread)
     {
      reason = "スプレッド拡大（" + PriceText2(CurrentSpread()) + "）";
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| 現在のグリッド間隔・微益幅（ATR可変）                              |
//+------------------------------------------------------------------+
void CalcWidths(double &step, double &tp)
  {
   step = InpGridStep;
   tp   = InpMicroTP;
   double atr = Buf(g_hATR, 0, 1);
   if(InpUseATRWidth && atr != EMPTY_VALUE && atr > 0)
     {
      step = MathMax(InpGridStep, atr * InpStepATRMult);
      tp   = MathMax(InpMicroTP, atr * InpTPATRMult);
     }
   step = NormPrice(step);
   tp   = NormPrice(tp);
  }

//+------------------------------------------------------------------+
//| グリッド発注：成行1本＋指値○本                                    |
//|   limitLine > 0：指値をこのラインの内側（成行価格との間）に収める     |
//|     間隔＝（成行価格〜ライン）÷（本数＋1）。ただし間隔は             |
//|     InpGridStep 以上とし、収まらない分は本数を減らす                 |
//+------------------------------------------------------------------+
bool PlaceGrid(const int side, const bool manual, const double limitLine = 0.0)
  {
   double step, tp;
   CalcWidths(step, tp);
   double lot = NormLot(InpLot);

//--- 既存のポジション・指値には一切触れずに追加する

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   int gid = NextGridId();
   bool ok = (side == SIDE_SELL) ? g_trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, GridComment(side, gid, 0, tp))
             : g_trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, GridComment(side, gid, 0, tp));
   uint rc = g_trade.ResultRetcode();
   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED))
     {
      string em = StringFormat("【%s】エントリー失敗：retcode=%u（%s）", SideName(side), rc, g_trade.ResultRetcodeDescription());
      SetAction(em);
      return(false);
     }

   double base = g_trade.ResultPrice();
   if(base <= 0)
      base = (side == SIDE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

//--- 範囲の制限（再ブレイク：損切りラインの内側に収める）
   int  count   = InpGridCount;
   bool limited = (limitLine > 0);
   if(limited)
     {
      double range = (side == SIDE_SELL) ? limitLine - base : base - limitLine;
      if(range <= 0)
         count = 0;
      else
        {
         step = NormPrice(MathMax(range / (InpGridCount + 1), InpGridStep));
         if(step <= 0)
            step = TickSize();
         while(count > 0 && step * count >= range)
            count--;   // 一番深い指値もラインの内側
        }
     }

   int placed = 0;
   for(int k = 1; k <= count; k++)
     {
      double pr  = NormPrice(side == SIDE_SELL ? base + step * k : base - step * k);
      double ptp = NormPrice(side == SIDE_SELL ? pr - tp : pr + tp);
      bool   r   = (side == SIDE_SELL)
                   ? g_trade.SellLimit(lot, pr, _Symbol, 0.0, ptp, ORDER_TIME_GTC, 0, GridComment(side, gid, k, tp))
                   : g_trade.BuyLimit(lot, pr, _Symbol, 0.0, ptp, ORDER_TIME_GTC, 0, GridComment(side, gid, k, tp));
      uint rr = g_trade.ResultRetcode();
      if(r && (rr == TRADE_RETCODE_DONE || rr == TRADE_RETCODE_PLACED))
         placed++;
      else
         PrintFormat("%s指値失敗 %s @%s retcode=%u（%s）", LOG_TAG, SideName(side), PriceText(pr), rr, g_trade.ResultRetcodeDescription());
     }

   g_gridTP[side]   = tp;
   g_gridStep[side] = step;
   g_gridTime[side] = TimeCurrent();
   SaveState();

   double atr = Buf(g_hATR, 0, 1);
   string msg = StringFormat("【%s】%sエントリー #%d：成行 %.2f lot @%s ＋ 指値%d本（間隔 %s／微益 %s／ATR %s）",
                             SideName(side), (manual ? "裁量" : "自動"), gid, lot, PriceText(base), placed,
                             PriceText2(step), PriceText2(tp), (atr == EMPTY_VALUE ? "-" : PriceText2(atr)));
   if(limited)
      msg += StringFormat("　※指値は損切りライン %s の内側に%d本", PriceText(limitLine), count);
   if(placed < count)
      msg += StringFormat("　※指値%d本が発注失敗（エキスパートタブ参照）", count - placed);
   SetAction(msg);          // 通知はしない（ログとパネル表示のみ）
   return(true);
  }

//+------------------------------------------------------------------+
//| 裁量エントリー（パネルのボタン）                                   |
//+------------------------------------------------------------------+
void ManualEntry(const int side)
  {
   string reason = "";
   if(!EntryAllowed(side, true, reason))
     {
      SetAction("【" + SideName(side) + "】裁量エントリー不可：" + reason);
      return;
     }
   PlaceGrid(side, true);   // 確認画面・アラームなし
  }

//+------------------------------------------------------------------+
//| 自EAのポジション・注文を決済（パネルのボタン）                      |
//+------------------------------------------------------------------+
void ManualCloseOwn(const int side)
  {
   int pos = CountOwnPositions(side);
   int ord = CountOwnOrders(side);
   if(pos == 0 && ord == 0)
     {
      SetAction("【" + SideName(side) + "】決済するポジション・注文はありません");
      return;
     }
   StartFlatten(side, "【" + SideName(side) + "】裁量決済");   // 確認なしで即実行
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|   ■ 一括決済（決済ボタン・目標利益）                               |
//|     自EAの指値削除・ポジション決済を非同期で一斉に送信し、           |
//|     完了するまで1秒ごとに残りを再送する                             |
//|                                                                  |
//+------------------------------------------------------------------+
bool FlatSide(const int side)
  {
   return(g_flatSide < 0 || g_flatSide == side);
  }

//+------------------------------------------------------------------+
void StartFlatten(const int sideFilter, const string reason)
  {
//--- 別方向の一括決済が進行中なら、両方向にまとめる
   int sf = sideFilter;
   if(g_flatActive && g_flatSide != sideFilter)
      sf = -1;

   g_flatSide   = sf;
   g_flatReason = (g_flatActive && sf != sideFilter) ? g_flatReason + "＋" + reason : reason;
   g_flatPos    = 0;
   g_flatOrd    = 0;
   for(int s = 0; s < 2; s++)
     {
      if(!FlatSide(s))
         continue;
      g_flatPos += CountOwnPositions(s);
      g_flatOrd += CountOwnOrders(s);
      g_gridTime[s] = 0;
     }
   g_flatActive     = true;
   g_flatTries      = 0;
   g_flatStartMs    = NowMs();
   g_failPrintCount = 0;
   SaveState();
   SendFlatten();
   ProcessFlatten();   // テスター等で即時に約定していれば、その場で完了表示
  }

//+------------------------------------------------------------------+
//| 対象の指値削除・ポジション決済を一斉送信（応答は待たない）           |
//+------------------------------------------------------------------+
void SendFlatten()
  {
   g_flatSendMs = NowMs();
   g_flatTries++;
   for(int s = 0; s < 2; s++)
     {
      if(!FlatSide(s))
         continue;
      DeleteOwnOrders(s, true);   // 指値を先に送る（決済中に約定させない）
      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsOwnPositionSelected() || PositionSideSelected() != s)
            continue;
         ClosePositionTicket(ticket, true);
        }
     }
  }

//+------------------------------------------------------------------+
//| 完了確認：残りがあれば1秒ごとに再送                                 |
//+------------------------------------------------------------------+
void ProcessFlatten()
  {
   if(!g_flatActive)
      return;

   int remain = 0;
   for(int s = 0; s < 2; s++)
      if(FlatSide(s))
         remain += CountOwnPositions(s) + CountOwnOrders(s);

   if(remain == 0)
     {
      g_flatActive = false;
      SetAction(StringFormat("%s：ポジ%d件決済・指値%d件削除（%.2f秒）", g_flatReason, g_flatPos, g_flatOrd,
                             (double)(NowMs() - g_flatStartMs) / 1000.0));
      return;
     }

   if(NowMs() - g_flatSendMs < 1000)
      return;   // 送信済みの注文の処理待ち
   if(g_flatTries == 3)
      SetAction(StringFormat("%s：残り%d件の決済・削除に失敗しています。再試行中（自動売買ON・市場オープンを確認してください）",
                             g_flatReason, remain));
   SendFlatten();
  }

//+------------------------------------------------------------------+
//| 目標利益：自EAの合計損益が目標額に達したら全決済                    |
//+------------------------------------------------------------------+
void CheckTarget()
  {
   if(g_targetAmt <= 0 || g_flatActive || g_closing[SIDE_SELL] || g_closing[SIDE_BUY])
      return;
   int    n = 0;
   double p = OwnProfit(n);
   if(n == 0 || p < g_targetAmt)
      return;
   StartFlatten(-1, StringFormat("目標利益到達（合計 %s ≧ %s）で全決済", FormatMoney(p), FormatMoney(g_targetAmt)));
  }

//+------------------------------------------------------------------+
//| 自EAのポジションの合計損益（スワップ・手数料は損切り監視の設定に従う）|
//+------------------------------------------------------------------+
double OwnProfit(int &count)
  {
   count = 0;
   double sum = 0.0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOwnPositionSelected())
         continue;
      double p = PositionGetDouble(POSITION_PROFIT);
      if(InpIncludeSwap)
         p += PositionGetDouble(POSITION_SWAP);
      if(InpIncludeCommission)
         p += GetEntryCommission((ulong)PositionGetInteger(POSITION_IDENTIFIER));
      sum += p;
      count++;
     }
   return(sum);
  }

//+------------------------------------------------------------------+
//| パネルの目標利益入力                                              |
//+------------------------------------------------------------------+
void ApplyTarget()
  {
   string name = OBJ_PREFIX + "tgt";
   string txt  = ObjectGetString(0, name, OBJPROP_TEXT);
   bool   ok   = false;
   double v    = ParseAmount(txt, ok);
   if(!ok)
     {
      Print(LOG_TAG + "金額として読み取れません：" + txt);
      ObjectSetString(0, name, OBJPROP_TEXT, FormatPlain(g_targetAmt));
      return;
     }
   g_targetAmt = v;
   SaveState();
   ObjectSetString(0, name, OBJPROP_TEXT, FormatPlain(v));
   SetAction("目標利益を " + (v > 0 ? "+" + FormatMoney(v) : "0（OFF）") + " に変更しました");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|   ■ 自EAポジションの管理（微益利確・最有利ポジ）                   |
//|                                                                  |
//+------------------------------------------------------------------+
void ManageOwn()
  {
   ulong now = NowMs();
   if(g_lastManageMs != 0 && (now - g_lastManageMs) < 300)
      return;
   g_lastManageMs = now;

   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid0 = Buf(g_hBB, 0, 0);
   if(bid <= 0 || ask <= 0)
      return;

   for(int side = 0; side < 2; side++)
     {
      if(g_closing[side] || (g_flatActive && FlatSide(side)))
         continue;

      ulong  tk[];
      double op[];
      double sl[];
      double tp[];
      double tw[];
      int    n = 0;

      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsOwnPositionSelected() || PositionSideSelected() != side)
            continue;
         ArrayResize(tk, n + 1);
         ArrayResize(op, n + 1);
         ArrayResize(sl, n + 1);
         ArrayResize(tp, n + 1);
         ArrayResize(tw, n + 1);
         tk[n] = ticket;
         op[n] = PositionGetDouble(POSITION_PRICE_OPEN);
         sl[n] = PositionGetDouble(POSITION_SL);
         tp[n] = PositionGetDouble(POSITION_TP);
         int    g  = 0;
         double gw = 0.0;
         tw[n] = (ParseGridComment(PositionGetString(POSITION_COMMENT), g, gw) && gw > 0) ? gw : 0.0;
         n++;
        }

      //--- ポジションが無い：残った指値の片付け
      if(n == 0)
        {
         if(CountOwnOrders(side) > 0)
           {
            bool midHit  = (mid0 != EMPTY_VALUE) && (side == SIDE_SELL ? bid <= mid0 : ask >= mid0);
            bool expired = (InpGridExpireHours > 0 && g_gridTime[side] > 0 &&
                            (double)(TimeCurrent() - g_gridTime[side]) >= InpGridExpireHours * 3600.0);
            if(midHit || expired)
              {
               int d = DeleteOwnOrders(side);
               if(d > 0)
                  Print(LOG_TAG + SideName(side) + "グリッド終了：残りの指値" + IntegerToString(d) + "件を削除（" +
                        (midHit ? "BBミドル到達" : "時間経過") + "）");
               g_gridTime[side] = 0;
               SaveState();
              }
           }
         continue;
        }

      //--- 最有利ポジ：SELLは最も高い建値、BUYは最も低い建値
      int best = 0;
      for(int i = 1; i < n; i++)
         if(side == SIDE_SELL ? op[i] > op[best] : op[i] < op[best])
            best = i;

      double tpDefault = (g_gridTP[side] > 0) ? g_gridTP[side] : NormPrice(InpMicroTP);

      for(int i = 0; i < n; i++)
        {
         if(i == best)
            ManageBest(side, tk[i], op[i], sl[i], tp[i], bid, ask, mid0);
         else
            ManageMicro(side, tk[i], op[i], sl[i], tp[i], (tw[i] > 0 ? tw[i] : tpDefault), bid, ask);
        }

      //--- 終了済みグリッドの指値は、BBミドル到達で片付ける
      if(mid0 != EMPTY_VALUE && (side == SIDE_SELL ? bid <= mid0 : ask >= mid0))
         DeleteStaleOrders(side);
     }
  }

//+------------------------------------------------------------------+
//| 不利な位置のポジ：微益利確（サーバー側TPを設定）                    |
//+------------------------------------------------------------------+
void ManageMicro(const int side, const ulong ticket, const double open, const double sl, const double tp,
                 const double tpw, const double bid, const double ask)
  {
   double want = NormPrice(side == SIDE_SELL ? open - tpw : open + tpw);

//--- すでに到達していれば成行で決済
   if(side == SIDE_SELL ? ask <= want : bid >= want)
     {
      ClosePositionTicket(ticket);
      return;
     }

   double tick = TickSize();
   if(MathAbs(tp - want) > tick * 0.5)
     {
      double dist = (side == SIDE_SELL) ? ask - want : want - bid;
      if(dist >= MinStopDistance())
         g_trade.PositionModify(ticket, sl, want);
     }
  }

//+------------------------------------------------------------------+
//| 最有利ポジ：TPを外して伸ばす／BBミドル決済／建値＋トレール          |
//+------------------------------------------------------------------+
void ManageBest(const int side, const ulong ticket, const double open, const double sl, const double tp,
                const double bid, const double ask, const double mid0)
  {
   double tick     = TickSize();
   double profitPx = (side == SIDE_SELL) ? open - ask : bid - open;

//--- BBミドル到達で決済（利益が出ている場合のみ）
   if(InpBestExit == BEST_MIDDLE && mid0 != EMPTY_VALUE && profitPx > 0)
     {
      if(side == SIDE_SELL ? ask <= mid0 : bid >= mid0)
        {
         if(ClosePositionTicket(ticket))
            Print(LOG_TAG + SideName(side) + "最有利ポジをBBミドルで決済（+" + PriceText2(profitPx) + "）");
         return;
        }
     }

   double newSL = sl;
   double newTP = 0.0;   // 最有利ポジはTPなし

//--- 建値ストップ＋トレール
   if(InpBestBE > 0 && profitPx >= InpBestBE)
     {
      double target = open;
      if(InpBestTrail > 0)
        {
         double tr = (side == SIDE_SELL) ? ask + InpBestTrail : bid - InpBestTrail;
         target = (side == SIDE_SELL) ? MathMin(open, tr) : MathMax(open, tr);
        }
      target = NormPrice(target);

      bool better = (sl == 0.0) || (side == SIDE_SELL ? target < sl - tick * 0.5 : target > sl + tick * 0.5);
      double dist = (side == SIDE_SELL) ? target - ask : bid - target;
      if(better && dist >= MinStopDistance())
         newSL = target;
     }

   if(MathAbs(tp - newTP) > tick * 0.5 || MathAbs(newSL - sl) > tick * 0.5)
      g_trade.PositionModify(ticket, newSL, newTP);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|   ■ 損切り監視（SELL群／BUY群・口座通貨）                           |
//|                                                                  |
//+------------------------------------------------------------------+
void GuardCheck()
  {
   SideStat st[2];
   TakeStats(st);

   for(int s = 0; s < 2; s++)
     {
      if(g_closing[s])
        {
         ProcessClosing(s);
         continue;
        }
      if(g_locked[s])
        {
         EnforceLock(s, st[s]);
         continue;
        }
      Evaluate(s, st[s]);
     }
  }

//+------------------------------------------------------------------+
void Evaluate(const int side, const SideStat &st)
  {
   if(st.count == 0)
     {
      g_warned[side]      = false;
      g_dryNotified[side] = false;
      return;
     }
   if(!g_enabled[side] || g_slAmt[side] <= 0)
      return;

   double amt = g_slAmt[side];

   if(st.profit <= -amt)
     {
      if(InpDryRun)
        {
         if(!g_dryNotified[side])
           {
            LogEvent(StringFormat("【%s群・テストモード】損切り条件に到達：合計損益 %s ≦ -%s（%d件／注文%d件）※決済・削除はしていません",
                                SideName(side), FormatMoney(st.profit), FormatMoney(amt), st.count, st.orders));
            g_dryNotified[side] = true;
            g_lastEvent = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + " " + SideName(side) +
                          "（テスト）" + FormatMoney(st.profit);
           }
        }
      else
         StartClosing(side, st);
     }
   else
      if(g_dryNotified[side] && st.profit > -amt * 0.9)
         g_dryNotified[side] = false;
  }

//+------------------------------------------------------------------+
void StartClosing(const int side, const SideStat &st)
  {
   g_closing[side]       = true;
   g_stuckNotified[side] = false;
   g_balanceBefore[side] = AccountInfoDouble(ACCOUNT_BALANCE);
   g_triggerProfit[side] = st.profit;
   g_closedCount[side]   = st.count;   // 発動時のポジ数（非同期で送るため、送信回数ではなく件数で表示）
   g_closeTries[side]    = 0;
   g_deletedCount[side]  = 0;
   g_lastTryMs[side]     = 0;
   g_failPrintCount      = 0;

   LogEvent(StringFormat("【%s群】損切り発動：合計損益 %s ≦ -%s。%d件（%.2f lot）を決済し、未約定注文を%s",
                       SideName(side), FormatMoney(st.profit), FormatMoney(g_slAmt[side]), st.count, st.lots,
                       DeleteModeText()));

   if(InpDeleteOrders == DEL_ALL)
      g_deletedCount[side] += DeleteOrders(-1, true);
   else
      if(InpDeleteOrders == DEL_SAME)
         g_deletedCount[side] += DeleteOrders(side, true);

   ProcessClosing(side);
  }

//+------------------------------------------------------------------+
void ProcessClosing(const int side)
  {
//--- 完了確認は毎回（非同期で送った決済の約定を待たずに検知する）
   int remaining = CountPositions(side);
   if(remaining == 0)
     {
      FinishClosing(side);
      return;
     }

//--- 非同期で一斉送信し、1秒ごとに残りを再送する（応答待ちで止まらない）
   ulong now = NowMs();
   if(g_lastTryMs[side] != 0 && (now - g_lastTryMs[side]) < 1000)
      return;
   g_lastTryMs[side] = now;

   if(InpDeleteOrders != DEL_NONE && g_closeTries[side] > 0)
      DeleteOrders(side, true);   // 発動後に出た注文の削除・再送（件数は発動時の分だけ数える）
   ClosePositions(side, true);
   g_closeTries[side]++;

   remaining = CountPositions(side);
   if(remaining == 0)
     {
      FinishClosing(side);
      return;
     }

   if(g_closeTries[side] >= MathMax(3, InpMaxRetry) && !g_stuckNotified[side])
     {
      LogEvent(StringFormat("【%s群】未決済のポジションが%d件残っています。引き続き決済を試みます（自動売買ON・市場オープンを確認してください）",
                          SideName(side), remaining));
      g_stuckNotified[side] = true;
     }
  }

//+------------------------------------------------------------------+
void FinishClosing(const int side)
  {
   double diff = AccountInfoDouble(ACCOUNT_BALANCE) - g_balanceBefore[side];

   string msg = StringFormat("【%s群】損切り完了：%d件決済・注文%d件削除／判定時の合計損益 %s／残高の変化 %s（概算）",
                             SideName(side), g_closedCount[side], g_deletedCount[side],
                             FormatMoney(g_triggerProfit[side]), FormatMoney(diff));

   g_closing[side]       = false;
   g_warned[side]        = false;
   g_stuckNotified[side] = false;
   g_gridTime[side]      = 0;
   g_lastEvent = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + " " + SideName(side) + " " +
                 FormatMoney(g_triggerProfit[side]);

   if(InpLockAfterSL)
     {
      g_locked[side]       = true;
      g_lockNotified[side] = false;
      msg += "／" + SideName(side) + "はロック中。分析をやり直してからパネルの「解除」を押してください";
     }
   SaveState();
   LogEvent(msg);
  }

//+------------------------------------------------------------------+
void EnforceLock(const int side, const SideStat &st)
  {
   if(InpDryRun)
      return;
   if(st.count == 0 && st.orders == 0)
      return;

   ulong now = NowMs();
   if(g_lastLockMs[side] != 0 && (now - g_lastLockMs[side]) < 1000)
      return;
   g_lastLockMs[side] = now;

   int deleted = DeleteOrders(side, true);
   int closed  = (st.count > 0) ? ClosePositions(side, true) : 0;

   if(!g_lockNotified[side] && (deleted > 0 || closed > 0))
     {
      LogEvent(StringFormat("【%s群】ロック中のため、新規注文%d件を削除・新規ポジション%d件を決済しました。"
                          "再開時はパネルの「解除」を押してください",
                          SideName(side), deleted, closed));
      g_lockNotified[side] = true;
     }
  }

//+------------------------------------------------------------------+
//| 監視対象ポジション（指定方向）を全て決済し、送信した件数を返す       |
//+------------------------------------------------------------------+
int ClosePositions(const int side, const bool async = false)
  {
   int sent  = 0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsTargetPositionSelected() || PositionSideSelected() != side)
         continue;
      if(ClosePositionTicket(ticket, async))
         sent++;
     }
   return(sent);
  }

//+------------------------------------------------------------------+
//| async＝true：応答を待たずに送信（送信できたら true）               |
//+------------------------------------------------------------------+
bool ClosePositionTicket(const ulong ticket, const bool async = false)
  {
   if(!PositionSelectByTicket(ticket))
      return(false);
   string  sym = PositionGetString(POSITION_SYMBOL);
   CTrade *tr  = async ? GetPointer(g_fast) : GetPointer(g_trade);
   tr.SetTypeFillingBySymbol(sym);

   ResetLastError();
   bool ok = tr.PositionClose(ticket, (ulong)MathMax(0, InpDeviationPoints));
   uint rc = tr.ResultRetcode();
   if(ok && (async || rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED))
      return(true);

   if(g_failPrintCount < 30)
     {
      PrintFormat("%s決済失敗 #%I64u %s retcode=%u（%s） err=%d",
                  LOG_TAG, ticket, sym, rc, tr.ResultRetcodeDescription(), GetLastError());
      g_failPrintCount++;
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| 監視対象の未約定注文を削除（sideFilter：-1＝全方向）               |
//+------------------------------------------------------------------+
int DeleteOrders(const int sideFilter, const bool async = false)
  {
   int deleted = 0;
   int total   = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsTargetOrderSelected())
         continue;
      int sd = OrderSideOf((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE));
      if(sd < 0 || (sideFilter >= 0 && sd != sideFilter))
         continue;
      if(DeleteOrderTicket(ticket, async))
         deleted++;
     }
   return(deleted);
  }

//+------------------------------------------------------------------+
//| 自EAの未約定注文を削除                                            |
//+------------------------------------------------------------------+
int DeleteOwnOrders(const int side, const bool async = false)
  {
   int deleted = 0;
   int total   = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOwnOrderSelected())
         continue;
      if(OrderSideOf((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)) != side)
         continue;
      if(DeleteOrderTicket(ticket, async))
         deleted++;
     }
   return(deleted);
  }

//+------------------------------------------------------------------+
bool DeleteOrderTicket(const ulong ticket, const bool async = false)
  {
   CTrade *tr = async ? GetPointer(g_fast) : GetPointer(g_trade);
   ResetLastError();
   bool ok = tr.OrderDelete(ticket);
   uint rc = tr.ResultRetcode();
   if(ok && (async || rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
      return(true);
   if(g_failPrintCount < 30)
     {
      PrintFormat("%s注文削除失敗 #%I64u retcode=%u（%s） err=%d",
                  LOG_TAG, ticket, rc, tr.ResultRetcodeDescription(), GetLastError());
      g_failPrintCount++;
     }
   return(false);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|   ■ レート予約（7th HEAVEN風の入力ボックス）                        |
//|     SELL／BUY 各3つ。Setで予約、価格が到達したら成行＋指値を撒く     |
//|                                                                  |
//+------------------------------------------------------------------+
string ResBoxName(const int side, const int r)
  {
   return(OBJ_PREFIX + "res" + IntegerToString(side) + "_" + IntegerToString(r));
  }

//+------------------------------------------------------------------+
string ResLineName(const int side, const int r)
  {
   return(OBJ_PREFIX + "rl" + IntegerToString(side) + "_" + IntegerToString(r));
  }

//+------------------------------------------------------------------+
string RateText(const double v)
  {
   return(v > 0 ? DoubleToString(v, _Digits) : "0");
  }

//+------------------------------------------------------------------+
//| Set：ボックスの値で予約を確定                                      |
//+------------------------------------------------------------------+
void ApplyReservations()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   string summary = "";
   int    armed   = 0;

   for(int s = 0; s < 2; s++)
     {
      for(int r = 0; r < RES_SLOTS; r++)
        {
         bool   ok = false;
         double v  = ParseAmount(ObjectGetString(0, ResBoxName(s, r), OBJPROP_TEXT), ok);
         if(!ok || v <= 0)
           {
            g_resRate[s][r] = 0.0;
            g_resDir[s][r]  = 0;
           }
         else
           {
            double px = (s == SIDE_SELL) ? bid : ask;
            g_resRate[s][r] = NormPrice(v);
            g_resDir[s][r]  = (g_resRate[s][r] >= px) ? 1 : -1;
            armed++;
            summary += StringFormat(" %s %s（%s）", SideName(s), RateText(g_resRate[s][r]),
                                    (g_resDir[s][r] == 1 ? "上昇で到達" : "下落で到達"));
           }
         ObjectSetString(0, ResBoxName(s, r), OBJPROP_TEXT, RateText(g_resRate[s][r]));
        }
     }
   SaveState();
   DrawResLines();

   string warn = "";
   for(int s = 0; s < 2; s++)
      if(g_locked[s] && HasReservation(s))
         warn += "／" + SideName(s) + "はロック中（解除しないとエントリーしません）";
   SetAction(armed > 0 ? "予約を設定：" + summary + warn : "予約をすべて解除しました");
  }

//+------------------------------------------------------------------+
//| Del／Clear：予約を消去（side＝-1で全部）                           |
//+------------------------------------------------------------------+
void ClearReservations(const int sideFilter)
  {
   for(int s = 0; s < 2; s++)
     {
      if(sideFilter >= 0 && s != sideFilter)
         continue;
      for(int r = 0; r < RES_SLOTS; r++)
        {
         g_resRate[s][r] = 0.0;
         g_resDir[s][r]  = 0;
         ObjectSetString(0, ResBoxName(s, r), OBJPROP_TEXT, "0");
        }
     }
   SaveState();
   DrawResLines();
   SetAction(sideFilter < 0 ? "予約をすべて消去しました" : SideName(sideFilter) + "の予約を消去しました");
  }

//+------------------------------------------------------------------+
//| +50：空いているボックスに仮レートを入れる（Setを押すまで予約しない）|
//+------------------------------------------------------------------+
void FillTempRates()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int s = 0; s < 2; s++)
     {
      for(int r = 0; r < RES_SLOTS; r++)
        {
         bool   ok = false;
         double v  = ParseAmount(ObjectGetString(0, ResBoxName(s, r), OBJPROP_TEXT), ok);
         if(ok && v > 0)
            continue;
         double t = (s == SIDE_SELL) ? bid + InpTempWidth : ask - InpTempWidth;
         ObjectSetString(0, ResBoxName(s, r), OBJPROP_TEXT, DoubleToString(NormPrice(t), _Digits));
         break;   // 各方向1つだけ
        }
     }
   SetAction("仮レートを入力しました（修正して「Set」で予約）");
  }

//+------------------------------------------------------------------+
bool HasReservation(const int side)
  {
   for(int r = 0; r < RES_SLOTS; r++)
      if(g_resRate[side][r] > 0)
         return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| 到達チェック：到達したら成行＋指値（裁量エントリーとして扱う）       |
//+------------------------------------------------------------------+
void CheckReservations()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0)
      return;

   for(int s = 0; s < 2; s++)
     {
      for(int r = 0; r < RES_SLOTS; r++)
        {
         double rate = g_resRate[s][r];
         if(rate <= 0)
            continue;
         double px  = (s == SIDE_SELL) ? bid : ask;
         bool   hit = (g_resDir[s][r] == 1) ? (px >= rate) : (px <= rate);
         if(!hit)
            continue;

         //--- 予約を使用済みにする（1回だけ）
         g_resRate[s][r] = 0.0;
         g_resDir[s][r]  = 0;
         ObjectSetString(0, ResBoxName(s, r), OBJPROP_TEXT, "0");
         SaveState();
         DrawResLines();

         string reason = "";
         Print(LOG_TAG + StringFormat("%s予約レート %s に到達（現在 %s）", SideName(s), RateText(rate), PriceText(px)));
         if(EntryAllowed(s, true, reason))
            PlaceGrid(s, true);
         else
            SetAction(StringFormat("【%s】予約レート %s 到達・エントリー不可：%s", SideName(s), RateText(rate), reason));
        }
     }
  }

//+------------------------------------------------------------------+
//| 予約ラインの描画                                                  |
//+------------------------------------------------------------------+
void DrawResLines()
  {
   for(int s = 0; s < 2; s++)
     {
      for(int r = 0; r < RES_SLOTS; r++)
        {
         string name = ResLineName(s, r);
         if(g_resRate[s][r] <= 0)
           {
            if(ObjectFind(0, name) >= 0)
               ObjectDelete(0, name);
            continue;
           }
         if(ObjectFind(0, name) < 0)
            ObjectCreate(0, name, OBJ_HLINE, 0, 0, g_resRate[s][r]);
         ObjectSetDouble(0, name, OBJPROP_PRICE, g_resRate[s][r]);
         ObjectSetInteger(0, name, OBJPROP_COLOR, s == SIDE_SELL ? InpSellLineColor : InpBuyLineColor);
         ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, name, OBJPROP_BACK, true);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
         ObjectSetString(0, name, OBJPROP_TOOLTIP, StringFormat("%s予約 %s（到達で成行＋指値%d本）",
                         SideName(s), RateText(g_resRate[s][r]), InpGridCount));
        }
     }
  }

//+------------------------------------------------------------------+
//| グリッドID・コメント                                              |
//|   コメント形式：7HA|S|グリッド番号|段数|微益幅                     |
//+------------------------------------------------------------------+
int NextGridId()
  {
   g_gridSeq++;
   if(g_gridSeq > 999999)
      g_gridSeq = 1;
   SaveState();
   return(g_gridSeq);
  }

//+------------------------------------------------------------------+
string GridComment(const int side, const int gid, const int k, const double tpw)
  {
   return(StringFormat("7HA|%s|%d|%d|%s", (side == SIDE_SELL ? "S" : "B"), gid, k, DoubleToString(tpw, _Digits)));
  }

//+------------------------------------------------------------------+
bool ParseGridComment(const string c, int &gid, double &tpw)
  {
   gid = 0;
   tpw = 0.0;
   string parts[];
   if(StringSplit(c, '|', parts) < 5)
      return(false);
   if(parts[0] != "7HA")
      return(false);
   gid = (int)StringToInteger(parts[2]);
   tpw = StringToDouble(parts[4]);
   return(gid > 0);
  }

//+------------------------------------------------------------------+
//| ポジションが残っているグリッド番号の一覧（コメント不明は0）          |
//+------------------------------------------------------------------+
int ActiveGridIds(const int side, int &ids[])
  {
   ArrayResize(ids, 0);
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOwnPositionSelected() || PositionSideSelected() != side)
         continue;
      int    g = 0;
      double w = 0.0;
      ParseGridComment(PositionGetString(POSITION_COMMENT), g, w);
      bool found = false;
      for(int k = 0; k < ArraySize(ids); k++)
         if(ids[k] == g)
           {
            found = true;
            break;
           }
      if(!found)
        {
         int sz = ArraySize(ids);
         ArrayResize(ids, sz + 1);
         ids[sz] = g;
        }
     }
   return(ArraySize(ids));
  }

//+------------------------------------------------------------------+
int CountActiveGrids(const int side)
  {
   int ids[];
   return(ActiveGridIds(side, ids));
  }

//+------------------------------------------------------------------+
//| 終了済みグリッド（ポジが1本も残っていない）の指値を削除             |
//+------------------------------------------------------------------+
int DeleteStaleOrders(const int side)
  {
   if(OrdersTotal() == 0)
      return(0);
   int ids[];
   ActiveGridIds(side, ids);
   for(int k = 0; k < ArraySize(ids); k++)
      if(ids[k] == 0)
         return(0);   // グリッド番号を読めないポジがある時は、誤削除を避けて何もしない

   int deleted = 0;
   int total   = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOwnOrderSelected())
         continue;
      if(OrderSideOf((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)) != side)
         continue;
      int    g = 0;
      double w = 0.0;
      ParseGridComment(OrderGetString(ORDER_COMMENT), g, w);
      bool active = false;
      for(int k = 0; k < ArraySize(ids); k++)
         if(ids[k] == g)
           {
            active = true;
            break;
           }
      if(!active && DeleteOrderTicket(ticket))
         deleted++;
     }
   if(deleted > 0)
      Print(LOG_TAG + SideName(side) + "：終了済みグリッドの指値" + IntegerToString(deleted) + "件を削除");
   return(deleted);
  }

//+------------------------------------------------------------------+
void SetAction(const string msg)
  {
   g_actionErr  = (StringFind(msg, "不可") >= 0 || StringFind(msg, "失敗") >= 0);
   g_lastAction = TimeToString(TimeCurrent(), TIME_MINUTES | TIME_SECONDS) + " " + msg;
   Print(LOG_TAG + msg);
  }

//+------------------------------------------------------------------+
//| 件数                                                             |
//+------------------------------------------------------------------+
int CountPositions(const int side)
  {
   int cnt = 0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && IsTargetPositionSelected() && PositionSideSelected() == side)
         cnt++;
     }
   return(cnt);
  }

//+------------------------------------------------------------------+
int CountOwnPositions(const int side)
  {
   int cnt = 0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && IsOwnPositionSelected() && PositionSideSelected() == side)
         cnt++;
     }
   return(cnt);
  }

//+------------------------------------------------------------------+
int CountOwnOrders(const int side)
  {
   int cnt = 0;
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket != 0 && IsOwnOrderSelected() && OrderSideOf((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)) == side)
         cnt++;
     }
   return(cnt);
  }

//+------------------------------------------------------------------+
//| 集計                                                             |
//+------------------------------------------------------------------+
void TakeStats(SideStat &st[])
  {
   for(int s = 0; s < 2; s++)
     {
      st[s].count     = 0;
      st[s].lots      = 0.0;
      st[s].profit    = 0.0;
      st[s].orders    = 0;
      st[s].ownCount  = 0;
      st[s].ownOrders = 0;
     }

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsTargetPositionSelected())
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      double swap   = PositionGetDouble(POSITION_SWAP);
      double vol    = PositionGetDouble(POSITION_VOLUME);
      int    side   = PositionSideSelected();
      bool   own    = IsOwnPositionSelected();
      ulong  posId  = (ulong)PositionGetInteger(POSITION_IDENTIFIER);

      double p = profit;
      if(InpIncludeSwap)
         p += swap;
      if(InpIncludeCommission)
         p += GetEntryCommission(posId);

      st[side].count++;
      st[side].lots   += vol;
      st[side].profit += p;
      if(own)
         st[side].ownCount++;
     }

   int ototal = OrdersTotal();
   for(int i = ototal - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsTargetOrderSelected())
         continue;
      int sd = OrderSideOf((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE));
      if(sd < 0)
         continue;
      st[sd].orders++;
      if(IsOwnOrderSelected())
         st[sd].ownOrders++;
     }
  }

//+------------------------------------------------------------------+
//| 対象判定                                                         |
//+------------------------------------------------------------------+
bool IsTargetMagicSymbol(const long magic, const string sym)
  {
   return(magic == InpMagic && SymbolMatches(sym));
  }

//+------------------------------------------------------------------+
bool IsTargetPositionSelected()
  {
   return(IsTargetMagicSymbol(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL)));
  }

//+------------------------------------------------------------------+
bool IsTargetOrderSelected()
  {
   return(IsTargetMagicSymbol(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL)));
  }

//+------------------------------------------------------------------+
bool IsOwnPositionSelected()
  {
   return(PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == _Symbol);
  }

//+------------------------------------------------------------------+
bool IsOwnOrderSelected()
  {
   return(OrderGetInteger(ORDER_MAGIC) == InpMagic && OrderGetString(ORDER_SYMBOL) == _Symbol);
  }

//+------------------------------------------------------------------+
int PositionSideSelected()
  {
   return(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? SIDE_BUY : SIDE_SELL);
  }

//+------------------------------------------------------------------+
int OrderSideOf(const ENUM_ORDER_TYPE t)
  {
   if(t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_BUY_STOP || t == ORDER_TYPE_BUY_STOP_LIMIT)
      return(SIDE_BUY);
   if(t == ORDER_TYPE_SELL_LIMIT || t == ORDER_TYPE_SELL_STOP || t == ORDER_TYPE_SELL_STOP_LIMIT)
      return(SIDE_SELL);
   return(-1);
  }

//+------------------------------------------------------------------+
//| 銘柄の照合（サフィックス・プレフィックスの有無を問わない）           |
//+------------------------------------------------------------------+
bool SymbolMatches(const string sym)
  {
   if(sym == "")
      return(false);

   string core = CachedCore(sym);
   if(core == g_targetCore)
      return(true);

   int    tl = StringLen(g_targetCore);
   int    cl = StringLen(core);
   string up = UpperCopy(sym);

   if(tl >= 4 && StringFind(up, g_targetCore) == 0 && StringLen(up) - tl <= 5)
      return(true);
   if(cl >= 4 && StringFind(g_targetCore, core) == 0 && tl - cl <= 5)
      return(true);
   if(tl >= 6 && cl >= 6 && tl - 6 <= 5 && cl - 6 <= 5 &&
      IsAlpha6(g_targetCore) && StringSubstr(g_targetCore, 0, 6) == StringSubstr(core, 0, 6))
      return(true);
   return(false);
  }

//+------------------------------------------------------------------+
string SymbolCore(const string sym)
  {
   string up = UpperCopy(sym);
   StringTrimLeft(up);
   StringTrimRight(up);
   if(up == "")
      return("");

   string b = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string p = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   StringToUpper(b);
   StringToUpper(p);
   if(StringLen(b) == 3 && StringLen(p) == 3 && b != p && StringFind(up, b + p) >= 0)
      return(b + p);

   string out = "";
   int len = StringLen(up);
   for(int i = 0; i < len; i++)
     {
      ushort c = StringGetCharacter(up, i);
      bool sep = (c == '.' || c == '-' || c == '_' || c == '#' || c == '+' || c == '!' || c == ' ');
      if(sep)
        {
         if(StringLen(out) > 0)
            break;
         continue;
        }
      out += ShortToString(c);
     }
   return(out);
  }

//+------------------------------------------------------------------+
string CachedCore(const string sym)
  {
   int n = ArraySize(g_scName);
   for(int i = 0; i < n; i++)
      if(g_scName[i] == sym)
         return(g_scCore[i]);

   string core = SymbolCore(sym);
   if(n < 200)
     {
      ArrayResize(g_scName, n + 1);
      ArrayResize(g_scCore, n + 1);
      g_scName[n] = sym;
      g_scCore[n] = core;
     }
   return(core);
  }

//+------------------------------------------------------------------+
bool IsAlpha6(const string s)
  {
   if(StringLen(s) < 6)
      return(false);
   for(int i = 0; i < 6; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c < 'A' || c > 'Z')
         return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
string UpperCopy(const string s)
  {
   string t = s;
   StringToUpper(t);
   return(t);
  }

//+------------------------------------------------------------------+
//| 手数料（新規約定分・キャッシュ）                                   |
//+------------------------------------------------------------------+
double GetEntryCommission(const ulong posId)
  {
   int n = ArraySize(g_commId);
   for(int i = 0; i < n; i++)
      if(g_commId[i] == posId)
         return(g_commVal[i]);

   if(!HistorySelectByPosition((long)posId))
      return(0.0);

   double comm  = 0.0;
   bool   found = false;
   int    deals = HistoryDealsTotal();
   for(int k = 0; k < deals; k++)
     {
      ulong d = HistoryDealGetTicket(k);
      if(d == 0)
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
        {
         comm += HistoryDealGetDouble(d, DEAL_COMMISSION);
         found = true;
        }
     }
   if(!found)
      return(0.0);

   if(n >= 5000)
     {
      ArrayResize(g_commId, 0);
      ArrayResize(g_commVal, 0);
      n = 0;
     }
   ArrayResize(g_commId, n + 1);
   ArrayResize(g_commVal, n + 1);
   g_commId[n]  = posId;
   g_commVal[n] = comm;
   return(comm);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|   ■ 状態の保存・復元                                              |
//|                                                                  |
//+------------------------------------------------------------------+
string SideKey(const int side)
  {
   return(side == SIDE_SELL ? "S" : "B");
  }

//+------------------------------------------------------------------+
void SaveState()
  {
   if(g_gvBase == "" || g_tester)
      return;   // テスターでは保存しない（次のテストに状態を持ち越さない・軽量化）
   GlobalVariableSet(g_gvBase + "_init", g_initAmount);
   GlobalVariableSet(g_gvBase + "_autoInit", (double)InpAutoMode);
   GlobalVariableSet(g_gvBase + "_auto", (double)g_autoMode);
   GlobalVariableSet(g_gvBase + "_gseq", (double)g_gridSeq);
   GlobalVariableSet(g_gvBase + "_fold", g_collapsed ? 1.0 : 0.0);
   GlobalVariableSet(g_gvBase + "_tgtInit", MathAbs(InpTargetProfit));
   GlobalVariableSet(g_gvBase + "_tgt", g_targetAmt);
//--- 再ブレイクの決済管理（再起動後も同じグリッドを管理し続ける）
   int nr = ArraySize(g_rbt);
   GlobalVariableSet(g_gvBase + "_rbtN", (double)nr);
   for(int i = 0; i < nr; i++)
     {
      string k = g_gvBase + "_rbt" + IntegerToString(i);
      GlobalVariableSet(k + "g", (double)g_rbt[i].gid);
      GlobalVariableSet(k + "s", (double)g_rbt[i].side);
      GlobalVariableSet(k + "l", g_rbt[i].level);
      GlobalVariableSet(k + "e", g_rbt[i].ext);
      GlobalVariableSet(k + "a", g_rbt[i].atr);
      GlobalVariableSet(k + "p", g_rbt[i].peak);
      GlobalVariableSet(k + "t", (double)g_rbt[i].entryTime);
      GlobalVariableSet(k + "b", g_rbt[i].beDone ? 1.0 : 0.0);
     }
   for(int s = 0; s < 2; s++)
     {
      string k = g_gvBase + "_" + SideKey(s);
      GlobalVariableSet(k + "_amt", g_slAmt[s]);
      GlobalVariableSet(k + "_on", g_enabled[s] ? 1.0 : 0.0);
      GlobalVariableSet(k + "_lock", g_locked[s] ? 1.0 : 0.0);
      GlobalVariableSet(k + "_gtp", g_gridTP[s]);
      GlobalVariableSet(k + "_gstep", g_gridStep[s]);
      GlobalVariableSet(k + "_gtime", (double)g_gridTime[s]);
      GlobalVariableSet(k + "_arm", (double)g_armUsed[s]);
      for(int r = 0; r < RES_SLOTS; r++)
        {
         GlobalVariableSet(k + "_rr" + IntegerToString(r), g_resRate[s][r]);
         GlobalVariableSet(k + "_rd" + IntegerToString(r), (double)g_resDir[s][r]);
        }
     }
  }

//+------------------------------------------------------------------+
void LoadState()
  {
   bool sameInit = GlobalVariableCheck(g_gvBase + "_init") &&
                   MathAbs(GlobalVariableGet(g_gvBase + "_init") - g_initAmount) < 0.0000001;
   bool sameAuto = GlobalVariableCheck(g_gvBase + "_autoInit") &&
                   (int)GlobalVariableGet(g_gvBase + "_autoInit") == (int)InpAutoMode;

   if(sameAuto && GlobalVariableCheck(g_gvBase + "_auto"))
     {
      int m = (int)GlobalVariableGet(g_gvBase + "_auto");
      if(m == (int)AUTO_OFF || m == (int)AUTO_TRADE)
         g_autoMode = (ENUM_AUTO_MODE)m;
     }

   if(GlobalVariableCheck(g_gvBase + "_gseq"))
      g_gridSeq = (int)GlobalVariableGet(g_gvBase + "_gseq");
   if(GlobalVariableCheck(g_gvBase + "_fold"))
      g_collapsed = (GlobalVariableGet(g_gvBase + "_fold") > 0.5);
//--- 目標利益：入力の初期値を変えていなければ、パネルで変更した値を引き継ぐ
   if(GlobalVariableCheck(g_gvBase + "_tgtInit") && GlobalVariableCheck(g_gvBase + "_tgt") &&
      MathAbs(GlobalVariableGet(g_gvBase + "_tgtInit") - MathAbs(InpTargetProfit)) < 0.0000001)
      g_targetAmt = MathAbs(GlobalVariableGet(g_gvBase + "_tgt"));

   ArrayResize(g_rbt, 0);
   int nr = GlobalVariableCheck(g_gvBase + "_rbtN") ? (int)GlobalVariableGet(g_gvBase + "_rbtN") : 0;
   for(int i = 0; i < nr && i < 100; i++)
     {
      string k = g_gvBase + "_rbt" + IntegerToString(i);
      if(!GlobalVariableCheck(k + "g") || !GlobalVariableCheck(k + "b"))
         continue;
      int n = ArraySize(g_rbt);
      ArrayResize(g_rbt, n + 1);
      g_rbt[n].gid       = (int)GlobalVariableGet(k + "g");
      g_rbt[n].side      = ((int)GlobalVariableGet(k + "s") == SIDE_BUY) ? SIDE_BUY : SIDE_SELL;
      g_rbt[n].level     = GlobalVariableGet(k + "l");
      g_rbt[n].ext       = GlobalVariableGet(k + "e");
      g_rbt[n].atr       = GlobalVariableGet(k + "a");
      g_rbt[n].peak      = GlobalVariableGet(k + "p");
      g_rbt[n].entryTime = (datetime)(long)GlobalVariableGet(k + "t");
      g_rbt[n].beDone    = (GlobalVariableGet(k + "b") > 0.5);
      g_rbt[n].closing   = false;
      g_rbt[n].sendMs    = 0;
     }

   for(int s = 0; s < 2; s++)
     {
      string k = g_gvBase + "_" + SideKey(s);
      if(sameInit)
        {
         if(GlobalVariableCheck(k + "_amt"))
            g_slAmt[s] = MathAbs(GlobalVariableGet(k + "_amt"));
         if(GlobalVariableCheck(k + "_on"))
            g_enabled[s] = (GlobalVariableGet(k + "_on") > 0.5);
        }
      if(GlobalVariableCheck(k + "_lock"))
         g_locked[s] = (GlobalVariableGet(k + "_lock") > 0.5);
      if(GlobalVariableCheck(k + "_gtp"))
         g_gridTP[s] = GlobalVariableGet(k + "_gtp");
      if(GlobalVariableCheck(k + "_gstep"))
         g_gridStep[s] = GlobalVariableGet(k + "_gstep");
      if(GlobalVariableCheck(k + "_gtime"))
         g_gridTime[s] = (datetime)(long)GlobalVariableGet(k + "_gtime");
      if(GlobalVariableCheck(k + "_arm"))
         g_armUsed[s] = (datetime)(long)GlobalVariableGet(k + "_arm");
      for(int r = 0; r < RES_SLOTS; r++)
        {
         string rr = k + "_rr" + IntegerToString(r);
         string rd = k + "_rd" + IntegerToString(r);
         if(GlobalVariableCheck(rr) && GlobalVariableCheck(rd))
           {
            g_resRate[s][r] = GlobalVariableGet(rr);
            g_resDir[s][r]  = (int)GlobalVariableGet(rd);
            if(g_resRate[s][r] <= 0 || (g_resDir[s][r] != 1 && g_resDir[s][r] != -1))
              {
               g_resRate[s][r] = 0.0;
               g_resDir[s][r]  = 0;
              }
           }
        }
     }
   SaveState();
  }

//+------------------------------------------------------------------+
//| パネルの金額入力                                                  |
//+------------------------------------------------------------------+
void ApplyEdit(const int side)
  {
   string name = ObjName("edit", side);
   string txt  = ObjectGetString(0, name, OBJPROP_TEXT);
   bool   ok   = false;
   double v    = ParseAmount(txt, ok);
   if(!ok)
     {
      Print(LOG_TAG + "金額として読み取れません：" + txt);
      ObjectSetString(0, name, OBJPROP_TEXT, FormatPlain(g_slAmt[side]));
      return;
     }
   g_slAmt[side]  = v;
   g_warned[side] = false;
   SaveState();
   ObjectSetString(0, name, OBJPROP_TEXT, FormatPlain(v));
   Print(LOG_TAG + SideName(side) + "群の損切り額を " + (v > 0 ? "-" + FormatMoney(v) : "0（OFF）") + " に変更しました。");
  }

//+------------------------------------------------------------------+
double ParseAmount(string s, bool &ok)
  {
   for(int d = 0; d <= 9; d++)
      StringReplace(s, ShortToString((ushort)(0xFF10 + d)), IntegerToString(d));
   StringReplace(s, "．", ".");
   StringReplace(s, "，", "");
   StringReplace(s, ",", "");
   StringReplace(s, "円", "");
   StringReplace(s, "USD", "");
   StringReplace(s, "$", "");
   StringReplace(s, "-", "");
   StringReplace(s, "－", "");
   StringReplace(s, " ", "");
   StringReplace(s, "　", "");

   ok = (StringLen(s) > 0);
   int dots = 0;
   for(int i = 0; i < StringLen(s) && ok; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == '.')
         dots++;
      else
         if(c < '0' || c > '9')
            ok = false;
     }
   if(dots > 1)
      ok = false;
   if(!ok)
      return(0.0);
   return(StringToDouble(s));
  }

//+------------------------------------------------------------------+
//| 共通ユーティリティ                                                |
//+------------------------------------------------------------------+
double Buf(const int handle, const int buffer, const int shift)
  {
   double tmp[];
   if(handle == INVALID_HANDLE)
      return(EMPTY_VALUE);
   if(CopyBuffer(handle, buffer, shift, 1, tmp) != 1)
      return(EMPTY_VALUE);
   return(tmp[0]);
  }

//+------------------------------------------------------------------+
double TickSize()
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return(ts > 0 ? ts : _Point);
  }

//+------------------------------------------------------------------+
double NormPrice(const double p)
  {
   double ts = TickSize();
   return(NormalizeDouble(MathRound(p / ts) * ts, _Digits));
  }

//+------------------------------------------------------------------+
double NormLot(const double lot)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0)
      step = 0.01;
   double v = MathFloor(lot / step + 0.0000001) * step;
   v = MathMax(vmin, MathMin(vmax, v));
   return(NormalizeDouble(v, 2));
  }

//+------------------------------------------------------------------+
double MinStopDistance()
  {
   long lv = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return(lv * _Point);
  }

//+------------------------------------------------------------------+
double CurrentSpread()
  {
   return(SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID));
  }

//+------------------------------------------------------------------+
double CalcPip()
  {
   if(InpPipSize > 0)
      return(InpPipSize);
   string c = SymbolCore(_Symbol);
   if(StringFind(c, "XAU") == 0 || StringFind(c, "GOLD") == 0)
      return(0.1);
   if(_Digits == 3 || _Digits == 5)
      return(_Point * 10.0);
   return(_Point);
  }

//+------------------------------------------------------------------+
void RemoveOurIndicators()
  {
   if(g_bbName != "" && g_bbWin >= 0)
      ChartIndicatorDelete(0, g_bbWin, g_bbName);
   g_bbName = "";
  }

//+------------------------------------------------------------------+
void LogEvent(const string msg)
  {
   Print(LOG_TAG + msg);   // 通知（アラート・スマホ・メール）は行わない
  }

//+------------------------------------------------------------------+
//| 表示用文字列                                                     |
//+------------------------------------------------------------------+
string SideName(const int side)
  {
   return(side == SIDE_SELL ? "SELL" : "BUY");
  }

//+------------------------------------------------------------------+
string TFName(const ENUM_TIMEFRAMES tf)
  {
   ENUM_TIMEFRAMES t = (tf == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : tf;
   string s = EnumToString(t);
   StringReplace(s, "PERIOD_", "");
   return(s);
  }

//+------------------------------------------------------------------+
string AutoModeText(const ENUM_AUTO_MODE m)
  {
   if(m == AUTO_TRADE)
      return("自動エントリー");
   return("自動化OFF");
  }

//+------------------------------------------------------------------+
string EntryModeText()
  {
   if(InpEntryMode == ENTRY_REBREAK)
      return("再ブレイク");
   if(InpEntryMode == ENTRY_TREND)
      return("順張り");
   return("逆張り");
  }

//+------------------------------------------------------------------+
string ScopeText()
  {
   return(_Symbol);
  }

//+------------------------------------------------------------------+
string MagicListText()
  {
   return(IntegerToString(InpMagic));
  }

//+------------------------------------------------------------------+
string DeleteModeText()
  {
   if(InpDeleteOrders == DEL_ALL)
      return("全て削除します");
   if(InpDeleteOrders == DEL_SAME)
      return("同方向のみ削除します");
   return("削除しません");
  }

//+------------------------------------------------------------------+
string PriceText(const double p)
  {
   if(p == EMPTY_VALUE || p <= 0)
      return("-");
   return(DoubleToString(p, _Digits));
  }

//+------------------------------------------------------------------+
string PriceText2(const double p)
  {
   if(p == EMPTY_VALUE)
      return("-");
   return(DoubleToString(p, 2));
  }

//+------------------------------------------------------------------+
string FormatPlain(const double v)
  {
   int    digits = (g_currency == "JPY") ? 0 : 2;
   string num    = DoubleToString(MathAbs(v), digits);
   string intPart = num;
   string decPart = "";
   int dot = StringFind(num, ".");
   if(dot >= 0)
     {
      intPart = StringSubstr(num, 0, dot);
      decPart = StringSubstr(num, dot);
     }
   string out = "";
   int len = StringLen(intPart);
   for(int i = 0; i < len; i++)
     {
      out += StringSubstr(intPart, i, 1);
      int rest = len - 1 - i;
      if(rest > 0 && rest % 3 == 0)
         out += ",";
     }
   return(out + decPart);
  }

//+------------------------------------------------------------------+
string CurrencyUnit()
  {
   return(g_currency == "JPY" ? "円" : " " + g_currency);
  }

//+------------------------------------------------------------------+
string FormatMoney(const double v)
  {
   return((v < 0 ? "-" : "") + FormatPlain(v) + CurrencyUnit());
  }

//+------------------------------------------------------------------+
string StringTrimLeftCopy(const string s)
  {
   string t = s;
   StringTrimLeft(t);
   return(t);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//|   ■ パネル                                                       |
//|                                                                  |
//+------------------------------------------------------------------+
string ObjName(const string key, const int side)
  {
   return(OBJ_PREFIX + key + "_" + IntegerToString(side));
  }

//+------------------------------------------------------------------+
int Px(const int v)
  {
   return((int)MathRound(v * MathMax(9, InpFontSize) / 10.0));
  }

//+------------------------------------------------------------------+
void SetCommon(const string name, const int x, const int y)
  {
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpPanelX + x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpPanelY + y);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
  }

//+------------------------------------------------------------------+
void MakeRect(const string name, const int x, const int y, const int w, const int h, const color bg, const color border)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   SetCommon(name, x, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
  }

//+------------------------------------------------------------------+
void MakeLabel(const string name, const int x, const int y, const string text, const color clr, const int size)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   SetCommon(name, x, y);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_FONT, "Meiryo UI");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
void MakeButton(const string name, const int x, const int y, const int w, const int h,
                const string text, const color bg, const color fg)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   SetCommon(name, x, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_FONT, "Meiryo UI");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize - 1);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 10);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
  }

//+------------------------------------------------------------------+
void MakeEdit(const string name, const int x, const int y, const int w, const int h, const string text)
  {
   bool isNew = (ObjectFind(0, name) < 0);
   if(isNew)
      ObjectCreate(0, name, OBJ_EDIT, 0, 0, 0);
   SetCommon(name, x, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetString(0, name, OBJPROP_FONT, "Meiryo UI");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_ALIGN, ALIGN_RIGHT);
   ObjectSetInteger(0, name, OBJPROP_READONLY, false);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrBlack);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 10);
   if(isNew)
      ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
//| パネル共通                                                        |
//+------------------------------------------------------------------+
#define PANEL_W      250

string Fit(const string t, const int n)
  {
   if(StringLen(t) <= n)
      return(t);
   return(StringSubstr(t, 0, n - 1) + "…");
  }

//+------------------------------------------------------------------+
void SetText(const string name, const string text, const color clr)
  {
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
void SetTip(const string name, const string tip)
  {
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip);
  }

//+------------------------------------------------------------------+
//| パネル作成（左端に寄せた縦長・幅250）                               |
//+------------------------------------------------------------------+
void CreatePanel()
  {
   int fs = InpFontSize;
   int W  = PANEL_W;

//--- 折りたたみ時：タイトル行だけ
   if(g_collapsed)
     {
      MakeRect(OBJ_PREFIX + "bg", 0, 0, Px(W), Px(24), C'24,26,34', C'90,95,120');
      MakeLabel(OBJ_PREFIX + "title", Px(6), Px(4), "裁量Nanpin", clrWhite, fs - 1);
      MakeLabel(OBJ_PREFIX + "mini", Px(80), Px(5), "", clrSilver, fs - 2);
      MakeButton(OBJ_PREFIX + "collapse", Px(W - 26), Px(2), Px(22), Px(20), "＋", clrDimGray, clrWhite);
      SetTip(OBJ_PREFIX + "collapse", "パネルを開く");
      DrawResLines();
      return;
     }

   MakeRect(OBJ_PREFIX + "bg", 0, 0, Px(W), Px(492), C'24,26,34', C'90,95,120');
   MakeLabel(OBJ_PREFIX + "title", Px(6), Px(4), "裁量Nanpin v4.72", clrWhite, fs);
   MakeButton(OBJ_PREFIX + "collapse", Px(W - 26), Px(2), Px(22), Px(20), "－", clrDimGray, clrWhite);
   SetTip(OBJ_PREFIX + "collapse", "パネルを折りたたむ（チャートを広く見る）");
   MakeLabel(OBJ_PREFIX + "status", Px(6), Px(24), "", clrLime, fs - 2);

//--- 相場情報（詳細はマウスを乗せるとツールチップ表示）
   MakeLabel(OBJ_PREFIX + "atr",   Px(6), Px(40), "", clrWhite, fs);
   MakeLabel(OBJ_PREFIX + "htf",   Px(6), Px(58), "", clrWhite, fs - 1);
   MakeLabel(OBJ_PREFIX + "trend", Px(6), Px(74), "", clrSilver, fs - 1);

//--- 自動化
   MakeButton(OBJ_PREFIX + "auto", Px(6), Px(92), Px(W - 12), Px(22), "", clrDimGray, clrWhite);
   MakeLabel(OBJ_PREFIX + "grid", Px(6), Px(118), "", clrSilver, fs - 2);

//--- SELL／BUY（強制決済の監視）
   for(int s = 0; s < 2; s++)
     {
      int   y0     = (s == SIDE_SELL) ? Px(136) : Px(196);
      color sideBg = (s == SIDE_SELL) ? clrCrimson : clrRoyalBlue;

      MakeButton(ObjName("side", s), Px(6), y0, Px(40), Px(54), SideName(s), sideBg, clrWhite);
      MakeLabel(ObjName("pos", s),  Px(52),  y0 + Px(1),  "", clrWhite, fs - 1);
      MakeLabel(ObjName("ord", s),  Px(52),  y0 + Px(17), "", clrSilver, fs - 2);
      MakeLabel(ObjName("pl", s),   Px(150), y0 + Px(1),  "", clrWhite, fs);
      MakeLabel(ObjName("st", s),   Px(150), y0 + Px(18), "", clrWhite, fs - 2);
      MakeEdit(ObjName("edit", s),  Px(52),  y0 + Px(33), Px(78), Px(20), FormatPlain(g_slAmt[s]));
      MakeButton(ObjName("onoff", s), Px(133), y0 + Px(33), Px(34), Px(20), "ON", clrSeaGreen, clrWhite);
      MakeLabel(ObjName("rest", s), Px(172), y0 + Px(37), "", clrSilver, fs - 2);
      MakeButton(ObjName("release", s), Px(172), y0 + Px(33), Px(72), Px(20), "解除", clrDarkOrange, clrWhite);
      SetTip(ObjName("edit", s), "強制決済額（" + StringTrimLeftCopy(CurrencyUnit()) + "）：この群の含み損合計がこの額に達したら全決済。0でOFF");
     }

//--- 裁量ボタン
   MakeButton(ObjName("manual", SIDE_SELL),   Px(6),   Px(258), Px(118), Px(22), "SELL 成行グリッド", clrCrimson, clrWhite);
   MakeButton(ObjName("closeown", SIDE_SELL), Px(126), Px(258), Px(118), Px(22), "SELL 決済", C'90,40,40', clrWhite);
   MakeButton(ObjName("manual", SIDE_BUY),    Px(6),   Px(282), Px(118), Px(22), "BUY 成行グリッド", clrRoyalBlue, clrWhite);
   MakeButton(ObjName("closeown", SIDE_BUY),  Px(126), Px(282), Px(118), Px(22), "BUY 決済", C'40,50,100', clrWhite);
   SetTip(ObjName("closeown", SIDE_SELL), "このEAのSELLポジションを全決済＋SELL指値を全削除（確認なしで即実行）");
   SetTip(ObjName("closeown", SIDE_BUY), "このEAのBUYポジションを全決済＋BUY指値を全削除（確認なしで即実行）");

//--- 目標利益
   MakeLabel(OBJ_PREFIX + "tgtlbl", Px(6), Px(312), "目標利益", clrWhite, fs - 1);
   MakeEdit(OBJ_PREFIX + "tgt", Px(62), Px(308), Px(78), Px(20), FormatPlain(g_targetAmt));
   MakeLabel(OBJ_PREFIX + "tgtst", Px(144), Px(312), "", clrSilver, fs - 2);
   SetTip(OBJ_PREFIX + "tgt", "目標利益（" + StringTrimLeftCopy(CurrencyUnit()) + "）：このEAの合計損益（SELL＋BUYの含み損益）がこの額に達したら、"
          "全ポジション決済＋指値全削除。0でOFF");

//--- レート予約（7th HEAVEN風）
   MakeLabel(OBJ_PREFIX + "rstitle", Px(6), Px(336), "予約（到達で成行＋指値・Setで確定）", clrSilver, fs - 2);
   for(int s = 0; s < 2; s++)
     {
      int   y  = (s == SIDE_SELL) ? Px(352) : Px(376);
      color bg = (s == SIDE_SELL) ? clrCrimson : clrRoyalBlue;
      MakeButton(ObjName("rsside", s), Px(6), y, Px(30), Px(20), (s == SIDE_SELL ? "S" : "B"), bg, clrWhite);
      for(int r = 0; r < RES_SLOTS; r++)
         MakeEdit(ResBoxName(s, r), Px(40 + r * 68), y, Px(64), Px(20), RateText(g_resRate[s][r]));
     }
   MakeButton(ObjName("rsdel", SIDE_SELL), Px(6),   Px(400), Px(46), Px(20), "S Del", C'240,170,170', clrBlack);
   MakeButton(ObjName("rsdel", SIDE_BUY),  Px(54),  Px(400), Px(46), Px(20), "B Del", C'160,220,220', clrBlack);
   MakeButton(OBJ_PREFIX + "rsclear",      Px(102), Px(400), Px(46), Px(20), "Clear", C'205,92,92', clrWhite);
   MakeButton(OBJ_PREFIX + "rsplus",       Px(150), Px(400), Px(44), Px(20),
              StringFormat("+%.0f", InpTempWidth / g_pip), C'235,225,200', clrBlack);
   MakeButton(OBJ_PREFIX + "rsset",        Px(196), Px(400), Px(48), Px(20), "Set", clrDodgerBlue, clrWhite);
   SetTip(ObjName("rsdel", SIDE_SELL), "SELLの予約を消去");
   SetTip(ObjName("rsdel", SIDE_BUY), "BUYの予約を消去");
   SetTip(OBJ_PREFIX + "rsclear", "予約をすべて消去");
   SetTip(OBJ_PREFIX + "rsplus", "空き枠に現在値±仮レート幅を入力（Setで確定）");
   MakeLabel(OBJ_PREFIX + "rsstate", Px(6), Px(424), "", clrSilver, fs - 2);
   DrawResLines();

//--- 補足
   MakeLabel(OBJ_PREFIX + "info1", Px(6), Px(440), "", clrSilver, fs - 2);
   MakeLabel(OBJ_PREFIX + "info2", Px(6), Px(456), "", clrSilver, fs - 2);
   MakeLabel(OBJ_PREFIX + "info3", Px(6), Px(472), "", clrSilver, fs - 2);
  }

//+------------------------------------------------------------------+
//| パネル更新                                                       |
//+------------------------------------------------------------------+
void RefreshPanel(const bool force)
  {
   if(g_noPanel)
      return;
//--- 表示更新は0.2秒（実時間）に1回まで。操作直後は即時
   ulong now = GetTickCount64();
   if(!force && g_lastPanelMs != 0 && (now - g_lastPanelMs) < 200)
      return;
   g_lastPanelMs = now;

   if(ObjectFind(0, OBJ_PREFIX + "bg") < 0)
      CreatePanel();

   SideStat st[2];
   TakeStats(st);

//--- 折りたたみ時：損益だけ
   if(g_collapsed)
     {
      SetText(OBJ_PREFIX + "mini", "S " + FormatMoney(st[SIDE_SELL].profit) + "  B " + FormatMoney(st[SIDE_BUY].profit),
              (st[SIDE_SELL].profit + st[SIDE_BUY].profit) < 0 ? clrTomato : clrSilver);
      DrawRebreakLines();
      ChartRedraw(0);
      return;
     }

//--- 全体ステータス
   string status = InpDryRun ? "[監視中・テストモード]" : "[監視中]";
   color  scol   = InpDryRun ? clrGold : clrLime;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      status = "[自動売買が無効：発注・決済できません]";
      scol   = clrOrangeRed;
     }
   SetText(OBJ_PREFIX + "status", status + "　口座通貨 " + g_currency + "　Magic " + MagicListText(), scol);

//--- ATR
   double atr0 = Buf(g_hATR, 0, 0);
   double atr1 = Buf(g_hATR, 0, 1);
   double atrH = Buf(g_hATRH, 0, 1);
   string atrState = "OK";
   color  atrCol   = clrLime;
   if(atr1 != EMPTY_VALUE && InpATRMax > 0 && atr1 > InpATRMax)
     {
      atrState = "上限超え";
      atrCol   = clrOrangeRed;
     }
   else
      if(atr1 != EMPTY_VALUE && InpATRMin > 0 && atr1 < InpATRMin)
        {
         atrState = "下限未満";
         atrCol   = clrOrange;
        }
   SetText(OBJ_PREFIX + "atr", StringFormat("ATR(%s) %s／%sp %s", TFName(g_entryTF), PriceText2(atr0),
                                            (atr0 == EMPTY_VALUE ? "-" : DoubleToString(atr0 / g_pip, 1)), atrState), atrCol);

//--- BB（詳細はツールチップ）
   double up0 = Buf(g_hBB, 1, 0);
   double md0 = Buf(g_hBB, 0, 0);
   double lo0 = Buf(g_hBB, 2, 0);
   double ue  = Buf(g_hBBE, 1, 0);
   double le  = Buf(g_hBBE, 2, 0);
   SetTip(OBJ_PREFIX + "atr",
          StringFormat("ATR(%d,%s) 現在 %s／確定足 %s／上位足(%s) %s\n上限 %s／下限 %s／スプレッド %s\n"
                       "BB(%d,%s) +%.1fσ %s／+%.1fσ %s／中 %s／-%.1fσ %s／-%.1fσ %s",
                       InpATRPeriod, TFName(g_entryTF), PriceText2(atr0), PriceText2(atr1), TFName(InpHTF), PriceText2(atrH),
                       (InpATRMax > 0 ? PriceText2(InpATRMax) : "OFF"), (InpATRMin > 0 ? PriceText2(InpATRMin) : "OFF"),
                       PriceText2(CurrentSpread()),
                       InpBBPeriod, TFName(g_entryTF), InpBBDev, PriceText(up0), InpTrendEntryDev, PriceText(ue), PriceText(md0),
                       InpTrendEntryDev, PriceText(le), InpBBDev, PriceText(lo0)));

//--- 上位足
   string htfText;
   color  htfCol = clrWhite;
   if(!InpUseHTF)
      htfText = "上位足：OFF（両方向）";
   else
     {
      int tr = HTFTrend();
      if(tr == 1)
        {
         htfText = TFName(InpHTF) + "：上昇 → 買いのみ";
         htfCol  = clrDeepSkyBlue;
        }
      else
         if(tr == -1)
           {
            htfText = TFName(InpHTF) + "：下降 → 売りのみ";
            htfCol  = clrTomato;
           }
         else
           {
            htfText = TFName(InpHTF) + "：方向不明確 → " + (InpHTFNeutral == HTF_NEUTRAL_BOTH ? "両方向" : "見送り");
            htfCol  = clrSilver;
           }
     }
   SetText(OBJ_PREFIX + "htf", htfText, htfCol);

//--- 順張りの待機状態
   color  tcol = clrSilver;
   string ttxt = TrendStatusText(tcol);
   StringReplace(ttxt, "方式：", "");
   StringReplace(ttxt, "到達済 → ", "済→");
   StringReplace(ttxt, "到達待ち", "待ち");
   SetText(OBJ_PREFIX + "trend", Fit(ttxt, 24), tcol);
   SetTip(OBJ_PREFIX + "trend", ttxt);
   DrawRebreakLines();

//--- 自動化ボタン・グリッド設定
   ObjectSetString(0, OBJ_PREFIX + "auto", OBJPROP_TEXT, "自動化：" + AutoModeText(g_autoMode));
   ObjectSetInteger(0, OBJ_PREFIX + "auto", OBJPROP_BGCOLOR, (g_autoMode == AUTO_TRADE) ? clrSeaGreen : clrDimGray);

   double step, tp;
   CalcWidths(step, tp);
   SetText(OBJ_PREFIX + "grid", StringFormat("成行1＋指値%d　間隔%s／微益%s　%.2flot", InpGridCount,
                                             PriceText2(step), PriceText2(tp), NormLot(InpLot)), clrSilver);

//--- SELL／BUY
   for(int s = 0; s < 2; s++)
     {
      SetText(ObjName("pos", s), StringFormat("%dポジ %.2flot", st[s].count, st[s].lots), clrWhite);
      SetText(ObjName("ord", s), StringFormat("指値%d　G%d", st[s].orders, CountActiveGrids(s)), clrSilver);
      SetText(ObjName("pl", s), FormatMoney(st[s].profit),
              st[s].profit < 0 ? clrTomato : (st[s].profit > 0 ? clrDeepSkyBlue : clrWhite));

      ObjectSetString(0, ObjName("onoff", s), OBJPROP_TEXT, g_enabled[s] ? "ON" : "OFF");
      ObjectSetInteger(0, ObjName("onoff", s), OBJPROP_BGCOLOR, g_enabled[s] ? clrSeaGreen : clrDimGray);

      string stText;
      color  stCol = clrWhite;
      string rest  = "";
      if(g_closing[s])
        {
         stText = "決済中…";
         stCol  = clrOrangeRed;
        }
      else
         if(g_locked[s])
           {
            stText = "ロック中";
            stCol  = clrOrange;
           }
         else
            if(!g_enabled[s] || g_slAmt[s] <= 0)
              {
               stText = "強制決済OFF";
               stCol  = clrDarkGray;
              }
            else
              {
               stText = (st[s].count > 0) ? "監視中" : "待機中";
               stCol  = clrLime;
               if(st[s].count > 0)
                 {
                  rest = "あと" + FormatMoney(MathMax(0.0, g_slAmt[s] + st[s].profit));
                  if(st[s].profit <= -g_slAmt[s] * 0.8)
                     stCol = clrOrangeRed;
                 }
              }
      SetText(ObjName("st", s), stText, stCol);
      SetText(ObjName("rest", s), g_locked[s] ? "" : rest, clrSilver);
      ObjectSetInteger(0, ObjName("release", s), OBJPROP_TIMEFRAMES, g_locked[s] ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
     }

//--- 目標利益
   if(g_flatActive)
      SetText(OBJ_PREFIX + "tgtst", "一括決済中…", clrOrangeRed);
   else
      if(g_targetAmt <= 0)
         SetText(OBJ_PREFIX + "tgtst", "OFF（0で無効）", clrDarkGray);
      else
        {
         int    tn = 0;
         double tp = OwnProfit(tn);   // 目標判定と同じ集計（このEAのポジションのみ）
         SetText(OBJ_PREFIX + "tgtst", "あと" + FormatMoney(MathMax(0.0, g_targetAmt - tp)), tn > 0 ? clrGold : clrSilver);
        }

//--- レート予約の状態
   string rs = "";
   for(int s = 0; s < 2; s++)
      for(int r = 0; r < RES_SLOTS; r++)
        {
         bool on = (g_resRate[s][r] > 0);
         ObjectSetInteger(0, ResBoxName(s, r), OBJPROP_BGCOLOR, on ? C'255,245,200' : clrWhite);
         if(on)
            rs += StringFormat("%s%s%s ", (s == SIDE_SELL ? "S" : "B"), RateText(g_resRate[s][r]), (g_resDir[s][r] == 1 ? "↑" : "↓"));
        }
   SetText(OBJ_PREFIX + "rsstate", "予約中：" + (rs == "" ? "なし" : Fit(rs, 34)), rs == "" ? clrSilver : clrGold);
   SetTip(OBJ_PREFIX + "rsstate", "予約中：" + (rs == "" ? "なし" : rs + "（↑＝上昇して到達／↓＝下落して到達）"));

//--- 補足（長い文はツールチップで全文）
   string i1 = "シグナル：" + (g_lastSignal == "" ? "なし" : g_lastSignal);
   string i2 = "操作：" + (g_lastAction == "" ? "なし" : g_lastAction);
   string i3 = "強制決済：" + (g_lastEvent == "" ? "なし" : g_lastEvent);
   SetText(OBJ_PREFIX + "info1", Fit(i1, 27), clrSilver);
   SetText(OBJ_PREFIX + "info2", Fit(i2, 27), g_actionErr ? clrOrangeRed : clrSilver);
   SetText(OBJ_PREFIX + "info3", Fit(i3, 27), clrSilver);
   SetTip(OBJ_PREFIX + "info1", i1);
   SetTip(OBJ_PREFIX + "info2", i2);
   SetTip(OBJ_PREFIX + "info3", i3 + "\n強制決済時の指値：" + DeleteModeText() + "／ロック：" + (InpLockAfterSL ? "ON" : "OFF") +
          "\n銘柄：" + ScopeText());

   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
