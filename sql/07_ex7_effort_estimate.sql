-- =====================================================================
-- 07_ex7_effort_estimate.sql  Exercise 7：業務効果を確認する（10分）
-- 注意 : 以下の時間はすべて「PoC で測定すべき仮説」です。確定した効果ではありません。
--        現状の時間（合計 100 時間）も説明用の架空の値です。実際の内訳は業務担当者へのヒアリングや PoC の実測で置き換えてください。
-- =====================================================================
-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

CREATE OR REPLACE TABLE effort_estimate (
  task_order        INT,
  task              STRING  COMMENT '作業工程',
  current_hours     DOUBLE  COMMENT '現状の想定時間（新機種1台分のコスト積み上げ、仮置き）',
  target_hours      DOUBLE  COMMENT 'Databricks 導入後の想定時間（仮説。参加者が入力）',
  databricks_lever  STRING  COMMENT '短縮の手段',
  poc_measurement   STRING  COMMENT 'PoC で何を測るか'
) COMMENT '業務効果試算（仮説）。PoC で実測して検証する。';

INSERT INTO effort_estimate VALUES
 (1,'データ収集'        ,22, 8,'計画・販売・生産を Delta に集約（元システムは変更しない）'          ,'データ取得〜集計可能状態までの時間'),
 (2,'名称・コード調査'  ,20, 5,'Discover Page で正式定義・別名を参照、Genie One で質問'              ,'「このコードは何の車両か」の調査1件あたり時間・件数'),
 (3,'マッチング'        ,22, 7,'vehicle_alias_master と正規化ルールで自動変換、残りだけレビュー'    ,'自動変換率、レビュー対象件数、1件あたり確認時間'),
 (4,'不整合確認'        ,17, 4,'DQ ルール（タイヤ本数、重複、マスタ矛盾、欠損）で自動検出'          ,'検出件数、見逃し件数、原因調査時間'),
 (5,'集計'              ,11, 2,'共通機種ID × 月の採算 View で再集計（再実行は数秒）'                ,'再集計1回あたりの時間、再集計回数'),
 (6,'レビュー'          , 8, 6,'根拠（Page・対応表の承認記録）を添えたレビュー。判断自体は人が行う','レビュー時間、差し戻し件数');

-- 7-1. 仮説値で試算
SELECT task, current_hours, target_hours,
       current_hours - target_hours                                  AS saved_hours,
       round((current_hours - target_hours) / current_hours * 100, 1) AS saved_pct,
       databricks_lever, poc_measurement
FROM effort_estimate
UNION ALL
SELECT '合計', sum(current_hours), sum(target_hours),
       sum(current_hours) - sum(target_hours),
       round((sum(current_hours) - sum(target_hours)) / sum(current_hours) * 100, 1),
       NULL, NULL
FROM effort_estimate;
-- 期待値（仮説値のまま）: 100h → 32h、削減 68h、削減率 68.0%（すべて架空の値）

-- 7-2. 参加者が自分の想定値を入力して試算する（SQL エディタのパラメータ :h_xxx に数値を入力）
WITH input AS (
  SELECT * FROM VALUES
    ('データ収集'      , CAST(:h_collect   AS DOUBLE)),
    ('名称・コード調査', CAST(:h_research  AS DOUBLE)),
    ('マッチング'      , CAST(:h_matching  AS DOUBLE)),
    ('不整合確認'      , CAST(:h_quality   AS DOUBLE)),
    ('集計'            , CAST(:h_aggregate AS DOUBLE)),
    ('レビュー'        , CAST(:h_review    AS DOUBLE)) AS t(task, my_target_hours)
)
SELECT e.task_order, e.task, e.current_hours, i.my_target_hours,
       e.current_hours - i.my_target_hours                                  AS saved_hours,
       round((e.current_hours - i.my_target_hours) / e.current_hours * 100, 1) AS saved_pct,
       sum(e.current_hours - i.my_target_hours) OVER ()                     AS total_saved_hours,
       round(sum(e.current_hours - i.my_target_hours) OVER () / sum(e.current_hours) OVER () * 100, 1) AS total_saved_pct
FROM effort_estimate e JOIN input i USING (task)
ORDER BY e.task_order;

-- 7-3. （パラメータが使えない場合の代替）UPDATE で自分の想定値を入れてから 7-1 を再実行
-- UPDATE effort_estimate SET target_hours = 20 WHERE task = 'データ収集';
