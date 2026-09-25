-- =====================================================================
-- 01_ex1_siloed_data.sql  Exercise 1：分断されたデータを確認する（10分）
-- =====================================================================
-- @config-begin  ノートブック版では 00_config がカタログ・スキーマを設定するため、この範囲は自動で除去されます
USE CATALOG workspace;             -- ★ SQL エディタで実行する場合は config/00_config と同じ値にする
USE SCHEMA vehicle_alias_handson;  -- ★ 同上
-- @config-end

-- 1-1. 各システムのコードを並べて見る（同じ車両なのにコードが全部違う）
SELECT 'DEVELOPMENT' AS system, development_vehicle_code AS vehicle_code, count(*) AS rows FROM development_plan  GROUP BY ALL
UNION ALL
SELECT 'SALES'      , sales_vehicle_code, count(*) FROM sales_actual      GROUP BY ALL
UNION ALL
SELECT 'PRODUCTION' , mto_code          , count(*) FROM production_actual GROUP BY ALL
ORDER BY system, vehicle_code;

-- 1-2. 計画 × 販売をコードでそのまま JOIN → 0 件
SELECT p.plan_month, p.development_vehicle_code, s.sales_vehicle_code, s.sales_volume
FROM development_plan p
JOIN sales_actual s
  ON p.development_vehicle_code = s.sales_vehicle_code
 AND p.plan_month = s.sales_month;

-- 1-3. 販売 × 生産をコードでそのまま JOIN → 0 件
SELECT s.sales_month, s.sales_vehicle_code, pr.mto_code
FROM sales_actual s
JOIN production_actual pr
  ON s.sales_vehicle_code = pr.mto_code
 AND s.sales_month = pr.production_month;

-- 1-4. 「名前なら一致するのでは？」→ 'Alpha' は先代（10th Gen）でも使われており、名称だけでは判定できない
SELECT local_vehicle_name, local_vehicle_code, canonical_vehicle_id, valid_from, valid_to
FROM vehicle_alias_master
WHERE upper(local_vehicle_name) = 'ALPHA';

-- 1-5. 同じ「日本の Alpha」でもコードの表記揺れがある（完全一致では拾えない）
SELECT sales_record_id, sales_vehicle_code,
       length(sales_vehicle_code) AS len,
       sales_vehicle_code = 'JP-A11' AS exact_match
FROM sales_actual
WHERE country = 'JP' AND sales_vehicle_code NOT IN ('JP-A10', 'JP-A11E', 'JP-A11-SE');

-- 1-6. 粒度の違い：販売は「パワートレイン × 月」、生産は「MTO × 月」、計画は「開発コード × 月」
SELECT 'sales_actual' AS t, sales_month AS month, count(*) AS rows_per_month
FROM sales_actual WHERE norm_code(sales_vehicle_code) IN ('JPA11', 'CNX123', 'CNX123B') GROUP BY ALL
UNION ALL
SELECT 'production_actual', production_month, count(*) FROM production_actual WHERE norm_code(mto_code) = 'MTO987' GROUP BY ALL
UNION ALL
SELECT 'development_plan', plan_month, count(*) FROM development_plan WHERE development_vehicle_code = 'DEV-A11' GROUP BY ALL
ORDER BY t, month;
