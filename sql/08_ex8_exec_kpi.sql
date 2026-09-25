-- =====================================================================
-- 08_ex8_exec_kpi.sql  Exercise 8-1〜8-3：経営KPI・データ信頼度・打ち手を定義する（第2回・25分）
-- 前提 : 第1回（00〜06）と、第2回の 05b・07 を実行済みであること
-- 方針 : 経営者が見る数字の「定義」を Metric View に 1 か所でまとめ、ダッシュボードでも Genie でも同じ数字を出す。
--        あわせて「その数字がどこまで信用できるか」（データ信頼度）と「どこに手を打つべきか」（打ち手）を用意する。
--        金額は百万円、すべて架空データ。「1台あたり簡易限界利益」は売上単価 − 材料費単価で、正式な利益指標ではない。
-- =====================================================================
-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

-- ---------------------------------------------------------------------
-- 8-1. 経営KPIを Metric View で定義する（KPI の定義を 1 か所にまとめる）
--   1台あたりの指標は、合計を割り算するので、どの粒度（月・期間・車種）で集計しても正しく計算される
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW mv_vehicle_profitability
WITH METRICS
LANGUAGE YAML
AS $$
version: 1.1
comment: "車種別採算の経営KPI（架空データ・金額は百万円）。定義は Page「採算KPIの定義」を参照。共通機種IDで計画・販売・生産を統合した v_vehicle_monthly_profitability が元データ。"
source: v_vehicle_monthly_profitability
dimensions:
  - name: 共通機種ID
    expr: canonical_vehicle_id
  - name: 車種名
    expr: global_vehicle_name
  - name: 月
    expr: month
measures:
  - name: 計画売上
    expr: SUM(planned_sales)
  - name: 実績売上
    expr: SUM(actual_sales)
  - name: 売上差額
    expr: SUM(actual_sales) - SUM(planned_sales)
    comment: "実績売上 − 計画売上"
  - name: 売上計画比
    expr: SUM(actual_sales) / SUM(planned_sales) - 1
    comment: "実績売上 ÷ 計画売上 − 1（−0.05 は計画比 −5%）"
  - name: 計画材料費
    expr: SUM(planned_material_cost)
  - name: 実績材料費
    expr: SUM(actual_material_cost)
  - name: 材料費差額
    expr: SUM(actual_material_cost) - SUM(planned_material_cost)
    comment: "実績材料費 − 計画材料費（プラスは計画超過）"
  - name: 計画台数
    expr: SUM(planned_volume)
  - name: 販売台数
    expr: SUM(sales_volume)
  - name: 生産台数
    expr: SUM(production_volume)
  - name: 1台あたり計画売上
    expr: SUM(planned_sales) / SUM(planned_volume)
  - name: 1台あたり実績売上
    expr: SUM(actual_sales) / SUM(sales_volume)
    comment: "実績売上 ÷ 販売台数"
  - name: 1台あたり計画材料費
    expr: SUM(planned_material_cost) / SUM(planned_volume)
  - name: 1台あたり実績材料費
    expr: SUM(actual_material_cost) / SUM(production_volume)
    comment: "実績材料費 ÷ 生産台数（材料費は生産側で発生するため生産台数で割る）"
  - name: 1台あたり計画限界利益（簡易）
    expr: SUM(planned_sales) / SUM(planned_volume) - SUM(planned_material_cost) / SUM(planned_volume)
    comment: "1台あたり計画売上 − 1台あたり計画材料費（ハンズオン用の簡易指標）"
  - name: 1台あたり実績限界利益（簡易）
    expr: SUM(actual_sales) / SUM(sales_volume) - SUM(actual_material_cost) / SUM(production_volume)
    comment: "1台あたり実績売上 − 1台あたり実績材料費（ハンズオン用の簡易指標）"
$$;

-- Metric View の使い方：測定値は MEASURE() で取り出す（SELECT * は使えない）
SELECT `車種名`,
       MEASURE(`実績売上`)                     AS actual_sales,
       MEASURE(`売上計画比`)                   AS sales_vs_plan,
       MEASURE(`材料費差額`)                   AS cost_variance,
       MEASURE(`1台あたり計画限界利益（簡易）`) AS unit_margin_plan,
       MEASURE(`1台あたり実績限界利益（簡易）`) AS unit_margin_actual
FROM mv_vehicle_profitability
WHERE `共通機種ID` = 'VEHICLE-001'
GROUP BY ALL;

-- 同じ定義を月別に集計しても、1台あたりの指標は月ごとに正しく計算される
SELECT `月`,
       MEASURE(`材料費差額`)                   AS cost_variance,
       MEASURE(`1台あたり実績材料費`)           AS actual_cost_per_unit,
       MEASURE(`1台あたり実績限界利益（簡易）`) AS unit_margin_actual
FROM mv_vehicle_profitability
WHERE `共通機種ID` = 'VEHICLE-001'
GROUP BY ALL
ORDER BY `月`;

-- ---------------------------------------------------------------------
-- 8-2. データ信頼度：経営者が「この数字はどこまで信用できるか」を判断するための指標
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_data_trust_summary
COMMENT '経営ダッシュボードの数字の信頼度（共通機種IDへの変換率、未変換の影響額、品質ルール違反、承認待ち候補）'
AS
WITH sales AS (
  SELECT count(*) AS records,
         count_if(resolution_status = 'RESOLVED') AS resolved_records,
         sum(actual_sales) AS amount,
         sum(CASE WHEN resolution_status = 'RESOLVED' THEN actual_sales ELSE 0 END) AS resolved_amount
  FROM v_sales_resolved
), cost AS (
  SELECT sum(actual_material_cost) AS amount,
         sum(CASE WHEN resolution_status = 'RESOLVED' THEN actual_material_cost ELSE 0 END) AS resolved_amount
  FROM v_production_resolved
), dq AS (
  SELECT sum(CASE WHEN severity = 'HIGH' THEN violations ELSE 0 END) AS high_violations,
         sum(violations) AS all_violations
  FROM v_dq_summary
), cand AS (
  SELECT count(*) AS pending_candidates FROM vehicle_alias_master WHERE approval_status = 'CANDIDATE'
)
SELECT
  sales.records                                        AS sales_records,
  sales.resolved_records                               AS sales_resolved_records,
  round(sales.resolved_amount / sales.amount, 4)       AS sales_amount_coverage,
  round(cost.resolved_amount / cost.amount, 4)         AS cost_amount_coverage,
  sales.amount - sales.resolved_amount                 AS unresolved_sales_amount,
  cost.amount - cost.resolved_amount                   AS unresolved_cost_amount,
  dq.high_violations,
  dq.all_violations,
  cand.pending_candidates,
  CASE
    WHEN dq.high_violations > 0 THEN '要注意（重要な品質ルール違反あり）'
    WHEN sales.resolved_amount / sales.amount < 0.99 OR cost.resolved_amount / cost.amount < 0.99 THEN '要注意（未変換のデータあり）'
    ELSE '良好'
  END                                                  AS trust_level
FROM sales CROSS JOIN cost CROSS JOIN dq CROSS JOIN cand;

SELECT * FROM v_data_trust_summary;

-- ---------------------------------------------------------------------
-- 8-3. 打ち手の一覧：経営者が「どこに手を打つべきか」を判断するための一覧（担当と次の一手つき）
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_exec_action_items
COMMENT '経営者向けの打ち手一覧。材料費の計画超過、未解決のコード、重要な品質ルール違反を、影響額・担当・次の一手とともに並べる。'
AS
SELECT 1 AS priority, '材料費の計画超過' AS category,
       concat(global_vehicle_name, ' ', date_format(month, 'yyyy-MM'), '：実績 ', CAST(actual_material_cost AS STRING),
              ' / 計画 ', CAST(planned_material_cost AS STRING)) AS item,
       material_cost_variance AS impact_million_jpy,
       '原価企画（架空）' AS owner_role,
       '部品表（BOM）の重複・旧版残存を確認する（DQ-1・DQ-2）' AS next_action
FROM v_vehicle_monthly_profitability
WHERE material_cost_variance > 0
UNION ALL
SELECT 2, concat('コード未確定：', review_category),
       concat(source_code, '（', business_area, '・', country, '）'),
       affected_amount,
       'マスタ管理担当（架空）',
       CASE
         WHEN review_category LIKE '要確認（確定マスタの矛盾）%' THEN '確定済み対応の誤りを是正する'
         WHEN review_category LIKE '要確認%'                   THEN '候補の根拠を確認して承認・却下する'
         WHEN review_category = '自動承認候補'                  THEN '根拠を確認して承認する'
         ELSE '根拠を集める（Exercise 5B の「次に集めるべき根拠」を参照）'
       END
FROM v_alias_review_queue
UNION ALL
SELECT 3, '品質ルール違反', concat(rule_id, '：', rule_name, '（', CAST(violations AS STRING), '件）'),
       CAST(NULL AS DECIMAL(12,1)), 'データ管理担当（架空）', '元データの是正と、ルールの常時監視（Lakeflow 期待値）'
FROM v_dq_summary
WHERE severity = 'HIGH' AND violations > 0;

SELECT * FROM v_exec_action_items ORDER BY priority, impact_million_jpy DESC NULLS LAST;
