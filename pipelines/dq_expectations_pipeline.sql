-- =====================================================================
-- dq_expectations_pipeline.sql  （任意）Lakeflow Spark Declarative Pipelines 版のデータ品質ルール
-- 使い方 : Jobs & Pipelines → 作成 → ETL パイプライン → このファイルをソースに指定
--          パイプラインの既定のカタログ・スキーマを config/00_config と同じ値に設定する
--          （Free Edition の既定: workspace / vehicle_alias_handson。元テーブルと同じスキーマに *_check が作成される）
--          Serverless で実行 → パイプライン画面の「データ品質」タブで違反件数を確認
-- 方針 : WARN（記録のみ）/ DROP ROW（除外）/ FAIL UPDATE（停止）を重要度に応じて使い分ける
-- =====================================================================

-- 1. 対応表：必須項目が欠損した行は「確定対応」から除外し、違反件数を記録
CREATE OR REFRESH MATERIALIZED VIEW alias_master_validated (
  CONSTRAINT code_not_null      EXPECT (local_vehicle_code IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT period_not_null    EXPECT (valid_from IS NOT NULL AND valid_to IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT period_order       EXPECT (valid_from <= valid_to) ON VIOLATION DROP ROW,
  CONSTRAINT score_range        EXPECT (confidence_score IS NULL OR confidence_score BETWEEN 0 AND 100)
)
COMMENT '必須項目チェック済みの対応表'
AS SELECT * FROM vehicle_alias_master;

-- 2. 同一元コードに複数の有効な共通機種ID（マスタ矛盾）。1件でもあれば警告として記録
CREATE OR REFRESH MATERIALIZED VIEW alias_conflict_check (
  CONSTRAINT single_vehicle_per_code EXPECT (vehicle_count = 1)
)
COMMENT '元コードごとの有効な共通機種ID数'
AS
SELECT business_area, country, upper(regexp_replace(local_vehicle_code, '[^A-Za-z0-9]', '')) AS norm_code,
       count(DISTINCT canonical_vehicle_id) AS vehicle_count
FROM alias_master_validated
WHERE approval_status = 'APPROVED'
GROUP BY ALL;
-- ※ 期間重複の厳密判定は sql/06_ex6_data_quality.sql の DQ-3 を参照（ここでは簡略化）

-- 3. BOM：タイヤ本数は 1台当たり 4本（ハンズオンでは WARN。本番で原価計算を止めたい場合は ON VIOLATION FAIL UPDATE）
CREATE OR REFRESH MATERIALIZED VIEW bom_tire_check (
  CONSTRAINT tire_qty_is_4 EXPECT (tire_qty_per_vehicle = 4)
)
COMMENT 'MTO別タイヤ本数チェック'
AS
SELECT mto_code, sum(quantity_per_vehicle) AS tire_qty_per_vehicle, count(*) AS bom_lines
FROM vehicle_bom
WHERE part_category = 'TIRE'
GROUP BY mto_code;

-- 4. BOM：同一 MTO × 部品の重複
CREATE OR REFRESH MATERIALIZED VIEW bom_duplicate_check (
  CONSTRAINT no_duplicate_part EXPECT (line_count = 1)
)
COMMENT 'MTO × 部品の重複チェック'
AS
SELECT mto_code, part_code, count(*) AS line_count, sum(quantity_per_vehicle) AS total_qty
FROM vehicle_bom
GROUP BY mto_code, part_code;
